(** Rails masked authenticity tokens and Campfire's header-only request policy.
    The deployed Rust server uses [verify_request]; token helpers retain Rails
    compatibility for forms and existing sessions. *)

let token_length = 32

let encode bytes = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet bytes

let decode token =
  let token = String.map (function '-' -> '+' | '_' -> '/' | c -> c) token in
  match Base64.decode ~pad:false token with Ok value -> Some value | Error _ -> None

let raw_session_token () = Secure_random.bytes token_length
let session_token () = encode (raw_session_token ())

let hmac key value =
  Mirage_crypto.Hash.SHA256.hmac
    ~key:(Cstruct.of_string key) (Cstruct.of_string value)
  |> Cstruct.to_string

let xor a b =
  if String.length a <> String.length b then invalid_arg "CSRF XOR requires equal lengths";
  String.init (String.length a) (fun i -> Char.chr (Char.code a.[i] lxor Char.code b.[i]))

let mask ?pad raw =
  if String.length raw <> token_length then invalid_arg "CSRF token must be 32 bytes";
  let pad = Option.value pad ~default:(Secure_random.bytes token_length) in
  if String.length pad <> token_length then invalid_arg "CSRF pad must be 32 bytes";
  encode (pad ^ xor pad raw)

let unmask token =
  match decode token with
  | Some value when String.length value = token_length -> Some (`Raw value)
  | Some value when String.length value = 2 * token_length ->
      Some (`Masked (xor (String.sub value 0 token_length) (String.sub value token_length token_length)))
  | _ -> None

let real_token session_token =
  match decode session_token with Some raw when String.length raw = token_length -> Some raw | _ -> None

let global_token session_token = Option.map (fun raw -> hmac raw "!real_csrf_token") (real_token session_token)
let global_masked ?pad session_token = Option.map (mask ?pad) (global_token session_token)

let normalize_path path =
  let len = String.length path in
  if len > 1 && path.[len - 1] = '/' then String.sub path 0 (len - 1) else path

let form_action_path ~page_path action =
  let action = if action = "" then page_path else action in
  let uri = Uri.of_string action in
  let path = Uri.path uri in
  let path =
    if path = "" then page_path
    else if path.[0] = '/' then path
    else
      page_path ^ "/" ^
      (if String.starts_with ~prefix:"./" path then String.sub path 2 (String.length path - 2) else path) in
  normalize_path path

let per_form_token session_token ~path ~method_ =
  Option.map (fun raw -> hmac raw (normalize_path path ^ "#" ^ String.lowercase_ascii method_))
    (real_token session_token)

let form_masked ?pad session_token ~page_path ~action ~method_ =
  let path = form_action_path ~page_path action in
  Option.map (mask ?pad) (per_form_token session_token ~path ~method_)

let valid_token ~session_token ~token ~path ~method_ =
  match real_token session_token, unmask token with
  | Some real, Some (`Raw supplied) -> Eqaf.equal supplied real
  | Some real, Some (`Masked supplied) ->
      Eqaf.equal supplied real ||
      Eqaf.equal supplied (hmac real "!real_csrf_token") ||
      Eqaf.equal supplied (hmac real (normalize_path path ^ "#" ^ String.lowercase_ascii method_))
  | _ -> false

type request = {
  method_ : string;
  origin : string option;
  base_url : string;
  sec_fetch_site : string option;
  ssl : bool;
  force_ssl : bool;
  origin_check : bool;
}

type rejection = { status : int; message : string; commit_cookies : bool }

let reject message = Error { status = 422; message; commit_cookies = false }

let valid_origin ~origin ~base_url =
  match origin with
  | None -> Ok true
  | Some "null" -> Error "The browser returned a 'null' origin"
  | Some value -> Ok (value = base_url)

let verify_request request =
  let method_ = String.uppercase_ascii request.method_ in
  if method_ = "GET" || method_ = "HEAD" then Ok (method_ = "GET")
  else
    let origin = if request.origin_check then valid_origin ~origin:request.origin ~base_url:request.base_url else Ok true in
    match origin with
    | Error message -> reject message
    | Ok false ->
        reject (Printf.sprintf "HTTP Origin header (%s) didn't match request.base_url (%s)"
          (Option.value request.origin ~default:"") request.base_url)
    | Ok true ->
        (match request.sec_fetch_site with
         | Some ("same-origin" | "same-site") -> Ok false
         | None when not request.ssl && not request.force_ssl -> Ok false
         | Some "cross-site" -> reject "Sec-Fetch-Site header (cross-site) indicates a cross-site request"
         | None -> reject "Sec-Fetch-Site header is missing or invalid (None)"
         | Some site -> reject (Printf.sprintf "Sec-Fetch-Site header is missing or invalid (Some %S)" site))

let verify_response ~marked_for_same_origin_verification ~content_type ~xhr =
  let javascript = match content_type with
    | Some value -> String.starts_with ~prefix:"text/javascript" value ||
        String.starts_with ~prefix:"application/javascript" value
    | None -> false in
  if marked_for_same_origin_verification && javascript && not xhr then
    reject "Security warning: an embedded <script> tag on another site requested protected JavaScript"
  else Ok ()

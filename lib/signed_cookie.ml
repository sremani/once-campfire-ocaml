(** Rails [cookies.signed] wire payloads. HTTP cookie attributes are handled elsewhere. *)

let key secret_key_base =
  Key_generator.derive ~secret_key_base ~salt:"signed cookie" ~length:64

let signature secret payload =
  Mirage_crypto.Hash.SHA1.hmac
    ~key:(Cstruct.of_string secret) (Cstruct.of_string payload)
  |> Cstruct.to_hex_string

let html_safe_json value =
  let raw = Yojson.Basic.to_string value in
  let out = Buffer.create (String.length raw) in
  String.iter (function
    | '<' -> Buffer.add_string out "\\u003c"
    | '>' -> Buffer.add_string out "\\u003e"
    | '&' -> Buffer.add_string out "\\u0026"
    | c -> Buffer.add_char out c) raw;
  Buffer.contents out

let generate ~secret_key_base ~name ~value ~expires_at =
  let dumped = html_safe_json (`String value) in
  let message = Base64.encode_string dumped in
  let expiry = match expires_at with None -> `Null | Some value -> `String value in
  let envelope = `Assoc ["_rails", `Assoc [
      "message", `String message;
      "exp", expiry;
      "pur", `String ("cookie." ^ name)]]
    |> html_safe_json in
  let payload = Base64.encode_string envelope in
  payload ^ "--" ^ signature (key secret_key_base) payload

let parse_time value =
  match Ptime.of_rfc3339 value with
  | Ok (time, _, _) -> Some time
  | Error _ -> None

let not_expired ~now = function
  | `Null -> true
  | `String expires_at ->
      (match parse_time now, parse_time expires_at with
       | Some now, Some expiry -> Ptime.compare now expiry < 0
       | _ -> false)
  | _ -> false

let parse_json value = try Some (Yojson.Basic.from_string value) with _ -> None

let verify_value ~secret_key_base ~name ~raw ~now =
  let len = String.length raw in
  if len < 43 || String.sub raw (len - 42) 2 <> "--" then None
  else
    let payload = String.sub raw 0 (len - 42) in
    let supplied = String.sub raw (len - 40) 40 in
    let expected = signature (key secret_key_base) payload in
    if not (Eqaf.equal supplied expected) then None
    else
      match Base64.decode payload with
      | Error _ -> None
      | Ok decoded ->
          (match parse_json decoded with
           | Some (`Assoc ["_rails", `Assoc fields]) when List.mem_assoc "message" fields ->
               let field key = List.assoc_opt key fields in
               let purpose_ok =
                 match field "pur" with
                 | Some (`String value) -> value = "cookie." ^ name
                 | Some `Null | None -> true
                 | _ -> false
               in
               if not purpose_ok || not (not_expired ~now (Option.value (field "exp") ~default:`Null))
               then None
               else (match field "message" with
                 | Some (`String value) ->
                     (match Base64.decode value with
                      | Ok dumped -> parse_json dumped
                      | Error _ -> None)
                 | _ -> None)
           | Some value -> Some value
           | None -> None)

let verify ~secret_key_base ~name ~raw ~now =
  match verify_value ~secret_key_base ~name ~raw ~now with
  | Some (`String value) -> Some value
  | _ -> None

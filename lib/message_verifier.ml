(** Rails ActiveSupport::MessageVerifier wire format, shared by signed IDs, SGIDs,
    and Turbo streams. The optional old keys are accepted only for callers which
    explicitly configure a secret rotation. *)

type digest = Sha1 | Sha256
type encoding = Strict | Url_safe | Url_safe_padded

type key = { secret : string; digest : digest }

let key ~secret_key_base ~salt ~digest =
  { secret = Key_generator.derive ~secret_key_base ~salt ~length:64; digest }

let signature key encoded =
  let data = Cstruct.of_string encoded and secret = Cstruct.of_string key.secret in
  (match key.digest with
   | Sha1 -> Mirage_crypto.Hash.SHA1.hmac ~key:secret data
   | Sha256 -> Mirage_crypto.Hash.SHA256.hmac ~key:secret data)
  |> Cstruct.to_hex_string

let replace_alphabet s ~url_safe =
  String.map (function
    | '+' when url_safe -> '-'
    | '/' when url_safe -> '_'
    | '-' when not url_safe -> '+'
    | '_' when not url_safe -> '/'
    | c -> c) s

let strip_padding s =
  let rec length n = if n > 0 && s.[n - 1] = '=' then length (n - 1) else n in
  String.sub s 0 (length (String.length s))

let encode encoding bytes =
  let strict = Base64.encode_string bytes in
  match encoding with
  | Strict -> strict
  | Url_safe -> strip_padding (replace_alphabet strict ~url_safe:true)
  | Url_safe_padded -> replace_alphabet strict ~url_safe:true

let decode encoded =
  let valid = String.for_all (function
    | 'A'..'Z' | 'a'..'z' | '0'..'9' | '+' | '/' | '-' | '_' | '=' -> true
    | _ -> false) encoded in
  if not valid then None
  else
    let strict = replace_alphabet encoded ~url_safe:false in
    let padded = strict ^ String.make ((4 - String.length strict mod 4) mod 4) '=' in
    match Base64.decode padded with Ok bytes -> Some bytes | Error _ -> None

let sign ~key ~encoding payload =
  let encoded = encode encoding payload in
  encoded ^ "--" ^ signature key encoded

let signed_payload ~key raw =
  let hex_len = match key.digest with Sha1 -> 40 | Sha256 -> 64 in
  let len = String.length raw in
  if len <= hex_len + 2 then None
  else
    let boundary = len - hex_len - 2 in
    if String.sub raw boundary 2 <> "--" then None
    else
      let encoded = String.sub raw 0 boundary in
      let supplied = String.sub raw (boundary + 2) hex_len in
      if String.trim encoded = "" || not (Eqaf.equal supplied (signature key encoded))
      then None else decode encoded

let json_string = Yojson.Basic.to_string

let serialize ?purpose ?expires_at value =
  if purpose = None && expires_at = None then json_string value
  else
    let fields = ["data", value] in
    let fields = match expires_at with None -> fields | Some t -> fields @ ["exp", `String t] in
    let fields = match purpose with None -> fields | Some p -> fields @ ["pur", `String p] in
    json_string (`Assoc ["_rails", `Assoc fields])

let serialize_raw ?purpose ?expires_at data_json =
  if purpose = None && expires_at = None then data_json
  else
    let expiry = match expires_at with
      | None -> "" | Some value -> ",\"exp\":" ^ json_string (`String value) in
    let purpose = match purpose with
      | None -> "" | Some value -> ",\"pur\":" ^ json_string (`String value) in
    "{\"_rails\":{\"data\":" ^ data_json ^ expiry ^ purpose ^ "}}"

let parse_json s = try Some (Yojson.Basic.from_string s) with _ -> None

let valid_expiry ~now = function
  | None | Some `Null -> true
  | Some (`String expiry) ->
      (match Ptime.of_rfc3339 now, Ptime.of_rfc3339 expiry with
       | Ok (now, _, _), Ok (expiry, _, _) -> Ptime.compare now expiry < 0
       | _ -> false)
  | _ -> false

let string_of_purpose = function
  | Some (`String s) -> s
  | Some (`Int i) -> string_of_int i
  | Some (`Bool b) -> string_of_bool b
  | _ -> ""

let value ?purpose ~now ~allow_marshal decoded =
  let parse_dumped dumped =
    if allow_marshal && String.length dumped >= 2 && String.sub dumped 0 2 = "\004\008" then
      Option.map (fun s -> `String s) (Rails_format.load_marshaled_string dumped)
    else parse_json dumped
  in
  match parse_json decoded with
  | Some (`Assoc fields as raw) ->
      (match List.assoc_opt "_rails" fields with
       | Some (`Assoc rails) ->
           if not (valid_expiry ~now (List.assoc_opt "exp" rails)) ||
              string_of_purpose (List.assoc_opt "pur" rails) <> Option.value purpose ~default:""
           then None
           else (match List.assoc_opt "message" rails with
             | Some (`String encoded) -> Option.bind (decode encoded) parse_dumped
             | _ -> List.assoc_opt "data" rails)
       | Some _ -> None
       | None -> if purpose = None then Some raw else None)
  | Some raw -> if purpose = None then Some raw else None
  | None -> if allow_marshal then parse_dumped decoded else None

let verify ?purpose ~now ~allow_marshal ~keys raw =
  let rec loop = function
    | [] -> None
    | key :: rest ->
        (match signed_payload ~key raw with
         | None -> loop rest
         | Some payload -> value ?purpose ~now ~allow_marshal payload)
  in loop keys

(* Rails wire formats used by signed values and metadata envelopes. *)
type serializer = Null | Json | Json_with_fallback of { allow_marshal : bool }
type error = Invalid_message | Invalid_signature | Expired | Purpose_mismatch

let strict_encode = Base64.encode_string
let urlsafe_encode ?(pad=false) s = Base64.encode_string ~pad ~alphabet:Base64.uri_safe_alphabet s

let strict_decode s =
  match Base64.decode ~pad:true s with
  | Ok v when Base64.encode_string v = s -> Some v
  | _ -> None

let urlsafe_decode s =
  let s = String.map (function '-' -> '+' | '_' -> '/' | c -> c) s in
  let s = if not (String.ends_with ~suffix:"=" s) then
      s ^ String.make ((4 - String.length s mod 4) mod 4) '=' else s in
  strict_decode s

let load_marshaled_string s =
  let n = String.length s in
  if n < 4 || s.[0] <> '\004' || s.[1] <> '\008' then None else
  let i = ref 2 in
  if !i < n && s.[!i] = 'I' then incr i;
  if !i >= n || s.[!i] <> '"' then None else begin
    incr i;
    if !i >= n then None else
    let first = Char.code s.[!i] in incr i;
    let signed = if first >= 128 then first - 256 else first in
    let length =
      if signed = 0 then Some 0
      else if signed >= 5 then Some (signed-5)
      else if signed <= -5 then Some (signed+5)
      else if signed > 0 then begin
        let count = signed in
        if !i + count > n then None else begin
          let v = ref 0L in
          for j=0 to count-1 do
            v := Int64.logor !v (Int64.shift_left (Int64.of_int (Char.code s.[!i+j])) (8*j))
          done;
          i := !i+count;
          if Int64.compare !v (Int64.of_int max_int) > 0 then None else Some (Int64.to_int !v)
        end
      end else None in
    match length with
    | Some len when len >= 0 && len <= n - !i -> Some (String.sub s !i len)
    | _ -> None
  end

let json_quote s =
  let b = Buffer.create (String.length s+2) in
  Buffer.add_char b '"';
  String.iter (fun c -> match c with
    | '"' -> Buffer.add_string b "\\\"" | '\\' -> Buffer.add_string b "\\\\"
    | '\b' -> Buffer.add_string b "\\b" | '\012' -> Buffer.add_string b "\\f"
    | '\n' -> Buffer.add_string b "\\n" | '\r' -> Buffer.add_string b "\\r"
    | '\t' -> Buffer.add_string b "\\t"
    | c when Char.code c < 0x20 -> Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
    | c -> Buffer.add_char b c) s;
  Buffer.add_char b '"'; Buffer.contents b

let json_float f =
  if Float.is_nan f || Float.is_infinite f then "null"
  else if f = 0. then if Float.sign_bit f then "-0.0" else "0.0"
  else begin
    let sci = Ruby_compat.float_to_s (abs_float f) in
    let sign = if f < 0. then "-" else "" in
    let exponent, digits =
      match String.index_opt sci 'e' with
      | Some pos ->
        let mantissa = String.sub sci 0 pos in
        int_of_string (String.sub sci (pos+1) (String.length sci-pos-1)),
        String.to_seq mantissa |> List.of_seq |> List.filter (fun c -> c <> '.') |> List.to_seq |> String.of_seq
      | None ->
        let point = match String.index_opt sci '.' with Some p -> p | None -> String.length sci in
        let all = String.to_seq sci |> List.of_seq |> List.filter (fun c -> c <> '.') |> List.to_seq |> String.of_seq in
        let k = ref 0 in while !k < String.length all && all.[!k]='0' do incr k done;
        let digits = if !k = String.length all then "0" else String.sub all !k (String.length all - !k) in
        point - !k - 1, digits in
    let last = ref (String.length digits) in
    while !last > 1 && digits.[!last-1] = '0' do decr last done;
    let digits = String.sub digits 0 !last in
    let k = exponent + 1 - String.length digits in
    sign ^ (if k >= 0 && exponent < 15 then digits ^ String.make k '0' ^ ".0"
    else if k < 0 && (k > -7 || abs exponent < 10) then
      let point = exponent+1 in
      if point <= 0 then "0." ^ String.make (-point) '0' ^ digits
      else String.sub digits 0 point ^ "." ^ String.sub digits point (String.length digits-point)
    else let frac = if String.length digits=1 then "" else "." ^ String.sub digits 1 (String.length digits-1) in
      String.make 1 digits.[0] ^ frac ^ "e" ^ (if exponent < 0 then "-" else "+") ^ string_of_int (abs exponent))
  end

let rec generate : Yojson.Safe.t -> string = function
  | `Null -> "null" | `Bool true -> "true" | `Bool false -> "false"
  | `Int n -> string_of_int n | `Intlit s -> s | `Float f -> json_float f
  | `String s -> json_quote s
  | `List xs -> "[" ^ String.concat "," (List.map generate xs) ^ "]"
  | `Assoc xs -> "{" ^ String.concat "," (List.map (fun (k,v) -> json_quote k ^ ":" ^ generate v) xs) ^ "}"
  | `Tuple xs -> "[" ^ String.concat "," (List.map generate xs) ^ "]"
  | `Variant (tag, None) -> json_quote tag
  | `Variant (tag, Some v) -> generate (`List [`String tag; v])

let escape_html_entities s =
  let b = Buffer.create (String.length s) in
  String.iter (function
    | '<' -> Buffer.add_string b "\\u003c"
    | '>' -> Buffer.add_string b "\\u003e"
    | '&' -> Buffer.add_string b "\\u0026"
    | c -> Buffer.add_char b c) s;
  Buffer.contents b

let encode v = escape_html_entities (generate v)
let parse s =
  if not (String.is_valid_utf_8 s) then None
  else try Some (Yojson.Safe.from_string s) with _ -> None

let utf8_lossy s =
  if String.is_valid_utf_8 s then s else
  let b = Buffer.create (String.length s) and i = ref 0 in
  while !i < String.length s do
    let d = String.get_utf_8_uchar s !i in
    Buffer.add_utf_8_uchar b (Uchar.utf_decode_uchar d);
    i := !i + Uchar.utf_decode_length d
  done;
  Buffer.contents b

let iso8601_millis t =
  let t = Ptime.truncate ~frac_s:3 t in
  Ptime.to_rfc3339 ~frac_s:3 ~tz_offset_s:0 t

let dump serializer value = match serializer, value with
  | Null, `String s -> s
  | Null, _ -> invalid_arg "Null serializer accepts only strings"
  | Json, v -> generate v
  | Json_with_fallback _, v -> encode v

let load serializer bytes =
  match serializer with
  | Null -> if String.is_valid_utf_8 bytes then Ok (`String bytes) else Error Invalid_message
  | Json when bytes = "" -> Ok `Null
  | Json -> (match parse bytes with Some v -> Ok v | None -> Error Invalid_message)
  | Json_with_fallback {allow_marshal} ->
    if String.starts_with ~prefix:"\004\008" bytes then
      if not allow_marshal then Error Invalid_message else
      (match load_marshaled_string bytes with Some s -> Ok (`String (utf8_lossy s)) | None -> Error Invalid_message)
    else (match parse bytes with Some v -> Ok v | None -> Error Invalid_message)

let serialize_dumped_with_metadata serializer dumped ~purpose ~expires_at =
  if purpose = None && expires_at = None then dumped else
  let expiration = Option.map (fun t -> `String (iso8601_millis t)) expires_at in
  let purpose_value = Option.map (fun p -> `String p) purpose in
  let field f = function None -> "" | Some v -> ",\"" ^ f ^ "\":" ^ (match serializer with Json -> generate v | _ -> encode v) in
  match serializer with
  | Null ->
    let msg = `String (strict_encode dumped) in
    let nullable = function None -> `Null | Some v -> v in
    "{\"_rails\":{\"message\":" ^ encode msg ^ ",\"exp\":" ^ encode (nullable expiration) ^
    ",\"pur\":" ^ encode (nullable purpose_value) ^ "}}"
  | Json | Json_with_fallback _ ->
    "{\"_rails\":{\"data\":" ^ dumped ^ field "exp" expiration ^ field "pur" purpose_value ^ "}}"

let serialize_with_metadata serializer value ~purpose ~expires_at =
  serialize_dumped_with_metadata serializer (dump serializer value) ~purpose ~expires_at

let ruby_to_s = function
  | None | Some `Null -> ""
  | Some (`String s) -> s
  | Some (`Int n) -> string_of_int n
  | Some (`Intlit s) -> s
  | Some (`Float f) -> Ruby_compat.float_to_s f
  | Some (`Bool b) -> string_of_bool b
  | Some _ -> "\000"

let extract value ~purpose ~now =
  let assoc = function `Assoc xs -> Some xs | _ -> None in
  let rails = Option.bind (assoc value) (fun xs -> List.assoc_opt "_rails" xs) in
  match Option.bind rails assoc with
  | None -> Error Invalid_message
  | Some fields ->
    let exp = List.assoc_opt "exp" fields in
    let expiration = match exp with
      | None | Some `Null -> Ok ()
      | Some (`String s) -> (match Ptime.of_rfc3339 s with
        | Ok (t,_,_) -> if Ptime.compare now t >= 0 then Error Expired else Ok ()
        | Error _ -> Error Invalid_message)
      | _ -> Error Invalid_message in
    match expiration with
    | Error e -> Error e
    | Ok () -> if ruby_to_s (List.assoc_opt "pur" fields) <> Option.value ~default:"" purpose
      then Error Purpose_mismatch else Ok fields

let deserialize_with_metadata serializer bytes ~purpose ~now ~decode_legacy_message =
  if String.starts_with ~prefix:"{\"_rails\":{\"message\":" bytes then
    match parse bytes with
    | None -> Error Invalid_signature
    | Some envelope ->
      (match extract envelope ~purpose ~now with
      | Error e -> Error e
      | Ok fields ->
        match List.assoc_opt "message" fields with
        | Some (`String message) ->
          (match decode_legacy_message message with
          | None -> Error Invalid_signature
          | Some data -> load serializer data)
        | _ -> Error Invalid_signature)
  else
    match load serializer bytes with
    | Error e -> Error e
    | Ok value ->
      match value with
      | `Assoc fields when List.mem_assoc "_rails" fields ->
        (match extract value ~purpose ~now with
        | Error e -> Error e
        | Ok fields -> Ok (Option.value ~default:`Null (List.assoc_opt "data" fields)))
      | _ -> if purpose = None then Ok value else Error Purpose_mismatch

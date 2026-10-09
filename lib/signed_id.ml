(** ActiveRecord::SignedId. [model] is the record's base class name. *)

open Message_verifier

let salt = "active_record/signed_id"

let underscore name =
  let normalized =
    let b = Buffer.create (String.length name) in
    let rec add i =
      if i < String.length name then
        if i + 1 < String.length name && name.[i] = ':' && name.[i + 1] = ':'
        then (Buffer.add_char b '/'; add (i + 2))
        else (Buffer.add_char b name.[i]; add (i + 1))
    in add 0; Buffer.contents b
  in
  let b = Buffer.create (String.length normalized + 4) in
  String.iteri (fun i c ->
    if c >= 'A' && c <= 'Z' then begin
      if i > 0 then begin
        let previous = normalized.[i - 1] in
        let after_lower_or_digit =
          (previous >= 'a' && previous <= 'z') ||
          (previous >= '0' && previous <= '9') in
        let acronym_end = previous >= 'A' && previous <= 'Z' &&
          i + 1 < String.length normalized &&
          normalized.[i + 1] >= 'a' && normalized.[i + 1] <= 'z' in
        if after_lower_or_digit || acronym_end then Buffer.add_char b '_'
      end;
      Buffer.add_char b (Char.lowercase_ascii c)
    end else Buffer.add_char b (if c = '-' then '_' else c)) normalized;
  Buffer.contents b

let combine_purposes ~model purpose =
  let base = underscore model in
  match purpose with
  | Some p when String.trim p <> "" -> base ^ "/" ^ p
  | _ -> base

let generate ~secret_key_base ~model ~id ~purpose ~expires_at =
  let key = Message_verifier.key ~secret_key_base ~salt ~digest:Sha256 in
  let payload = Message_verifier.serialize
      ~purpose:(combine_purposes ~model purpose) ?expires_at (`Int id) in
  Message_verifier.sign ~key ~encoding:Url_safe payload

let decimal_id value =
  let value = String.trim value in
  let first = if String.length value > 0 && value.[0] = '-' then 1 else 0 in
  if first >= String.length value then None
  else if not (String.for_all (function '0'..'9' -> true | _ -> false)
      (String.sub value first (String.length value - first))) then None
  else try Some (int_of_string value) with _ -> None

let verify ?(rotated_secret_key_bases=[]) ~secret_key_base ~model ~raw ~purpose ~now () =
  let mk secret digest = Message_verifier.key ~secret_key_base:secret ~salt ~digest in
  let keys =
    [mk secret_key_base Sha256; mk secret_key_base Sha1] @
    List.concat_map (fun secret -> [mk secret Sha256; mk secret Sha1]) rotated_secret_key_bases
  in
  match Message_verifier.verify
      ~purpose:(combine_purposes ~model purpose) ~now ~allow_marshal:true ~keys raw with
  | Some (`Int id) -> Some id
  | Some (`String id) -> decimal_id id
  | _ -> None

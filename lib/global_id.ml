(** GlobalID and SignedGlobalID payload handling. Looking up a record and enforcing
    model restrictions belongs to the caller. *)

open Message_verifier

type t = { app : string; model_name : string; id : string }

let app = "campfire"
let salt = "signed_global_ids"
let attachable_purpose = "attachable"
let default_purpose = "default"

let make ~model_name ~id = { app; model_name; id }
let to_string gid = "gid://" ^ gid.app ^ "/" ^ gid.model_name ^ "/" ^ gid.id

let parse raw =
  let prefix = "gid://" in
  if not (String.starts_with ~prefix raw) then None
  else
    let rest = String.sub raw (String.length prefix) (String.length raw - String.length prefix) in
    let without_query = match String.index_opt rest '?' with
      | None -> rest | Some i -> String.sub rest 0 i in
    match String.split_on_char '/' without_query with
    | app :: model_name :: id_parts when app <> "" && model_name <> "" && id_parts <> [] ->
        let id = String.concat "/" id_parts in
        if id = "" then None else Some { app; model_name; id }
    | _ -> None

let to_param gid = Message_verifier.encode Url_safe (to_string gid)
let from_param raw = Option.bind (Message_verifier.decode raw) parse

let verifier_key secret_key_base =
  Message_verifier.key ~secret_key_base ~salt ~digest:Sha1

let sgid ~secret_key_base ~gid ~purpose ~expires_at =
  let payload = Message_verifier.serialize ~purpose ?expires_at (`String (to_string gid)) in
  Message_verifier.sign ~key:(verifier_key secret_key_base)
    ~encoding:Url_safe_padded payload

let attachable_sgid ~secret_key_base ~gid =
  let payload = Message_verifier.serialize ~purpose:attachable_purpose
      (`String (to_string gid ^ "?expires_in")) in
  Message_verifier.sign ~key:(verifier_key secret_key_base)
    ~encoding:Url_safe_padded payload

let legacy_self_validated ~purpose ~now = function
  | `Assoc fields when List.mem_assoc "gid" fields ->
      let purpose_ok =
        Message_verifier.string_of_purpose (List.assoc_opt "purpose" fields) = purpose in
      let expiry_ok =
        Message_verifier.valid_expiry ~now (List.assoc_opt "expires_at" fields) in
      if purpose_ok && expiry_ok then List.assoc_opt "gid" fields else None
  | _ -> None

let locate_signed ?(rotated_secret_key_bases=[]) ~secret_key_base ~raw ~purpose ~now () =
  let keys = verifier_key secret_key_base :: List.map verifier_key rotated_secret_key_bases in
  let verified = Message_verifier.verify ~purpose ~now ~allow_marshal:true ~keys raw in
  let data = match verified with
    | Some v -> Some v
    | None ->
        Option.bind
          (Message_verifier.verify ~now ~allow_marshal:true ~keys raw)
          (legacy_self_validated ~purpose ~now)
  in
  match data with
  | Some (`String uri) -> (match parse uri with Some gid -> Some gid | None -> from_param uri)
  | _ -> None

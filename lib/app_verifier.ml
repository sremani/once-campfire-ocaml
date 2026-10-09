(** Rails.application.message_verifier(name), used by Active Storage. *)

open Message_verifier

let key ~secret_key_base ~name =
  Message_verifier.key ~secret_key_base ~salt:name ~digest:Sha1

let generate_raw ~secret_key_base ~name ~data_json ~purpose ~expires_at =
  let payload = Message_verifier.serialize_raw ?purpose ?expires_at data_json in
  Message_verifier.sign ~key:(key ~secret_key_base ~name)
    ~encoding:Strict payload

let verify_raw ?(rotated_secret_key_bases=[]) ~secret_key_base ~name ~raw ~purpose ~now () =
  let keys = key ~secret_key_base ~name ::
    List.map (fun secret_key_base -> key ~secret_key_base ~name)
      rotated_secret_key_bases in
  match Message_verifier.verify ?purpose ~now ~allow_marshal:true ~keys raw with
  | None -> None
  | Some data ->
      let safe = Yojson.Safe.from_string (Yojson.Basic.to_string data) in
      Some (Rails_format.encode safe)

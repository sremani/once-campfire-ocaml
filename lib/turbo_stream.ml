(** Turbo::StreamsChannel signed stream names. *)

open Message_verifier

let salt = "turbo/signed_stream_verifier_key"

let key secret_key_base =
  Message_verifier.key ~secret_key_base ~salt ~digest:Sha256

let stream_name parts = String.concat ":" parts

let signed_stream_name ~secret_key_base parts =
  Message_verifier.sign ~key:(key secret_key_base) ~encoding:Strict
    (Yojson.Basic.to_string (`String (stream_name parts)))

let verified_stream_name ?(rotated_secret_key_bases=[]) ~secret_key_base raw =
  let keys = key secret_key_base :: List.map key rotated_secret_key_bases in
  match Message_verifier.verify ~now:"1970-01-01T00:00:00Z"
      ~allow_marshal:false ~keys raw with
  | Some (`String name) -> Some name
  | Some (`Int n) -> Some (string_of_int n)
  | _ -> None

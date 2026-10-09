(** VAPID identification using the installed P-256 ES256 implementation. *)

type error = Missing | Invalid_public_key | Invalid_private_key | Mismatched
type t = { subject : string; private_key : Mirage_crypto_ec.P256.Dsa.priv;
           public_key : string }

let cs = Cstruct.of_string
let string = Cstruct.to_string
let encode64 = Web_push_crypto.encode64

let left_pad_32 bytes =
  if String.length bytes > 32 then None else
  Some (String.make (32-String.length bytes) '\000' ^ bytes)

let create ~subject ~public_key ~private_key =
  let decode = Web_push_crypto.decode64 in
  if public_key = "" then Error Invalid_public_key else
  if private_key = "" then Error Invalid_private_key else
  match decode public_key with
  | Error _ -> Error Invalid_public_key
  | Ok public_bytes ->
    (match Mirage_crypto_ec.P256.Dsa.pub_of_cstruct (cs public_bytes) with
     | Error _ -> Error Invalid_public_key
     | Ok public ->
       match decode private_key with
       | Error _ -> Error Invalid_private_key
       | Ok private_bytes ->
         match Option.bind (left_pad_32 private_bytes)
           (fun bytes -> Result.to_option (Mirage_crypto_ec.P256.Dsa.priv_of_cstruct (cs bytes))) with
         | None -> Error Invalid_private_key
         | Some private_key ->
           let expected = Mirage_crypto_ec.P256.Dsa.pub_of_priv private_key
             |> Mirage_crypto_ec.P256.Dsa.pub_to_cstruct |> string in
           let actual = Mirage_crypto_ec.P256.Dsa.pub_to_cstruct public |> string in
           if expected <> actual then Error Mismatched else
           Ok {subject; private_key; public_key=public_bytes})

let from_options ~subject ~public_key ~private_key = match public_key,private_key with
  | Some public_key,Some private_key -> create ~subject ~public_key ~private_key
  | _ -> Error Missing

let authorization t ~audience ~now =
  let header = {|{"typ":"JWT","alg":"ES256"}|} in
  let claims = Yojson.Basic.to_string (`Assoc [
    "aud",`String audience; "exp",`Int (now+43200); "sub",`String t.subject]) in
  let signing_input = encode64 header ^ "." ^ encode64 claims in
  let digest = Mirage_crypto.Hash.SHA256.digest (cs signing_input) in
  let r,s = Mirage_crypto_ec.P256.Dsa.sign ~key:t.private_key digest in
  let signature = string r ^ string s in
  "vapid t=" ^ signing_input ^ "." ^ encode64 signature ^ ",k=" ^ encode64 t.public_key

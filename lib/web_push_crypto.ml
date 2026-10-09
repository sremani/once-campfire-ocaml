(** RFC 8291 encryption with the web-push gem's RFC 8188 framing. *)

type error = Argument of string | Invalid_key of string

let encode64 bytes = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet bytes

let decode64 value =
  let normalized = String.map (function '-' -> '+' | '_' -> '/' | c -> c) value in
  let bare = String.trim normalized in
  let bare = String.sub bare 0 (match String.index_opt bare '=' with None -> String.length bare | Some i -> i) in
  if String.length bare mod 4 = 1 then Error (Argument "invalid base64") else
  match Base64.decode ~pad:false bare with
  | Ok bytes -> Ok bytes
  | Error _ -> Error (Argument "invalid base64")

let cs = Cstruct.of_string
let string = Cstruct.to_string
let hkdf ~salt ~ikm ~info length =
  let prk = Mirage_crypto.Hash.SHA256.hmac ~key:(cs salt) (cs ikm) in
  let output = Buffer.create length in
  let rec expand previous counter =
    if Buffer.length output >= length then () else (
      let next = Mirage_crypto.Hash.SHA256.hmac ~key:prk
        (Cstruct.concat [previous; cs info; cs (String.make 1 (Char.chr counter))]) in
      Buffer.add_string output (string next);
      expand next (counter + 1)) in
  expand Cstruct.empty 1;
  String.sub (Buffer.contents output) 0 length

let strip_leading_zeros bytes =
  let rec start i = if i < String.length bytes && bytes.[i] = '\000' then start (i+1) else i in
  let i = start 0 in String.sub bytes i (String.length bytes-i)

let int32_be n = String.init 4 (fun i -> Char.chr ((n lsr ((3-i)*8)) land 255))

let rng_mutex = Mutex.create ()
let ensure_rng () =
  Mutex.lock rng_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock rng_mutex) (fun () ->
    try ignore (Mirage_crypto_rng.default_generator ()) with
    | Mirage_crypto_rng.No_default_generator ->
      Mirage_crypto_rng_unix.initialize (module Mirage_crypto_rng.Fortuna))

let encrypt_with ~message ~p256dh ~auth ~server_private ~salt ?record_size ?(padding="\002\000") () =
  let ( >>= ) = Result.bind in
  if message = "" then Error (Argument "message cannot be blank") else
  if p256dh = "" then Error (Argument "p256dh cannot be blank") else
  if auth = "" then Error (Argument "auth cannot be blank") else
  if String.length salt <> 16 then Error (Argument "salt must have 16 bytes") else
  decode64 p256dh >>= fun client_bytes ->
  decode64 auth >>= fun auth_bytes ->
  let client_bytes = strip_leading_zeros client_bytes in
  match Mirage_crypto_ec.P256.Dh.secret_of_cs (cs server_private) with
  | Error _ -> Error (Argument "invalid server private key")
  | Ok (secret, server_public) ->
    (match Mirage_crypto_ec.P256.Dh.key_exchange secret (cs client_bytes) with
     | Error _ -> Error (Invalid_key "invalid encoding")
     | Ok shared ->
       let server_public = string server_public in
       let prk = hkdf ~salt:auth_bytes ~ikm:(string shared)
         ~info:("WebPush: info\000" ^ client_bytes ^ server_public) 32 in
       let key = hkdf ~salt ~ikm:prk ~info:"Content-Encoding: aes128gcm\000" 16 in
       let nonce = hkdf ~salt ~ikm:prk ~info:"Content-Encoding: nonce\000" 12 in
       let cipher = Mirage_crypto.Cipher_block.AES.GCM.authenticate_encrypt
         ~key:(Mirage_crypto.Cipher_block.AES.GCM.of_secret (cs key))
         ~nonce:(cs nonce) (cs (message ^ padding)) |> string in
       if String.length cipher > 4096 then Error (Argument "encrypted payload is too big") else
       let size = Option.value ~default:(String.length cipher) record_size in
       Ok (salt ^ int32_be size ^ String.make 1 (Char.chr (String.length server_public)) ^ server_public ^ cipher))

let encrypt ~message ~p256dh ~auth =
  ensure_rng ();
  (* DSA and DH use the same P-256 scalar format. *)
  let private_key,_ = Mirage_crypto_ec.P256.Dsa.generate () in
  encrypt_with ~message ~p256dh ~auth
    ~server_private:(string (Mirage_crypto_ec.P256.Dsa.priv_to_cstruct private_key))
    ~salt:(string (Mirage_crypto_rng.generate 16)) ()

(** Receiver-side decryption for the pinned gem and RFC vectors. *)
let decrypt ~ciphertext ~receiver_private ~auth =
  let ( >>= ) = Result.bind in
  if String.length ciphertext < 21 then Error (Argument "short encrypted payload") else
  let salt=String.sub ciphertext 0 16 in
  let record_size=ref 0 in
  for i=16 to 19 do
    record_size := (!record_size lsl 8) lor Char.code ciphertext.[i]
  done;
  let key_length=Char.code ciphertext.[20] in
  if String.length ciphertext < 21+key_length+16 then Error (Argument "short encrypted payload") else
  let server_public=String.sub ciphertext 21 key_length in
  let body=String.sub ciphertext (21+key_length)
    (String.length ciphertext-21-key_length) in
  decode64 auth >>= fun auth_bytes ->
  match Mirage_crypto_ec.P256.Dh.secret_of_cs (cs receiver_private) with
  | Error _ -> Error (Argument "invalid receiver private key")
  | Ok (secret,receiver_public) ->
    (match Mirage_crypto_ec.P256.Dh.key_exchange secret (cs server_public) with
     | Error _ -> Error (Invalid_key "invalid encoding")
     | Ok shared ->
       let prk=hkdf ~salt:auth_bytes ~ikm:(string shared)
         ~info:("WebPush: info\000"^string receiver_public^server_public) 32 in
       let key=hkdf ~salt ~ikm:prk ~info:"Content-Encoding: aes128gcm\000" 16 in
       let nonce=hkdf ~salt ~ikm:prk ~info:"Content-Encoding: nonce\000" 12 in
       match Mirage_crypto.Cipher_block.AES.GCM.authenticate_decrypt
         ~key:(Mirage_crypto.Cipher_block.AES.GCM.of_secret (cs key))
         ~nonce:(cs nonce) (cs body) with
       | None -> Error (Argument "invalid encrypted payload")
       | Some plaintext -> Ok (!record_size,string plaintext))

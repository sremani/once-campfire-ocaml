(** Rails [cookies.encrypted] AES-256-GCM payloads. *)

let key secret_key_base =
  Key_generator.derive ~secret_key_base ~salt:"authenticated encrypted cookie" ~length:32
  |> Cstruct.of_string |> Mirage_crypto.Cipher_block.AES.GCM.of_secret

let encrypt_with_iv ~secret_key_base ~name ~value ~expires_at ~iv =
  if String.length iv <> 12 then invalid_arg "AES-GCM cookie IV must be 12 bytes";
  let dumped = Signed_cookie.html_safe_json value in
  let message = Base64.encode_string dumped in
  let expiry = match expires_at with None -> `Null | Some value -> `String value in
  let plaintext = `Assoc ["_rails", `Assoc [
      "message", `String message;
      "exp", expiry;
      "pur", `String ("cookie." ^ name)]]
    |> Signed_cookie.html_safe_json in
  let cipher = Mirage_crypto.Cipher_block.AES.GCM.authenticate_encrypt
      ~key:(key secret_key_base) ~nonce:(Cstruct.of_string iv) (Cstruct.of_string plaintext) in
  let size = Cstruct.length cipher in
  let ciphertext = Cstruct.sub cipher 0 (size - 16) |> Cstruct.to_string in
  let tag = Cstruct.sub cipher (size - 16) 16 |> Cstruct.to_string in
  String.concat "--" (List.map Base64.encode_string [ciphertext; iv; tag])

let encrypt ~secret_key_base ~name ~value ~expires_at =
  encrypt_with_iv ~secret_key_base ~name ~value ~expires_at ~iv:(Secure_random.bytes 12)

let decrypt ~secret_key_base ~name ~raw ~now =
  (* The IV and tag have fixed Base64 lengths. *)
  let len = String.length raw in
  if len < 44 then None
  else
        let tag_start = len - 24 in
        let iv_start = tag_start - 2 - 16 in
        let ciphertext_end = iv_start - 2 in
        if ciphertext_end < 0 || String.sub raw (tag_start - 2) 2 <> "--" ||
           String.sub raw ciphertext_end 2 <> "--" then None
        else
          let decode value = match Base64.decode value with Ok data -> Some data | Error _ -> None in
          let ciphertext = String.sub raw 0 ciphertext_end |> decode in
          let iv = String.sub raw iv_start 16 |> decode in
          let tag = String.sub raw tag_start 24 |> decode in
          match ciphertext, iv, tag with
          | Some ciphertext, Some iv, Some tag when String.length iv = 12 && String.length tag = 16 ->
              let sealed = Cstruct.of_string (ciphertext ^ tag) in
              let plaintext = Mirage_crypto.Cipher_block.AES.GCM.authenticate_decrypt
                  ~key:(key secret_key_base) ~nonce:(Cstruct.of_string iv) sealed in
              (match plaintext with
               | None -> None
               | Some plaintext ->
                   (match Signed_cookie.parse_json (Cstruct.to_string plaintext) with
                    | Some (`Assoc ["_rails", `Assoc fields]) when List.mem_assoc "message" fields ->
                        let field key = List.assoc_opt key fields in
                        let purpose_ok = match field "pur" with
                          | Some (`String value) -> value = "cookie." ^ name
                          | Some `Null | None -> true
                          | _ -> false in
                        if not purpose_ok ||
                           not (Signed_cookie.not_expired ~now (Option.value (field "exp") ~default:`Null))
                        then None
                        else (match field "message" with
                          | Some (`String message) ->
                              (match Base64.decode message with
                               | Ok dumped -> Signed_cookie.parse_json dumped
                               | Error _ -> None)
                          | _ -> None)
                    | Some value -> Some value
                    | None -> None))
          | _ -> None

(** Rails' PBKDF2-HMAC-SHA256 key generator (1000 iterations). *)

let derive ~secret_key_base ~salt ~length =
  Pbkdf.pbkdf2 ~prf:`SHA256
    ~password:(Cstruct.of_string secret_key_base)
    ~salt:(Cstruct.of_string salt)
    ~count:1000 ~dk_len:(Int32.of_int length)
  |> Cstruct.to_string

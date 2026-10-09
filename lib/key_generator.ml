(** Rails' PBKDF2-HMAC-SHA256 key generator (1000 iterations). *)

(* Rails caches generated keys for each salt and length. A process uses one
   secret_key_base in production; include it in this bounded cache's key so
   fixture and embedded callers with different secrets remain independent. *)
let cache : ((string * string * int), string) Hashtbl.t = Hashtbl.create 8
let cache_mutex = Mutex.create ()
let cache_capacity = 64

let derive ~secret_key_base ~salt ~length =
  Mutex.lock cache_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock cache_mutex) (fun () ->
    let key = secret_key_base, salt, length in
    match Hashtbl.find_opt cache key with
    | Some derived -> derived
    | None ->
        let derived =
          Pbkdf.pbkdf2 ~prf:`SHA256
            ~password:(Cstruct.of_string secret_key_base)
            ~salt:(Cstruct.of_string salt)
            ~count:1000 ~dk_len:(Int32.of_int length)
          |> Cstruct.to_string in
        if Hashtbl.length cache < cache_capacity then Hashtbl.add cache key derived;
        derived)

(** Login attempts are process-local in the usual one-server deployment.  A
    multi-process server sets CAMPFIRE_RATE_LIMIT_DIR to share the same window. *)

let limits : (string, int * float) Hashtbl.t = Hashtbl.create 64
let mutex = Mutex.create ()
let shared_mutex = Mutex.create ()

let local ~now ~ip =
  Mutex.lock mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock mutex) (fun () ->
    let count, expires = match Hashtbl.find_opt limits ip with
      | Some (count, expires) when expires > now -> count + 1, expires
      | _ -> 1, now +. 180. in
    Hashtbl.replace limits ip (count, expires);
    count > 10)

let rec write_all fd bytes offset remaining =
  if remaining > 0 then
    try
      let written = Unix.write fd bytes offset remaining in
      write_all fd bytes (offset + written) (remaining - written)
    with Unix.Unix_error (Unix.EINTR, _, _) ->
      write_all fd bytes offset remaining

let shared ~directory ~now ~ip =
  Mutex.lock shared_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock shared_mutex) (fun () ->
  let key = Http_cache.hex (Http_cache.sha256 ip) in
  let path = Filename.concat directory key in
  let fd = Unix.openfile path [Unix.O_CREAT; Unix.O_RDWR] 0o600 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
    Unix.lockf fd Unix.F_LOCK 0;
    Fun.protect ~finally:(fun () ->
      ignore (Unix.lseek fd 0 Unix.SEEK_SET);
      Unix.lockf fd Unix.F_ULOCK 0) (fun () ->
      let data = Bytes.create 128 in
      ignore (Unix.lseek fd 0 Unix.SEEK_SET);
      let length = Unix.read fd data 0 (Bytes.length data) in
      let prior = if length = 0 then None else
        match String.split_on_char ' ' (String.trim (Bytes.sub_string data 0 length)) with
        | [count; expires] ->
            (match int_of_string_opt count, float_of_string_opt expires with
             | Some count, Some expires -> Some (count, expires)
             | _ -> None)
        | _ -> None in
      let count, expires = match prior with
        | Some (count, expires) when expires > now -> count + 1, expires
        | _ -> 1, now +. 180. in
      let contents = Bytes.of_string
        (Printf.sprintf "%d %.17g\n" count expires) in
      ignore (Unix.lseek fd 0 Unix.SEEK_SET);
      Unix.ftruncate fd 0;
      write_all fd contents 0 (Bytes.length contents);
      count > 10)))

let hit ~now ~ip = match Sys.getenv_opt "CAMPFIRE_RATE_LIMIT_DIR" with
  | Some directory when directory <> "" -> shared ~directory ~now ~ip
  | _ -> local ~now ~ip

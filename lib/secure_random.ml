let shared_enabled = Sys.getenv_opt "CAMPFIRE_RANDOM_FD" <> Some "0"
let shared = Atomic.make None
let init_mutex = Mutex.create ()

let shared_fd () = match Atomic.get shared with
  | Some fd -> fd
  | None ->
      Mutex.lock init_mutex;
      Fun.protect ~finally:(fun () -> Mutex.unlock init_mutex) (fun () ->
        match Atomic.get shared with
        | Some fd -> fd
        | None ->
            let fd = Unix.openfile "/dev/urandom" [Unix.O_RDONLY] 0 in
            Atomic.set shared (Some fd);
            fd)

let bytes length =
  if length < 0 then invalid_arg "Secure_random.bytes";
  let input = if shared_enabled then shared_fd ()
    else Unix.openfile "/dev/urandom" [Unix.O_RDONLY] 0 in
  Fun.protect ~finally:(fun () ->
    if not shared_enabled then Unix.close input) (fun () ->
    let output=Bytes.create length in
    let rec fill offset =
      if offset<length then
        match (try Unix.read input output offset (length-offset)
          with Unix.Unix_error (Unix.EINTR, _, _) -> -1) with
        | 0 -> failwith "/dev/urandom returned EOF"
        | -1 -> fill offset
        | count -> fill (offset+count) in
    fill 0;Bytes.to_string output)

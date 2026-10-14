(** Pass accepted TCP connections to HTTP processes without a byte proxy.
    POST connections start on the worker with the SQLite writer; other
    connections use all workers. Each worker still handles mixed keep-alive
    requests correctly after the initial connection is assigned. *)

open Lwt.Infix

let path directory index =
  Filename.concat directory ("fd-worker-" ^ string_of_int index ^ ".sock")

let post_connection ~read_timeout fd =
  let bytes = Bytes.create 5 in
  let deadline = if read_timeout > 0 then
    Some (Unix.gettimeofday () +. float read_timeout) else None in
  let rec peek () =
    Lwt_unix.recv fd bytes 0 5 [Unix.MSG_PEEK] >>= fun count ->
    if count = 0 then Lwt.return_none else
    let prefix = Bytes.sub_string bytes 0 count in
    if count = 5 then Lwt.return_some (prefix = "POST ")
    else if prefix <> String.sub "POST " 0 count then Lwt.return_some false
    else if Option.fold ~none:false
        ~some:(fun deadline -> Unix.gettimeofday () >= deadline) deadline
      then Lwt.return_none
    else Lwt_unix.sleep 0.001 >>= peek in
  peek ()

let serve ~bind_ip ~port ~read_timeout ~directory ~workers =
  if workers < 2 then invalid_arg "fd router requires multiple workers";
  let listener = Lwt_unix.socket
    (if String.contains bind_ip ':' then Unix.PF_INET6 else Unix.PF_INET)
    Unix.SOCK_STREAM 0 in
  let mailbox = Lwt_unix.socket Unix.PF_UNIX Unix.SOCK_DGRAM 0 in
  Lwt_unix.setsockopt listener Unix.SO_REUSEADDR true;
  let round_robin = ref 0 in
  let pending = ref 0 in
  let forward fd =
    Lwt.finalize (fun () ->
      post_connection ~read_timeout fd >>= function
      | None -> Lwt.return_unit
      | Some is_post ->
          let index = if is_post then 0 else (
            let index = !round_robin mod workers in
            incr round_robin; index) in
          let vectors = Lwt_unix.IO_vectors.create () in
          Lwt_unix.IO_vectors.append_bytes vectors (Bytes.of_string "x") 0 1;
          Lwt_unix.send_msgto ~socket:mailbox ~io_vectors:vectors
            ~fds:[Lwt_unix.unix_file_descr fd]
            ~dest:(Unix.ADDR_UNIX (path directory index)) >|= fun sent ->
          if sent <> 1 then failwith "fd router did not transfer a descriptor")
      (fun () -> decr pending; Lwt_unix.close fd) in
  Lwt.finalize (fun () ->
    Lwt_unix.bind listener
      (Unix.ADDR_INET (Unix.inet_addr_of_string bind_ip,port)) >>= fun () ->
    Lwt_unix.listen listener 128;
    let rec accept () =
      Lwt_unix.accept listener >>= fun (fd,_) ->
      if !pending >= 512 then
        Lwt_unix.close fd >>= accept
      else (
        incr pending;
        Lwt.async (fun () ->
          Lwt.catch (fun () -> forward fd) (fun error ->
            Logs.warn (fun log -> log "FD routing failed: %s"
              (Printexc.to_string error));
            Lwt.return_unit));
        accept ()) in
    accept ())
    (fun () -> Lwt_unix.close listener >>= fun () -> Lwt_unix.close mailbox)

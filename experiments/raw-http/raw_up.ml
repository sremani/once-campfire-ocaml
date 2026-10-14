(* Disposable HTTP/1.1 ceiling probe. It accepts only GET /up and has no app
   router, WebSocket, body handling, or production hardening. *)
open Lwt.Infix

let body = "<!DOCTYPE html><html><body style=\"background-color: green\"></body></html>"
let response =
  "HTTP/1.1 200 OK\r\ncontent-type: text/html; charset=utf-8\r\n" ^
  "content-length: " ^ string_of_int (String.length body) ^
  "\r\nconnection: keep-alive\r\n\r\n" ^ body
let response = Bytes.of_string response

let rec write_all fd offset remaining =
  if remaining = 0 then Lwt.return_unit else
  Lwt_unix.write fd response offset remaining >>= fun written ->
  if written = 0 then Lwt.fail End_of_file
  else write_all fd (offset + written) (remaining - written)

let find_end bytes length =
  let rec scan i =
    if i + 3 >= length then None
    else if Bytes.get bytes i = '\r' && Bytes.get bytes (i+1) = '\n' &&
      Bytes.get bytes (i+2) = '\r' && Bytes.get bytes (i+3) = '\n'
    then Some (i+4) else scan (i+1) in
  scan 0

let handle fd =
  let buffer = Bytes.create 65536 in
  let rec loop used =
    match find_end buffer used with
    | Some consumed ->
        let first_line_end =
          let rec find i =
            if i + 1 >= consumed then i
            else if Bytes.get buffer i = '\r' && Bytes.get buffer (i+1) = '\n'
            then i else find (i+1) in find 0 in
        let valid = first_line_end = 16 &&
          Bytes.sub_string buffer 0 first_line_end = "GET /up HTTP/1.1" in
        if not valid then Lwt.return_unit else
        write_all fd 0 (Bytes.length response) >>= fun () ->
        let remaining = used - consumed in
        Bytes.blit buffer consumed buffer 0 remaining;
        loop remaining
    | None when used = Bytes.length buffer -> Lwt.return_unit
    | None ->
        Lwt_unix.read fd buffer used (Bytes.length buffer - used) >>= function
        | 0 -> Lwt.return_unit
        | n -> loop (used+n) in
  Lwt.finalize (fun () -> Lwt.catch (fun () -> loop 0)
    (fun _ -> Lwt.return_unit))
    (fun () -> Lwt_unix.close fd)

let () =
  let port = int_of_string Sys.argv.(1) in
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt socket Unix.SO_REUSEADDR true;
  Lwt_unix.setsockopt socket Unix.SO_REUSEPORT true;
  Lwt_unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_any,port)) |> Lwt_main.run;
  Lwt_unix.listen socket 4096;
  let rec accept () =
    Lwt_unix.accept socket >>= fun (fd,_) ->
    Lwt.async (fun () -> handle fd);
    accept () in
  Lwt_main.run (accept ())

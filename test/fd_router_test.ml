open Campfire
open Lwt.Infix

let recv_fd socket =
  let bytes = Bytes.create 1 in
  let vectors = Lwt_unix.IO_vectors.create () in
  Lwt_unix.IO_vectors.append_bytes vectors bytes 0 1;
  let result = Lwt.pick [
    (Lwt_unix.recv_msg ~socket ~io_vectors:vectors >|= fun (_,fds) -> fds);
    (Lwt_unix.sleep 2. >>= fun () -> Lwt.fail_with "descriptor timed out")]
    |> Lwt_main.run in
  match result with [fd] -> fd | _ -> failwith "expected one transferred descriptor"

let test_routing_and_socket_options () =
  let directory = Filename.temp_file "campfire-fd-router-" "" in
  Sys.remove directory;
  Unix.mkdir directory 0o700;
  let mailboxes = List.init 2 (fun index ->
    let socket = Lwt_unix.socket Unix.PF_UNIX Unix.SOCK_DGRAM 0 in
    let path = Fd_router.path directory index in
    Lwt_main.run (Lwt_unix.bind socket (Unix.ADDR_UNIX path));
    socket) in
  let probe = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind probe (Unix.ADDR_INET (Unix.inet_addr_loopback,0));
  let port = match Unix.getsockname probe with
    | Unix.ADDR_INET (_,port) -> port | _ -> assert false in
  Unix.close probe;
  let error_path = Filename.concat directory "child-error" in
  let child = Unix.fork () in
  if child = 0 then (
    List.iter (fun socket ->
      Unix.close (Lwt_unix.unix_file_descr socket)) mailboxes;
    try Lwt_main.run (Fd_router.serve ~bind_ip:"127.0.0.1"
      ~port ~read_timeout:5 ~directory ~workers:2)
    with error ->
      let output = open_out error_path in
      output_string output (Printexc.to_string error);
      close_out output;
      exit 1)
  else Fun.protect ~finally:(fun () ->
    (try Unix.kill child Sys.sigterm with _ -> ());
    ignore (Unix.waitpid [] child);
    List.iter (fun socket -> Lwt_main.run (Lwt_unix.close socket)) mailboxes;
    List.iter (fun index ->
      let path = Fd_router.path directory index in
      if Sys.file_exists path then Unix.unlink path) [0;1];
    if Sys.file_exists error_path then Unix.unlink error_path;
    Unix.rmdir directory) (fun () ->
    let connect () =
      let rec attempt remaining =
        let client = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
        try Unix.connect client (Unix.ADDR_INET (Unix.inet_addr_loopback,port));
          client
        with Unix.Unix_error (Unix.ECONNREFUSED,_,_) when remaining > 0 ->
          Unix.close client;
          Unix.sleepf 0.01;
          attempt (remaining-1)
        | error ->
          if Sys.file_exists error_path then (
            let input = open_in error_path in
            let detail = input_line input in
            close_in input;
            failwith ("router startup: " ^ detail));
          raise error in
      attempt 100 in
    let route request expected =
      let client = connect () in
      Fun.protect ~finally:(fun () -> Unix.close client) (fun () ->
        ignore (Unix.write_substring client request 0 (String.length request));
        let fd = recv_fd (List.nth mailboxes expected) in
        Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
          Alcotest.(check bool) "TCP_NODELAY transferred" true
            (Unix.getsockopt fd Unix.TCP_NODELAY);
          let peek = Bytes.create 5 in
          let count = Unix.recv fd peek 0 5 [Unix.MSG_PEEK] in
          Alcotest.(check string) "request bytes remain unread"
            (String.sub request 0 5) (Bytes.sub_string peek 0 count))) in
    route "POST /rooms/1/messages HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n" 0;
    route "GET /up HTTP/1.1\r\nHost: localhost\r\n\r\n" 0;
    route "GET /up HTTP/1.1\r\nHost: localhost\r\n\r\n" 1)

let () = Alcotest.run "FD router" [
  "routing", [Alcotest.test_case "POST, GET, and TCP_NODELAY" `Quick
    test_routing_and_socket_options]
]

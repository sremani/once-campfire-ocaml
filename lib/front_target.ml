(** Cohttp HTTP/1.1 target listener with phase-specific connection deadlines.

    Conduit's [Server.create ~timeout] measures a connection's entire lifetime,
    including upgraded WebSockets. Keep Cohttp's request parser, body reader,
    response writer and framing, but bound each HTTP phase separately. *)

open Lwt.Infix

exception Deadline
exception Header_limit

let max_header_bytes = 64 * 1024
let max_header_lines = 256
let header_fast_enabled = Sys.getenv_opt "CAMPFIRE_HEADER_FAST" <> Some "0"
let health_html =
  "<!DOCTYPE html><html><body style=\"background-color: green\"></body></html>"
let health_gzip = lazy (Http_gzip.compress health_html)
let health_etag = lazy (Option.get (Http_cache.rack_etag health_html))

let health_request_id incoming = match incoming with
  | Some id when String.trim id <> "" ->
      String.to_seq id |> List.of_seq
      |> List.filter (function
           | 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' | '-' | '@' -> true
           | _ -> false)
      |> List.to_seq |> String.of_seq
      |> fun id -> String.sub id 0 (min 255 (String.length id))
  | _ ->
      let bytes = Secure_random.bytes 16 in
      let chars = "0123456789abcdef" in
      let out = Bytes.create 36 in
      let j = ref 0 in
      String.iteri (fun i c ->
        if List.mem i [4;6;8;10] then (Bytes.set out !j '-'; incr j);
        let n = Char.code c in
        Bytes.set out !j chars.[n lsr 4]; incr j;
        Bytes.set out !j chars.[n land 15]; incr j) bytes;
      Bytes.unsafe_to_string out

type phase = Initial | Headers | Body | Response | Idle | Upgrade

type clock = {
  mutable phase : phase;
  mutable header_deadline : float option;
  mutable header_bytes : int;
  mutable header_lines : int;
}

let within seconds operation =
  if seconds <= 0. then operation ()
  else
    let result = operation () in
    (* Lwt's timer heap retains canceled sleepers until their deadline.
       Buffered operations normally complete synchronously. For an operation
       that waits, check the same absolute deadline in short intervals so a
       canceled sleeper leaves the heap promptly after the operation ends. *)
    match Lwt.state result with
    | Lwt.Sleep ->
        let deadline = Unix.gettimeofday () +. seconds in
        let rec expire () =
          let left = deadline -. Unix.gettimeofday () in
          if left <= 0. then Lwt.fail Deadline
          else Lwt_unix.sleep (min left 0.5) >>= expire in
        Lwt.pick [result; expire ()]
    | Lwt.Return _ | Lwt.Fail _ -> result

let remaining = function
  | None -> 0.
  | Some deadline ->
      let seconds = deadline -. Unix.gettimeofday () in
      if seconds <= 0. then raise Deadline else seconds

let serve ?stop ?(raw_health=false) ?socket ?worker_socket
    ~read_timeout ~write_timeout ~idle_timeout ~callback () =
  let on_client peer ic oc =
    let clock = {
      phase=Initial;
      header_deadline=(if read_timeout > 0 then
        Some (Unix.gettimeofday () +. float read_timeout) else None);
      header_bytes=0; header_lines=0;
    } in
    (* Cohttp asks its IO module for one header line at a time. Read the socket
       in blocks and retain bytes after a newline for the next line or body. *)
    let input = Bytes.create 4096 in
    let input_start = ref 0 and input_end = ref 0 in
    let fill ic =
      if !input_start < !input_end then Lwt.return_true else
      Lwt_io.read_into ic input 0 (Bytes.length input) >|= fun count ->
      input_start := 0;
      input_end := count;
      count > 0 in
    let module Timed_io = struct
      include Cohttp_lwt_unix.IO

      let read_line ic =
        let buffer = ref (if header_fast_enabled then None
          else Some (Buffer.create 128)) in
        let buffered () = match !buffer with
          | Some value -> value
          | None ->
              let value = Buffer.create 128 in
              buffer := Some value;
              value in
        let rec next () =
          fill ic >>= function
          | false ->
              (match !buffer with
               | None -> Lwt.return_none
               | Some value when Buffer.length value = 0 -> Lwt.return_none
               | Some value -> Lwt.return_some (Buffer.contents value))
          | true ->
              if clock.phase = Initial then (
                clock.phase <- Headers;
                clock.header_bytes <- 0;
                clock.header_lines <- 0);
              let first = !input_start in
              let rec find_newline position =
                if position >= !input_end then None
                else if Bytes.get input position = '\n' then Some position
                else find_newline (position + 1) in
              let newline = find_newline first in
              let last = match newline with
                | Some position -> position + 1 | None -> !input_end in
              let count = last - first in
              if clock.phase = Headers then (
                clock.header_bytes <- clock.header_bytes + count;
                if clock.header_bytes > max_header_bytes then raise Header_limit);
              let copy_count = if Option.is_some newline then count - 1 else count in
              input_start := last;
              match newline with
              | None ->
                  let value = buffered () in
                  Buffer.add_subbytes value input first copy_count;
                  if Buffer.length value > max_header_bytes then raise Header_limit;
                  next ()
              | Some _ ->
                  if clock.phase = Headers then (
                    clock.header_lines <- clock.header_lines + 1;
                    if clock.header_lines > max_header_lines then raise Header_limit);
                  (match !buffer with
                   | None ->
                       let length = if copy_count > 0 &&
                         Bytes.get input (first + copy_count - 1) = '\r'
                         then copy_count - 1 else copy_count in
                       Lwt.return_some (Bytes.sub_string input first length)
                   | Some value ->
                       Buffer.add_subbytes value input first copy_count;
                       let line = Buffer.contents value in
                       let length = String.length line in
                       Lwt.return_some (if length > 0 && line.[length - 1] = '\r' then
                         String.sub line 0 (length - 1) else line)) in
        (* The idle timer covers the wait for the next request's first byte.
           The fixed header deadline then covers its entire first line. *)
        match clock.phase with
        | Idle ->
            within (float idle_timeout) (fun () -> fill ic) >>= (function
              | false -> Lwt.return_none
              | true ->
                  clock.phase <- Headers;
                  clock.header_deadline <-
                    (if read_timeout > 0 then
                       Some (Unix.gettimeofday () +. float read_timeout)
                     else None);
                  clock.header_bytes <- 0;
                  clock.header_lines <- 0;
                  within (remaining clock.header_deadline) next)
        | Initial | Headers ->
            within (remaining clock.header_deadline) next
        | Body -> within (float read_timeout) next
        | Response | Upgrade -> next ()

      let read ic count =
        if !input_start < !input_end then (
          let length = min count (!input_end - !input_start) in
          let data = Bytes.sub_string input !input_start length in
          input_start := !input_start + length;
          Lwt.return data)
        else within (float read_timeout) (fun () -> Cohttp_lwt_unix.IO.read ic count)

      let write oc data =
        within (float write_timeout) (fun () -> Cohttp_lwt_unix.IO.write oc data)

      let flush oc =
        within (float write_timeout) (fun () -> Cohttp_lwt_unix.IO.flush oc)
    end in
    let module Request = Cohttp.Request.Make (Timed_io) in
    let module Response = Cohttp.Response.Make (Timed_io) in
    let conn = peer,Cohttp.Connection.create () in
    let try_raw_health () =
      if not raw_health then Lwt.return_false else
      (match clock.phase with
       | Idle -> within (float idle_timeout) (fun () -> fill ic)
       | Initial | Headers -> within (remaining clock.header_deadline) (fun () -> fill ic)
       | _ -> fill ic) >>= function
      | false -> Lwt.return_false
      | true ->
          if clock.phase = Idle then (
            clock.header_deadline <-
              (if read_timeout > 0 then
                 Some (Unix.gettimeofday () +. float read_timeout)
               else None);
            clock.header_bytes <- 0;
            clock.header_lines <- 0);
          clock.phase <- Headers;
          let prefix = "GET /up HTTP/1.1\r\n" in
          let prefix_length = String.length prefix in
          if !input_end - !input_start < prefix_length ||
             not (Bytes.sub_string input !input_start prefix_length = prefix)
          then Lwt.return_false
          else
            let rec header_end i =
              if i + 3 >= !input_end then None
              else if Bytes.get input i = '\r' && Bytes.get input (i+1) = '\n' &&
                      Bytes.get input (i+2) = '\r' && Bytes.get input (i+3) = '\n'
              then Some (i+4) else header_end (i+1) in
            let rec await_header () = match header_end !input_start with
              | Some finish -> Lwt.return_some finish
              | None when !input_end = Bytes.length input && !input_start > 0 ->
                  let unread = !input_end - !input_start in
                  Bytes.blit input !input_start input 0 unread;
                  input_start := 0;
                  input_end := unread;
                  await_header ()
              | None when !input_end = Bytes.length input -> Lwt.return_none
              | None ->
                  within (remaining clock.header_deadline) (fun () ->
                    Lwt_io.read_into ic input !input_end
                      (Bytes.length input - !input_end))
                  >>= fun count ->
                  input_end := !input_end + count;
                  if count = 0 then Lwt.return_none else await_header () in
            await_header () >>= function
            | None -> Lwt.return_false
            | Some finish ->
                let text = Bytes.sub_string input !input_start (finish - !input_start) in
                let lines = String.split_on_char '\n' text in
                let headers = List.filter_map (fun line ->
                  match String.index_opt line ':' with
                  | None -> None
                  | Some at -> Some (String.lowercase_ascii
                      (String.sub line 0 at),
                      String.trim (String.sub line (at+1)
                        (String.length line-at-1)))) lines in
                let header name = List.assoc_opt name headers in
                let accepted =
                  (match header "accept" with
                   | None | Some "text/html" | Some "*/*" -> true
                   | _ -> false) &&
                  header "accept-encoding" = Some "gzip" &&
                  header "if-none-match" = None &&
                  header "if-modified-since" = None &&
                  header "transfer-encoding" = None &&
                  header "content-length" = None &&
                  (match header "connection" with
                   | None | Some "keep-alive" -> true | _ -> false) in
                if not accepted then Lwt.return_false else
                let started = Unix.gettimeofday () in
                let id = health_request_id (header "x-request-id") in
                let gzip = Lazy.force health_gzip in
                let response = Buffer.create 512 in
                Buffer.add_string response
                  "HTTP/1.1 200 OK\r\ncontent-type: text/html; charset=utf-8\r\netag: ";
                Buffer.add_string response (Lazy.force health_etag);
                Buffer.add_string response
                  "\r\ncache-control: max-age=0, private, must-revalidate\r\nvary: Accept-Encoding\r\ncontent-encoding: gzip\r\nx-cache: miss\r\nx-request-id: ";
                Buffer.add_string response id;
                Buffer.add_string response "\r\nx-runtime: ";
                Buffer.add_string response
                  (Printf.sprintf "%.6f" (max 0. (Unix.gettimeofday () -. started)));
                Buffer.add_string response "\r\ntransfer-encoding: chunked\r\n\r\n";
                Buffer.add_string response (Printf.sprintf "%x\r\n" (String.length gzip));
                Buffer.add_string response gzip;
                Buffer.add_string response "\r\n0\r\n\r\n";
                input_start := finish;
                clock.phase <- Response;
                within (float write_timeout) (fun () ->
                  Lwt_io.write oc (Buffer.contents response) >>= fun () ->
                  Lwt_io.flush oc) >|= fun () ->
                clock.phase <- Idle;
                clock.header_deadline <- None;
                true in
    let rec serve_one () =
      try_raw_health () >>= fun handled ->
      if handled then serve_one () else
      Perf_probe.time_lwt "http_request_read" (fun () -> Request.read ic) >>= function
      | `Eof | `Invalid _ -> Lwt.return_unit
      | `Ok request ->
          clock.phase <- Body;
          let body = match Request.has_body request with
            | `Yes ->
                let reader = Request.make_body_reader request ic in
                Cohttp_lwt.Body.of_stream
                  (Cohttp_lwt.Body.create_stream Request.read_body_chunk reader)
            | `No | `Unknown -> Cohttp_lwt.Body.empty in
          let timed_out () =
            let headers = Cohttp.Header.of_list
              ["content-length", "0"; "connection", "close"] in
            let response = Cohttp.Response.make ~status:`Request_timeout
              ~headers () in
            Lwt.return (`Response (response, Cohttp_lwt.Body.empty)) in
          Lwt.catch
            (fun () ->
              Lwt.catch (fun () -> callback conn request body)
                (function Deadline as error -> Lwt.fail error
                | _ -> Cohttp_lwt_unix.Server.respond_error
                    ~body:"Internal Server Error" () >|= fun response ->
                    `Response response)
              >>= fun action ->
              let too_large = match action with
                | `Response (response,_) ->
                    Cohttp.Code.code_of_status (Cohttp.Response.status response) = 413
                | `Expert _ -> false in
              (if too_large then Lwt.return_unit
               else Cohttp_lwt.Body.drain_body body) >|= fun () -> action)
            (function Deadline -> timed_out () | error -> Lwt.fail error)
          >>= fun action ->
          let close_after_response = match action with
            | `Response (response,_) ->
                List.mem (Cohttp.Code.code_of_status (Cohttp.Response.status response))
                  [408; 413]
            | `Expert _ -> false in
          clock.phase <- Response;
          (match action with
           | `Response (response,response_body) ->
               Perf_probe.time_lwt "http_response_write" (fun () ->
               Response.write ~flush:(Cohttp.Response.flush response)
                 (fun writer ->
                   Cohttp_lwt.Body.write_body
                     (Response.write_body writer) response_body)
                 response oc) >>= fun () ->
               if Cohttp.Request.is_keep_alive request && not close_after_response then (
                 clock.phase <- Idle;
                 clock.header_deadline <- None;
                 serve_one ())
               else Lwt.return_unit
           | `Expert (response,handler) ->
               Response.write_header response oc >>= fun () ->
               clock.phase <- Upgrade;
               (* A frame can arrive in the same packet as the upgrade headers.
                  Hand any prefetched bytes to the protocol handler first. *)
               let expert_ic =
                 if !input_start >= !input_end then ic
                 else Lwt_io.make ~mode:Lwt_io.input
                   ~close:(fun () -> Lwt_io.close ic)
                   (fun target offset length ->
                     if !input_start < !input_end then (
                       let count = min length (!input_end - !input_start) in
                       Lwt_bytes.blit_from_bytes input !input_start target offset count;
                       input_start := !input_start + count;
                       Lwt.return count)
                     else Lwt_io.read_into_bigstring ic target offset length) in
               handler expert_ic oc >>= fun () ->
               clock.phase <- Idle;
               clock.header_deadline <- None;
               serve_one ()) in
    Lwt.catch serve_one (function
      | Deadline | Header_limit | End_of_file -> Lwt.return_unit
      | Lwt.Canceled -> Lwt.return_unit
      | error ->
          Logs.warn (fun log -> log "Target HTTP connection closed: %s"
            (Printexc.to_string error));
          Lwt.return_unit) in
  match socket,worker_socket with
  | Some socket,None ->
      Conduit_lwt_unix.serve ?stop
        ~on_exn:(fun error -> Logs.warn (fun log ->
          log "Target accept error: %s" (Printexc.to_string error)))
        ~ctx:(Lazy.force Conduit_lwt_unix.default_ctx)
        ~mode:(`TCP (`Socket socket))
        (fun flow ic oc ->
          let peer = match flow with
            | Conduit_lwt_unix.TCP tcp -> Ipaddr.to_string tcp.ip
            | _ -> "127.0.0.1" in
          on_client peer ic oc)
  | None,Some path ->
      if Sys.file_exists path then Unix.unlink path;
      let mailbox = Lwt_unix.socket Unix.PF_UNIX Unix.SOCK_DGRAM 0 in
      Lwt.finalize (fun () ->
        Lwt_unix.bind mailbox (Unix.ADDR_UNIX path) >>= fun () ->
        Unix.chmod path 0o600;
        let rec receive () =
          let data = Bytes.create 1 in
          let vectors = Lwt_unix.IO_vectors.create () in
          Lwt_unix.IO_vectors.append_bytes vectors data 0 1;
          let next = Lwt_unix.recv_msg ~socket:mailbox ~io_vectors:vectors
            >|= fun (_,fds) -> Some fds in
          (match stop with
           | None -> next
           | Some stopped -> Lwt.pick [next; (stopped >|= fun () -> None)])
          >>= function
          | None -> Lwt.return_unit
          | Some fds ->
              List.iter (fun raw ->
                let peer = match Unix.getpeername raw with
                  | Unix.ADDR_INET (ip,_) -> Unix.string_of_inet_addr ip
                  | _ -> "127.0.0.1" in
                let input = Lwt_io.of_unix_fd ~mode:Lwt_io.input raw in
                let output_fd = Unix.dup raw in
                (* Cached page responses are hundreds of KiB. The default
                   4 KiB buffer forces many copies and socket writes, while
                   64 KiB stays modest per connected client. *)
                let output = Lwt_io.of_unix_fd
                  ~buffer:(Lwt_bytes.create (64 * 1024))
                  ~mode:Lwt_io.output output_fd in
                Lwt.async (fun () ->
                  Lwt.finalize
                    (fun () -> on_client peer input output)
                    (fun () -> Lwt_io.close output >>= fun () ->
                      Lwt_io.close input))) fds;
              receive () in
        receive ())
        (fun () -> Lwt_unix.close mailbox >>= fun () ->
          if Sys.file_exists path then Unix.unlink path;
          Lwt.return_unit)
  | _ -> invalid_arg "exactly one HTTP listener mode is required"

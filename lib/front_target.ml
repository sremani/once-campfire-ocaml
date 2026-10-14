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

type phase = Initial | Headers | Body | Response | Idle | Upgrade

type clock = {
  mutable phase : phase;
  mutable header_deadline : float option;
  mutable header_bytes : int;
  mutable header_lines : int;
}

let within seconds operation =
  if seconds <= 0. then operation ()
  else Lwt.pick [
    operation ();
    (Lwt_unix.sleep seconds >>= fun () -> Lwt.fail Deadline)]

let remaining = function
  | None -> 0.
  | Some deadline ->
      let seconds = deadline -. Unix.gettimeofday () in
      if seconds <= 0. then raise Deadline else seconds

let serve ?stop ~socket ~read_timeout ~write_timeout ~idle_timeout ~callback () =
  let on_client flow ic oc =
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
    let conn = flow,Cohttp.Connection.create () in
    let rec serve_one () =
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
  Conduit_lwt_unix.serve ?stop
    ~on_exn:(fun error -> Logs.warn (fun log ->
      log "Target accept error: %s" (Printexc.to_string error)))
    ~ctx:(Lazy.force Conduit_lwt_unix.default_ctx)
    ~mode:(`TCP (`Socket socket)) on_client

(** Cohttp HTTP/1.1 target listener with phase-specific connection deadlines.

    Conduit's [Server.create ~timeout] measures a connection's entire lifetime,
    including upgraded WebSockets. Keep Cohttp's request parser, body reader,
    response writer and framing, but bound each HTTP phase separately. *)

open Lwt.Infix

exception Deadline
exception Header_limit

let max_header_bytes = 64 * 1024
let max_header_lines = 256

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
    let module Timed_io = struct
      include Cohttp_lwt_unix.IO

      let read_line ic =
        let rec next buffer =
          let deadline = match clock.phase with
            | Initial | Headers -> remaining clock.header_deadline
            | Idle -> float idle_timeout
            | Body -> float read_timeout
            | Response | Upgrade -> 0. in
          within deadline (fun () -> Lwt_io.read_char_opt ic) >>= function
          | None ->
              if Buffer.length buffer = 0 then Lwt.return_none
              else Lwt.return_some (Buffer.contents buffer)
          | Some char ->
              (match clock.phase with
               | Initial ->
                   clock.phase <- Headers;
                   clock.header_bytes <- 0;
                   clock.header_lines <- 0
               | Idle ->
                   clock.phase <- Headers;
                   clock.header_deadline <-
                     (if read_timeout > 0 then
                        Some (Unix.gettimeofday () +. float read_timeout)
                      else None);
                   clock.header_bytes <- 0;
                   clock.header_lines <- 0
               | _ -> ());
              (match clock.phase with
               | Headers ->
                   clock.header_bytes <- clock.header_bytes + 1;
                   if clock.header_bytes > max_header_bytes then raise Header_limit
               | _ -> ());
              if char = '\n' then (
                (match clock.phase with
                 | Headers ->
                     clock.header_lines <- clock.header_lines + 1;
                     if clock.header_lines > max_header_lines then raise Header_limit
                 | _ -> ());
                let line = Buffer.contents buffer in
                let length = String.length line in
                let line = if length > 0 && line.[length - 1] = '\r' then
                  String.sub line 0 (length - 1) else line in
                Lwt.return_some line)
              else (
                Buffer.add_char buffer char;
                if Buffer.length buffer > max_header_bytes then raise Header_limit;
                next buffer) in
        next (Buffer.create 128)

      let read ic count =
        within (float read_timeout) (fun () -> Cohttp_lwt_unix.IO.read ic count)

      let write oc data =
        within (float write_timeout) (fun () -> Cohttp_lwt_unix.IO.write oc data)

      let flush oc =
        within (float write_timeout) (fun () -> Cohttp_lwt_unix.IO.flush oc)
    end in
    let module Request = Cohttp.Request.Make (Timed_io) in
    let module Response = Cohttp.Response.Make (Timed_io) in
    let conn = flow,Cohttp.Connection.create () in
    let rec serve_one () =
      Request.read ic >>= function
      | `Eof | `Invalid _ -> Lwt.return_unit
      | `Ok request ->
          clock.phase <- Body;
          let body = match Request.has_body request with
            | `Yes ->
                let reader = Request.make_body_reader request ic in
                Cohttp_lwt.Body.of_stream
                  (Cohttp_lwt.Body.create_stream Request.read_body_chunk reader)
            | `No | `Unknown -> Cohttp_lwt.Body.empty in
          Lwt.catch (fun () -> callback conn request body)
            (fun _ -> Cohttp_lwt_unix.Server.respond_error
              ~body:"Internal Server Error" () >|= fun response -> `Response response)
          >>= fun action ->
          let too_large = match action with
            | `Response (response,_) ->
                Cohttp.Code.code_of_status (Cohttp.Response.status response) = 413
            | `Expert _ -> false in
          (if too_large then Lwt.return_unit else Cohttp_lwt.Body.drain_body body)
          >>= fun () ->
          clock.phase <- Response;
          (match action with
           | `Response (response,response_body) ->
               Response.write ~flush:(Cohttp.Response.flush response)
                 (fun writer ->
                   Cohttp_lwt.Body.write_body
                     (Response.write_body writer) response_body)
                 response oc >>= fun () ->
               if Cohttp.Request.is_keep_alive request && not too_large then (
                 clock.phase <- Idle;
                 clock.header_deadline <- None;
                 serve_one ())
               else Lwt.return_unit
           | `Expert (response,handler) ->
               Response.write_header response oc >>= fun () ->
               clock.phase <- Upgrade;
               handler ic oc >>= fun () ->
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

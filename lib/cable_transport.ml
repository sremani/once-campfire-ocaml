open Lwt.Infix

module Ws_io = Websocket.Make (Cohttp_lwt_unix.IO)
module Frame = Websocket.Frame
module Opcode = Frame.Opcode

external deflate_raw : string -> string = "campfire_cable_deflate"
external inflate_raw : string -> int -> string = "campfire_cable_inflate"

let max_message = 1 lsl 20
let min_compressed = 256
let write_timeout = 30.

type config = {
  disable_request_forgery_protection : bool;
  allowed_request_origins : string list;
  allow_same_origin_as_host : bool;
  assume_ssl : bool;
}

let default_config = {
  disable_request_forgery_protection = false;
  allowed_request_origins = [];
  allow_same_origin_as_host = true;
  assume_ssl = true;
}

type incoming = Text of string | Binary | Closed

type connection = {
  protocol : string option;
  compression : bool;
  reader : int -> Frame.t Lwt.t;
  writer : Frame.t list -> unit Lwt.t;
  partial : (Opcode.t * bool * Buffer.t) option ref;
  mutable closed : bool;
}

let protocol c = c.protocol
let compression c = c.compression

let header headers name = Cohttp.Header.get headers name
let header_values headers name = Cohttp.Header.get_multi headers name
let tokens value = String.split_on_char ',' value |> List.map String.trim
let equals_ci a b = String.equal (String.lowercase_ascii a) (String.lowercase_ascii b)
let has_token headers name token =
  List.exists (fun value -> List.exists (fun part -> equals_ci part token) (tokens value))
    (header_values headers name)

let first_header headers name =
  Option.map (fun value -> match tokens value with x :: _ -> String.lowercase_ascii x | [] -> "")
    (header headers name)

let ssl_request headers =
  first_header headers "x-forwarded-ssl" = Some "on"
  || first_header headers "x-forwarded-scheme" = Some "https"
  || first_header headers "x-forwarded-proto" = Some "https"

let origin_allowed config headers =
  if config.disable_request_forgery_protection then true else
  let origin = header headers "origin" in
  let host = Option.value ~default:"" (header headers "host") in
  let scheme = if config.assume_ssl || ssl_request headers then "https" else "http" in
  (config.allow_same_origin_as_host && origin = Some (scheme ^ "://" ^ host))
  || Option.fold ~none:false ~some:(fun value -> List.mem value config.allowed_request_origins) origin

let acceptable_deflate_offer offer =
  match String.split_on_char ';' offer |> List.map String.trim with
  | "permessage-deflate" :: params ->
      List.for_all (fun param ->
        let name, value = match String.split_on_char '=' param with
          | [name] -> name, None
          | [name; value] -> name, Some (String.trim value |> String.split_on_char '"' |> String.concat "")
          | _ -> "", None in
        match name with
        | "server_no_context_takeover" | "client_no_context_takeover" -> value = None
        | "client_max_window_bits" -> (match value with None -> true | Some v ->
            (match int_of_string_opt v with Some bits -> bits >= 8 && bits <= 15 | None -> false))
        | "server_max_window_bits" -> value = Some "15"
        | _ -> false) params
  | _ -> false

let negotiated_compression headers =
  header_values headers "sec-websocket-extensions"
  |> List.exists (fun value -> List.exists acceptable_deflate_offer (tokens value))

let negotiated_protocol headers =
  header_values headers "sec-websocket-protocol"
  |> List.concat_map tokens
  |> List.find_opt (function "actioncable-v1-json" | "actioncable-unsupported" -> true | _ -> false)

let valid_key headers =
  match header headers "sec-websocket-key" with
  | None -> None
  | Some key -> (match Base64.decode key with Ok decoded when String.length decoded = 16 -> Some key | _ -> None)

let websocket_request request =
  let headers = Cohttp.Request.headers request in
  Cohttp.Request.meth request = `GET && has_token headers "connection" "upgrade"
  && Option.fold ~none:false ~some:(fun value -> equals_ci value "websocket")
       (header headers "upgrade")

let page_not_found () =
  let headers = Cohttp.Header.init_with "content-type" "text/plain; charset=utf-8" in
  let response = Cohttp.Response.make ~status:`Not_found ~headers () in
  `Response (response, Cohttp_lwt.Body.of_string "Page not found")

let valid_utf8 text =
  let decoder = Uutf.decoder ~encoding:`UTF_8 (`String text) in
  let rec loop () = match Uutf.decode decoder with
    | `Uchar _ -> loop ()
    | `End -> true
    | `Malformed _ -> false
    | `Await -> false in
  loop ()

let write_frames c frames = Lwt_unix.with_timeout write_timeout (fun () -> c.writer frames)
let write_frame c frame = write_frames c [frame]

let send_texts c texts =
  if c.closed then Lwt.fail End_of_file else
  if List.length texts > 64 then invalid_arg "Cable_transport.send_texts: batch exceeds 64" else
  let frames = List.map (fun text ->
    let payload, extension =
      if c.compression && String.length text >= min_compressed
      then deflate_raw text, 4 else text, 0 in
    Frame.create ~opcode:Opcode.Text ~extension ~content:payload ()) texts in
  write_frames c frames

let send_text c text = send_texts c [text]

let send_close ?(code=1000) c =
  if c.closed then Lwt.return_unit else begin
    c.closed <- true;
    write_frame c (Frame.close code)
  end

let protocol_error c code = send_close ~code c >>= fun () -> Lwt.return Closed

let close_code content =
  let len = String.length content in
  if len = 0 then Some None
  else if len = 1 then None
  else
    let code = (Char.code content.[0] lsl 8) lor Char.code content.[1] in
    let allowed = (code >= 1000 && code <= 1003) || (code >= 1007 && code <= 1014)
      || (code >= 3000 && code <= 4999) in
    if allowed && valid_utf8 (String.sub content 2 (len - 2)) then Some (Some code) else None

let finish_message c opcode compressed data =
  let payload = Buffer.contents data in
  let decoded = try Ok (if compressed then inflate_raw payload max_message else payload)
    with Failure message when message = "cable inflated message too large" -> Error 1009
       | Failure _ -> Error 1002 in
  match decoded with
  | Error code -> protocol_error c code
  | Ok text when String.length text > max_message -> protocol_error c 1009
  | Ok text -> (match opcode with
      | Opcode.Text -> if valid_utf8 text then Lwt.return (Text text) else protocol_error c 1007
      | Opcode.Binary -> Lwt.return Binary
      | _ -> protocol_error c 1002)

let rec read c =
  if c.closed then Lwt.return Closed else
  let partial_size = match !(c.partial) with None -> 0 | Some (_, _, data) -> Buffer.length data in
  Lwt.catch (fun () -> c.reader partial_size >>= fun frame ->
    match frame.Frame.opcode with
    | Opcode.Ping ->
        write_frame c (Frame.create ~opcode:Opcode.Pong ~content:frame.content ()) >>= fun () -> read c
    | Opcode.Pong -> read c
    | Opcode.Close -> (match close_code frame.content with
        | None -> protocol_error c 1002
        | Some code ->
            (match code with
             | Some code -> send_close ~code c
             | None ->
                 c.closed <- true;
                 write_frame c (Frame.create ~opcode:Opcode.Close ()))
            >>= fun () -> Lwt.return Closed)
    | Opcode.Text | Opcode.Binary as opcode ->
        if Option.is_some !(c.partial) then protocol_error c 1002
        else let data = Buffer.create (String.length frame.content) in
          Buffer.add_string data frame.content;
          if frame.final then finish_message c opcode (frame.extension = 4) data
          else (c.partial := Some (opcode, frame.extension = 4, data); read c)
    | Opcode.Continuation -> (match !(c.partial) with
        | None -> protocol_error c 1002
        | Some (opcode, compressed, data) ->
            if Buffer.length data + String.length frame.content > max_message then protocol_error c 1009
            else begin
              Buffer.add_string data frame.content;
              if frame.final then (c.partial := None; finish_message c opcode compressed data)
              else read c
            end)
    | _ -> protocol_error c 1002)
  (function
    | End_of_file | Websocket.Protocol_error _ -> c.closed <- true; Lwt.return Closed
    | exn -> Lwt.fail exn)

let handle ?(config=default_config) request ~run =
  let headers = Cohttp.Request.headers request in
  let key = valid_key headers in
  if not (websocket_request request && origin_allowed config headers
      && header headers "sec-websocket-version" = Some "13" && Option.is_some key)
  then Lwt.return (page_not_found ())
  else
    let key = Option.get key in
    let protocol = negotiated_protocol headers in
    let compression = negotiated_compression headers in
    let response_headers = Cohttp.Header.of_list
      (["Upgrade", "websocket"; "Connection", "Upgrade";
        "Sec-WebSocket-Accept", Websocket.b64_encoded_sha1sum (key ^ Websocket.websocket_uuid)]
       @ (match protocol with None -> [] | Some value -> ["Sec-WebSocket-Protocol", value])
       @ (if compression then ["Sec-WebSocket-Extensions",
          "permessage-deflate; server_no_context_takeover; client_no_context_takeover"] else [])) in
    let response = Cohttp.Response.make ~status:`Switching_protocols
      ~encoding:Cohttp.Transfer.Unknown ~headers:response_headers () in
    let expert ic oc =
      let read_buffer = Buffer.create 128 in
      let reader partial_size = Ws_io.make_read_frame ~buf:read_buffer ~mode:Server
          ~allow_rsv1:compression ~max_payload:max_message ~partial_size ic oc () in
      let write_lock = Lwt_mutex.create () in
      let writer frames = Lwt_mutex.with_lock write_lock (fun () ->
        let length = List.fold_left (fun n frame -> n + String.length frame.Frame.content + 16) 0 frames in
        let buf = Buffer.create length in
        List.iter (Ws_io.write_frame_to_buf ~mode:Server buf) frames;
        Lwt_io.write oc (Buffer.contents buf) >>= fun () -> Lwt_io.flush oc) in
      let connection = { protocol; compression; reader; writer; partial = ref None; closed = false } in
      Lwt.finalize (fun () -> run connection) (fun () -> Lwt_io.close ic) in
    Lwt.return (`Expert (response, expert))

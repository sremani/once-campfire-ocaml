(** Disposable HTTP/1.1 adapter over Lwt_unix. This probes transport cost while
    routing through the real application. It deliberately lacks chunked
    requests, WebSocket upgrades, streaming responses, and production limits. *)

open Lwt.Infix

let header_limit = 65536
let body_limit = 16 * 1024 * 1024

let find_header_end bytes length =
  let rec scan i =
    if i + 3 >= length then None
    else if Bytes.get bytes i = '\r' && Bytes.get bytes (i+1) = '\n' &&
      Bytes.get bytes (i+2) = '\r' && Bytes.get bytes (i+3) = '\n'
    then Some (i+4) else scan (i+1) in
  scan 0

let trim_cr line =
  let n = String.length line in
  if n > 0 && line.[n-1] = '\r' then String.sub line 0 (n-1) else line

let parse_header bytes length =
  let lines = Bytes.sub_string bytes 0 length
    |> String.split_on_char '\n' |> List.map trim_cr in
  match lines with
  | first :: rest ->
      (match String.split_on_char ' ' first with
       | [method_; target; "HTTP/1.1"] ->
           let headers = List.filter_map (fun line ->
             match String.index_opt line ':' with
             | None -> None
             | Some colon ->
                 let name = String.sub line 0 colon |> String.lowercase_ascii in
                 let value = String.sub line (colon+1)
                   (String.length line-colon-1) |> String.trim in
                 Some (name,value)) rest in
           let content_length = match List.assoc_opt "content-length" headers with
             | None -> 0 | Some raw -> int_of_string raw in
           if content_length < 0 || content_length > body_limit ||
              List.mem_assoc "transfer-encoding" headers
           then invalid_arg "unsupported request framing";
           method_,target,headers,content_length
       | _ -> invalid_arg "unsupported request line")
  | [] -> invalid_arg "empty request"

let rec write_all fd bytes offset remaining =
  if remaining = 0 then Lwt.return_unit else
  Lwt_unix.write fd bytes offset remaining >>= fun written ->
  if written = 0 then Lwt.fail End_of_file
  else write_all fd bytes (offset+written) (remaining-written)

let rec write_string_all fd bytes offset remaining =
  if remaining = 0 then Lwt.return_unit else
  Lwt_unix.write_string fd bytes offset remaining >>= fun written ->
  if written = 0 then Lwt.fail End_of_file
  else write_string_all fd bytes (offset+written) (remaining-written)

let serialize (response, body) =
  Cohttp_lwt.Body.to_string body >|= fun body ->
  let status = Cohttp.Response.status response in
  let headers = Cohttp.Response.headers response |> Cohttp.Header.to_list
    |> List.filter (fun (name,_) ->
      not (List.mem (String.lowercase_ascii name)
        ["connection";"content-length";"transfer-encoding"])) in
  let out = Buffer.create 1024 in
  Buffer.add_string out "HTTP/1.1 ";
  Buffer.add_string out (Cohttp.Code.string_of_status status);
  Buffer.add_string out "\r\n";
  List.iter (fun (name,value) ->
    Buffer.add_string out name;
    Buffer.add_string out ": ";
    Buffer.add_string out value;
    Buffer.add_string out "\r\n") headers;
  Buffer.add_string out "content-length: ";
  Buffer.add_string out (string_of_int (String.length body));
  Buffer.add_string out "\r\nconnection: keep-alive\r\n\r\n";
  Bytes.of_string (Buffer.contents out), body

let serve ?(port=3000) ?(bind_ip="127.0.0.1") ?front_config:_ ?stop
    ?track_request:_ ?cable_run:_ ?cable_config:_ ?cable ?event_sink
    ?front_cache ?private_cache
    ~runtime ~secret_key_base ?(ssl=false) ?(force_ssl=false)
    ?(action_not_found_pages=false) ?max_body_bytes ~dispatch () =
  let front_cache = Option.value front_cache ~default:(Http_cache.Front.create
    ~capacity:(64 * 1024 * 1024) ~max_item_size:(1024 * 1024)) in
  let owned_private_cache = match private_cache with
    | Some cache -> Some cache
    | None -> Http_app.create_private_cache ~capacity:(64 * 1024 * 1024) runtime in
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt socket Unix.SO_REUSEADDR true;
  if Sys.getenv_opt "CAMPFIRE_REUSEPORT" = Some "1" then
    Lwt_unix.setsockopt socket Unix.SO_REUSEPORT true;
  let handle peer fd =
    let buffer = ref (Bytes.create header_limit) in
    let peer_ip = match peer with
      | Unix.ADDR_INET (ip,_) -> Unix.string_of_inet_addr ip
      | _ -> "127.0.0.1" in
    let rec ensure used needed =
      if needed > body_limit + header_limit then Lwt.fail Exit
      else if used >= needed then Lwt.return used
      else (
        if needed > Bytes.length !buffer then (
          let bigger = Bytes.create (max needed (2 * Bytes.length !buffer)) in
          Bytes.blit !buffer 0 bigger 0 used;
          buffer := bigger);
        Lwt_unix.read fd !buffer used (Bytes.length !buffer-used) >>= function
        | 0 -> Lwt.fail End_of_file
        | n -> ensure (used+n) needed) in
    let rec loop used =
      match find_header_end !buffer used with
      | None when used >= header_limit -> Lwt.return_unit
      | None -> ensure used (used+1) >>= loop
      | Some header_end ->
          let method_,target,header_list,content_length = Perf_probe.time
            "raw_parse" (fun () -> parse_header !buffer header_end) in
          ensure used (header_end+content_length) >>= fun used ->
          let body = Bytes.sub_string !buffer header_end content_length in
          let request = Perf_probe.time "raw_request" (fun () ->
            let method_ = Cohttp.Code.method_of_string method_ in
            let headers = Cohttp.Header.of_list header_list in
            Cohttp.Request.make ~meth:method_ ~headers
              (Uri.of_string target)) in
          Perf_probe.time_lwt "raw_handle" (fun () ->
            Http_app.handle ~runtime ~secret_key_base ?cable ?event_sink
            ~front_cache ?private_cache:owned_private_cache ~remote_ip:peer_ip
            ~ssl ~force_ssl ~action_not_found_pages ?max_body_bytes
            ~dispatch request (Cohttp_lwt.Body.of_string body))
          >>= fun reply ->
          Perf_probe.time_lwt "raw_serialize" (fun () -> serialize reply)
          >>= fun (header,body) ->
          Perf_probe.time_lwt "raw_write" (fun () ->
            write_all fd header 0 (Bytes.length header) >>= fun () ->
            write_string_all fd body 0 (String.length body)) >>= fun () ->
          let consumed = header_end+content_length in
          let remaining = used-consumed in
          Bytes.blit !buffer consumed !buffer 0 remaining;
          loop remaining in
    Lwt.finalize
      (fun () -> Lwt.catch (fun () -> loop 0) (fun _ -> Lwt.return_unit))
      (fun () -> Lwt_unix.close fd) in
  Lwt.finalize (fun () ->
    Lwt_unix.bind socket
      (Unix.ADDR_INET (Unix.inet_addr_of_string bind_ip,port)) >>= fun () ->
    Lwt_unix.listen socket 4096;
    let rec accept () =
      Lwt_unix.accept socket >>= fun (fd,peer) ->
      Lwt_unix.setsockopt fd Unix.TCP_NODELAY true;
      Lwt.async (fun () -> handle peer fd);
      accept () in
    match stop with
    | None -> accept ()
    | Some stopped -> Lwt.pick [accept ();stopped])
    (fun () ->
      Lwt.catch (fun () -> Lwt_unix.close socket) (fun _ -> Lwt.return_unit)
      >>= fun () ->
      (match private_cache with
       | Some _ -> ()
       | None -> Option.iter Http_app.close_private_cache owned_private_cache);
      Lwt.return_unit)

(** Disposable HTTP/af transport probe. It calls the real Campfire router but
    deliberately has no WebSocket upgrade, upload streaming, or shutdown
    integration. It must never be used as the production listener. *)

open Lwt.Infix

let trace message =
  if Sys.getenv_opt "CAMPFIRE_HTTPAF_TRACE" = Some "1" then
    prerr_endline ("httpaf probe: " ^ message)

let body_string body =
  let finished, wake = Lwt.wait () in
  let buffer = Buffer.create 1024 in
  let rec read () =
    Httpaf.Body.schedule_read body
      ~on_eof:(fun () -> if Lwt.is_sleeping finished then
        Lwt.wakeup_later wake (Buffer.contents buffer))
      ~on_read:(fun bytes ~off ~len ->
        Buffer.add_string buffer (Bigstringaf.substring bytes ~off ~len);
        read ()) in
  read ();
  finished

let respond reqd (response, body) =
  Cohttp_lwt.Body.to_string body >|= fun bytes ->
  let status = Cohttp.Response.status response
    |> Cohttp.Code.code_of_status in
  let headers = Cohttp.Response.headers response
    |> fun headers -> Cohttp.Header.remove headers "transfer-encoding"
    |> fun headers -> Cohttp.Header.replace headers "content-length"
      (string_of_int (String.length bytes))
    |> Cohttp.Header.to_list |> Httpaf.Headers.of_list in
  Httpaf.Reqd.respond_with_string reqd
    (Httpaf.Response.create ~headers (`Code status)) bytes

let run () =
  let config = match Campfire.Config.from_env () with
    | Ok config -> config | Error error -> failwith error in
  let front = Campfire.Front_config.from_env () in
  Campfire.Runtime_ops.storage_ready config;
  let runtime = Campfire.Db_runtime.open_db
    ~readers:config.db_readers ~environment:config.environment
    config.storage.database in
  Campfire.Runtime_ops.boot_check runtime;
  let storage = Campfire.Storage_disk.create
    ~root:config.storage.files ~name:"local" in
  Campfire.Storage_http.register storage;
  Campfire.Storage_http.register_representation (fun c blob json ->
    match (try Some (Campfire.Storage_variation.of_json
      (Yojson.Safe.from_string (Yojson.Basic.to_string json)))
      with Invalid_argument _ -> None) with
    | None -> Lwt.return_none
    | Some variation -> Lwt_preemptive.detach (fun () ->
        Campfire.Storage_media.process_representation
          c.Campfire.Http_app.runtime storage blob variation
          ~now:(Campfire.Authentication.now_time c.now)) ());
  Campfire.Controller_rooms.register_storage storage;
  Campfire.Controller_accounts.register_storage storage;
  Campfire.Controller_aux.register_unfurl Campfire.Opengraph.controller_adapter;
  let cable = Campfire.Cable_channels.create ~db:runtime
    ~secret_key_base:config.secret_key_base
    ~now:Campfire.Http_app.now_utc () in
  let jobs = Campfire.App_jobs.start ~config ~runtime ~storage ~cable () in
  let private_cache = Campfire.Http_app.create_private_cache
    ~capacity:(64 * 1024 * 1024) runtime in
  let front_cache = Campfire.Http_cache.Front.create
    ~capacity:(64 * 1024 * 1024) ~max_item_size:(1024 * 1024) in
  let dispatch = Campfire.App_dispatch.endpoint in
  let force_ssl = not config.disable_ssl in
  let max_body_bytes = if front.max_request_body > 0 then
    Some front.max_request_body else None in
  let request_handler peer reqd =
    trace "request callback";
    Lwt.async (fun () ->
      Lwt.catch
        (fun () ->
          let raw = Httpaf.Reqd.request reqd in
          trace ("request " ^ raw.target);
          let method_ = Httpaf.Method.to_string raw.meth
            |> Cohttp.Code.method_of_string in
          let headers = Httpaf.Headers.to_list raw.headers
            |> Cohttp.Header.of_list in
          let request = Cohttp.Request.make ~meth:method_ ~headers
            (Uri.of_string raw.target) in
          let peer = match peer with
            | Unix.ADDR_INET (address, _) -> Unix.string_of_inet_addr address
            | Unix.ADDR_UNIX _ -> "127.0.0.1" in
          let request, remote_ip, front_ssl =
            Campfire.Front_proxy.prepare ~config:front ~peer request in
          let ssl = Option.value front_ssl ~default:force_ssl in
          (match Httpaf.Request.body_length raw with
           | `Fixed 0L -> trace "empty body"; Lwt.return ""
           | _ -> body_string (Httpaf.Reqd.request_body reqd)) >>= fun bytes ->
          trace ("body read " ^ string_of_int (String.length bytes));
          let body = Cohttp_lwt.Body.of_string bytes in
          Campfire.Http_app.handle ~runtime
            ~secret_key_base:config.secret_key_base ~cable
            ~event_sink:(Campfire.App_jobs.event_sink jobs)
            ~front_cache ?private_cache ~remote_ip ~ssl ~force_ssl
            ~action_not_found_pages:true ?max_body_bytes ~dispatch
            request body >>= fun response ->
          trace "app response";
          respond reqd response >>= fun () ->
          trace "response sent";
          Lwt.return_unit)
        (fun exn ->
          prerr_endline (Printexc.to_string exn);
          let response = Httpaf.Response.create `Internal_server_error in
          Httpaf.Reqd.respond_with_string reqd response "";
          Lwt.return_unit)) in
  let error_handler _peer ?request:_ _error start_response =
    let body = start_response (Httpaf.Headers.of_list
      ["content-type", "text/plain"; "content-length", "0"]) in
    Httpaf.Body.close_writer body in
  let handler = Httpaf_lwt_unix.Server.create_connection_handler
    ~request_handler ~error_handler in
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt socket Unix.SO_REUSEADDR true;
  Lwt_main.run (
    Lwt_unix.bind socket (Unix.ADDR_INET
      (Unix.inet_addr_of_string front.target_bind, front.target_port))
    >>= fun () ->
    Lwt_unix.listen socket 128;
    let rec accept () =
      Lwt_unix.accept socket >>= fun (client, peer) ->
      Lwt.async (fun () -> handler peer client);
      accept () in
    accept ())

let () = run ()

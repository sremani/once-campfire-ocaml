open Lwt.Infix

let inspect database =
  match Campfire.Database.inspect database with
  | Error message -> prerr_endline message; `Error (false, message)
  | Ok inspection ->
      let open Yojson.Basic in
      let report = `Assoc [
        "database", `String database;
        "sqlite_version", `String inspection.sqlite_version;
        "account_count", `Int inspection.account_count;
        "missing_tables", `List (List.map (fun s -> `String s) inspection.missing_tables);
        "required_tables_present", `Bool (inspection.missing_tables = []);
      ] in
      print_endline (pretty_to_string report);
      if inspection.missing_tables = [] then `Ok ()
      else `Error (false, "Required Campfire tables are missing")

let database =
  let open Cmdliner in
  let doc = "Path to the existing Campfire SQLite database." in
  Arg.(required & opt (some string) None & info ["database"] ~docv:"PATH" ~doc)

let check_cmd =
  let open Cmdliner in
  let info = Cmd.info "check" ~doc:"Inspect an existing Campfire database without writing to it." in
  Cmd.v info Term.(ret (const inspect $ database))

let configure_logging (config:Campfire.Config.t) =
  Logs.set_reporter (Logs_fmt.reporter ());
  let level = match Sys.getenv_opt "CAMPFIRE_LOG" with
    | None -> config.log_level
    | Some filter -> List.hd (String.split_on_char ',' filter) in
  Logs.set_level (Campfire.Runtime_ops.log_level level)

let backup () =
  match Campfire.Config.from_env () with
  | Error message -> `Error (false,message)
  | Ok config ->
      configure_logging config;
      (try
         ignore (Campfire.Runtime_ops.backup config);
         `Ok ()
       with exn -> `Error (false, Printexc.to_string exn))

let backup_cmd =
  let open Cmdliner in
  let info = Cmd.info "backup" ~doc:"Write and verify an atomic SQLite snapshot for ONCE." in
  Cmd.v info Term.(ret (const backup $ const ()))

let serve database port =
  match Campfire.Config.from_env () with
  | Error message -> `Error (false, message)
  | Ok config ->
      configure_logging config;
      let front = Campfire.Front_config.from_env () in
      let port = Option.value port ~default:front.target_port in
      let max_body_bytes =
        if front.max_request_body > 0 then Some front.max_request_body else None in
      let database = Option.value database ~default:config.storage.database in
      (try
         Campfire.Runtime_ops.storage_ready config;
         let runtime = Campfire.Db_runtime.open_db
           ~readers:config.db_readers ~environment:config.environment database in
         let close_runtime = ref true in
         Fun.protect ~finally:(fun () ->
           if !close_runtime then Campfire.Db_runtime.close runtime) (fun () ->
           Campfire.Runtime_ops.boot_check runtime;
           Campfire.Runtime_ops.reset_presence runtime;
           let storage=Campfire.Storage_disk.create
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
           let force_ssl = not config.disable_ssl in
           let cable = Campfire.Cable_channels.create ~db:runtime
             ~secret_key_base:config.secret_key_base
             ~now:Campfire.Http_app.now_utc () in
           let jobs=Campfire.App_jobs.start ~config ~runtime ~storage ~cable () in
           Fun.protect ~finally:(fun () ->
             let drained = Lwt_main.run (Lwt_preemptive.detach (fun () ->
               Campfire.App_jobs.shutdown jobs
                 ~deadline:(Unix.gettimeofday () +. 10.)) ()) in
             if not drained then (
               close_runtime := false;
               Logs.warn (fun m -> m "jobs or Web Push still active after shutdown grace")))
             (fun () ->
               let stopped, stop = Lwt.wait () in
               let drain = Campfire.Runtime_ops.Drain.create () in
               let signal number =
                 Logs.info (fun m -> m "shutting down on signal %d" number);
                 ignore (Campfire.Cable_channels.restart cable);
                 if Lwt.is_sleeping stopped then Lwt.wakeup_later stop () in
               let signals = List.map (fun number ->
                 Lwt_unix.on_signal number signal) [Sys.sigint; Sys.sigterm] in
               Fun.protect ~finally:(fun () ->
                 List.iter Lwt_unix.disable_signal_handler signals) (fun () ->
                 let drained = Lwt_main.run (
                   Campfire.Http_app.serve ~runtime
                     ~secret_key_base:config.secret_key_base ~port
                     ~bind_ip:front.target_bind ~front_config:front ~stop:stopped
                     ~track_request:(Campfire.Runtime_ops.Drain.track drain)
                     ?max_body_bytes ~ssl:force_ssl ~force_ssl
                     ~action_not_found_pages:true
                     ~cable ~cable_run:(Campfire.Cable_channels.run cable)
                     ~event_sink:(Campfire.App_jobs.event_sink jobs)
                     ~dispatch:Campfire.App_dispatch.endpoint ()
                   >>= fun () ->
                   Campfire.Runtime_ops.Drain.wait drain
                     ~deadline:(Unix.gettimeofday () +. 10.)) in
                 if not drained then (
                   close_runtime := false;
                   Logs.warn (fun m -> m "requests still active after shutdown grace"))));
           `Ok ())
       with exn -> `Error (false, Printexc.to_string exn))

let serve_cmd =
  let open Cmdliner in
  let database = Arg.(value & opt (some string) None & info ["database"]
    ~docv:"PATH" ~doc:"SQLite database path; defaults to CAMPFIRE_DATABASE_PATH or the configured storage path.") in
  let port = Arg.(value & opt (some int) None & info ["port"] ~docv:"PORT"
    ~doc:"Override THRUSTER_TARGET_PORT for the Cohttp application listener.") in
  let info = Cmd.info "serve" ~doc:"Serve the OCaml Campfire application over HTTP." in
  Cmd.v info Term.(ret (const serve $ database $ port))

let server_cmd =
  let open Cmdliner in
  let info = Cmd.info "server" ~doc:"Serve the OCaml Campfire application." in
  Cmd.v info Term.(ret (const serve $ const None $ const None))

let () =
  let open Cmdliner in
  let info = Cmd.info "campfire" ~doc:"OCaml port of ONCE Campfire (in progress)." in
  exit (Cmd.eval (Cmd.group info ~default:Term.(ret (const serve $ const None $ const None))
    [check_cmd; serve_cmd; server_cmd; backup_cmd]))

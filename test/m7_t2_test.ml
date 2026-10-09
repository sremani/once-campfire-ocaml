open Alcotest
open Lwt.Infix

let with_dir f =
  let path = Filename.temp_file "campfire-operations-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () ->
    let rec remove path =
      if Sys.is_directory path then (
        Sys.readdir path |> Array.iter (fun name ->
          remove (Filename.concat path name));
        Unix.rmdir path)
      else Sys.remove path in
    remove path) (fun () -> f path)

let config root =
  let get = function
    | "SECRET_KEY_BASE" -> Some "test-only"
    | "CAMPFIRE_STORAGE_PATH" -> Some root
    | _ -> None in
  match Campfire.Config.from_lookup get with
  | Ok config -> config
  | Error reason -> fail reason

let config_defaults () = with_dir (fun root ->
  let c = config root in
  check string "production environment" "production" c.environment;
  check string "Rails log default" "info" c.log_level;
  check string "backup path" (Filename.concat root "backups") c.storage.backups)

let force_ssl_redirect () =
  let request method_ = Cohttp.Request.make ~meth:method_
    ~headers:(Cohttp.Header.of_list ["host","localhost:3000"])
    (Uri.of_string "/up?probe=1") in
  let check_redirect method_ status =
    let response,_ = Campfire.Http_app.https_redirect ~trusted_front:false
      (request method_) in
    check int "redirect status" status
      (Cohttp.Code.code_of_status (Cohttp.Response.status response));
    check (option string) "HTTPS location" (Some "https://localhost/up?probe=1")
      (Cohttp.Header.get (Cohttp.Response.headers response) "location") in
  check_redirect `GET 301;
  check_redirect `POST 308

let scalar db sql =
  Option.get (Campfire.Db_runtime.query_one db sql []
    (fun stmt -> Sqlite3.column_text stmt 0))

let backup_restore () = with_dir (fun root ->
  let c = config root in
  Campfire.Runtime_ops.storage_ready c;
  let rt = Campfire.Db_runtime.open_db c.storage.database in
  Campfire.Db_runtime.write rt (fun tx ->
    ignore (Campfire.Db_runtime.execute (Campfire.Db_runtime.conn tx)
      "INSERT INTO accounts (name, join_code, created_at, updated_at) VALUES ('Before', 'abc', '2026-01-01', '2026-01-01')" []));
  let backup = Campfire.Runtime_ops.backup c in
  check string "backup path" (Filename.concat c.storage.backups "production.sqlite3") backup;
  let snap = Sqlite3.db_open ~mode:`READONLY backup in
  check string "committed WAL in backup" "Before"
    (scalar snap "SELECT name FROM accounts LIMIT 1");
  check string "backup integrity" "ok" (scalar snap "PRAGMA integrity_check");
  ignore (Sqlite3.db_close snap);
  Campfire.Db_runtime.write rt (fun tx ->
    ignore (Campfire.Db_runtime.execute (Campfire.Db_runtime.conn tx)
      "UPDATE accounts SET name='After'" []));
  Campfire.Db_runtime.close rt;
  let copy_file source destination =
    let input = open_in_bin source and output = open_out_bin destination in
    Fun.protect ~finally:(fun () -> close_in input; close_out output) (fun () ->
      really_input_string input (in_channel_length input) |> output_string output) in
  copy_file backup c.storage.database;
  List.iter (fun suffix ->
    let path = c.storage.database ^ suffix in
    if Sys.file_exists path then Sys.remove path) ["-wal";"-shm"];
  let restored = Sqlite3.db_open ~mode:`READONLY c.storage.database in
  check string "restore recovers snapshot" "Before"
    (scalar restored "SELECT name FROM accounts LIMIT 1");
  ignore (Sqlite3.db_close restored))

let preserves_last_good_backup () = with_dir (fun root ->
  let c = config root in
  Campfire.Runtime_ops.storage_ready c;
  let rt = Campfire.Db_runtime.open_db c.storage.database in
  Campfire.Db_runtime.close rt;
  let backup = Campfire.Runtime_ops.backup c in
  let before = (Unix.stat backup).Unix.st_size in
  Sys.remove c.storage.database;
  let failed = try ignore (Campfire.Runtime_ops.backup c); false
    with Invalid_argument _ -> true in
  check bool "missing source fails" true failed;
  let corrupt = open_out_bin c.storage.database in
  output_string corrupt "not a SQLite database";
  close_out corrupt;
  let failed = try ignore (Campfire.Runtime_ops.backup c); false
    with _ -> true in
  check bool "corrupt source fails" true failed;
  check int "last good backup kept" before (Unix.stat backup).Unix.st_size;
  let partials = Sys.readdir c.storage.backups |> Array.to_list
    |> List.filter (String.starts_with ~prefix:".backup-") in
  check (list string) "failed partial removed" [] partials)

let concurrent_backups () = with_dir (fun root ->
  let c = config root in
  Campfire.Runtime_ops.storage_ready c;
  let rt = Campfire.Db_runtime.open_db c.storage.database in
  Campfire.Db_runtime.write rt (fun tx ->
    ignore (Campfire.Db_runtime.execute (Campfire.Db_runtime.conn tx)
      "INSERT INTO accounts (name, join_code, created_at, updated_at) VALUES ('Concurrent', 'abc', '2026-01-01', '2026-01-01')" []));
  Campfire.Db_runtime.close rt;
  let results = Array.make 4 None in
  let workers = Array.init 4 (fun index -> Thread.create (fun () ->
    results.(index) <- Some (try Ok (Campfire.Runtime_ops.backup c)
      with exn -> Error (Printexc.to_string exn))) ()) in
  Array.iter Thread.join workers;
  Array.iter (function
    | Some (Ok path) -> check string "same destination"
        (Filename.concat c.storage.backups "production.sqlite3") path
    | Some (Error message) -> fail message
    | None -> fail "backup worker did not report") results;
  let db = Sqlite3.db_open ~mode:`READONLY
    (Filename.concat c.storage.backups "production.sqlite3") in
  check string "concurrent snapshot integrity" "ok"
    (scalar db "PRAGMA integrity_check");
  check string "concurrent snapshot content" "Concurrent"
    (scalar db "SELECT name FROM accounts LIMIT 1");
  ignore (Sqlite3.db_close db);
  let partials = Sys.readdir c.storage.backups |> Array.to_list
    |> List.filter (String.starts_with ~prefix:".backup-") in
  check (list string) "concurrent partials removed" [] partials)

let push_drain () = with_dir (fun root ->
  let c = config root in
  Campfire.Runtime_ops.storage_ready c;
  let runtime = Campfire.Db_runtime.open_db c.storage.database in
  Fun.protect ~finally:(fun () -> Campfire.Db_runtime.close runtime) (fun () ->
    let storage = Campfire.Storage_disk.create ~root:c.storage.files ~name:"local" in
    let cable = Campfire.Cable_channels.create ~db:runtime
      ~secret_key_base:c.secret_key_base ~now:Campfire.Http_app.now_utc () in
    let config = { c with
      vapid_subject="mailto:support@37signals.com";
      vapid_public_key=Some "BEYXTBB5_jNhNzXDmx5KEU55Vbbd-u--Lk9rM5OFQvUkPIBwZJ9QzAq0zdEzFw6yTV8cTriz_qYBVicY02_VxTQ=";
      vapid_private_key=Some "qfXLHghuG1rSHZUVo9SscNRI-0EIHRbIrfeGCqbAwak=" } in
    let mutex = Mutex.create () and gate = Condition.create () in
    let started = ref false and release = ref false and delivered = ref 0 in
    let outbound _ =
      Mutex.lock mutex;
      started := true;
      Condition.broadcast gate;
      while not !release do Condition.wait gate mutex done;
      incr delivered;
      Mutex.unlock mutex;
      Ok {Campfire.Web_push.status=201;reason="Created"} in
    let app = Campfire.App_jobs.start ~config ~runtime ~storage ~cable
      ~resolve:(fun _ -> Some "142.250.185.206") ~outbound () in
    Fun.protect ~finally:(fun () ->
      Mutex.lock mutex; release := true; Condition.broadcast gate;
      Mutex.unlock mutex;
      ignore (Campfire.App_jobs.shutdown app
        ~deadline:(Unix.gettimeofday () +. 1.))) (fun () ->
      let subscription = {Campfire.Db_remaining.Push_subscription.id=1L;
        user_id=1L;endpoint=Some "https://fcm.googleapis.com/fcm/send/abc";
        p256dh_key=Some "BDaRUn_gvMok9AhEo1soNNypgpMDfe2K0hz6RMEIxxULWKfVUqodLAxtX1mrUMC4PGgk1RkZJTut7vJ2RMrxowo=";
        auth_key=Some "BCuqPYqblNIL9NEJ4WT1Yw==";
        user_agent=None;created_at="";updated_at=""} in
      let notification = {Campfire.Web_push.title="Campfire Test";
        body="Shutdown drain";path="/rooms/1";badge=1L;subscription} in
      let pool = Option.get app.Campfire.App_jobs.push_pool in
      check bool "push was queued" true
        (Campfire.Web_push.enqueue pool notification);
      Mutex.lock mutex;
      while not !started do Condition.wait gate mutex done;
      Mutex.unlock mutex;
      check bool "blocked Web Push exceeds short shutdown deadline" false
        (Campfire.App_jobs.shutdown app
          ~deadline:(Unix.gettimeofday () +. 0.02));
      Mutex.lock mutex; release := true; Condition.broadcast gate;
      Mutex.unlock mutex;
      check bool "Web Push drains after transport completes" true
        (Campfire.App_jobs.shutdown app
          ~deadline:(Unix.gettimeofday () +. 1.));
      check int "one Web Push delivered" 1 !delivered)))

let boot_resets_presence () = with_dir (fun root ->
  let c = config root in
  Campfire.Runtime_ops.storage_ready c;
  let rt = Campfire.Db_runtime.open_db c.storage.database in
  let now = Campfire.Http_app.now_utc () in
  Campfire.Db_runtime.write rt (fun tx ->
    ignore (Campfire.Db_runtime.execute (Campfire.Db_runtime.conn tx)
      "INSERT INTO memberships (user_id, room_id, created_at, updated_at, connected_at, connections) VALUES (1, 1, ?, ?, ?, 3)"
      (List.init 3 (fun _ -> Sqlite3.Data.TEXT now))));
  Campfire.Runtime_ops.boot_check rt;
  Campfire.Runtime_ops.reset_presence rt;
  Campfire.Db_runtime.read rt (fun db ->
    check string "stale connections cleared" "0"
      (scalar db "SELECT CAST(connections AS TEXT) FROM memberships LIMIT 1");
    check string "connected_at cleared" "1"
      (scalar db "SELECT CAST(connected_at IS NULL AS TEXT) FROM memberships LIMIT 1"));
  Campfire.Db_runtime.close rt)

let follow_on_job_drain () =
  let mutex = Mutex.create () and gate = Condition.create () in
  let active = ref false and release = ref false and purged = ref 0 in
  let sink = ref (fun (_:Campfire.Db_remaining.Event.t) -> ()) in
  let jobs = Campfire.Jobs.create ~workers:1
    ~on_push:(fun ~room_id:_ ~message_id:_ -> ())
    ~on_webhook:(fun ~bot_id:_ ~message_id:_ -> ())
    ~on_remove_banned:(fun ~user_id:_ ->
      Mutex.lock mutex;
      active := true; Condition.broadcast gate;
      while not !release do Condition.wait gate mutex done;
      Mutex.unlock mutex;
      !sink (Campfire.Db_remaining.Event.PurgeBlob {blob_id=1L}))
    ~on_purge:(fun ~blob_id:_ -> incr purged) () in
  sink := Campfire.Jobs.event_sink jobs;
  !sink (Campfire.Db_remaining.Event.RemoveBannedContent {user_id=1L});
  Mutex.lock mutex;
  while not !active do Condition.wait gate mutex done;
  Mutex.unlock mutex;
  let result = ref false in
  let closer = Thread.create (fun () ->
    result := Campfire.Jobs.shutdown jobs
      ~deadline:(Unix.gettimeofday () +. 1.)) () in
  Thread.delay 0.02;
  Mutex.lock mutex;
  release := true; Condition.broadcast gate;
  Mutex.unlock mutex;
  Thread.join closer;
  check bool "jobs drained" true !result;
  check int "follow-on purge ran" 1 !purged;
  let _,_,_,_,dropped = Campfire.Jobs.stats jobs Campfire.Jobs.Purge_blob in
  check int "follow-on purge not dropped" 0 dropped

let lwt_job_drain () =
  let completed = ref false in
  let jobs = Campfire.Jobs.create ~workers:1
    ~on_push:(fun ~room_id:_ ~message_id:_ -> ())
    ~on_webhook:(fun ~bot_id:_ ~message_id:_ ->
      Lwt_preemptive.run_in_main (fun () ->
        Lwt_unix.sleep 0.02 >|= fun () -> completed := true))
    ~on_remove_banned:(fun ~user_id:_ -> ())
    ~on_purge:(fun ~blob_id:_ -> ()) () in
  let sink = Campfire.Jobs.event_sink jobs in
  sink (Campfire.Db_remaining.Event.DeliverWebhook {bot_id=1L;message_id=1L});
  let drained = Lwt_main.run (Lwt_preemptive.detach (fun () ->
    Campfire.Jobs.shutdown jobs ~deadline:(Unix.gettimeofday ()+.5.)) ()) in
  check bool "event loop dependent job drained" true drained;
  check bool "event loop callback completed" true !completed

let job_deadline () =
  let mutex = Mutex.create () and gate = Condition.create () in
  let active = ref false and release = ref false in
  let jobs = Campfire.Jobs.create ~workers:1
    ~on_push:(fun ~room_id:_ ~message_id:_ -> ())
    ~on_webhook:(fun ~bot_id:_ ~message_id:_ -> ())
    ~on_remove_banned:(fun ~user_id:_ -> ())
    ~on_purge:(fun ~blob_id:_ -> ()) () in
  ignore (Campfire.Jobs.perform_later jobs (fun () ->
    Mutex.lock mutex;
    active := true; Condition.broadcast gate;
    while not !release do Condition.wait gate mutex done;
    Mutex.unlock mutex));
  Mutex.lock mutex;
  while not !active do Condition.wait gate mutex done;
  Mutex.unlock mutex;
  let start = Unix.gettimeofday () in
  check bool "deadline returns false" false
    (Campfire.Jobs.shutdown jobs ~deadline:(start +. 0.02));
  check bool "deadline bounded" true (Unix.gettimeofday () -. start < 0.2);
  Mutex.lock mutex;
  release := true; Condition.broadcast gate;
  Mutex.unlock mutex;
  check bool "worker eventually drains" true
    (Campfire.Jobs.shutdown jobs ~deadline:(Unix.gettimeofday () +. 1.))

let () = run "M7-T2 operations" [
  "config", [test_case "production defaults" `Quick config_defaults;
    test_case "force SSL redirects" `Quick force_ssl_redirect];
  "backup", [test_case "WAL snapshot and restore" `Quick backup_restore;
    test_case "failure preserves last good" `Quick preserves_last_good_backup;
    test_case "concurrent invocations" `Quick concurrent_backups];
  "boot", [test_case "presence reset" `Quick boot_resets_presence];
  "shutdown", [test_case "follow-on job drain" `Quick follow_on_job_drain;
    test_case "Lwt job drain" `Quick lwt_job_drain;
    test_case "deadline" `Quick job_deadline;
    test_case "production Web Push drain" `Quick push_drain]]

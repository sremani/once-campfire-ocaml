open Campfire

let check label value = if not value then failwith label

let rec reference_root path remaining =
  if remaining = 0 then failwith "once-campfire-rust checkout not found"
  else
    let candidate = Filename.concat path "once-campfire-rust" in
    if Sys.file_exists (Filename.concat candidate "parity/.seed/default/db/production.sqlite3")
    then candidate
    else reference_root (Filename.dirname path) (remaining - 1)

let reference = reference_root (Sys.getcwd ()) 8

let with_path f =
  let path = Filename.temp_file "campfire-m2-t1-" ".sqlite3" in
  Sys.remove path;
  Fun.protect ~finally:(fun () ->
    List.iter (fun suffix ->
      let file = path ^ suffix in
      if Sys.file_exists file then Sys.remove file) [""; "-wal"; "-shm"])
    (fun () -> f path)

let backup_file source_path destination =
  let source = Sqlite3.db_open ~mode:`READONLY source_path in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close source)) (fun () ->
    let quoted = String.concat "''" (String.split_on_char '\'' destination) in
    Db_runtime.exec source ("VACUUM INTO '" ^ quoted ^ "'"))

let with_seed name f =
  let seed = Filename.concat reference
    ("parity/.seed/" ^ name ^ "/db/production.sqlite3") in
  with_path (fun path -> backup_file seed path; f path)

let scalar db sql =
  match Db_runtime.query_one db sql [] (fun stmt -> Sqlite3.column_text stmt 0) with
  | Some value -> value
  | None -> failwith ("no row: " ^ sql)

let count db table =
  match Db_runtime.query_one db ("SELECT count(*) FROM \"" ^ table ^ "\"") []
    (fun stmt -> Sqlite3.column_int stmt 0) with
  | Some value -> value | None -> assert false

let data_snapshot db =
  let tables = Db_runtime.query_all db
    "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name" []
    (fun stmt -> Sqlite3.column_text stmt 0) in
  List.map (fun table ->
    let rows = Db_runtime.query_all db
      ("SELECT * FROM \"" ^ table ^ "\"") []
      (fun stmt ->
        List.init (Sqlite3.column_count stmt) (fun i ->
          Sqlite3.Data.to_string_debug (Sqlite3.column stmt i))) in
    (table, rows)) tables

let schema_objects db =
  Db_runtime.query_all db
    "SELECT name, sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name" []
    (fun stmt -> Sqlite3.column_text stmt 0, Sqlite3.column_text stmt 1)

let foreign_key_violations db =
  Db_runtime.query_all db "PRAGMA foreign_key_check" []
    (fun stmt -> List.init (Sqlite3.column_count stmt) (fun i ->
      Sqlite3.Data.to_string_debug (Sqlite3.column stmt i)))

let test_existing_seed name accounts users rooms messages =
  with_seed name (fun path ->
    let before = Sqlite3.db_open ~mode:`READONLY path in
    let rows_before = data_snapshot before in
    let schema_before = schema_objects before in
    let violations_before = foreign_key_violations before in
    ignore (Sqlite3.db_close before);
    let runtime = Db_runtime.open_db path in
    Fun.protect ~finally:(fun () -> Db_runtime.close runtime) (fun () ->
      Db_runtime.read runtime (fun db ->
        check "account rows" (count db "accounts" = accounts);
        check "user rows" (count db "users" = users);
        check "room rows" (count db "rooms" = rooms);
        check "message rows" (count db "messages" = messages);
        check "existing rows preserved" (data_snapshot db = rows_before);
        let before_names = List.map fst schema_before in
        let after_names = List.map fst (schema_objects db) in
        let additions = List.filter (fun name -> not (List.mem name before_names)) after_names in
        check "only additive Rust indexes"
          (additions = ["index_messages_on_room_id_and_created_at";
                        "index_messages_on_room_id_and_updated_at"]);
        check "integrity" (scalar db "PRAGMA integrity_check" = "ok");
        check "foreign key state preserved"
          (foreign_key_violations db = violations_before);
        check "foreign keys" (scalar db "PRAGMA foreign_keys" = "1");
        check "read-only pool" (scalar db "PRAGMA query_only" = "1");
        check "no pending migrations" (Db_runtime.pending_migrations db = []))))

let test_pending_migration () =
  with_seed "first_run" (fun path ->
    let db = Sqlite3.db_open path in
    ignore (Db_runtime.execute db
      "DELETE FROM schema_migrations WHERE version = ?"
      [Sqlite3.Data.TEXT "20251212154340"]);
    ignore (Sqlite3.db_close db);
    let rejected = match Db_runtime.open_db path with
      | _ -> false
      | exception Failure message -> String.starts_with ~prefix:"pending migrations:" message
    in
    check "pending migration rejects open" rejected;
    let after = Sqlite3.db_open ~mode:`READONLY path in
    Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close after)) (fun () ->
      check "migration left pending" (List.mem "20251212154340"
        (Db_runtime.pending_migrations after));
      check "no index added on rejection"
        (not (List.mem "index_messages_on_room_id_and_created_at"
          (List.map fst (schema_objects after))))))

let test_new_schema () =
  with_path (fun path ->
    let runtime = Db_runtime.open_db path in
    Fun.protect ~finally:(fun () -> Db_runtime.close runtime) (fun () ->
      Db_runtime.read runtime (fun db ->
        check "fresh schema account" (count db "accounts" = 0);
        check "fresh migrations" (Db_runtime.pending_migrations db = []);
        check "fresh environment" (scalar db
          "SELECT value FROM ar_internal_metadata WHERE key = 'environment'" = "production");
        check "fresh SHA1" (scalar db
          "SELECT value FROM ar_internal_metadata WHERE key = 'schema_sha1'" =
          Db_runtime.schema_sha1);
        check "fresh integrity" (scalar db "PRAGMA integrity_check" = "ok"))))

let test_transactions_and_callbacks () =
  with_path (fun path ->
    let runtime = Db_runtime.open_db path in
    Fun.protect ~finally:(fun () -> Db_runtime.close runtime) (fun () ->
      Db_runtime.write runtime (fun tx ->
        Db_runtime.exec (Db_runtime.conn tx)
          "CREATE TABLE runtime_counter (value integer NOT NULL)");
      let emitted = ref [] in
      let raised = match Db_runtime.write runtime (fun tx ->
        ignore (Db_runtime.execute (Db_runtime.conn tx)
          "INSERT INTO runtime_counter (value) VALUES (?)" [Sqlite3.Data.INT 1L]);
        Db_runtime.emit_after_commit tx (fun () -> emitted := 1 :: !emitted);
        failwith "rollback") with
      | exception Failure message when message = "rollback" -> true | _ -> false in
      check "write raised" raised;
      check "rollback discarded callback" (!emitted = []);
      Db_runtime.read runtime (fun db ->
        check "rollback discarded row" (count db "runtime_counter" = 0));
      Db_runtime.write runtime (fun tx ->
        ignore (Db_runtime.execute (Db_runtime.conn tx)
          "INSERT INTO runtime_counter (value) VALUES (?)" [Sqlite3.Data.INT 2L]);
        Db_runtime.after_commit tx (fun committed ->
          check "callback runs outside transaction" (not (Db_runtime.in_transaction committed));
          ignore (Db_runtime.execute (Db_runtime.conn committed)
            "INSERT INTO runtime_counter (value) VALUES (?)" [Sqlite3.Data.INT 3L]);
          emitted := 2 :: !emitted);
        Db_runtime.emit_after_commit tx (fun () -> emitted := 3 :: !emitted));
      check "ordered callbacks" (List.rev !emitted = [2; 3]);
      Db_runtime.read runtime (fun db ->
        check "callback write committed" (count db "runtime_counter" = 2));
      let callback_error = match Db_runtime.write runtime (fun tx ->
        ignore (Db_runtime.execute (Db_runtime.conn tx)
          "INSERT INTO runtime_counter (value) VALUES (?)" [Sqlite3.Data.INT 4L]);
        Db_runtime.after_commit tx (fun _ -> failwith "callback failed");
        Db_runtime.after_commit tx (fun _ -> emitted := 5 :: !emitted)) with
      | exception Failure message when message = "callback failed" -> true | _ -> false in
      check "callback error propagated" callback_error;
      check "subsequent callback still ran" (List.hd !emitted = 5);
      Db_runtime.read runtime (fun db ->
        check "commit survives callback error" (count db "runtime_counter" = 3))))

let test_concurrency_and_backup () =
  with_path (fun path -> with_path (fun backup ->
    let runtime = Db_runtime.open_db ~readers:2 path in
    Fun.protect ~finally:(fun () -> Db_runtime.close runtime) (fun () ->
      Db_runtime.write runtime (fun tx ->
        Db_runtime.exec (Db_runtime.conn tx)
          "CREATE TABLE runtime_counter (value integer NOT NULL)";
        ignore (Db_runtime.execute (Db_runtime.conn tx)
          "INSERT INTO runtime_counter (value) VALUES (?)" [Sqlite3.Data.INT 0L]));
      let errors = ref [] in
      let error_mutex = Mutex.create () in
      let worker () =
        try for _ = 1 to 25 do
          Db_runtime.write runtime (fun tx ->
            Db_runtime.exec (Db_runtime.conn tx)
              "UPDATE runtime_counter SET value = value + 1");
          Db_runtime.read runtime (fun db ->
            ignore (scalar db "SELECT value FROM runtime_counter"))
        done with exn ->
          Mutex.lock error_mutex; errors := exn :: !errors; Mutex.unlock error_mutex in
      let threads = List.init 4 (fun _ -> Thread.create worker ()) in
      List.iter Thread.join threads;
      check "workers succeeded" (!errors = []);
      Db_runtime.read runtime (fun db ->
        check "serialized writes" (scalar db "SELECT value FROM runtime_counter" = "100");
        Db_runtime.read runtime (fun inner ->
          check "nested reader" (scalar inner "SELECT value FROM runtime_counter" = "100")));
      Db_runtime.backup_to runtime backup;
      let copied = Sqlite3.db_open ~mode:`READONLY backup in
      Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close copied)) (fun () ->
        check "backup includes committed WAL" (scalar copied
          "SELECT value FROM runtime_counter" = "100");
        check "backup integrity" (scalar copied "PRAGMA integrity_check" = "ok")))))

let wait_until label predicate =
  let deadline = Unix.gettimeofday () +. 5. in
  while not (predicate ()) do
    if Unix.gettimeofday () > deadline then failwith ("timed out: " ^ label);
    Thread.delay 0.001
  done

let test_fifo_and_close () =
  with_path (fun path ->
    let runtime = Db_runtime.open_db ~readers:1 path in
    let gate = Mutex.create () in
    let ready = Condition.create () in
    let release = ref false in
    let started = ref false in
    let order = ref [] in
    let first = Thread.create (fun () ->
      Db_runtime.write runtime (fun _ ->
        Mutex.lock gate;
        started := true; Condition.broadcast ready;
        while not !release do Condition.wait ready gate done;
        Mutex.unlock gate)) () in
    Mutex.lock gate;
    while not !started do Condition.wait ready gate done;
    Mutex.unlock gate;
    let workers = List.init 5 (fun n ->
      let worker = Thread.create (fun () ->
        Db_runtime.write runtime (fun _ -> order := n :: !order)) () in
      wait_until "writer queued" (fun () ->
        Mutex.lock runtime.Db_runtime.scheduler_mutex;
        let count = List.length runtime.Db_runtime.queued_writers in
        Mutex.unlock runtime.Db_runtime.scheduler_mutex;
        count = n + 1);
      worker) in
    Mutex.lock gate; release := true; Condition.broadcast ready; Mutex.unlock gate;
    Thread.join first; List.iter Thread.join workers;
    check "writer FIFO" (List.rev !order = [0; 1; 2; 3; 4]);
    let reader_gate = Mutex.create () in
    let reader_ready = Condition.create () in
    let reader_release = ref false in
    let reader_started = ref false in
    let held = Thread.create (fun () ->
      Db_runtime.read runtime (fun _ ->
        Mutex.lock reader_gate;
        reader_started := true; Condition.broadcast reader_ready;
        while not !reader_release do Condition.wait reader_ready reader_gate done;
        Mutex.unlock reader_gate)) () in
    Mutex.lock reader_gate;
    while not !reader_started do Condition.wait reader_ready reader_gate done;
    Mutex.unlock reader_gate;
    let read_order = ref [] in
    let readers = List.init 5 (fun n ->
      let worker = Thread.create (fun () ->
        Db_runtime.read runtime (fun _ -> read_order := n :: !read_order)) () in
      wait_until "reader queued" (fun () ->
        Mutex.lock runtime.Db_runtime.pool_mutex;
        let count = List.length runtime.Db_runtime.queued_readers in
        Mutex.unlock runtime.Db_runtime.pool_mutex;
        count = n + 1);
      worker) in
    Mutex.lock reader_gate;
    reader_release := true; Condition.broadcast reader_ready;
    Mutex.unlock reader_gate;
    Thread.join held; List.iter Thread.join readers;
    check "reader FIFO" (List.rev !read_order = [0; 1; 2; 3; 4]);
    Db_runtime.close runtime)

let test_close_waits_for_reader () =
  with_path (fun path ->
    let runtime = Db_runtime.open_db ~readers:1 path in
    let gate = Mutex.create () in
    let ready = Condition.create () in
    let started = ref false in
    let release = ref false in
    let holding = Thread.create (fun () ->
      Db_runtime.read runtime (fun db ->
        check "reader starts" (scalar db "SELECT 1" = "1");
        Mutex.lock gate;
        started := true; Condition.broadcast ready;
        while not !release do Condition.wait ready gate done;
        Mutex.unlock gate)) () in
    Mutex.lock gate;
    while not !started do Condition.wait ready gate done;
    Mutex.unlock gate;
    let rejected = ref false in
    let waiting = Thread.create (fun () ->
      try Db_runtime.read runtime (fun _ -> ())
      with Invalid_argument _ -> rejected := true) () in
    wait_until "read queued" (fun () ->
      Mutex.lock runtime.Db_runtime.pool_mutex;
      let queued = List.length runtime.Db_runtime.queued_readers in
      Mutex.unlock runtime.Db_runtime.pool_mutex;
      queued = 1);
    let finished = ref false in
    let closing = Thread.create (fun () ->
      Db_runtime.close runtime; finished := true) () in
    wait_until "close began" (fun () -> runtime.Db_runtime.closed);
    check "close waits for active reader" (not !finished);
    Mutex.lock gate; release := true; Condition.broadcast ready; Mutex.unlock gate;
    Thread.join holding; Thread.join waiting; Thread.join closing;
    check "queued read rejected on close" !rejected;
    check "close finished" !finished)

let test_close_waits_for_writer () =
  with_path (fun path ->
    let runtime = Db_runtime.open_db path in
    let gate = Mutex.create () in
    let ready = Condition.create () in
    let started = ref false in
    let release = ref false in
    let holding = Thread.create (fun () ->
      Db_runtime.write runtime (fun _ ->
        Mutex.lock gate;
        started := true; Condition.broadcast ready;
        while not !release do Condition.wait ready gate done;
        Mutex.unlock gate)) () in
    Mutex.lock gate;
    while not !started do Condition.wait ready gate done;
    Mutex.unlock gate;
    let rejected = ref false in
    let waiting = Thread.create (fun () ->
      try Db_runtime.write runtime (fun _ -> ())
      with Invalid_argument _ -> rejected := true) () in
    wait_until "write queued" (fun () ->
      Mutex.lock runtime.Db_runtime.scheduler_mutex;
      let queued = List.length runtime.Db_runtime.queued_writers in
      Mutex.unlock runtime.Db_runtime.scheduler_mutex;
      queued = 1);
    let finished = ref false in
    let closing = Thread.create (fun () ->
      Db_runtime.close runtime; finished := true) () in
    wait_until "close began" (fun () -> runtime.Db_runtime.closed);
    check "close waits for active writer" (not !finished);
    Mutex.lock gate; release := true; Condition.broadcast ready; Mutex.unlock gate;
    Thread.join holding; Thread.join waiting; Thread.join closing;
    check "queued write rejected on close" !rejected;
    check "writer close finished" !finished)

let test_async_saturation () =
  with_path (fun path ->
    let runtime = Db_runtime.open_db ~readers:1 path in
    Fun.protect ~finally:(fun () -> Db_runtime.close runtime) (fun () ->
      Db_runtime.write runtime (fun tx ->
        Db_runtime.exec (Db_runtime.conn tx)
          "CREATE TABLE runtime_counter (value integer NOT NULL)");
      let gate = Mutex.create () in
      let ready = Condition.create () in
      let started = ref false in
      let release = ref false in
      let order = ref [] in
      Lwt_main.run (
        let first = Db_runtime.write_async runtime (fun _ ->
          Mutex.lock gate;
          started := true; Condition.broadcast ready;
          while not !release do Condition.wait ready gate done;
          Mutex.unlock gate) in
        let open Lwt.Infix in
        let deadline = Unix.gettimeofday () +. 5. in
        let rec until label predicate =
          if predicate () then Lwt.return_unit
          else if Unix.gettimeofday () > deadline then Lwt.fail_with ("timed out: " ^ label)
          else Lwt_unix.sleep 0.001 >>= fun () -> until label predicate in
        until "async writer started" (fun () -> !started) >>= fun () ->
        let jobs = List.init 300 (fun n ->
          Db_runtime.write_async runtime (fun tx ->
            ignore (Db_runtime.execute (Db_runtime.conn tx)
              "INSERT INTO runtime_counter (value) VALUES (?)"
              [Sqlite3.Data.INT (Int64.of_int n)]);
            order := n :: !order)) in
        Mutex.lock runtime.Db_runtime.async_mutex;
        let queued = List.length runtime.Db_runtime.async_write_queue in
        let waiting = List.length runtime.Db_runtime.async_write_waiting in
        Mutex.unlock runtime.Db_runtime.async_mutex;
        check "bounded admitted queue" (queued = 256 && waiting = 44);
        Lwt_unix.sleep 0.02 >>= fun () ->
        Mutex.lock runtime.Db_runtime.async_mutex;
        let still_waiting = List.length runtime.Db_runtime.async_write_waiting in
        Mutex.unlock runtime.Db_runtime.async_mutex;
        check "event loop stayed live during saturation" (still_waiting = 44);
        Mutex.lock gate; release := true; Condition.broadcast ready; Mutex.unlock gate;
        first >>= fun () ->
        Lwt.join jobs) ;
      check "async writer FIFO" (List.rev !order = List.init 300 Fun.id);
      Db_runtime.read runtime (fun db ->
        check "all async writes committed" (count db "runtime_counter" = 300));
      Lwt_main.run (
        let open Lwt.Infix in
        let failed = Db_runtime.write_async runtime (fun tx ->
          ignore (Db_runtime.execute (Db_runtime.conn tx)
            "INSERT INTO runtime_counter (value) VALUES (?)" [Sqlite3.Data.INT 999L]);
          Db_runtime.emit_after_commit tx (fun () -> failwith "async callback error")) in
        Lwt.catch (fun () -> failed >|= fun () -> false)
          (function Failure message when message = "async callback error" -> Lwt.return_true
            | exn -> Lwt.fail exn) >>= fun rejected ->
        check "async callback error propagated" rejected;
        Db_runtime.read_async runtime (fun db -> count db "runtime_counter") >>= fun count ->
        check "async workers survive callback error" (count = 301);
        Lwt.return_unit)))

let test_async_reads_and_close () =
  with_path (fun path ->
    let runtime = Db_runtime.open_db ~readers:1 path in
    let gate = Mutex.create () in
    let ready = Condition.create () in
    let started = ref false in
    let release = ref false in
    Lwt_main.run (
      let open Lwt.Infix in
      let held = Db_runtime.read_async runtime (fun _ ->
        Mutex.lock gate;
        started := true; Condition.broadcast ready;
        while not !release do Condition.wait ready gate done;
        Mutex.unlock gate) in
      let deadline = Unix.gettimeofday () +. 5. in
      let rec until label predicate =
        if predicate () then Lwt.return_unit
        else if Unix.gettimeofday () > deadline then Lwt.fail_with ("timed out: " ^ label)
        else Lwt_unix.sleep 0.001 >>= fun () -> until label predicate in
      until "async reader started" (fun () -> !started) >>= fun () ->
      let queued = List.init 100 (fun _ -> Db_runtime.read_async runtime (fun _ -> 1)) in
      Mutex.lock runtime.Db_runtime.async_mutex;
      let waiting = List.length runtime.Db_runtime.async_read_queue in
      let workers = List.length runtime.Db_runtime.async_threads in
      Mutex.unlock runtime.Db_runtime.async_mutex;
      check "queued reads occupy no extra workers" (waiting = 100 && workers = 2);
      Lwt_unix.sleep 0.02 >>= fun () ->
      let closer = Lwt_preemptive.detach (fun () -> Db_runtime.close runtime) () in
      until "close began" (fun () -> runtime.Db_runtime.closed) >>= fun () ->
      Mutex.lock gate; release := true; Condition.broadcast ready; Mutex.unlock gate;
      held >>= fun () ->
      Lwt_list.map_s (fun promise ->
        Lwt.catch (fun () -> promise >|= fun _ -> false)
          (function Invalid_argument _ -> Lwt.return_true | exn -> Lwt.fail exn))
        queued >>= fun rejected ->
      check "pending async reads rejected" (List.for_all Fun.id rejected);
      closer))

let test_wal_and_backup_under_load () =
  with_path (fun path -> with_path (fun backup ->
    let runtime = Db_runtime.open_db ~readers:2 path in
    Fun.protect ~finally:(fun () -> Db_runtime.close runtime) (fun () ->
      Db_runtime.write runtime (fun tx ->
        Db_runtime.exec (Db_runtime.conn tx)
          "CREATE TABLE runtime_counter (value integer NOT NULL, payload blob NOT NULL)";
        ignore (Db_runtime.execute (Db_runtime.conn tx)
          "INSERT INTO runtime_counter (value, payload) VALUES (?, ?)"
          [Sqlite3.Data.INT 0L; Sqlite3.Data.BLOB (String.make 16_384 'x')]));
      Db_runtime.write runtime (fun tx ->
        check "writer auto checkpoint disabled"
          (scalar (Db_runtime.conn tx) "PRAGMA wal_autocheckpoint" = "0"));
      let maximum_pages = ref 0 in
      for _ = 1 to 2800 do
        Db_runtime.write runtime (fun tx ->
          Db_runtime.exec (Db_runtime.conn tx)
            "UPDATE runtime_counter SET value = value + 1, payload = randomblob(16384)");
        maximum_pages := max !maximum_pages (Db_runtime.wal_pages runtime)
      done;
      check "WAL restart threshold exercised" (!maximum_pages >= 9_000);
      check "WAL stayed below restart limit" (!maximum_pages < 10_000);
      wait_until "passive checkpoint" (fun () ->
        runtime.Db_runtime.passive_checkpoints > 0);
      check "truncating checkpoint ran"
        (runtime.Db_runtime.truncating_checkpoints > 0);
      Db_runtime.backup_to runtime backup;
      let copied = Sqlite3.db_open ~mode:`READONLY backup in
      Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close copied)) (fun () ->
        check "backup after sustained writes" (scalar copied
          "SELECT value FROM runtime_counter" = "2800");
        check "backup integrity under WAL" (scalar copied "PRAGMA integrity_check" = "ok")))))

let test_backup_during_writes () =
  with_path (fun path -> with_path (fun backup ->
    let runtime = Db_runtime.open_db path in
    Fun.protect ~finally:(fun () -> Db_runtime.close runtime) (fun () ->
      Db_runtime.write runtime (fun tx ->
        Db_runtime.exec (Db_runtime.conn tx)
          "CREATE TABLE balanced (id integer PRIMARY KEY, amount integer NOT NULL)";
        Db_runtime.exec (Db_runtime.conn tx)
          "INSERT INTO balanced VALUES (1, 0), (2, 1000)");
      let errors = ref [] in
      let worker = Thread.create (fun () ->
        try for _ = 1 to 500 do
          Db_runtime.write runtime (fun tx ->
            Db_runtime.exec (Db_runtime.conn tx)
              "UPDATE balanced SET amount = amount + CASE id WHEN 1 THEN 1 ELSE -1 END")
        done with exn -> errors := exn :: !errors) () in
      wait_until "writer started" (fun () ->
        Db_runtime.read runtime (fun db ->
          int_of_string (scalar db "SELECT amount FROM balanced WHERE id = 1") > 10));
      Db_runtime.backup_to runtime backup;
      Thread.join worker;
      check "writer completed" (!errors = []);
      let copied = Sqlite3.db_open ~mode:`READONLY backup in
      Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close copied)) (fun () ->
        check "backup captured one transaction boundary"
          (scalar copied "SELECT sum(amount) FROM balanced" = "1000");
        let first = int_of_string (scalar copied
          "SELECT amount FROM balanced WHERE id = 1") in
        check "backup captured live state" (first > 0 && first <= 500));
      Db_runtime.read runtime (fun db ->
        check "source writer finished" (scalar db
          "SELECT amount FROM balanced WHERE id = 1" = "500")))))

exception Statement_probe_rollback

let test_reused_writer_statements () =
  with_path (fun path ->
    let runtime = Db_runtime.open_db path in
    let query = "SELECT value FROM statement_probe WHERE id>=? ORDER BY id LIMIT 1" in
    let value db id = Db_runtime.query_one db query [Sqlite3.Data.INT id]
      (fun stmt -> Sqlite3.column_text stmt 0) in
    Fun.protect ~finally:(fun () -> Db_runtime.close runtime) (fun () ->
      Db_runtime.write runtime (fun tx ->
        let db = Db_runtime.conn tx in
        Db_runtime.exec db
          "CREATE TABLE statement_probe (id integer PRIMARY KEY, value text NOT NULL)";
        for id = 1 to 20 do
          ignore (Db_runtime.execute db
            "INSERT INTO statement_probe (id, value) VALUES (?, ?)"
            [Sqlite3.Data.INT (Int64.of_int id);
             Sqlite3.Data.TEXT (string_of_int id)])
        done;
        check "rebound query reads next row" (value db 5L = Some "5");
        let nested = Db_runtime.query_one db query [Sqlite3.Data.INT 2L]
          (fun stmt ->
            let outer = Sqlite3.column_text stmt 0 in
            check "same SQL nested while active" (value db 19L = Some "19");
            outer) in
        check "outer statement remains valid" (nested = Some "2"));
      (try Db_runtime.write runtime (fun tx ->
        ignore (Db_runtime.execute (Db_runtime.conn tx)
          "INSERT INTO statement_probe (id, value) VALUES (?, ?)"
          [Sqlite3.Data.INT 21L; Sqlite3.Data.TEXT "rollback"]);
        raise Statement_probe_rollback) with
        Statement_probe_rollback -> () | exn -> raise exn);
      Db_runtime.write runtime (fun tx ->
        check "rollback did not poison bound statement"
          (value (Db_runtime.conn tx) 21L = None));
      let rejected = try
        Db_runtime.write runtime (fun tx ->
          ignore (Db_runtime.execute (Db_runtime.conn tx)
            "INSERT INTO statement_probe (id, value) VALUES (?, ?)"
            [Sqlite3.Data.INT 1L; Sqlite3.Data.TEXT "duplicate"]));
        false
      with Failure message -> String.starts_with ~prefix:"SQLite execute:" message in
      check "constraint failure reported" rejected;
      Db_runtime.write runtime (fun tx ->
        ignore (Db_runtime.execute (Db_runtime.conn tx)
          "INSERT INTO statement_probe (id, value) VALUES (?, ?)"
          [Sqlite3.Data.INT 22L; Sqlite3.Data.TEXT "recovered"]);
        check "statement reused after SQLite error"
          (value (Db_runtime.conn tx) 22L = Some "recovered"));
      Db_runtime.read runtime (fun db ->
        check "reader sees reused writer result" (value db 20L = Some "20")));
    let reopened = Db_runtime.open_db ~prepare:false path in
    Fun.protect ~finally:(fun () -> Db_runtime.close reopened) (fun () ->
      Db_runtime.write reopened (fun tx ->
        check "cache finalized before reopen"
          (value (Db_runtime.conn tx) 20L = Some "20"))))

let () =
  Alcotest.run "database runtime" [
    "schema", [
      Alcotest.test_case "fresh" `Quick test_new_schema;
      Alcotest.test_case "default seed preservation" `Quick
        (fun () -> test_existing_seed "default" 1 10 11 169);
      Alcotest.test_case "first run seed preservation" `Quick
        (fun () -> test_existing_seed "first_run" 0 0 0 0);
      Alcotest.test_case "pending migration" `Quick test_pending_migration;
    ];
    "runtime", [
      Alcotest.test_case "transactions and callbacks" `Quick test_transactions_and_callbacks;
      Alcotest.test_case "concurrency and backup" `Quick test_concurrency_and_backup;
      Alcotest.test_case "FIFO scheduling" `Quick test_fifo_and_close;
      Alcotest.test_case "close waits for readers" `Quick test_close_waits_for_reader;
      Alcotest.test_case "close waits for writers" `Quick test_close_waits_for_writer;
      Alcotest.test_case "async saturation and callbacks" `Quick test_async_saturation;
      Alcotest.test_case "async reads and close" `Quick test_async_reads_and_close;
      Alcotest.test_case "WAL and backup under load" `Slow test_wal_and_backup_under_load;
      Alcotest.test_case "backup during writes" `Quick test_backup_during_writes;
      Alcotest.test_case "reused writer statements" `Quick test_reused_writer_statements;
    ];
  ]

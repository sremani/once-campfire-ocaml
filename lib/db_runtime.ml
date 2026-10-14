(** SQLite runtime compatible with Campfire's pinned Rails and Rust schema. *)

let schema_sql = {campfire_schema|
CREATE TABLE "accounts" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "created_at" datetime(6) NOT NULL, "custom_styles" text, "join_code" varchar NOT NULL, "name" varchar NOT NULL, "settings" json, "singleton_guard" integer DEFAULT 0 NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE UNIQUE INDEX "index_accounts_on_singleton_guard" ON "accounts" ("singleton_guard");
CREATE TABLE "action_text_rich_texts" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "body" text, "created_at" datetime(6) NOT NULL, "name" varchar NOT NULL, "record_id" bigint NOT NULL, "record_type" varchar NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE UNIQUE INDEX "index_action_text_rich_texts_uniqueness" ON "action_text_rich_texts" ("record_type", "record_id", "name");
CREATE TABLE "active_storage_blobs" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "byte_size" bigint NOT NULL, "checksum" varchar, "content_type" varchar, "created_at" datetime(6) NOT NULL, "filename" varchar NOT NULL, "key" varchar NOT NULL, "metadata" text, "service_name" varchar NOT NULL);
CREATE UNIQUE INDEX "index_active_storage_blobs_on_key" ON "active_storage_blobs" ("key");
CREATE TABLE "memberships" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "connected_at" datetime(6), "connections" integer DEFAULT 0 NOT NULL, "created_at" datetime(6) NOT NULL, "involvement" varchar DEFAULT 'mentions', "room_id" integer NOT NULL, "unread_at" datetime(6), "updated_at" datetime(6) NOT NULL, "user_id" integer NOT NULL);
CREATE INDEX "index_memberships_on_room_id_and_created_at" ON "memberships" ("room_id", "created_at");
CREATE UNIQUE INDEX "index_memberships_on_room_id_and_user_id" ON "memberships" ("room_id", "user_id");
CREATE INDEX "index_memberships_on_room_id" ON "memberships" ("room_id");
CREATE INDEX "index_memberships_on_user_id" ON "memberships" ("user_id");
CREATE TABLE "rooms" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "created_at" datetime(6) NOT NULL, "creator_id" bigint NOT NULL, "name" varchar, "type" varchar NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE TABLE "users" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "bio" text, "bot_token" varchar, "created_at" datetime(6) NOT NULL, "email_address" varchar, "name" varchar NOT NULL, "password_digest" varchar, "role" integer DEFAULT 0 NOT NULL, "status" integer DEFAULT 0 NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE UNIQUE INDEX "index_users_on_bot_token" ON "users" ("bot_token");
CREATE UNIQUE INDEX "index_users_on_email_address" ON "users" ("email_address");
CREATE TABLE "active_storage_attachments" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "blob_id" bigint NOT NULL, "created_at" datetime(6) NOT NULL, "name" varchar NOT NULL, "record_id" bigint NOT NULL, "record_type" varchar NOT NULL, CONSTRAINT "fk_rails_c3b3935057"
FOREIGN KEY ("blob_id")
  REFERENCES "active_storage_blobs" ("id")
);
CREATE INDEX "index_active_storage_attachments_on_blob_id" ON "active_storage_attachments" ("blob_id");
CREATE UNIQUE INDEX "index_active_storage_attachments_uniqueness" ON "active_storage_attachments" ("record_type", "record_id", "name", "blob_id");
CREATE TABLE "active_storage_variant_records" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "blob_id" bigint NOT NULL, "variation_digest" varchar NOT NULL, CONSTRAINT "fk_rails_993965df05"
FOREIGN KEY ("blob_id")
  REFERENCES "active_storage_blobs" ("id")
);
CREATE UNIQUE INDEX "index_active_storage_variant_records_uniqueness" ON "active_storage_variant_records" ("blob_id", "variation_digest");
CREATE TABLE "bans" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "created_at" datetime(6) NOT NULL, "ip_address" varchar NOT NULL, "updated_at" datetime(6) NOT NULL, "user_id" integer NOT NULL, CONSTRAINT "fk_rails_070022cd76"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE INDEX "index_bans_on_ip_address" ON "bans" ("ip_address");
CREATE INDEX "index_bans_on_user_id" ON "bans" ("user_id");
CREATE TABLE "boosts" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "booster_id" integer NOT NULL, "content" varchar(16) NOT NULL, "created_at" datetime(6) NOT NULL, "message_id" integer NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_3539c52d73"
FOREIGN KEY ("message_id")
  REFERENCES "messages" ("id")
);
CREATE INDEX "index_boosts_on_booster_id" ON "boosts" ("booster_id");
CREATE INDEX "index_boosts_on_message_id" ON "boosts" ("message_id");
CREATE TABLE "messages" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "client_message_id" varchar NOT NULL, "created_at" datetime(6) NOT NULL, "creator_id" integer NOT NULL, "room_id" integer NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_a8db0fb63a"
FOREIGN KEY ("room_id")
  REFERENCES "rooms" ("id")
, CONSTRAINT "fk_rails_761a2f12b3"
FOREIGN KEY ("creator_id")
  REFERENCES "users" ("id")
);
CREATE INDEX "index_messages_on_creator_id" ON "messages" ("creator_id");
CREATE INDEX "index_messages_on_room_id" ON "messages" ("room_id");
CREATE TABLE "push_subscriptions" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "auth_key" varchar, "created_at" datetime(6) NOT NULL, "endpoint" varchar, "p256dh_key" varchar, "updated_at" datetime(6) NOT NULL, "user_agent" varchar, "user_id" integer NOT NULL, CONSTRAINT "fk_rails_43d43720fc"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE INDEX "idx_on_endpoint_p256dh_key_auth_key_7553014576" ON "push_subscriptions" ("endpoint", "p256dh_key", "auth_key");
CREATE INDEX "index_push_subscriptions_on_user_id" ON "push_subscriptions" ("user_id");
CREATE TABLE "searches" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "created_at" datetime(6) NOT NULL, "query" varchar NOT NULL, "updated_at" datetime(6) NOT NULL, "user_id" integer NOT NULL, CONSTRAINT "fk_rails_e192b86393"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE INDEX "index_searches_on_user_id" ON "searches" ("user_id");
CREATE TABLE "sessions" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "created_at" datetime(6) NOT NULL, "ip_address" varchar, "last_active_at" datetime(6) NOT NULL, "token" varchar NOT NULL, "updated_at" datetime(6) NOT NULL, "user_agent" varchar, "user_id" integer NOT NULL, CONSTRAINT "fk_rails_758836b4f0"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE UNIQUE INDEX "index_sessions_on_token" ON "sessions" ("token");
CREATE INDEX "index_sessions_on_user_id" ON "sessions" ("user_id");
CREATE TABLE "webhooks" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, "url" varchar, "user_id" integer NOT NULL, CONSTRAINT "fk_rails_51bf96d3bc"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE INDEX "index_webhooks_on_user_id" ON "webhooks" ("user_id");
CREATE VIRTUAL TABLE message_search_index USING fts5 (body, tokenize=porter);
CREATE TABLE "schema_migrations" ("version" varchar NOT NULL PRIMARY KEY);
CREATE TABLE "ar_internal_metadata" ("key" varchar NOT NULL PRIMARY KEY, "value" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
|campfire_schema}

let migration_versions = [
  "20231215043540"; "20231220143106"; "20240110071740";
  "20240115124901"; "20240130003150"; "20240130213001";
  "20240131105830"; "20240209110503"; "20250825100957";
  "20250825100958"; "20250825100959"; "20251126092013";
  "20251126115722"; "20251126130131"; "20251212154340";
]

let schema_sha1 = "f75da8dad38bfb179ffd757bd7a7c2b3f818bc29"

let additions = [
  "CREATE INDEX IF NOT EXISTS \"index_messages_on_room_id_and_created_at\" ON \"messages\" (\"room_id\", \"created_at\")";
  "CREATE INDEX IF NOT EXISTS \"index_messages_on_room_id_and_updated_at\" ON \"messages\" (\"room_id\", \"updated_at\")";
]

let check_rc context = function
  | Sqlite3.Rc.OK -> ()
  | rc -> failwith (context ^ ": " ^ Sqlite3.Rc.to_string rc)

let exec db sql = check_rc "SQLite exec" (Sqlite3.exec db sql)

(* The writer has exclusive use of its connection. Reusing its compiled SQL
   avoids preparing the same INSERT and UPDATE on every message. Reader
   queries deliberately retain the normal prepare/finalize path: caching
   statements on all connections regressed the four measured GET routes. *)
let statement_cache_enabled = Sys.getenv_opt "CAMPFIRE_SQL_CACHE" <> Some "0"
let auth_statement_cache_enabled = Sys.getenv_opt "CAMPFIRE_AUTH_STMT_CACHE" = Some "1"
type cached_statement = { statement : Sqlite3.stmt; mutable in_use : bool }
type statement_cache = {
  statements : (string, cached_statement) Hashtbl.t;
  automatic : bool;
}
let statement_caches : (Sqlite3.db * statement_cache) list Atomic.t =
  Atomic.make []
let automatic_statement_caches : (Sqlite3.db * statement_cache) list Atomic.t =
  Atomic.make []

let atomic_add registry item =
  let rec add () =
    let before = Atomic.get registry in
    if not (Atomic.compare_and_set registry before (item :: before)) then add () in
  add ()

let atomic_remove registry db =
  let rec remove () =
    let before = Atomic.get registry in
    let after = List.filter (fun (registered, _) -> registered != db) before in
    if not (Atomic.compare_and_set registry before after) then remove () in
  remove ()

let register_statement_cache ?(automatic=true) db =
  if statement_cache_enabled then
    let cache = { statements = Hashtbl.create 128; automatic } in
    (atomic_add statement_caches (db, cache);
     if automatic then atomic_add automatic_statement_caches (db, cache))

let unregister_statement_cache db =
  if statement_cache_enabled then (
    let rec remove () =
      let before = Atomic.get statement_caches in
      let cache = List.find_opt (fun (registered, _) -> registered == db) before in
      let after = List.filter (fun (registered, _) -> registered != db) before in
      if Atomic.compare_and_set statement_caches before after then cache
      else remove () in
    let cache = remove () in
    atomic_remove automatic_statement_caches db;
    Option.iter (fun (_, cache) ->
      Hashtbl.iter (fun _ entry -> ignore (Sqlite3.finalize entry.statement))
        cache.statements) cache)

let with_statement_impl ~explicit db sql f =
  let cached =
    if not statement_cache_enabled then None else (
        let registry = if explicit then statement_caches else automatic_statement_caches in
        match List.find_opt (fun (registered, _) -> registered == db)
          (Atomic.get registry) with
        | None -> None
        | Some (_, cache) ->
            match Hashtbl.find_opt cache.statements sql with
            | Some entry when not entry.in_use ->
                entry.in_use <- true;
                Perf_probe.bump "sql_cache_hit";
                Some entry
            | None when Hashtbl.length cache.statements < 512 ->
                let entry = {statement=Sqlite3.prepare db sql;in_use=true} in
                Hashtbl.add cache.statements sql entry;
                Perf_probe.bump "sql_cache_miss";
                Some entry
            | _ -> Perf_probe.bump "sql_cache_fallback"; None) in
  match cached with
  | None ->
      let stmt = Sqlite3.prepare db sql in
      Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () -> f stmt)
  | Some entry ->
      Fun.protect ~finally:(fun () ->
        (try ignore (Sqlite3.reset entry.statement) with _ -> ());
        (try ignore (Sqlite3.clear_bindings entry.statement) with _ -> ());
        entry.in_use <- false)
        (fun () -> f entry.statement)

let with_statement db sql f = with_statement_impl ~explicit:false db sql f
let with_cached_statement db sql f = with_statement_impl ~explicit:true db sql f

let bind stmt params =
  check_rc "SQLite bind" (Sqlite3.bind_values stmt params)

let query_all db sql params row =
  with_statement db sql (fun stmt ->
    bind stmt params;
    let rec loop acc = match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW -> loop (row stmt :: acc)
      | Sqlite3.Rc.DONE -> List.rev acc
      | rc -> failwith ("SQLite query: " ^ Sqlite3.Rc.to_string rc)
    in loop [])

let query_one db sql params row =
  with_statement db sql (fun stmt ->
    bind stmt params;
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW -> Some (row stmt)
    | Sqlite3.Rc.DONE -> None
    | rc -> failwith ("SQLite query: " ^ Sqlite3.Rc.to_string rc))

let execute db sql params =
  with_statement db sql (fun stmt ->
    bind stmt params;
    match Sqlite3.step stmt with
    | Sqlite3.Rc.DONE -> Sqlite3.changes db
    | rc -> failwith ("SQLite execute: " ^ Sqlite3.Rc.to_string rc))

let placeholders n = String.concat ", " (List.init n (fun _ -> "?"))

let table_exists db name =
  Option.is_some (query_one db
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?"
    [Sqlite3.Data.TEXT name] (fun _ -> ()))

let pending_migrations db =
  if not (table_exists db "schema_migrations") then migration_versions
  else
    let installed = query_all db "SELECT version FROM schema_migrations" []
      (fun stmt -> Sqlite3.column_text stmt 0) in
    List.filter (fun version -> not (List.mem version installed)) migration_versions

let timestamp_now () =
  let now = Unix.gettimeofday () in
  let tm = Unix.gmtime now in
  let micros = int_of_float ((now -. floor now) *. 1_000_000.) in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d.%06d"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec micros

let set_internal_metadata db ~now key value =
  let existing = query_one db
    "SELECT value FROM ar_internal_metadata WHERE key = ?"
    [Sqlite3.Data.TEXT key] (fun stmt -> Sqlite3.column_text stmt 0) in
  match existing with
  | None ->
      ignore (execute db
        "INSERT INTO ar_internal_metadata (key, value, created_at, updated_at) VALUES (?, ?, ?, ?)"
        (List.map (fun s -> Sqlite3.Data.TEXT s) [key; value; now; now]))
  | Some current when current <> value ->
      ignore (execute db
        "UPDATE ar_internal_metadata SET value = ?, updated_at = ? WHERE key = ?"
        (List.map (fun s -> Sqlite3.Data.TEXT s) [value; now; key]))
  | Some _ -> ()

let transaction db f =
  exec db "BEGIN IMMEDIATE";
  match f () with
  | value ->
      (try exec db "COMMIT" with exn ->
        (try exec db "ROLLBACK" with _ -> ());
        raise exn);
      value
  | exception exn ->
      (try exec db "ROLLBACK" with _ -> ());
      raise exn

type prepared = Loaded | Up_to_date

let prepare_schema db ~environment =
  let prepared =
    if table_exists db "schema_migrations" then (
      let pending = pending_migrations db in
      if pending <> [] then
        failwith ("pending migrations: " ^ String.concat ", " pending);
      Up_to_date)
    else (
      (* An unrelated database must never be overwritten by schema load. *)
      let existing = query_one db
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' LIMIT 1"
        [] (fun stmt -> Sqlite3.column_text stmt 0) in
      if Option.is_some existing then failwith "database has tables but no schema_migrations";
      transaction db (fun () ->
        exec db schema_sql;
        List.iter (fun version ->
          ignore (execute db "INSERT INTO schema_migrations (version) VALUES (?)"
            [Sqlite3.Data.TEXT version])) (List.rev migration_versions);
        let now = timestamp_now () in
        set_internal_metadata db ~now "environment" environment;
        set_internal_metadata db ~now "schema_sha1" schema_sha1);
      Loaded) in
  List.iter (exec db) additions;
  prepared

let configure_connection db ~reader =
  Sqlite3.busy_timeout db 5000;
  exec db "PRAGMA foreign_keys = ON";
  exec db "PRAGMA journal_mode = WAL";
  exec db "PRAGMA synchronous = NORMAL";
  exec db "PRAGMA journal_size_limit = 67108864";
  exec db "PRAGMA cache_size = 2000";
  if reader then exec db "PRAGMA query_only = ON"

type tx = {
  db : Sqlite3.db;
  mutable in_transaction : bool;
  mutable callbacks : (tx -> unit) list;
}

let conn tx = tx.db
let in_transaction tx = tx.in_transaction

let after_commit tx callback =
  if tx.in_transaction then tx.callbacks <- callback :: tx.callbacks
  else callback tx

let emit_after_commit tx callback = after_commit tx (fun _ -> callback ())

type async_job = { run : unit -> unit; reject : exn -> unit }
type async_worker_handle = Thread_worker of Thread.t | Domain_worker of unit Domain.t
let async_domains_enabled = Sys.getenv_opt "CAMPFIRE_DB_DOMAINS" <> Some "0"
let domain_readers = match Sys.getenv_opt "CAMPFIRE_DB_DOMAIN_READERS" with
  | Some raw -> (match int_of_string_opt raw with
    | Some count when count >= 1 && count <= 8 -> count | _ -> 2)
  | None -> 2
let execution_id () = Domain.self (), Thread.id (Thread.self ())

type t = {
  path : string;
  writer : Sqlite3.db;
  writer_mutex : Mutex.t;
  scheduler_mutex : Mutex.t;
  scheduler_ready : Condition.t;
  mutable queued_writers : Condition.t list;
  mutable writer_active : bool;
  mutable writer_owner : (Domain.id * int) option;
  pool_mutex : Mutex.t;
  pool_ready : Condition.t;
  mutable queued_readers : Condition.t list;
  mutable available : Sqlite3.db list;
  mutable checked_out : int;
  mutable closed : bool;
  readers : int;
  owners : (Domain.id * int, int) Hashtbl.t;
  async_mutex : Mutex.t;
  async_ready : Condition.t;
  mutable async_started : bool;
  mutable async_write_queue : async_job list;
  mutable async_write_waiting : async_job list;
  mutable async_read_queue : async_job list;
  mutable async_workers : async_worker_handle list;
  checkpoint_db : Sqlite3.db;
  checkpoint_mutex : Mutex.t;
  checkpoint_running : Mutex.t;
  checkpoint_ready : Condition.t;
  mutable checkpoint_pending : bool;
  mutable checkpoint_woken_at : int;
  mutable passive_checkpoints : int;
  mutable truncating_checkpoints : int;
  mutable checkpoint_thread : Thread.t option;
  page_size : int;
}

let wal_pages t =
  try
    let bytes = (Unix.stat (t.path ^ "-wal")).Unix.st_size in
    if bytes < 32 then 0 else (bytes - 32) / (t.page_size + 24)
  with Unix.Unix_error (Unix.ENOENT, _, _) -> 0

let checkpoint_loop t =
  let rec loop () =
    Mutex.lock t.checkpoint_mutex;
    while not t.checkpoint_pending && not t.closed do
      Condition.wait t.checkpoint_ready t.checkpoint_mutex
    done;
    let stop = t.closed in
    t.checkpoint_pending <- false;
    Mutex.unlock t.checkpoint_mutex;
    if not stop then (
      Mutex.lock t.checkpoint_running;
      let result =
        try Sqlite3.exec t.checkpoint_db "PRAGMA wal_checkpoint(PASSIVE)"
        with _ -> Sqlite3.Rc.ERROR in
      Mutex.unlock t.checkpoint_running;
      if result = Sqlite3.Rc.OK then (
        Mutex.lock t.checkpoint_mutex;
        t.passive_checkpoints <- t.passive_checkpoints + 1;
        Mutex.unlock t.checkpoint_mutex);
      loop ())
  in loop ()

let after_write_checkpoint t =
  let pages = wal_pages t in
  Mutex.lock t.checkpoint_mutex;
  if pages < t.checkpoint_woken_at then t.checkpoint_woken_at <- 0;
  if pages >= 10_000 then (
    (* TRUNCATE waits for readers and bounds a WAL that cannot restart during
       sustained writes. Truncation makes file size a reliable page count for
       the OCaml binding, which does not expose a WAL hook. *)
    Mutex.lock t.checkpoint_running;
    let completed = try query_one t.writer "PRAGMA wal_checkpoint(TRUNCATE)" []
      (fun stmt -> Sqlite3.column_int stmt 0) = Some 0
      with _ -> false in
    Mutex.unlock t.checkpoint_running;
    if completed then
      t.truncating_checkpoints <- t.truncating_checkpoints + 1;
    t.checkpoint_woken_at <- 0)
  else if pages - t.checkpoint_woken_at >= 1_000 then (
    t.checkpoint_pending <- true;
    t.checkpoint_woken_at <- pages;
    Condition.signal t.checkpoint_ready);
  Mutex.unlock t.checkpoint_mutex

let open_reader path =
  let db = Sqlite3.db_open ~mode:`NO_CREATE path in
  try
    configure_connection db ~reader:true;
    if auth_statement_cache_enabled then register_statement_cache ~automatic:false db;
    db
  with exn -> ignore (Sqlite3.db_close db); raise exn

let close_reader db =
  if auth_statement_cache_enabled then unregister_statement_cache db;
  Sqlite3.db_close db

let open_db ?(readers=8) ?(prepare=true) ?(environment="production") path =
  let readers = max 1 readers in
  let writer = Sqlite3.db_open path in
  try
    configure_connection writer ~reader:false;
    if prepare then ignore (prepare_schema writer ~environment);
    exec writer "PRAGMA wal_autocheckpoint = 0";
    let opened = ref [] in
    (try
       for _ = 1 to readers do opened := open_reader path :: !opened done
     with exn -> List.iter (fun db -> ignore (close_reader db)) !opened; raise exn);
    let checkpoint_db = Sqlite3.db_open ~mode:`NO_CREATE path in
    (try configure_connection checkpoint_db ~reader:false
     with exn -> ignore (Sqlite3.db_close checkpoint_db); raise exn);
    let page_size = match query_one writer "PRAGMA page_size" []
      (fun stmt -> Sqlite3.column_int stmt 0) with Some value -> value | None -> 4096 in
    let t = { path; writer; writer_mutex = Mutex.create ();
      scheduler_mutex = Mutex.create (); scheduler_ready = Condition.create ();
      queued_writers = []; writer_active = false; writer_owner = None;
      pool_mutex = Mutex.create (); pool_ready = Condition.create ();
      queued_readers = []; available = !opened; checked_out = 0;
      closed = false; readers; owners = Hashtbl.create readers;
      async_mutex = Mutex.create (); async_ready = Condition.create ();
      async_started = false; async_write_queue = []; async_write_waiting = [];
      async_read_queue = []; async_workers = [];
      checkpoint_db; checkpoint_mutex = Mutex.create ();
      checkpoint_running = Mutex.create (); checkpoint_ready = Condition.create ();
      checkpoint_pending = false; checkpoint_woken_at = 0;
      passive_checkpoints = 0; truncating_checkpoints = 0;
      checkpoint_thread = None; page_size } in
    t.checkpoint_thread <- Some (Thread.create checkpoint_loop t);
    register_statement_cache writer;
    t
  with exn -> ignore (Sqlite3.db_close writer); raise exn

let read t f =
  let thread = execution_id () in
  Mutex.lock t.pool_mutex;
  let rec take ticket =
    if t.closed then (
      (match ticket with
       | None -> ()
       | Some ticket ->
           t.queued_readers <- List.filter (fun pending -> pending != ticket) t.queued_readers);
      Mutex.unlock t.pool_mutex; invalid_arg "database closed")
    else if Hashtbl.mem t.owners thread then (
      Mutex.unlock t.pool_mutex;
      let db = open_reader t.path in
      Fun.protect ~finally:(fun () -> ignore (close_reader db)) (fun () -> f db))
    else if (match ticket, t.queued_readers with
      | None, [] -> true
      | Some mine, head :: _ -> mine == head
      | _ -> false) && t.available <> [] then
      match t.available with
      | db :: rest ->
          (match ticket with Some _ -> t.queued_readers <- List.tl t.queued_readers | None -> ());
          t.available <- rest;
          t.checked_out <- t.checked_out + 1;
          Hashtbl.replace t.owners thread 1;
          (match t.queued_readers with
           | head :: _ when t.available <> [] -> Condition.signal head
           | _ -> ());
          Mutex.unlock t.pool_mutex;
          Fun.protect ~finally:(fun () ->
            Mutex.lock t.pool_mutex;
            Hashtbl.remove t.owners thread;
            t.available <- db :: t.available;
            t.checked_out <- t.checked_out - 1;
            (match t.queued_readers with head :: _ -> Condition.signal head | [] -> ());
            Condition.broadcast t.pool_ready;
            Mutex.unlock t.pool_mutex) (fun () -> f db)
      | [] -> assert false
    else
      let ticket = match ticket with
        | Some ticket -> ticket
        | None ->
            let ticket = Condition.create () in
            t.queued_readers <- t.queued_readers @ [ticket];
            ticket in
      Condition.wait ticket t.pool_mutex;
      take (Some ticket)
  in take None

let enter_writer t =
  Mutex.lock t.scheduler_mutex;
  let thread = execution_id () in
  let rec enter ticket =
    if t.closed then (
      (match ticket with
       | None -> ()
       | Some ticket ->
           t.queued_writers <- List.filter (fun pending -> pending != ticket) t.queued_writers);
      Mutex.unlock t.scheduler_mutex; invalid_arg "database closed")
    else if t.writer_owner = Some thread then (
      Mutex.unlock t.scheduler_mutex; invalid_arg "recursive database write")
    else match ticket with
    | None when not t.writer_active && t.queued_writers = [] ->
        t.writer_active <- true; t.writer_owner <- Some thread;
        Mutex.unlock t.scheduler_mutex
    | None when List.length t.queued_writers >= 256 ->
        Condition.wait t.scheduler_ready t.scheduler_mutex; enter None
    | None ->
        let ticket = Condition.create () in
        t.queued_writers <- t.queued_writers @ [ticket];
        Condition.wait ticket t.scheduler_mutex; enter (Some ticket)
    | Some ticket ->
        (match t.queued_writers with
         | head :: rest when head == ticket && not t.writer_active ->
             t.queued_writers <- rest;
             t.writer_active <- true;
             t.writer_owner <- Some thread;
             Condition.broadcast t.scheduler_ready;
             Mutex.unlock t.scheduler_mutex
         | _ -> Condition.wait ticket t.scheduler_mutex; enter (Some ticket))
  in enter None

let leave_writer t =
  Mutex.lock t.scheduler_mutex;
  t.writer_active <- false;
  t.writer_owner <- None;
  (match t.queued_writers with head :: _ -> Condition.signal head | [] -> ());
  Condition.broadcast t.scheduler_ready;
  Mutex.unlock t.scheduler_mutex

let write t f =
  enter_writer t;
  Mutex.lock t.writer_mutex;
  Fun.protect ~finally:(fun () ->
    Perf_probe.time "db_write_checkpoint" (fun () ->
      after_write_checkpoint t);
    Mutex.unlock t.writer_mutex;
    leave_writer t) (fun () ->
    if t.closed then invalid_arg "database closed";
    Perf_probe.time "db_write_begin" (fun () ->
      exec t.writer "BEGIN IMMEDIATE");
    let tx = {db = t.writer; in_transaction = true; callbacks = []} in
    let value =
      match Perf_probe.time "db_write_tx_body" (fun () -> f tx) with
      | value ->
          (try Perf_probe.time "db_write_commit" (fun () ->
             exec t.writer "COMMIT") with exn ->
            (try exec t.writer "ROLLBACK" with _ -> ()); raise exn);
          value
      | exception exn ->
          (try exec t.writer "ROLLBACK" with _ -> ());
          raise exn in
    tx.in_transaction <- false;
    let first_error = ref None in
    Perf_probe.time "db_write_callbacks" (fun () ->
      List.iter (fun callback ->
        try callback tx with exn ->
          if !first_error = None then first_error := Some exn)
        (List.rev tx.callbacks));
    match !first_error with None -> value | Some exn -> raise exn)

let async_worker t ~writer =
  let rec loop () =
    Mutex.lock t.async_mutex;
    let rec next () =
      let queue = if writer then t.async_write_queue else t.async_read_queue in
      match queue with
      | job :: rest ->
          if writer then (
            t.async_write_queue <- rest;
            (match t.async_write_waiting with
             | waiting :: tail ->
                 t.async_write_waiting <- tail;
                 t.async_write_queue <- t.async_write_queue @ [waiting]
             | [] -> ()))
          else t.async_read_queue <- rest;
          Mutex.unlock t.async_mutex;
          Some job
      | [] when t.closed -> Mutex.unlock t.async_mutex; None
      | [] -> Condition.wait t.async_ready t.async_mutex; next ()
    in
    match next () with
    | None -> ()
    | Some job ->
        (try Perf_probe.time (if writer then "db_write_worker" else "db_read_worker") job.run
         with exn -> job.reject exn);
        loop ()
  in loop ()

let ensure_async_workers t =
  Mutex.lock t.async_mutex;
  (if t.closed then (
     Mutex.unlock t.async_mutex; invalid_arg "database closed")
   else if not t.async_started then (
     Lwt_preemptive.simple_init ();
     t.async_started <- true;
     let spawn writer =
       if async_domains_enabled then
         Domain_worker (Domain.spawn (fun () -> async_worker t ~writer))
       else Thread_worker (Thread.create (fun () -> async_worker t ~writer) ()) in
     let reader_workers = if async_domains_enabled then min t.readers domain_readers
       else t.readers in
     t.async_workers <- spawn true :: List.init reader_workers (fun _ -> spawn false)));
  Mutex.unlock t.async_mutex

let async_promise f =
  let promise, wakener = Lwt.wait () in
  let deliver result =
    Lwt_preemptive.run_in_main_dont_wait
      (fun () -> Lwt.wakeup_later_result wakener result; Lwt.return_unit)
      (fun _ -> ()) in
  let job = {
    run = (fun () -> deliver (try Ok (f ()) with exn -> Error exn));
    reject = (fun exn -> deliver (Error exn));
  } in
  promise, job

(** Queued reads run on a fixed set of reader threads. Queued jobs use no
    waiting OS threads; callers await the Lwt promise. *)
let read_async t f =
  ensure_async_workers t;
  let promise, job = async_promise (fun () -> read t f) in
  Mutex.lock t.async_mutex;
  if t.closed then job.reject (Invalid_argument "database closed")
  else (
    t.async_read_queue <- t.async_read_queue @ [job];
    Condition.broadcast t.async_ready);
  Mutex.unlock t.async_mutex;
  Perf_probe.time_lwt "db_read_wait" (fun () -> promise)

(** The writer's admitted queue is capped at 256. Further Lwt callers retain
    promises and wait in an admission queue without occupying OS threads. *)
let write_async t f =
  ensure_async_workers t;
  let promise, job = async_promise (fun () -> write t f) in
  Mutex.lock t.async_mutex;
  if t.closed then job.reject (Invalid_argument "database closed")
  else if List.length t.async_write_queue < 256 && t.async_write_waiting = [] then (
    t.async_write_queue <- t.async_write_queue @ [job];
    Condition.broadcast t.async_ready)
  else t.async_write_waiting <- t.async_write_waiting @ [job];
  Mutex.unlock t.async_mutex;
  Perf_probe.time_lwt "db_write_wait" (fun () -> promise)

let close t =
  Mutex.lock t.pool_mutex;
  let in_read = Hashtbl.mem t.owners (execution_id ()) in
  Mutex.unlock t.pool_mutex;
  if in_read then invalid_arg "close inside database read";
  Mutex.lock t.scheduler_mutex;
  if t.writer_owner = Some (execution_id ()) then (
    Mutex.unlock t.scheduler_mutex; invalid_arg "close inside database write");
  if t.closed then (
    Mutex.unlock t.scheduler_mutex; invalid_arg "database already closed");
  t.closed <- true;
  List.iter Condition.signal t.queued_writers;
  Condition.broadcast t.scheduler_ready;
  while t.writer_active do Condition.wait t.scheduler_ready t.scheduler_mutex done;
  Mutex.unlock t.scheduler_mutex;
  Mutex.lock t.async_mutex;
  let rejected = t.async_write_queue @ t.async_write_waiting @ t.async_read_queue in
  t.async_write_queue <- [];
  t.async_write_waiting <- [];
  t.async_read_queue <- [];
  Condition.broadcast t.async_ready;
  Mutex.unlock t.async_mutex;
  List.iter (fun job -> job.reject (Invalid_argument "database closed")) rejected;
  Mutex.lock t.checkpoint_mutex;
  Condition.signal t.checkpoint_ready;
  Mutex.unlock t.checkpoint_mutex;
  Mutex.lock t.writer_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.writer_mutex) (fun () ->
    Mutex.lock t.pool_mutex;
    List.iter Condition.signal t.queued_readers;
    Condition.broadcast t.pool_ready;
    while t.checked_out > 0 do Condition.wait t.pool_ready t.pool_mutex done;
    let readers = t.available in
    t.available <- [];
    Mutex.unlock t.pool_mutex;
    List.iter (function Thread_worker worker -> Thread.join worker
      | Domain_worker worker -> Domain.join worker) t.async_workers;
    (match t.checkpoint_thread with Some thread -> Thread.join thread | None -> ());
    List.iter (fun db -> if not (close_reader db) then failwith "reader still busy") readers;
    if not (Sqlite3.db_close t.checkpoint_db) then failwith "checkpointer still busy";
    unregister_statement_cache t.writer;
    if not (Sqlite3.db_close t.writer) then failwith "writer still busy")

let backup_to t destination =
  if Sys.file_exists destination then invalid_arg "backup destination already exists";
  (* VACUUM INTO copies one consistent snapshot, including committed WAL pages.
     The OCaml sqlite3 binding's Backup API crashes on the pinned fixture. *)
  try
    if t.closed then invalid_arg "database closed";
    let source = Sqlite3.db_open ~mode:`NO_CREATE t.path in
    Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close source)) (fun () ->
      Sqlite3.busy_timeout source 5000;
      let quoted = String.concat "''" (String.split_on_char '\'' destination) in
      exec source ("VACUUM INTO '" ^ quoted ^ "'"))
  with exn ->
    List.iter (fun suffix ->
      let file = destination ^ suffix in
      if Sys.file_exists file then Sys.remove file) [""; "-wal"; "-shm"];
    raise exn

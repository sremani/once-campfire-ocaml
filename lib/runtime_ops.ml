(** Process operations shared by the CLI and the service boot path. *)

open Lwt.Infix

let log = Logs.Src.create "campfire.operations"
module Log = (val Logs.src_log log : Logs.LOG)

let log_level value = match String.lowercase_ascii value with
  | "debug" -> Some Logs.Debug
  | "warn" -> Some Logs.Warning
  | "error" | "fatal" | "unknown" -> Some Logs.Error
  | _ -> Some Logs.Info

let rec ensure_directory path =
  if path <> "" && path <> "." then
    if Sys.file_exists path then (
      if not (Sys.is_directory path) then
        invalid_arg ("not a directory: " ^ path))
    else (
      ensure_directory (Filename.dirname path);
      try Unix.mkdir path 0o700 with
      | Unix.Unix_error (Unix.EEXIST, _, _) when Sys.is_directory path -> ())

let storage_ready (config:Config.t) =
  ensure_directory (Filename.dirname config.storage.database);
  ensure_directory config.storage.files

let verify_snapshot path =
  let db = Sqlite3.db_open ~mode:`READONLY path in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close db)) (fun () ->
    match Db_runtime.query_one db "PRAGMA integrity_check" []
      (fun stmt -> Sqlite3.column_text stmt 0) with
    | Some "ok" ->
        List.iter (fun name ->
          if not (Db_runtime.table_exists db name) then
            failwith ("backup missing table " ^ name)) Database.required_tables
    | Some issue -> failwith ("backup integrity check: " ^ issue)
    | None -> failwith "backup integrity check returned no result")

let backup (config:Config.t) =
  let source = config.storage.database in
  if not (Sys.file_exists source) then
    invalid_arg ("database does not exist: " ^ source);
  let destination = Filename.concat config.storage.backups
    (Filename.basename source) in
  ensure_directory config.storage.backups;
  let partial, channel = Filename.open_temp_file
    ~temp_dir:config.storage.backups ".backup-" ".sqlite3" in
  close_out channel;
  Sys.remove partial;
  Fun.protect ~finally:(fun () ->
    List.iter (fun suffix ->
      let path = partial ^ suffix in
      if Sys.file_exists path then Sys.remove path) ["";"-wal";"-shm"])
    (fun () ->
      let runtime = Db_runtime.open_db ~prepare:false source in
      Fun.protect ~finally:(fun () -> Db_runtime.close runtime) (fun () ->
        Db_runtime.backup_to runtime partial);
      verify_snapshot partial;
      let fd = Unix.openfile partial [Unix.O_RDONLY] 0 in
      Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd);
      Unix.rename partial destination;
      let dir = Unix.openfile config.storage.backups [Unix.O_RDONLY] 0 in
      Fun.protect ~finally:(fun () -> Unix.close dir) (fun () -> Unix.fsync dir);
      Log.info (fun m -> m "backup written: %s" destination);
      destination)

let boot_check runtime =
  Db_runtime.read runtime (fun db ->
    if not (Db_runtime.table_exists db "schema_migrations") then
      failwith "Campfire schema_migrations table is missing";
    if not (Db_runtime.table_exists db "memberships") then
      failwith "Campfire memberships table is missing");
  Log.info (fun m -> m "Campfire database ready")

let reset_presence runtime =
  let now = Http_app.now_utc () in
  Db_runtime.write runtime (fun tx ->
    ignore (Db_rooms.Membership.disconnect_all tx ~now))

module Drain = struct
  type t = { mutable active:int; changed:unit Lwt_condition.t }
  let create () = {active=0;changed=Lwt_condition.create ()}
  let track t f =
    t.active <- t.active + 1;
    Lwt.finalize f (fun () ->
      t.active <- t.active - 1;
      Lwt_condition.broadcast t.changed ();
      Lwt.return_unit)
  let rec wait t ~deadline =
    if t.active = 0 then Lwt.return_true
    else let remaining = deadline -. Unix.gettimeofday () in
      if remaining <= 0. then Lwt.return_false
      else Lwt.pick [
        (Lwt_condition.wait t.changed >|= fun () -> `Changed);
        (Lwt_unix.sleep remaining >|= fun () -> `Timeout)]
        >>= function `Timeout -> Lwt.return_false
          | `Changed -> wait t ~deadline
end

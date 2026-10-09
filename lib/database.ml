(** Read-only compatibility checks for the existing Rails SQLite database. *)

let required_tables = [
  "accounts"; "action_text_rich_texts"; "active_storage_blobs";
  "active_storage_attachments"; "active_storage_variant_records";
  "memberships"; "rooms"; "users"; "bans"; "boosts"; "messages";
  "push_subscriptions"; "searches"; "sessions"; "webhooks";
  "message_search_index"; "schema_migrations"; "ar_internal_metadata";
]

type inspection = {
  sqlite_version : string;
  missing_tables : string list;
  account_count : int;
}

let with_statement db sql f =
  let stmt = Sqlite3.prepare db sql in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () -> f stmt)

let table_names db =
  with_statement db "SELECT name FROM sqlite_master WHERE type IN ('table','view')" (fun stmt ->
    let rec gather names =
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW -> gather (Sqlite3.column_text stmt 0 :: names)
      | Sqlite3.Rc.DONE -> names
      | rc -> failwith ("SQLite schema query: " ^ Sqlite3.Rc.to_string rc)
    in
    gather [])

let account_count db =
  with_statement db "SELECT count(*) FROM accounts" (fun stmt ->
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW -> Sqlite3.column_int stmt 0
    | rc -> failwith ("SQLite account query: " ^ Sqlite3.Rc.to_string rc))

let inspect path =
  if not (Sys.file_exists path) then Error ("Database does not exist: " ^ path)
  else
    try
      let db = Sqlite3.db_open ~mode:`READONLY path in
      Fun.protect
        ~finally:(fun () -> ignore (Sqlite3.db_close db))
        (fun () ->
          let names = table_names db in
          let missing_tables = List.filter (fun name -> not (List.mem name names)) required_tables in
          let account_count = if List.mem "accounts" names then account_count db else 0 in
          Ok { sqlite_version = Sqlite3.sqlite_version_info (); missing_tables; account_count })
    with Sqlite3.SqliteError message -> Error message
       | Failure message -> Error message

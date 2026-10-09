(** Active Record's SQLite datetime(6) text encoding. *)

let to_db now =
  let value = Authentication.sql_time now in
  if String.ends_with ~suffix:".000000" value then
    String.sub value 0 (String.length value - 7)
  else value

let of_rfc3339 value = to_db (Authentication.now_time value)

let sqlite_now = "STRFTIME('%Y-%m-%d %H:%M:%f', 'NOW')"

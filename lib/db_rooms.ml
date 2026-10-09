(** Rooms and memberships in the pinned Campfire SQLite schema. Mutations compose
    inside [Db_runtime.write]; callback work runs only after a successful commit. *)

let q = Db_runtime.query_one
let query_all = Db_runtime.query_all
let run db sql values = ignore (Db_runtime.execute db sql values)
let i n = Sqlite3.Data.INT n
let s value = Sqlite3.Data.TEXT value
let opt f = function None -> Sqlite3.Data.NULL | Some x -> f x
let col_opt stmt n = match Sqlite3.column stmt n with
  | Sqlite3.Data.NULL -> None | _ -> Some (Sqlite3.column_text stmt n)
let sql_time = Db_time.to_db
let timestamp = Db_time.of_rfc3339
let db tx = Db_runtime.conn tx
let required name = function Some x -> x | None -> failwith (name ^ " not found")
let sql_count db sql values = match q db sql values (fun row -> Sqlite3.column_int64 row 0) with
  | Some n -> n | None -> assert false

type room_type = Open | Closed | Direct
let room_type_name = function Open -> "Rooms::Open" | Closed -> "Rooms::Closed" | Direct -> "Rooms::Direct"
let room_type_of_name = function
  | "Rooms::Open" -> Open | "Rooms::Closed" -> Closed | "Rooms::Direct" -> Direct
  | value -> failwith ("unknown room type " ^ value)
let involvement_for_type = function Direct -> "everything" | Open | Closed -> "mentions"

type involvement = Invisible | Nothing | Mentions | Everything
let involvement_name = function
  | Invisible -> "invisible" | Nothing -> "nothing" | Mentions -> "mentions" | Everything -> "everything"
let involvement_of_name = function
  | "invisible" -> Invisible | "nothing" -> Nothing | "mentions" -> Mentions | "everything" -> Everything
  | value -> failwith ("unknown involvement " ^ value)

module Room = struct
  type t = { id:int64; name:string option; room_type:room_type; creator_id:int64;
             created_at:string; updated_at:string }
  let columns = "rooms.id,rooms.name,rooms.type,rooms.creator_id,rooms.created_at,rooms.updated_at"
  let decode_at row n = {
    id=Sqlite3.column_int64 row n; name=col_opt row (n+1);
    room_type=room_type_of_name (Sqlite3.column_text row (n+2));
    creator_id=Sqlite3.column_int64 row (n+3);
    created_at=Sqlite3.column_text row (n+4); updated_at=Sqlite3.column_text row (n+5) }
  let decode row = decode_at row 0
  let select = "SELECT " ^ columns ^ " FROM rooms"
  let find_by_id db id = q db (select ^ " WHERE rooms.id=? LIMIT 1") [i id] decode
  let find db id = required "Room" (find_by_id db id)
  let all db = query_all db select [] decode
  let of_type db kind = query_all db (select ^ " WHERE rooms.type=?") [s (room_type_name kind)] decode
  let count_of_type db kind = sql_count db "SELECT COUNT(*) FROM rooms WHERE type=?" [s (room_type_name kind)]
  let original db = q db (select ^ " ORDER BY rooms.created_at ASC LIMIT 1") [] decode
  let user_select = select ^ " INNER JOIN memberships ON rooms.id=memberships.room_id WHERE memberships.user_id=?"
  let for_user db user_id = query_all db user_select [i user_id] decode
  let find_for_user db user_id room_id = q db (user_select ^ " AND rooms.id=? LIMIT 1") [i user_id;i room_id] decode
  let for_user_of_type db user_id kind = query_all db (user_select ^ " AND rooms.type=?") [i user_id;s (room_type_name kind)] decode
  let for_user_without_directs db user_id = query_all db (user_select ^ " AND rooms.type!=?") [i user_id;s (room_type_name Direct)] decode
  let original_for_user db user_id = q db (user_select ^ " ORDER BY rooms.created_at ASC LIMIT 1") [i user_id] decode
  let last_for_user db user_id = q db (user_select ^ " ORDER BY rooms.id DESC LIMIT 1") [i user_id] decode
  let open_ room = room.room_type=Open
  let closed room = room.room_type=Closed
  let direct room = room.room_type=Direct
  let default_involvement room = involvement_for_type room.room_type
  let reload db room = find db room.id
  let user_ids db room = query_all db
    "SELECT users.id FROM users INNER JOIN memberships ON users.id=memberships.user_id WHERE memberships.room_id=?"
    [i room.id] (fun row -> Sqlite3.column_int64 row 0)
  let users db room = query_all db
    ("SELECT users.id,users.name,users.email_address,users.password_digest,users.role,users.status,users.bio,users.bot_token,users.created_at,users.updated_at FROM users INNER JOIN memberships ON users.id=memberships.user_id WHERE memberships.room_id=?")
    [i room.id] Db_accounts.User.decode
  let active_bots db room = query_all db
    ("SELECT users.id,users.name,users.email_address,users.password_digest,users.role,users.status,users.bio,users.bot_token,users.created_at,users.updated_at FROM users INNER JOIN memberships ON users.id=memberships.user_id WHERE memberships.room_id=? AND users.status=0 AND users.role=2")
    [i room.id] Db_accounts.User.decode
  let insert_memberships tx room_id kind user_ids =
    let rec chunks = function
      | [] -> ()
      | ids ->
          let rec take n acc rest = match rest with
            | x::xs when n>0 -> take (n-1) (x::acc) xs
            | _ -> List.rev acc,rest in
          let batch,rest = take 1000 [] ids in
          let rows = List.map (fun _ -> "(STRFTIME('%Y-%m-%d %H:%M:%f','NOW'),?,?,STRFTIME('%Y-%m-%d %H:%M:%f','NOW'),?)") batch in
          let params = List.concat_map (fun uid -> [s (involvement_for_type kind);i room_id;i uid]) batch in
          run (db tx) ("INSERT INTO memberships (created_at,involvement,room_id,updated_at,user_id) VALUES " ^
            String.concat "," rows ^ " ON CONFLICT DO NOTHING") params;
          chunks rest in
    chunks user_ids
  let grant_to tx room user_ids = insert_memberships tx room.id room.room_type user_ids
  let grant_to_active_users tx room_id =
    let room = find (db tx) room_id in
    let ids = query_all (db tx) "SELECT id FROM users WHERE status=0" [] (fun row -> Sqlite3.column_int64 row 0) in
    grant_to tx room ids
  let create tx ~now kind ~name ~creator_id =
    let at = timestamp now in
    run (db tx) "INSERT INTO rooms (created_at,creator_id,name,type,updated_at) VALUES (?,?,?,?,?)"
      [s at;i creator_id;opt s name;s (room_type_name kind);s at];
    let id = Sqlite3.last_insert_rowid (db tx) in
    if kind=Open then Db_runtime.after_commit tx (fun tx -> grant_to_active_users tx id);
    find (db tx) id
  let create_for tx ~now kind ~name ~creator_id user_ids =
    let room = create tx ~now kind ~name ~creator_id in
    grant_to tx room user_ids; room
  let find_direct_for db participant_ids =
    let wanted = List.sort_uniq Int64.compare participant_ids in
    let candidates = query_all db (select ^ " INNER JOIN memberships ON memberships.room_id=rooms.id INNER JOIN users ON users.id=memberships.user_id WHERE rooms.type=?")
      [s (room_type_name Direct)] decode in
    List.find_opt (fun room -> List.sort_uniq Int64.compare (user_ids db room)=wanted) candidates
  let find_or_create_direct_for tx ~now ~user_ids ~creator_id =
    match find_direct_for (db tx) user_ids with
    | Some room -> room
    | None -> create_for tx ~now Direct ~name:None ~creator_id user_ids
  let update tx ~now room ?name ?room_type () =
    let new_name = Option.value ~default:room.name name in
    let new_type = Option.value ~default:room.room_type room_type in
    if room.room_type=Direct && room.room_type<>new_type then
      invalid_arg "type can't be changed for a direct room";
    if new_name=room.name && new_type=room.room_type then room else (
      let at = timestamp now in
      run (db tx) "UPDATE rooms SET name=?,type=?,updated_at=? WHERE id=?"
        [opt s new_name;s (room_type_name new_type);s at;i room.id];
      if new_type=Open && room.room_type<>Open then
        Db_runtime.after_commit tx (fun tx -> grant_to_active_users tx room.id);
      {room with name=new_name;room_type=new_type;updated_at=at})
  let touch tx ~now room_id =
    run (db tx) "UPDATE rooms SET updated_at=? WHERE id=?" [s (sql_time now);i room_id]
  let destroy_tx tx room ~destroy_messages =
    run (db tx) "DELETE FROM memberships WHERE room_id=?" [i room.id];
    destroy_messages tx ~room_id:room.id;
    run (db tx) "DELETE FROM rooms WHERE id=?" [i room.id]
  let receive tx ~now ~room_id ~message_id ~created_at ~creator_id ~on_push =
    let cutoff = sql_time (Ptime.sub_span now (Ptime.Span.of_int_s 60) |> Option.get) in
    run (db tx) "UPDATE memberships SET unread_at=?,updated_at=? WHERE room_id=? AND involvement!='invisible' AND (connected_at IS NULL OR connected_at<?) AND user_id!=?"
      [s created_at;s (sql_time now);i room_id;s cutoff;i creator_id];
    Db_runtime.emit_after_commit tx (fun () -> on_push ~room_id ~message_id)
end

module Membership = struct
  type t = { id:int64;room_id:int64;user_id:int64;involvement:involvement option;
             unread_at:string option;connected_at:string option;connections:int64;
             created_at:string;updated_at:string }
  let columns = "memberships.id,memberships.room_id,memberships.user_id,memberships.involvement,memberships.unread_at,memberships.connected_at,memberships.connections,memberships.created_at,memberships.updated_at"
  let decode_at row n = {
    id=Sqlite3.column_int64 row n;room_id=Sqlite3.column_int64 row (n+1);
    user_id=Sqlite3.column_int64 row (n+2);
    involvement=Option.map involvement_of_name (col_opt row (n+3));
    unread_at=col_opt row (n+4);connected_at=col_opt row (n+5);
    connections=Sqlite3.column_int64 row (n+6);
    created_at=Sqlite3.column_text row (n+7);updated_at=Sqlite3.column_text row (n+8) }
  let decode row = decode_at row 0
  let select = "SELECT " ^ columns ^ " FROM memberships"
  let find db id = required "Membership" (q db (select ^ " WHERE memberships.id=? LIMIT 1") [i id] decode)
  let count db = sql_count db "SELECT COUNT(*) FROM memberships" []
  let for_user db user_id = query_all db (select ^ " WHERE memberships.user_id=?") [i user_id] decode
  let for_room db room_id = query_all db (select ^ " WHERE memberships.room_id=?") [i room_id] decode
  let find_by_room_and_user db room_id user_id = q db (select ^ " WHERE memberships.room_id=? AND memberships.user_id=? LIMIT 1") [i room_id;i user_id] decode
  let with_ordered_room db user_id = query_all db
    ("SELECT " ^ columns ^ "," ^ Room.columns ^ " FROM memberships INNER JOIN rooms ON rooms.id=memberships.room_id WHERE memberships.user_id=? ORDER BY LOWER(rooms.name)")
    [i user_id] (fun row -> decode row,Room.decode_at row 9)
  let visible_with_ordered_room db user_id = query_all db
    ("SELECT " ^ columns ^ "," ^ Room.columns ^ " FROM memberships INNER JOIN rooms ON rooms.id=memberships.room_id WHERE memberships.user_id=? AND memberships.involvement!='invisible' ORDER BY LOWER(rooms.name)")
    [i user_id] (fun row -> decode row,Room.decode_at row 9)
  let count_without_direct_rooms db user_id = sql_count db
    "SELECT COUNT(*) FROM memberships INNER JOIN rooms ON rooms.id=memberships.room_id WHERE memberships.user_id=? AND rooms.type!='Rooms::Direct'" [i user_id]
  let unread_count db user_id = sql_count db "SELECT COUNT(*) FROM memberships WHERE user_id=? AND unread_at IS NOT NULL" [i user_id]
  let cutoff now = sql_time (Ptime.sub_span (Db_accounts.now_time now) (Ptime.Span.of_int_s 60) |> Option.get)
  let connected_exists db id ~now = Option.is_some (q db "SELECT 1 FROM memberships WHERE connected_at>=? AND id=? LIMIT 1" [s (cutoff now);i id] (fun _ -> ()))
  let disconnected_exists db id ~now = Option.is_some (q db "SELECT 1 FROM memberships WHERE (connected_at IS NULL OR connected_at<?) AND id=? LIMIT 1" [s (cutoff now);i id] (fun _ -> ()))
  let room db membership = Room.find db membership.room_id
  let user db membership = Db_accounts.User.find db membership.user_id
  let involved_in membership involvement = membership.involvement=Some involvement
  let unread membership = Option.is_some membership.unread_at
  let reload db membership = find db membership.id
  let update_involvement tx ~now membership involvement =
    if membership.involvement=involvement then membership else (
      let at=timestamp now in
      run (db tx) "UPDATE memberships SET involvement=?,updated_at=? WHERE id=?"
        [opt (fun x -> s (involvement_name x)) involvement;s at;i membership.id];
      {membership with involvement;updated_at=at})
  let read tx ~now membership =
    if membership.unread_at=None then membership else (
      let at=timestamp now in
      run (db tx) "UPDATE memberships SET unread_at=NULL,updated_at=? WHERE id=?" [s at;i membership.id];
      {membership with unread_at=None;updated_at=at})
  let destroy tx membership ~on_disconnect =
    run (db tx) "DELETE FROM memberships WHERE id=?" [i membership.id];
    Db_runtime.emit_after_commit tx (fun () ->
      ignore (Db_accounts.User.find (db tx) membership.user_id);
      on_disconnect ~user_id:membership.user_id ~reconnect:true)
  let is_connected membership ~now = match membership.connected_at with
    | None -> false
    | Some at -> (match Db_accounts.parse_time at with
      | None -> false
      | Some at -> Ptime.compare at (Db_accounts.now_time now |> fun n -> Ptime.sub_span n (Ptime.Span.of_int_s 60) |> Option.get)>=0)
  let connect tx ~now id connections =
    run (db tx) "UPDATE memberships SET connections=?,connected_at=?,unread_at=NULL WHERE id=?"
      [i connections;s (timestamp now);i id]
  let present tx ~now membership =
    let connections=if is_connected membership ~now then Int64.succ membership.connections else 1L in
    connect tx ~now membership.id connections;
    (* [connect] updates the database directly; Rails leaves the instance stale. *)
    membership
  let disconnect_all tx ~now =
    Db_runtime.execute (db tx) "UPDATE memberships SET connected_at=NULL,connections=0,updated_at=? WHERE connected_at>=?"
      [s (timestamp now);s (cutoff now)]
  let update_connections tx ~now membership connections =
    if membership.connections=connections then membership else (
      let at=timestamp now in
      run (db tx) "UPDATE memberships SET connections=?,updated_at=? WHERE id=?" [i connections;s at;i membership.id];
      {membership with connections;updated_at=at})
  let update_counter tx ~now membership delta =
    let at=timestamp now in
    run (db tx) "UPDATE memberships SET connections=COALESCE(connections,0)+?,updated_at=? WHERE id=?"
      [i delta;s at;i membership.id];
    {membership with connections=Int64.add membership.connections delta;updated_at=at}
  let increment_connections tx ~now membership =
    if is_connected membership ~now then update_counter tx ~now membership 1L
    else update_connections tx ~now membership 1L
  let decrement_connections tx ~now membership =
    if is_connected membership ~now then update_counter tx ~now membership (-1L)
    else update_connections tx ~now membership 0L
  let touch_connected_at tx ~now membership =
    let at=timestamp now in
    run (db tx) "UPDATE memberships SET updated_at=?,connected_at=? WHERE id=?" [s at;s at;i membership.id];
    {membership with connected_at=Some at;updated_at=at}
  let connected tx ~now membership =
    increment_connections tx ~now membership |> touch_connected_at tx ~now
  let disconnected tx ~now membership =
    let membership=decrement_connections tx ~now membership in
    if membership.connections>=1L || membership.connected_at=None then membership else (
      let at=timestamp now in
      run (db tx) "UPDATE memberships SET connected_at=NULL,updated_at=? WHERE id=?" [s at;i membership.id];
      {membership with connected_at=None;updated_at=at})
  let refresh_connection tx ~now membership =
    let membership=if is_connected membership ~now then membership else increment_connections tx ~now membership in
    touch_connected_at tx ~now membership
end

let memberships db room = Membership.for_room db room.Room.id
let revoke_from tx room user_ids ~on_disconnect =
  if user_ids<>[] then (
    let members=memberships (db tx) room in
    List.iter (fun member ->
      if List.mem member.Membership.user_id user_ids then Membership.destroy tx member ~on_disconnect)
      members)
let revise tx room ~granted ~revoked ~on_disconnect =
  if granted<>[] then Room.grant_to tx room granted;
  if revoked<>[] then revoke_from tx room revoked ~on_disconnect

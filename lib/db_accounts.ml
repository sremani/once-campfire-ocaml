(** Account, user, and session rows in the pinned Rails SQLite schema.
    Mutations take a caller-owned connection so they compose with Db_runtime.write. *)

let check context = function
  | Sqlite3.Rc.OK | Sqlite3.Rc.DONE -> ()
  | rc -> failwith (context ^ ": " ^ Sqlite3.Rc.to_string rc)

let with_statement db sql values f =
  let stmt = Sqlite3.prepare db sql in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
    List.iteri (fun i value -> check "bind" (Sqlite3.bind stmt (i + 1) value)) values;
    f stmt)

let query_one db sql values decode =
  with_statement db sql values (fun stmt -> match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW -> Some (decode stmt)
    | Sqlite3.Rc.DONE -> None
    | rc -> failwith ("query: " ^ Sqlite3.Rc.to_string rc))

let query_all db sql values decode =
  with_statement db sql values (fun stmt ->
    let rec loop acc = match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW -> loop (decode stmt :: acc)
      | Sqlite3.Rc.DONE -> List.rev acc
      | rc -> failwith ("query: " ^ Sqlite3.Rc.to_string rc) in
    loop [])

let run db sql values =
  with_statement db sql values (fun stmt -> check "execute" (Sqlite3.step stmt))

let count db sql values =
  match query_one db sql values (fun stmt -> Sqlite3.column_int stmt 0) with
  | Some n -> n | None -> assert false

let text s = Sqlite3.Data.TEXT s
let integer n = Sqlite3.Data.INT n
let optional f = function None -> Sqlite3.Data.NULL | Some value -> f value
let column_option stmt index = match Sqlite3.column stmt index with
  | Sqlite3.Data.NULL -> None
  | _ -> Some (Sqlite3.column_text stmt index)
let required model = function Some row -> row | None -> failwith (model ^ " not found")

let random_from alphabet length =
  let width = String.length alphabet in
  let threshold = 256 - (256 mod width) in
  let result = Bytes.create length in
  let rec fill pos = if pos < length then (
    let value = Char.code (Secure_random.bytes 1).[0] in
    if value < threshold then (Bytes.set result pos alphabet.[value mod width]; fill (pos + 1))
    else fill pos) in
  fill 0; Bytes.unsafe_to_string result

let alphanumeric length = random_from "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789" length
let base58 length = random_from "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz" length

let uuid () =
  let b = Bytes.of_string (Secure_random.bytes 16) in
  Bytes.set b 6 (Char.chr ((Char.code (Bytes.get b 6) land 0x0f) lor 0x40));
  Bytes.set b 8 (Char.chr ((Char.code (Bytes.get b 8) land 0x3f) lor 0x80));
  let hex = String.concat "" (List.init 16 (fun i -> Printf.sprintf "%02x" (Char.code (Bytes.get b i)))) in
  String.concat "-" [String.sub hex 0 8; String.sub hex 8 4; String.sub hex 12 4;
                      String.sub hex 16 4; String.sub hex 20 12]

let sql_time = Db_time.to_db
let parse_time = Authentication.parse_time
let now_time = Authentication.now_time

module Password = struct
  external crypt_bcrypt : string -> string -> string = "campfire_crypt_bcrypt"

  let bcrypt_character = function
    | '.' | '/' | 'A'..'Z' | 'a'..'z' | '0'..'9' -> true
    | _ -> false

  let valid_digest digest =
    let length = String.length digest in
    length = 60 && digest.[0] = '$' && digest.[1] = '2' &&
    List.mem digest.[2] ['a'; 'b'; 'y'] && digest.[3] = '$' &&
    digest.[4] >= '0' && digest.[4] <= '9' &&
    digest.[5] >= '0' && digest.[5] <= '9' && digest.[6] = '$' &&
    let cost = int_of_string (String.sub digest 4 2) in
    cost >= 4 && cost <= 31 &&
    let rec chars i = i = length || (bcrypt_character digest.[i] && chars (i + 1)) in
    chars 7

  let digest_with_cost ~cost password =
    if cost < 4 || cost > 31 then invalid_arg "bcrypt cost must be between 4 and 31";
    let salt = random_from "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789" 22 in
    let setting = Printf.sprintf "$2a$%02d$%s" cost salt in
    let result = crypt_bcrypt password setting in
    if not (valid_digest result) then failwith "bcrypt returned an invalid digest";
    result

  let digest password = digest_with_cost ~cost:12 password

  let verify ~password digest =
    if not (valid_digest digest) then false
    else try Eqaf.equal (crypt_bcrypt password digest) digest with
      | Invalid_argument _ | Failure _ -> false

  let dummy_digest = "$2a$12$FiKmSp4UhLvSB4Sd/ZUjQunyKP6.NjDRHdr5LnKUVk.BUn4Mq12WS"
end

module Account = struct
  type t = {
    id : int64; name : string; join_code : string; custom_styles : string option;
    settings_json : string option; singleton_guard : int64;
    created_at : string; updated_at : string;
  }

  let select = "SELECT id,name,join_code,custom_styles,settings,singleton_guard,created_at,updated_at FROM accounts"
  let decode s = {
    id = Sqlite3.column_int64 s 0; name = Sqlite3.column_text s 1;
    join_code = Sqlite3.column_text s 2; custom_styles = column_option s 3;
    settings_json = column_option s 4; singleton_guard = Sqlite3.column_int64 s 5;
    created_at = Sqlite3.column_text s 6; updated_at = Sqlite3.column_text s 7;
  }
  let first db = query_one db (select ^ " ORDER BY id ASC LIMIT 1") [] decode
  let find db id = query_one db (select ^ " WHERE id=? LIMIT 1") [integer id] decode |> required "Account"
  let count db = count db "SELECT COUNT(*) FROM accounts" []

  let settings account =
    let data = match account.settings_json with
      | None -> []
      | Some raw -> (match Yojson.Basic.from_string raw with `Assoc values -> values | _ -> [])
      | exception _ -> [] in
    if List.mem_assoc "restrict_room_creation_to_administrators" data then data
    else data @ ["restrict_room_creation_to_administrators", `Bool false]

  let present = function
    | `Null | `Bool false -> false
    | `String s -> String.trim s <> ""
    | `List [] | `Assoc [] -> false
    | _ -> true
  let restrict_room_creation_to_administrators account =
    settings account |> List.assoc "restrict_room_creation_to_administrators" |> present

  let cast_boolean value =
    if value = "" then None
    else Some (not (List.mem value ["0"; "f"; "F"; "false"; "FALSE"; "off"; "OFF"]))

  let assign_settings account values =
    List.fold_left (fun data (key, value) ->
      if key <> "restrict_room_creation_to_administrators" then
        invalid_arg ("undefined method '" ^ key ^ "=' for account settings");
      let cast = match cast_boolean value with None -> `Null | Some value -> `Bool value in
      List.map (fun (k, old) -> if k = key then (k, cast) else (k, old)) data)
      (settings account) values

  let generate_join_code () =
    let code = alphanumeric 12 in
    String.concat "-" [String.sub code 0 4; String.sub code 4 4; String.sub code 8 4]

  let create db ~now ~name =
    let code = generate_join_code () in
    let settings = Yojson.Basic.to_string (`Assoc ["restrict_room_creation_to_administrators", `Bool false]) in
    let now = sql_time (now_time now) in
    run db "INSERT INTO accounts (created_at,custom_styles,join_code,name,settings,singleton_guard,updated_at) VALUES (?,NULL,?,?,?,0,?)"
      [text now; text code; text name; text settings; text now];
    find db (Sqlite3.last_insert_rowid db)

  let reset_join_code db ~now account =
    let code = generate_join_code () in
    let now = sql_time (now_time now) in
    run db "UPDATE accounts SET join_code=?,updated_at=? WHERE id=?"
      [text code; text now; integer account.id];
    find db account.id

  let update db ~now account ?name ?custom_styles ?settings:settings_values () =
    let changes = ref [] in
    let add key value = changes := !changes @ [key, value] in
    (match name with Some value when value <> account.name -> add "name" (text value) | _ -> ());
    (match custom_styles with
     | Some value when value <> account.custom_styles -> add "custom_styles" (optional text value)
     | _ -> ());
    (match settings_values with
     | Some values ->
         let updated = assign_settings account values in
         if account.settings_json = None || updated <> settings account then
           add "settings" (text (Yojson.Basic.to_string (`Assoc updated)))
     | None -> ());
    if !changes = [] then account else (
      let now = sql_time (now_time now) in
      add "updated_at" (text now);
      let assignments = List.map (fun (key, _) -> "\"" ^ key ^ "\"=?") !changes |> String.concat "," in
      run db ("UPDATE accounts SET " ^ assignments ^ " WHERE id=?")
        (List.map snd !changes @ [integer account.id]);
      find db account.id)
end

module User = struct
  type role = Member | Administrator | Bot
  type status = Active | Deactivated | Banned
  type t = {
    id : int64; name : string; email_address : string option; password_digest : string option;
    role : role; status : status; bio : string option; bot_token : string option;
    created_at : string; updated_at : string;
  }
  type new_user = {
    name : string; email_address : string option; password_digest : string option;
    role : role; bio : string option; bot_token : string option;
  }
  type changes = {
    name : string option; email_address : string option option; password_digest : string option;
    role : role option; status : status option; bio : string option option;
    bot_token : string option option;
  }
  let no_changes = { name=None; email_address=None; password_digest=None; role=None;
                     status=None; bio=None; bot_token=None }
  let role_number = function Member -> 0 | Administrator -> 1 | Bot -> 2
  let status_number = function Active -> 0 | Deactivated -> 1 | Banned -> 2
  let role_of_number = function 0 -> Member | 1 -> Administrator | 2 -> Bot | n -> failwith ("invalid role " ^ string_of_int n)
  let status_of_number = function 0 -> Active | 1 -> Deactivated | 2 -> Banned | n -> failwith ("invalid status " ^ string_of_int n)

  let select = "SELECT id,name,email_address,password_digest,role,status,bio,bot_token,created_at,updated_at FROM users"
  let decode s = {
    id=Sqlite3.column_int64 s 0; name=Sqlite3.column_text s 1;
    email_address=column_option s 2; password_digest=column_option s 3;
    role=role_of_number (Sqlite3.column_int s 4); status=status_of_number (Sqlite3.column_int s 5);
    bio=column_option s 6; bot_token=column_option s 7;
    created_at=Sqlite3.column_text s 8; updated_at=Sqlite3.column_text s 9;
  }
  let find_by_id db id = query_one db (select ^ " WHERE id=? LIMIT 1") [integer id] decode
  let find db id = find_by_id db id |> required "User"
  let find_active db id = query_one db (select ^ " WHERE status=0 AND id=? LIMIT 1") [integer id] decode |> required "User"
  let find_by_email_address db email = query_one db (select ^ " WHERE email_address=? LIMIT 1") [text email] decode
  let find_active_by_email_address db email =
    query_one db (select ^ " WHERE status=0 AND email_address=? LIMIT 1") [text email] decode
  let authenticate (user : t) password =
    match user.password_digest with
    | Some digest -> Password.verify ~password digest
    | None -> false
  let authenticated (candidate : t option) password =
    if password = "" then None else
    match candidate with
    | Some user -> if authenticate user password then Some user else None
    | None -> ignore (Password.verify ~password Password.dummy_digest); None
  let authenticate_by_email_address db ~email_address ~password =
    if password = "" then None else
    authenticated (find_active_by_email_address db email_address) password
  let all db = query_all db select [] decode
  let count db = count db "SELECT COUNT(*) FROM users" []
  let where_ids db ids =
    if ids = [] then [] else
    let placeholders = String.concat "," (List.map (fun _ -> "?") ids) in
    query_all db (select ^ " WHERE id IN (" ^ placeholders ^ ")") (List.map integer ids) decode
  let active db = query_all db (select ^ " WHERE status=0") [] decode
  let active_ordered db = query_all db (select ^ " WHERE status=0 ORDER BY LOWER(name)") [] decode
  let active_filtered_by_ordered db query =
    query_all db (select ^ " WHERE status=0 AND name LIKE ? ORDER BY LOWER(name)") [text ("%" ^ query ^ "%")] decode
  let active_ordered_without_bots db =
    query_all db (select ^ " WHERE status=0 AND role<>2 ORDER BY LOWER(name)") [] decode
  let active_bots_ordered db =
    query_all db (select ^ " WHERE status=0 AND role=2 ORDER BY LOWER(name)") [] decode
  let find_active_bot db id =
    query_one db (select ^ " WHERE status=0 AND role=2 AND id=? LIMIT 1") [integer id] decode |> required "User"
  let authenticate_bot db key = match String.split_on_char '-' key with
    | id :: token :: _ when token <> "" ->
        query_one db (select ^ " WHERE status=0 AND role=2 AND id=? AND bot_token=? LIMIT 1") [text id; text token] decode
    | _ -> None

  let create db ~now (user : new_user) =
    let now = sql_time (now_time now) in
    run db "INSERT INTO users (bio,bot_token,created_at,email_address,name,password_digest,role,status,updated_at) VALUES (?,?,?,?,?,?,?,0,?)"
      [optional text user.bio; optional text user.bot_token; text now;
       optional text user.email_address; text user.name; optional text user.password_digest;
       integer (Int64.of_int (role_number user.role)); text now];
    find db (Sqlite3.last_insert_rowid db)

  let grant_membership_to_open_rooms db ~user_id =
    let room_ids = query_all db "SELECT id FROM rooms WHERE type='Rooms::Open'" []
      (fun stmt -> Sqlite3.column_int64 stmt 0) in
    List.iter (fun room_id ->
      run db "INSERT INTO memberships (created_at,room_id,updated_at,user_id) VALUES (STRFTIME('%Y-%m-%d %H:%M:%f','NOW'),?,STRFTIME('%Y-%m-%d %H:%M:%f','NOW'),?) ON CONFLICT DO NOTHING"
        [integer room_id; integer user_id]) room_ids

  (** Rails' after_create_commit membership callback. *)
  let create_tx tx ~now user =
    let created = create (Db_runtime.conn tx) ~now user in
    Db_runtime.after_commit tx (fun tx ->
      grant_membership_to_open_rooms (Db_runtime.conn tx) ~user_id:created.id);
    created

  let update db ~now (user : t) (changes : changes) =
    let updates = ref [] in
    let add key value = updates := !updates @ [key,value] in
    (match changes.name with Some value when value <> user.name -> add "name" (text value) | _ -> ());
    (match changes.email_address with Some value when value <> user.email_address -> add "email_address" (optional text value) | _ -> ());
    (match changes.password_digest with Some value -> add "password_digest" (text value) | _ -> ());
    (match changes.role with Some value when value <> user.role -> add "role" (integer (Int64.of_int (role_number value))) | _ -> ());
    (match changes.status with Some value when value <> user.status -> add "status" (integer (Int64.of_int (status_number value))) | _ -> ());
    (match changes.bio with Some value when value <> user.bio -> add "bio" (optional text value) | _ -> ());
    (match changes.bot_token with Some value when value <> user.bot_token -> add "bot_token" (optional text value) | _ -> ());
    if !updates = [] then user else (
      add "updated_at" (text (sql_time (now_time now)));
      let assignments = List.map (fun (key, _) -> "\"" ^ key ^ "\"=?") !updates |> String.concat "," in
      run db ("UPDATE users SET " ^ assignments ^ " WHERE id=?")
        (List.map snd !updates @ [integer user.id]);
      find db user.id)

  let generate_bot_token () = alphanumeric 12
  let bot_key (user : t) = Int64.to_string user.id ^ "-" ^ Option.value ~default:"" user.bot_token
  let reset_bot_key db ~now (user : t) =
    update db ~now user { no_changes with bot_token=Some (Some (generate_bot_token ())) }
  let create_bot db ~now ~name =
    create db ~now {name; email_address=None; password_digest=None; role=Bot;
                    bio=None; bot_token=Some (generate_bot_token ())}
  let create_bot_tx tx ~now ~name ?webhook_url () =
    let user = create_tx tx ~now {name; email_address=None; password_digest=None;
                                  role=Bot; bio=None; bot_token=Some (generate_bot_token ())} in
    (match webhook_url with None -> () | Some url ->
      let now = sql_time (now_time now) in
      run (Db_runtime.conn tx)
        "INSERT INTO webhooks (created_at,updated_at,url,user_id) VALUES (?,?,?,?)"
        [text now; text now; text url; integer user.id]);
    user

  let webhook_url db (user : t) =
    query_one db "SELECT url FROM webhooks WHERE user_id=? LIMIT 1" [integer user.id]
      (fun stmt -> column_option stmt 0) |> Option.join

  let update_bot db ~now (user : t) changes ~webhook_url:url =
    let existing = query_one db "SELECT id FROM webhooks WHERE user_id=? LIMIT 1"
      [integer user.id] (fun stmt -> Sqlite3.column_int64 stmt 0) in
    let url = Option.bind url (fun value -> if String.trim value = "" then None else Some value) in
    (match url, existing with
     | Some value, Some id -> run db "UPDATE webhooks SET url=?,updated_at=? WHERE id=?"
         [text value; text (sql_time (now_time now)); integer id]
     | Some value, None ->
         let now = sql_time (now_time now) in
         run db "INSERT INTO webhooks (created_at,updated_at,url,user_id) VALUES (?,?,?,?)"
           [text now; text now; text value; integer user.id]
     | None, Some id -> run db "DELETE FROM webhooks WHERE id=?" [integer id]
     | None, None -> ());
    update db ~now user changes

  let deactivate db ~now (user : t) =
    run db "DELETE FROM memberships WHERE id IN (SELECT memberships.id FROM memberships INNER JOIN rooms ON rooms.id=memberships.room_id WHERE memberships.user_id=? AND rooms.type<>'Rooms::Direct')"
      [integer user.id];
    List.iter (fun table -> run db ("DELETE FROM " ^ table ^ " WHERE user_id=?") [integer user.id])
      ["push_subscriptions"; "searches"; "sessions"];
    let email_address = Option.map (fun email ->
      String.concat ("-deactivated-" ^ uuid () ^ "@") (String.split_on_char '@' email)) user.email_address in
    update db ~now user { no_changes with status=Some Deactivated; email_address=Some email_address }

  let deactivate_tx tx ~now ?(on_disconnect=(fun ~user_id:_ ~reconnect:_ -> ())) (user : t) =
    Db_runtime.emit_after_commit tx (fun () -> on_disconnect ~user_id:user.id ~reconnect:false);
    deactivate (Db_runtime.conn tx) ~now user

  let unban db ~now (user : t) =
    run db "DELETE FROM bans WHERE user_id=?" [integer user.id];
    update db ~now user { no_changes with status=Some Active }

  (** [create_ban] delegates address validation to the Ban model. *)
  let ban_tx tx ~now ~create_ban
      ?(on_disconnect=(fun ~user_id:_ ~reconnect:_ -> ()))
      ?(on_remove_content=(fun ~user_id:_ -> ())) (user : t) =
    let db = Db_runtime.conn tx in
    let addresses = query_all db "SELECT ip_address FROM sessions WHERE user_id=?"
      [integer user.id] (fun stmt -> column_option stmt 0) in
    let seen = Hashtbl.create 8 in
    List.iter (function
      | Some ip when String.trim ip <> "" && not (Hashtbl.mem seen ip) ->
          create_ban tx user.id ip; Hashtbl.add seen ip ()
      | _ -> ()) addresses;
    Db_runtime.emit_after_commit tx (fun () -> on_disconnect ~user_id:user.id ~reconnect:false);
    run db "DELETE FROM sessions WHERE user_id=?" [integer user.id];
    Db_runtime.emit_after_commit tx (fun () -> on_remove_content ~user_id:user.id);
    update db ~now user { no_changes with status=Some Banned }

  let reset_remote_connections tx ~on_disconnect (user : t) =
    Db_runtime.emit_after_commit tx
      (fun () -> on_disconnect ~user_id:user.id ~reconnect:true)

  let deliver_webhook_later tx ~message_id ~on_delivery (user : t) =
    let has_webhook = Option.is_some (query_one (Db_runtime.conn tx)
      "SELECT 1 FROM webhooks WHERE user_id=? LIMIT 1" [integer user.id]
      (fun _ -> ())) in
    if has_webhook then Db_runtime.emit_after_commit tx
      (fun () -> on_delivery ~bot_id:user.id ~message_id)
  let is_member (user : t) = user.role = Member
  let is_administrator (user : t) = user.role = Administrator
  let is_bot (user : t) = user.role = Bot
  let is_active (user : t) = user.status = Active
  let is_deactivated (user : t) = user.status = Deactivated
  let is_banned (user : t) = user.status = Banned
  let can_administer (user : t) ~record_creator_id ~record_is_new =
    is_administrator user || record_creator_id = Some user.id || record_is_new
  let title (user : t) =
    match user.bio with Some bio when String.trim bio <> "" -> user.name ^ " – " ^ bio
    | _ -> user.name
  let initials (user : t) =
    let is_ascii_word = function 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' -> true | _ -> false in
    let b = Buffer.create 4 in
    let prev_word = ref false in
    String.iter (fun c ->
      if is_ascii_word c && not !prev_word then Buffer.add_char b c;
      prev_word := is_ascii_word c || Char.code c >= 128) user.name;
    Buffer.contents b
  let attachable_plain_text_representation (user : t) = "@" ^ user.name
  let reload db (user : t) = find db user.id
end

module Session = struct
  type t = {
    id : int64; user_id : int64; token : string; ip_address : string option;
    user_agent : string option; last_active_at : string; created_at : string; updated_at : string;
  }
  let select = "SELECT id,user_id,token,ip_address,user_agent,last_active_at,created_at,updated_at FROM sessions"
  let decode s = {
    id=Sqlite3.column_int64 s 0; user_id=Sqlite3.column_int64 s 1;
    token=Sqlite3.column_text s 2; ip_address=column_option s 3;
    user_agent=column_option s 4; last_active_at=Sqlite3.column_text s 5;
    created_at=Sqlite3.column_text s 6; updated_at=Sqlite3.column_text s 7;
  }
  let find db id = query_one db (select ^ " WHERE id=? LIMIT 1") [integer id] decode |> required "Session"
  let find_by_token db token = query_one db (select ^ " WHERE token=? LIMIT 1") [text token] decode
  let for_user db user_id = query_all db (select ^ " WHERE user_id=?") [integer user_id] decode
  let count_for_user db user_id = count db "SELECT COUNT(*) FROM sessions WHERE user_id=?" [integer user_id]
  let start db ~now ~user_id ~user_agent ~ip_address =
    let now = sql_time (now_time now) in
    let token = base58 24 in
    run db "INSERT INTO sessions (created_at,ip_address,last_active_at,token,updated_at,user_agent,user_id) VALUES (?,?,?,?,?,?,?)"
      [text now; optional text ip_address; text now; text token; text now;
       optional text user_agent; integer user_id];
    find db (Sqlite3.last_insert_rowid db)
  let needs_resume session ~now =
    match parse_time session.last_active_at with
    | None -> failwith "invalid sessions.last_active_at"
    | Some active -> Ptime.diff (now_time now) active |> Ptime.Span.to_float_s > 3600.
  let resume db ~now ~user_agent ~ip_address session =
    if not (needs_resume session ~now) then session else (
      let now = sql_time (now_time now) in
      run db "UPDATE sessions SET ip_address=?,last_active_at=?,updated_at=?,user_agent=? WHERE id=?"
        [optional text ip_address; text now; text now; optional text user_agent; integer session.id];
      find db session.id)
  let destroy db session = run db "DELETE FROM sessions WHERE id=?" [integer session.id]
end

module First_run = struct
  let account_name = "Campfire"
  let first_room_name = "All Talk"

  (** Create the administrator, account and first open room in one write. The
      explicit membership grant follows the Rails after-commit callbacks. *)
  let create_tx tx ~now ~name ~email_address ~password_digest =
    let db = Db_runtime.conn tx in
    ignore (Account.create db ~now ~name:account_name);
    let administrator = User.create_tx tx ~now
      { User.name; email_address=Some email_address; password_digest=Some password_digest;
        role=User.Administrator; bio=None; bot_token=None } in
    let now = sql_time (now_time now) in
    run db "INSERT INTO rooms (created_at,creator_id,name,type,updated_at) VALUES (?,?,?,'Rooms::Open',?)"
      [text now; integer administrator.id; text first_room_name; text now];
    let room_id = Sqlite3.last_insert_rowid db in
    Db_runtime.after_commit tx (fun tx ->
      let db = Db_runtime.conn tx in
      run db "INSERT INTO memberships (created_at,room_id,updated_at,user_id) VALUES (STRFTIME('%Y-%m-%d %H:%M:%f','NOW'),?,STRFTIME('%Y-%m-%d %H:%M:%f','NOW'),?) ON CONFLICT DO NOTHING"
        [integer room_id; integer administrator.id]);
    administrator
end

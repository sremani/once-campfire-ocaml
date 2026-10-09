open Campfire

module A = Db_accounts.Account
module U = Db_accounts.User
module S = Db_accounts.Session
module P = Db_accounts.Password

let check label condition = Alcotest.(check bool) label true condition
let now = "2026-10-08T12:00:00Z"

let rec reference_root path remaining =
  if remaining = 0 then failwith "once-campfire-rust checkout not found"
  else
    let candidate = Filename.concat path "once-campfire-rust" in
    if Sys.file_exists (Filename.concat candidate "parity/.seed/default/db/production.sqlite3")
    then candidate else reference_root (Filename.dirname path) (remaining - 1)

let reference = reference_root (Sys.getcwd ()) 8

let with_seed_copy variant f =
  let source_path = Filename.concat reference
      ("parity/.seed/" ^ variant ^ "/db/production.sqlite3") in
  let source = Sqlite3.db_open ~mode:`READONLY source_path in
  let temporary = Filename.temp_file "campfire-m2-t2-" ".sqlite3" in
  Sys.remove temporary;
  let quoted = String.concat "''" (String.split_on_char '\'' temporary) in
  let rc = Sqlite3.exec source ("VACUUM INTO '" ^ quoted ^ "'") in
  if rc <> Sqlite3.Rc.OK then failwith ("VACUUM INTO: " ^ Sqlite3.Rc.to_string rc);
  ignore (Sqlite3.db_close source);
  let runtime = Db_runtime.open_db ~readers:1 ~prepare:false temporary in
  Fun.protect ~finally:(fun () ->
    Db_runtime.close runtime;
    Sys.remove temporary;
    List.iter (fun suffix -> let path = temporary ^ suffix in
      if Sys.file_exists path then Sys.remove path) ["-wal"; "-shm"])
    (fun () -> f runtime)

let test_fixture_queries () = with_seed_copy "default" (fun rt ->
  Db_runtime.read rt (fun db ->
    let a = Option.get (A.first db) in
    Alcotest.(check string) "account" "37signals" a.name;
    Alcotest.(check int) "users" 10 (U.count db);
    Alcotest.(check int) "sessions" 1 (S.count_for_user db 127326141L);
    let david = U.find db 127326141L in
    check "administrator" (U.is_administrator david);
    check "seed password" (U.authenticate david "secret123456");
    check "wrong password" (not (U.authenticate david "wrong"));
    check "blank password" (U.authenticate_by_email_address db
      ~email_address:"david@37signals.com" ~password:"" = None);
    check "missing user" (U.authenticate_by_email_address db
      ~email_address:"nobody@example.com" ~password:"secret123456" = None);
    check "lookup inactive restricted" (Option.is_some
      (U.find_active_by_email_address db "david@37signals.com"));
    let bot = U.find db 394959859L in
    check "bot lookup" (Option.is_some (U.authenticate_bot db (U.bot_key bot)));
    check "bad bot key" (U.authenticate_bot db (U.bot_key bot ^ "x") = None);
    check "active bots" (List.for_all U.is_bot (U.active_bots_ordered db));
    check "member list excludes bots" (List.for_all (fun u -> not (U.is_bot u))
      (U.active_ordered_without_bots db));
    check "where ids" (List.length (U.where_ids db [127326141L; 149087659L]) = 2));
  Db_runtime.write rt (fun tx ->
    let db = Db_runtime.conn tx in
    ignore (U.update db ~now (U.find db 127326141L)
      {U.no_changes with status=Some U.Deactivated}));
  Db_runtime.read rt (fun db ->
    check "inactive user cannot authenticate" (U.authenticate_by_email_address db
      ~email_address:"david@37signals.com" ~password:"secret123456" = None)))

let test_passwords () =
  let digest = P.digest_with_cost ~cost:4 "secret123456" in
  check "Rails bcrypt prefix" (String.starts_with ~prefix:"$2a$04$" digest);
  check "bcrypt verifies" (P.verify ~password:"secret123456" digest);
  check "bcrypt rejects wrong" (not (P.verify ~password:"wrong" digest));
  check "bcrypt rejects malformed" (not (P.verify ~password:"secret123456" "$2a$bad"));
  check "bcrypt rejects invalid cost" (try ignore (P.digest_with_cost ~cost:3 "x"); false
    with Invalid_argument _ -> true);
  let long = String.make 80 'a' in
  let long_digest = P.digest_with_cost ~cost:4 long in
  check "bcrypt truncates after 72 bytes like Rails" (P.verify ~password:(String.make 72 'a' ^ "suffix") long_digest);
  check "dummy digest is cost-12 bcrypt" (P.valid_digest P.dummy_digest &&
    String.starts_with ~prefix:"$2a$12$" P.dummy_digest);
  let before = Sys.time () in
  check "blank password returns immediately" (U.authenticated None "" = None);
  let blank_time = Sys.time () -. before in
  let before = Sys.time () in
  check "unknown user fails" (U.authenticated None "nonblank" = None);
  let unknown_time = Sys.time () -. before in
  check "unknown user takes the dummy bcrypt path" (unknown_time > 0.01 && unknown_time > blank_time)

let test_account_settings () = with_seed_copy "restricted" (fun rt ->
  Db_runtime.read rt (fun db ->
    check "restricted account" (A.restrict_room_creation_to_administrators (Option.get (A.first db))));
  Db_runtime.write rt (fun tx ->
    let db = Db_runtime.conn tx in
    let account = Option.get (A.first db) in
    let original_updated = account.updated_at in
    let unchanged = A.update db ~now account () in
    Alcotest.(check string) "no-op update preserves timestamp" original_updated unchanged.updated_at;
    let changed = A.update db ~now account ~settings:["restrict_room_creation_to_administrators","false"] () in
    check "setting updated" (not (A.restrict_room_creation_to_administrators changed));
    check "unknown settings rejected" (try
      ignore (A.update db ~now changed ~settings:["nope","1"] ()); false
      with Invalid_argument _ -> true)))

let test_rails_db_timestamps () =
  Alcotest.(check string) "whole seconds omit fraction"
    "2026-09-26 12:00:00" (Db_time.of_rfc3339 "2026-09-26T12:00:00Z");
  Alcotest.(check string) "microseconds retained"
    "2026-09-26 12:34:56.123456"
    (Db_time.of_rfc3339 "2026-09-26T12:34:56.123456Z");
  Alcotest.(check string) "submicroseconds truncated"
    "2026-09-26 12:34:56.123456"
    (Db_time.of_rfc3339 "2026-09-26T12:34:56.123456999Z")

let test_user_and_session_lifecycle () = with_seed_copy "default" (fun rt ->
  let user = Db_runtime.write rt (fun tx ->
    U.create_tx tx ~now {name="New User"; email_address=Some "new@example.com";
      password_digest=Some (P.digest_with_cost ~cost:4 "longpassword");
      role=U.Member; bio=None; bot_token=None}) in
  Db_runtime.read rt (fun db ->
    check "new user receives open rooms" (Db_accounts.count db
      "SELECT COUNT(*) FROM memberships m JOIN rooms r ON r.id=m.room_id WHERE m.user_id=? AND r.type='Rooms::Open'"
      [Db_accounts.integer user.id] > 0));
  let session = Db_runtime.write rt (fun tx -> S.start (Db_runtime.conn tx) ~now
    ~user_id:user.id ~user_agent:(Some "browser") ~ip_address:(Some "8.8.8.8")) in
  check "base58 secure token" (String.length session.token = 24 &&
    String.for_all (fun c -> not (String.contains "0OIl" c)) session.token);
  check "no early refresh" (not (S.needs_resume session ~now:"2026-10-08T13:00:00Z"));
  Db_runtime.write rt (fun tx ->
    let unchanged = S.resume (Db_runtime.conn tx) ~now:"2026-10-08T13:00:00Z"
      ~user_agent:(Some "new") ~ip_address:(Some "1.1.1.1") session in
    check "early resume skips write" (unchanged.user_agent = Some "browser");
    let refreshed = S.resume (Db_runtime.conn tx) ~now:"2026-10-08T13:00:01Z"
      ~user_agent:(Some "new") ~ip_address:(Some "1.1.1.1") session in
    check "late resume writes" (refreshed.user_agent = Some "new"));
  Db_runtime.write rt (fun tx ->
    ignore (U.deactivate_tx tx ~now (U.find (Db_runtime.conn tx) user.id)));
  Db_runtime.read rt (fun db ->
    check "deactivated" (U.is_deactivated (U.find db user.id));
    Alcotest.(check int) "sessions revoked" 0 (S.count_for_user db user.id)))

let test_first_run () = with_seed_copy "first_run" (fun rt ->
  let digest = P.digest_with_cost ~cost:4 "secret123456" in
  let user = Db_runtime.write rt (fun tx ->
    Db_accounts.First_run.create_tx tx ~now ~name:"User" ~email_address:"user@example.com"
      ~password_digest:digest) in
  Db_runtime.read rt (fun db ->
    check "administrator" (U.is_administrator user);
    check "first user signs in" (Option.is_some (U.authenticate_by_email_address db
      ~email_address:"user@example.com" ~password:"secret123456"));
    Alcotest.(check int) "one account" 1 (A.count db);
    Alcotest.(check int) "first room" 1 (Db_accounts.count db
      "SELECT COUNT(*) FROM rooms WHERE name='All Talk' AND type='Rooms::Open'" []);
    Alcotest.(check int) "first room membership" 1 (Db_accounts.count db
      "SELECT COUNT(*) FROM memberships WHERE user_id=?" [Db_accounts.integer user.id])))

let test_bot_and_ban_lifecycle () = with_seed_copy "default" (fun rt ->
  let events = ref [] in
  let bot = Db_runtime.write rt (fun tx ->
    U.create_bot_tx tx ~now ~name:"Test Bot" ~webhook_url:"https://example.com/hook" ()) in
  Db_runtime.read rt (fun db ->
    check "new bot has key" (Option.is_some (U.authenticate_bot db (U.bot_key bot))));
  Db_runtime.read rt (fun db -> Alcotest.(check (option string)) "webhook URL"
    (Some "https://example.com/hook") (U.webhook_url db bot));
  let old_key = U.bot_key bot in
  let bot = Db_runtime.write rt (fun tx ->
    let db = Db_runtime.conn tx in
    let bot = U.reset_bot_key db ~now bot in
    ignore (U.update_bot db ~now bot {U.no_changes with name=Some "New Bot"}
      ~webhook_url:None);
    U.deliver_webhook_later tx ~message_id:42L
      ~on_delivery:(fun ~bot_id:_ ~message_id:_ -> events := "webhook" :: !events) bot;
    bot) in
  Db_runtime.read rt (fun db ->
    check "old bot key revoked" (U.authenticate_bot db old_key = None);
    check "new bot key works" (Option.is_some (U.authenticate_bot db (U.bot_key bot)));
    check "webhook removed" (U.webhook_url db bot = None));
  check "removed webhook has no delivery" (!events = []);
  let user = Db_runtime.read rt (fun db -> U.find db 127326141L) in
  let ban_events = ref [] in
  let banned = Db_runtime.write rt (fun tx ->
    U.ban_tx tx ~now user
      ~create_ban:(fun tx user_id ip ->
        let db = Db_runtime.conn tx in
        Db_accounts.run db
          "INSERT INTO bans (created_at,ip_address,updated_at,user_id) VALUES (?,?,?,?)"
          [Db_accounts.text "2026-10-08 12:00:00"; Db_accounts.text ip;
           Db_accounts.text "2026-10-08 12:00:00"; Db_accounts.integer user_id])
      ~on_disconnect:(fun ~user_id:_ ~reconnect:_ -> ban_events := !ban_events @ ["disconnect"])
      ~on_remove_content:(fun ~user_id:_ -> ban_events := !ban_events @ ["remove"])) in
  check "banned status" (U.is_banned banned);
  check "ban callbacks ordered after commit" (!ban_events = ["disconnect"; "remove"]);
  Db_runtime.read rt (fun db ->
    Alcotest.(check int) "banned sessions revoked" 0 (S.count_for_user db user.id));
  let active = Db_runtime.write rt (fun tx -> U.unban (Db_runtime.conn tx) ~now banned) in
  check "unban restores active" (U.is_active active))

let test_crowd_and_singleton () =
  with_seed_copy "crowd" (fun rt -> Db_runtime.read rt (fun db ->
    Alcotest.(check int) "crowd users" 530 (U.count db);
    check "crowd filter" (List.length (U.active_filtered_by_ordered db "Abbott") > 0)));
  with_seed_copy "default" (fun rt ->
    check "account singleton enforced" (try
      Db_runtime.write rt (fun tx ->
        ignore (A.create (Db_runtime.conn tx) ~now ~name:"Second")); false
      with Sqlite3.SqliteError _ | Failure _ -> true))

let () = Alcotest.run "M2-T2 accounts users sessions" [
  "seed", [Alcotest.test_case "queries and authentication" `Quick test_fixture_queries];
  "password", [Alcotest.test_case "Rails bcrypt" `Quick test_passwords];
  "time", [Alcotest.test_case "Rails SQLite datetime" `Quick test_rails_db_timestamps];
  "account", [Alcotest.test_case "settings" `Quick test_account_settings];
  "lifecycle", [Alcotest.test_case "users and sessions" `Quick test_user_and_session_lifecycle];
  "bootstrap", [Alcotest.test_case "first run" `Quick test_first_run];
  "bot", [Alcotest.test_case "bot and ban lifecycle" `Quick test_bot_and_ban_lifecycle];
  "crowd", [Alcotest.test_case "large fixture and singleton" `Quick test_crowd_and_singleton];
]

open Campfire
module R = Db_rooms.Room
module M = Db_rooms.Membership
module D = Db_rooms

let now = "2026-10-08T12:00:00Z"
let later = "2026-10-08T12:01:01Z"
let david = 127326141L
let kevin = 712064548L
let jz = 773523953L
let check label value = Alcotest.(check bool) label true value
let len label expected rows = Alcotest.(check int) label expected (List.length rows)

let rec reference_root path remaining =
  if remaining=0 then failwith "once-campfire-rust checkout not found" else
  let candidate=Filename.concat path "once-campfire-rust" in
  if Sys.file_exists (Filename.concat candidate "parity/.seed/default/db/production.sqlite3")
  then candidate else reference_root (Filename.dirname path) (remaining-1)
let reference = reference_root (Sys.getcwd ()) 8

let with_seed variant f =
  let source_path=Filename.concat reference ("parity/.seed/" ^ variant ^ "/db/production.sqlite3") in
  let source=Sqlite3.db_open ~mode:`READONLY source_path in
  let temporary=Filename.temp_file "campfire-m2-t3-" ".sqlite3" in
  Sys.remove temporary;
  let quoted=String.concat "''" (String.split_on_char '\'' temporary) in
  let rc=Sqlite3.exec source ("VACUUM INTO '" ^ quoted ^ "'") in
  if rc<>Sqlite3.Rc.OK then failwith ("VACUUM INTO: " ^ Sqlite3.Rc.to_string rc);
  ignore (Sqlite3.db_close source);
  let rt=Db_runtime.open_db ~readers:2 ~prepare:false temporary in
  Fun.protect ~finally:(fun () ->
    Db_runtime.close rt;
    List.iter (fun suffix -> let path=temporary ^ suffix in if Sys.file_exists path then Sys.remove path)
      ["";"-wal";"-shm"])
    (fun () -> f rt)

let test_queries () = with_seed "default" (fun rt ->
  Db_runtime.read rt (fun db ->
    len "rooms" 11 (R.all db);
    Alcotest.(check int64) "direct count" 4L (R.count_of_type db D.Direct);
    check "original exists" (Option.is_some (R.original db));
    len "David direct" 3 (R.for_user_of_type db david D.Direct);
    len "David without direct" 7 (R.for_user_without_directs db david);
    check "Kevin lacks pets" (R.find_for_user db kevin 104393281L=None);
    let ordered=M.visible_with_ordered_room db david in
    let names=List.filter_map (fun (_,room) -> room.R.name) ordered in
    check "case-insensitive room order" (names=["All Pets";"All Talk";"Broken";"Designers";"HQ";"Quiet Corner"]);
    check "invisible included in unfiltered scope"
      (List.length (M.with_ordered_room db david)>List.length ordered);
    let room=R.find db 699448325L in
    check "direct predicate" (R.direct room);
    check "direct set lookup" (Option.map (fun room -> room.R.id) (R.find_direct_for db [kevin;david])=Some room.R.id);
    check "default direct involvement" (R.default_involvement room="everything");
    check "active bots" (List.for_all Db_accounts.User.is_bot (R.active_bots db (R.find db 201306877L)));
    check "membership count" (M.count db=39L)) )

let test_open_grants_and_revise () = with_seed "default" (fun rt ->
  let room=Db_runtime.write rt (fun tx -> R.create tx ~now D.Open ~name:(Some "New Open") ~creator_id:david) in
  Alcotest.(check string) "Rails zero-fraction room timestamp" "2026-10-08 12:00:00" room.R.created_at;
  Db_runtime.read rt (fun db ->
    let active=List.length (Db_accounts.User.active db) in
    let members=M.for_room db room.R.id in
    len "open grants active users after commit" active members;
    check "insert_all timestamp has milliseconds"
      (List.for_all (fun member -> String.length member.M.created_at=23) members));
  let closed=Db_runtime.write rt (fun tx -> R.create_for tx ~now D.Closed ~name:(Some "Closed") ~creator_id:david [david;kevin]) in
  Db_runtime.read rt (fun db ->
    check "closed membership involvement"
      (List.for_all (fun m -> m.M.involvement=Some D.Mentions) (M.for_room db closed.R.id)));
  let events=ref [] in
  Db_runtime.write rt (fun tx ->
    D.revise tx closed ~granted:[jz;kevin] ~revoked:[david]
      ~on_disconnect:(fun ~user_id ~reconnect -> events := (user_id,reconnect)::!events));
  Alcotest.(check (list (pair int64 bool))) "revoke disconnects after commit" [(david,true)] !events;
  Db_runtime.read rt (fun db ->
    let ids=R.user_ids db closed in
    check "grant and revoke" (List.sort Int64.compare ids=List.sort Int64.compare [kevin;jz]));
  let changed=Db_runtime.write rt (fun tx -> R.update tx ~now closed ~room_type:D.Open ()) in
  check "becomes open" (R.open_ changed);
  Db_runtime.read rt (fun db ->
    len "becoming open grants active users" (List.length (Db_accounts.User.active db)) (M.for_room db changed.R.id));
  let direct=Db_runtime.read rt (fun db -> R.find db 186869642L) in
  check "direct room type immutable"
    (try ignore (Db_runtime.write rt (fun tx -> R.update tx ~now direct ~room_type:D.Open ())); false
     with Invalid_argument _ -> true);
  let before=Db_runtime.read rt (fun db -> R.count_of_type db D.Open) in
  (try Db_runtime.write rt (fun tx ->
      ignore (R.create tx ~now D.Open ~name:(Some "Rolled back") ~creator_id:david);
      failwith "rollback")
   with Failure _ -> ());
  Db_runtime.read rt (fun db ->
    Alcotest.(check int64) "rollback suppresses room and grant" before (R.count_of_type db D.Open)))

let test_direct_concurrency () = with_seed "default" (fun rt ->
  let results=Array.make 8 None in
  let threads=Array.init 8 (fun n -> Thread.create (fun () ->
    let users=if n mod 2=0 then [jz;kevin] else [kevin;jz] in
    results.(n)<-Some (Db_runtime.write rt (fun tx ->
      R.find_or_create_direct_for tx ~now ~user_ids:users ~creator_id:jz))) ()) in
  Array.iter Thread.join threads;
  let ids=Array.to_list results |> List.map (fun item -> (Option.get item).R.id) in
  check "concurrent direct singleton" (List.length (List.sort_uniq Int64.compare ids)=1);
  Db_runtime.read rt (fun db ->
    let room=R.find db (List.hd ids) in
    check "exact participants" (List.sort Int64.compare (R.user_ids db room)=[kevin;jz]);
    check "direct defaults to everything"
      (List.for_all (fun m -> m.M.involvement=Some D.Everything) (M.for_room db room.R.id))))

let test_connection_and_unread () = with_seed "default" (fun rt ->
  let room=Db_runtime.read rt (fun db -> R.find db 699448326L) in
  let member=Db_runtime.read rt (fun db -> Option.get (M.find_by_room_and_user db room.R.id kevin)) in
  let after_connect=Db_runtime.write rt (fun tx -> M.connected tx ~now member) in
  check "connected" (M.is_connected after_connect ~now);
  Alcotest.(check int64) "one connection" 1L after_connect.M.connections;
  let after_second=Db_runtime.write rt (fun tx -> M.connected tx ~now after_connect) in
  Alcotest.(check int64) "two connections" 2L after_second.M.connections;
  let after_stale=Db_runtime.write rt (fun tx -> M.connected tx ~now:later after_second) in
  Alcotest.(check int64) "stale resets" 1L after_stale.M.connections;
  let after_disconnect=Db_runtime.write rt (fun tx -> M.disconnected tx ~now:later after_stale) in
  check "disconnect clears timestamp" (after_disconnect.M.connected_at=None);
  Db_runtime.read rt (fun db ->
    check "disconnected scope" (M.disconnected_exists db member.M.id ~now:later));
  let pushed=ref [] in
  Db_runtime.write rt (fun tx ->
    R.receive tx ~now:(Db_accounts.now_time later) ~room_id:room.R.id ~message_id:42L
      ~created_at:"2026-10-08 12:01:01" ~creator_id:david
      ~on_push:(fun ~room_id ~message_id -> pushed:=(room_id,message_id)::!pushed));
  Alcotest.(check int) "push callback" 1 (List.length !pushed);
  let member=Db_runtime.read rt (fun db -> Option.get (M.find_by_room_and_user db room.R.id kevin)) in
  check "member marked unread" (M.unread member);
  let read=Db_runtime.write rt (fun tx -> M.read tx ~now:later member) in
  check "read clears unread" (not (M.unread read));
  let unchanged=Db_runtime.write rt (fun tx -> M.read tx ~now:later read) in
  Alcotest.(check string) "already read is noop" read.M.updated_at unchanged.M.updated_at;
  Db_runtime.write rt (fun tx -> ignore (M.disconnect_all tx ~now:later)))

let test_receive_filters () = with_seed "default" (fun rt ->
  let jason=149087659L in
  let room=Db_runtime.write rt (fun tx ->
    R.create_for tx ~now D.Closed ~name:(Some "Unread test") ~creator_id:david [david;kevin;jz;jason]) in
  Db_runtime.write rt (fun tx ->
    let db=Db_runtime.conn tx in
    let invisible=Option.get (M.find_by_room_and_user db room.R.id jz) in
    ignore (M.update_involvement tx ~now invisible (Some D.Invisible));
    let connected=Option.get (M.find_by_room_and_user db room.R.id kevin) in
    M.connect tx ~now connected.M.id 1L);
  let push_count=ref 0 in
  let receive at = Db_runtime.write rt (fun tx ->
    R.receive tx ~now:(Db_accounts.now_time at) ~room_id:room.R.id ~message_id:1L
      ~created_at:(Db_time.of_rfc3339 at) ~creator_id:david
      ~on_push:(fun ~room_id:_ ~message_id:_ -> incr push_count)) in
  receive now;
  let unread user=Db_runtime.read rt (fun db ->
    M.find_by_room_and_user db room.R.id user |> Option.get |> M.unread) in
  check "creator stays read" (not (unread david));
  check "connected stays read" (not (unread kevin));
  check "invisible stays read" (not (unread jz));
  check "disconnected member unread" (unread jason);
  receive later;
  check "stale connection receives unread" (unread kevin);
  Alcotest.(check int) "pushes after commits" 2 !push_count)

let test_crowd_and_restricted () =
  List.iter (fun variant -> with_seed variant (fun rt ->
    let room=Db_runtime.write rt (fun tx -> R.create tx ~now D.Open ~name:(Some "Everyone") ~creator_id:david) in
    Db_runtime.read rt (fun db ->
      len (variant ^ " active users") (List.length (Db_accounts.User.active db)) (M.for_room db room.R.id))))
    ["crowd";"restricted"]

let test_membership_batch_boundary () = with_seed "crowd" (fun rt ->
  Db_runtime.write rt (fun tx ->
    let db=Db_runtime.conn tx in
    for n=1 to 600 do
      ignore (Db_runtime.execute db
        "INSERT INTO users (created_at,name,role,status,updated_at) VALUES (?,?,0,0,?)"
        [Sqlite3.Data.TEXT "2026-10-08 12:00:00";
         Sqlite3.Data.TEXT ("Batch User " ^ string_of_int n);
         Sqlite3.Data.TEXT "2026-10-08 12:00:00"])
    done);
  let room=Db_runtime.write rt (fun tx -> R.create tx ~now D.Open ~name:(Some "Batch") ~creator_id:david) in
  Db_runtime.read rt (fun db ->
    let active=Db_accounts.User.active db in
    check "crossed 1000 rows" (List.length active>1000);
    len "every active user granted across batches" (List.length active) (M.for_room db room.R.id)))

let test_destroy_with_message_lifecycle () = with_seed "default" (fun rt ->
  let room=Db_runtime.read rt (fun db -> R.find db 486777696L) in
  let message_ids=Db_runtime.read rt (fun db ->
    Db_runtime.query_all db "SELECT id FROM messages WHERE room_id=?" [Sqlite3.Data.INT room.R.id]
      (fun row -> Sqlite3.column_int64 row 0)) in
  check "fixture has messages" (message_ids<>[]);
  Db_runtime.write rt (fun tx ->
    R.destroy_tx tx room ~destroy_messages:(fun tx ~room_id ->
      Db_messages.Message.destroy_for_room tx ~now:(Db_accounts.now_time now) ~room_id));
  Db_runtime.read rt (fun db ->
    check "room deleted" (R.find_by_id db room.R.id=None);
    check "memberships deleted" (M.for_room db room.R.id=[]);
    check "messages deleted" (Db_messages.Message.for_room db room.R.id=[]);
    let boosted=Db_runtime.query_all db
      ("SELECT id FROM boosts WHERE message_id IN (" ^ Db_runtime.placeholders (List.length message_ids) ^ ")")
      (List.map (fun id -> Sqlite3.Data.INT id) message_ids)
      (fun row -> Sqlite3.column_int64 row 0) in
    check "boosts deleted" (boosted=[])))

let () = Alcotest.run "M2-T3 rooms and memberships" [
  "fixture", [Alcotest.test_case "queries and scopes" `Quick test_queries];
  "writes", [Alcotest.test_case "open grants and revision" `Quick test_open_grants_and_revise;
             Alcotest.test_case "direct singleton under concurrency" `Quick test_direct_concurrency];
  "state", [Alcotest.test_case "connections and unread" `Quick test_connection_and_unread];
  "receiving", [Alcotest.test_case "unread filters" `Quick test_receive_filters];
  "variants", [Alcotest.test_case "crowd and restricted" `Quick test_crowd_and_restricted];
  "batch", [Alcotest.test_case "more than 1000 members" `Quick test_membership_batch_boundary];
  "lifecycle", [Alcotest.test_case "destroy cascades through messages" `Quick test_destroy_with_message_lifecycle];
]

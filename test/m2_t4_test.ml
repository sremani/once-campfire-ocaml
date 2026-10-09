open Campfire

module M = Db_messages.Message
module B = Db_messages.Boost
module S = Db_messages.Search

let check label value = Alcotest.(check bool) label true value
let now = Authentication.now_time "2026-10-08T12:00:00Z"
let later seconds = Ptime.add_span now (Ptime.Span.of_int_s seconds) |> Option.get
let designers = 654632876L
let david = 127326141L
let jason = 149087659L
let kevin = 712064548L
let jz = 773523953L
let bender = 394959859L
exception Abort

let rec reference_root path remaining =
  if remaining=0 then failwith "reference seed not found" else
  let candidate = Filename.concat path "once-campfire-rust" in
  if Sys.file_exists (Filename.concat candidate "parity/.seed/default/db/production.sqlite3")
  then candidate else reference_root (Filename.dirname path) (remaining-1)

let with_seed f =
  let root = reference_root (Sys.getcwd ()) 8 in
  let source = Sqlite3.db_open ~mode:`READONLY
    (Filename.concat root "parity/.seed/default/db/production.sqlite3") in
  let destination = Filename.temp_file "campfire-m2-t4-" ".sqlite3" in
  Sys.remove destination;
  let sql = "VACUUM INTO '" ^ String.concat "''" (String.split_on_char '\'' destination) ^ "'" in
  let result = Sqlite3.exec source sql in
  ignore (Sqlite3.db_close source);
  if result <> Sqlite3.Rc.OK then failwith "seed copy failed";
  let runtime = Db_runtime.open_db ~readers:1 ~prepare:false destination in
  Fun.protect ~finally:(fun () ->
    Db_runtime.close runtime;
    List.iter (fun path -> if Sys.file_exists path then Sys.remove path)
      [destination; destination ^ "-wal"; destination ^ "-shm"])
    (fun () -> f runtime)

let new_message ?(room_id=designers) ?(creator_id=david) ?(body=Some "Hello") ?attachment_blob_id client_message_id =
  {M.room_id; creator_id; body; attachment_blob_id; client_message_id=Some client_message_id}

let fts db id = Db_runtime.query_one db
  "SELECT body FROM message_search_index WHERE rowid=?" [Sqlite3.Data.INT id]
  (fun s -> Sqlite3.column_text s 0)
let unread db user_id = Db_runtime.query_one db
  "SELECT unread_at FROM memberships WHERE room_id=? AND user_id=?"
  [Sqlite3.Data.INT designers; Sqlite3.Data.INT user_id]
  (fun s -> match Sqlite3.column s 0 with Sqlite3.Data.NULL -> None
    | _ -> Some (Sqlite3.column_text s 0)) |> Option.join

let test_lifecycle () = with_seed (fun rt ->
  let pushes = ref [] in
  let room_before = Db_runtime.read rt (fun db -> (Db_rooms.Room.find db designers).updated_at) in
  Db_runtime.write rt (fun tx ->
    let db = Db_runtime.conn tx in
    ignore (Db_runtime.execute db "UPDATE memberships SET involvement='invisible' WHERE room_id=? AND user_id=?"
      [Sqlite3.Data.INT designers; Sqlite3.Data.INT kevin]);
    ignore (Db_runtime.execute db "UPDATE memberships SET connected_at=? WHERE room_id=? AND user_id=?"
      [Sqlite3.Data.TEXT (Db_time.to_db now); Sqlite3.Data.INT designers; Sqlite3.Data.INT jz]);
    ignore (Db_runtime.execute db "UPDATE memberships SET unread_at=NULL WHERE room_id=?"
      [Sqlite3.Data.INT designers]));
  let message = Db_runtime.write rt (fun tx ->
    let message = M.create tx ~now ~on_push:(fun ~room_id ~message_id ->
      pushes := (room_id,message_id) :: !pushes)
      (new_message ~body:(Some "Hello <b>there</b>") "m2-t4-lifecycle") in
    check "index waits for commit" (fts (Db_runtime.conn tx) message.id=None);
    check "unread waits for commit" (unread (Db_runtime.conn tx) jason=None);
    check "push waits for commit" (!pushes=[]);
    message) in
  Db_runtime.read rt (fun db ->
    check "create row is stored row" (M.find db message.id=message);
    check "message touches room" ((Db_rooms.Room.find db designers).updated_at > room_before);
    Alcotest.(check (option string)) "FTS body" (Some "Hello there") (fts db message.id);
    Alcotest.(check (option string)) "Jason unread" (Some message.created_at) (unread db jason);
    check "invisible member not unread" (unread db kevin=None);
    check "connected member not unread" (unread db jz=None);
    check "creator not unread" (unread db david=None);
    check "rich text relation" (M.body_html db message=Some "Hello <b>there</b>");
    check "push event" (!pushes=[designers,message.id]);
    check "search text" (List.exists (fun m -> m.M.id=message.id) (M.search_in_room db designers "there")));
  let updated = Db_runtime.write rt (fun tx ->
    M.update_body tx ~now:(later 1) message "shark") in
  Db_runtime.read rt (fun db ->
    check "old term removed" (not (List.exists (fun m -> m.M.id=message.id) (M.search_in_room db designers "there")));
    check "new term indexed" (List.exists (fun m -> m.M.id=message.id) (M.search_in_room db designers "shark")));
  let boost = Db_runtime.write rt (fun tx ->
    B.create tx ~now:(later 2) ~message_id:message.id ~booster_id:jason ~content:"💯") in
  let second_boost = Db_runtime.write rt (fun tx ->
    B.create tx ~now:(later 3) ~message_id:message.id ~booster_id:kevin ~content:"👍") in
  Db_runtime.read rt (fun db ->
    check "boost touches message" ((M.find db message.id).updated_at > updated.updated_at);
    check "boost lookup" ((B.find_by_message_and_booster db message.id boost.id jason).content="💯");
    Alcotest.(check (list int64)) "boost creation order" [boost.id;second_boost.id]
      (Db_messages.boosts db message |> List.map (fun b -> b.B.id)));
  Db_runtime.write rt (fun tx -> B.destroy tx ~now:(later 4) boost);
  Db_runtime.write rt (fun tx -> M.destroy tx ~now:(later 4) message);
  Db_runtime.read rt (fun db ->
    check "destroy removes message" (M.find_by_id db message.id=None);
    check "destroy removes boosts" (B.for_message db message.id=[]);
    check "destroy removes FTS" (fts db message.id=None);
    check "destroy removes rich text" (Db_messages.Rich_text_record.find_for db
      ~record_type:"Message" ~record_id:message.id ~name:"body"=None)))

let test_search_and_permissions () = with_seed (fun rt ->
  let ids = List.init 105 (fun i -> (Db_runtime.write rt (fun tx ->
    M.create tx ~now:(later (i+1))
      (new_message ~body:(Some ("aardvark " ^ string_of_int i)) ("m2-t4-" ^ string_of_int i)))).M.id) in
  Db_runtime.read rt (fun db ->
    let found = M.search_reachable db kevin "aardvark" |> List.map (fun m -> m.M.id) in
    Alcotest.(check (list int64)) "newest 100, ascending" (List.filteri (fun i _ -> i>=5) ids) found;
    let plan = Db_runtime.query_all db ("EXPLAIN QUERY PLAN " ^ M.search_reachable_sql)
      [Sqlite3.Data.INT kevin; Sqlite3.Data.TEXT "\"aardvark\""]
      (fun s -> Sqlite3.column_text s 3) |> String.concat "; " in
    check "index walk avoids temporary sort"
      (Db_messages.replace_all plan "TEMP B-TREE" "" = plan);
    check "nonmember cannot search" (M.search_reachable db bender "aardvark"=[]);
    let syntax = ["NOT";"OR";"AND";"NEAR";"aardvark NOT";"\"";"*";"";"a\000b";"\000"] in
    List.iter (fun input -> ignore (M.search_in_room db designers input)) syntax;
    check "Unicode whitespace becomes AND terms"
      (M.search_in_room db designers "aardvark\194\160104" <> [] &&
       M.search_in_room db designers "aardvark\227\128\128104" <> []);
    check "all terms required" (M.search_in_room db designers "aardvark nonexistent"=[]));
  let lone = Db_runtime.write rt (fun tx ->
    M.create tx ~now:(later 200) (new_message ~room_id:104393281L ~body:(Some "sparseunique") "m2-sparse")) in
  Db_runtime.read rt (fun db ->
    check "room permission applies" (not (List.exists (fun m -> m.M.id=lone.id)
      (M.search_reachable db kevin "sparseunique")))))

let test_sparse_reachable_fallback () = with_seed (fun rt ->
  let reachable = Db_runtime.write rt (fun tx -> M.create tx ~now
    (new_message ~body:(Some "sparsefallback") "m2-sparse-reachable")) in
  Db_runtime.write rt (fun tx ->
    for i=1 to 1001 do
      ignore (M.create tx ~now:(later i)
        (new_message ~room_id:104393281L ~body:(Some "sparsefallback")
          ("m2-sparse-private-" ^ string_of_int i)))
    done);
  Db_runtime.read rt (fun db ->
    Alcotest.(check (list int64)) "older reachable hit beyond probe"
      [reachable.id] (M.search_reachable db kevin "sparsefallback" |> List.map (fun m -> m.M.id));
    check "unknown user sees nothing" (M.search_reachable db (-1L) "sparsefallback"=[])))

let test_mentionees () = with_seed (fun rt ->
  Db_runtime.read rt (fun db ->
    let users = M.mentionees_in_room db 104393281L [david;kevin;david] in
    Alcotest.(check (list int64)) "deduplicated room users" [david]
      (List.map (fun user -> user.Db_accounts.User.id) users));
  let adapter = { Db_messages.to_plain_text=(fun _ html -> html);
    mentioned_user_ids=(fun _ _ -> [david;kevin;david]) } in
  let message = Db_runtime.write rt (fun tx -> M.create tx ~now
    (new_message ~room_id:104393281L ~body:(Some "mention") "m2-mention")) in
  Db_runtime.read rt (fun db ->
    Alcotest.(check (list int64)) "message mentionees are user rows"
      [david] (M.mentionees ~rich_text:adapter db message
        |> List.map (fun user -> user.Db_accounts.User.id))))

let test_pagination_and_history () = with_seed (fun rt ->
  let original = Db_runtime.read rt (fun db -> M.last_page db designers) in
  let ids = List.init 45 (fun i -> (Db_runtime.write rt (fun tx ->
    M.create tx ~now:(later (i+1))
      (new_message ~body:(Some "page test") ("m2-page-" ^ string_of_int i)))).M.id) in
  Db_runtime.read rt (fun db ->
    let last = M.last_page db designers in
    Alcotest.(check int) "page length" 40 (List.length last);
    Alcotest.(check (list int64)) "last page newest" (List.filteri (fun i _ -> i>=5) ids)
      (List.map (fun m -> m.M.id) last);
    check "paged" (M.paged db designers);
    let middle = List.nth last 20 in
    check "before excludes middle" (List.for_all (fun m -> m.M.created_at<middle.created_at)
      (M.page_before db designers middle));
    check "after excludes middle" (List.for_all (fun m -> m.M.created_at>middle.created_at)
      (M.page_after db designers middle));
    check "exists before" (M.exists_before db designers middle);
    check "exists after" (M.exists_after db designers middle);
    check "first page includes original" ((List.hd (M.first_page db designers)).id=(List.hd original).id);
    let since = Db_time.to_db now in
    let created = M.page_created_since db designers since in
    Alcotest.(check int) "created page capped" 40 (List.length created);
    let updated = M.page_updated_since db designers since
      (List.map (fun m -> m.M.id) created) in
    Alcotest.(check int) "updated has five unexcluded rows" 5 (List.length updated);
    check "updated excludes created ids" (List.for_all (fun m ->
      not (List.exists (fun c -> c.M.id=m.M.id) created)) updated));
  for i=0 to 11 do
    Db_runtime.write rt (fun tx -> ignore (S.record tx ~now:(later (i+1))
      ~user_id:david ~query:("m2 search " ^ string_of_int i)))
  done;
  Db_runtime.read rt (fun db ->
    let searches = S.ordered_for_user db david in
    Alcotest.(check int) "search history capped" 10 (List.length searches);
    Alcotest.(check string) "latest search" "m2 search 11" (List.hd searches).query);
  Db_runtime.write rt (fun tx -> ignore (S.record tx ~now:(later 20) ~user_id:david ~query:"m2 search 5"));
  Db_runtime.read rt (fun db ->
    Alcotest.(check string) "existing search touched" "m2 search 5"
      (List.hd (S.ordered_for_user db david)).query);
  Db_runtime.write rt (fun tx -> S.destroy_all_for_user tx david);
  Db_runtime.read rt (fun db ->
    Alcotest.(check int) "search history cleared" 0 (S.count_for_user db david)))

let test_updated_page_and_ban_cleanup () = with_seed (fun rt ->
  let older = Db_runtime.read rt (fun db -> M.first_page db designers) in
  let since = Db_time.to_db now in
  let touched = [List.nth older 2; List.nth older 0; List.nth older 1] in
  List.iteri (fun i message -> Db_runtime.write rt (fun tx ->
    ignore (M.touch tx ~now:(later (i+1)) message))) touched;
  let created = List.init 38 (fun i -> (Db_runtime.write rt (fun tx ->
    M.create tx ~now:(later (i+4))
      (new_message ~body:(Some "ban cleanup") ("m2-updated-" ^ string_of_int i)))).M.id) in
  Db_runtime.read rt (fun db ->
    let found = M.page_updated_since db designers since [] |> List.map (fun m -> m.M.id) in
    Alcotest.(check (list int64)) "newest 40 updated, creation order"
      ([(List.nth older 1).M.id; (List.nth older 2).M.id] @ created)
      found);
  Db_runtime.write rt (fun tx -> M.destroy_by_creator tx ~now:(later 50) ~creator_id:david);
  Db_runtime.read rt (fun db ->
    check "creator content removed" (M.by_creator db david=[]);
    check "search rows removed" (M.search_in_room db designers "ban cleanup"=[])))

let test_attachment_and_sound () = with_seed (fun rt ->
  let purge = ref [] in
  let blob_id = Db_runtime.write rt (fun tx ->
    let db = Db_runtime.conn tx in
    ignore (Db_runtime.execute db
      "INSERT INTO active_storage_blobs (byte_size,created_at,filename,key,service_name) VALUES (1,?,'moon.jpg','m2-t4-moon','local')"
      [Sqlite3.Data.TEXT (Db_time.to_db now)]);
    Sqlite3.last_insert_rowid db) in
  let message = Db_runtime.write rt (fun tx -> M.create tx ~now
    (new_message ~body:None ~attachment_blob_id:blob_id "m2-attachment")) in
  Db_runtime.read rt (fun db ->
    Alcotest.(check string) "attachment fallback body" "moon.jpg" (M.plain_text_body db message);
    check "attachment type" (M.content_type db message=M.Attachment);
    check "filename indexed" (List.exists (fun m -> m.M.id=message.id)
      (M.search_in_room db designers "moon")));
  let updated = Db_runtime.write rt (fun tx -> M.replace_attachment tx ~now:(later 1)
    ~on_purge:(fun ~blob_id -> purge := blob_id :: !purge) message None) in
  check "purge callback" (!purge=[blob_id]);
  Db_runtime.read rt (fun db ->
    check "attachment removed" (M.attachment_blob_id db updated=None);
    check "filename unindexed" (not (List.exists (fun m -> m.M.id=message.id)
      (M.search_in_room db designers "moon"))));
  let sound = Db_runtime.write rt (fun tx -> M.create tx ~now:(later 2)
    (new_message ~body:(Some "/play trombone") "m2-sound")) in
  Db_runtime.read rt (fun db ->
    check "sound type" (M.content_type db sound=M.Sound);
    check "sound lookup" (Option.map (fun s -> s.Db_messages.Sound.name)
      (M.sound db sound)=Some "trombone"));
  check "sound catalog" (List.length Db_messages.Sound.names=56);
  check "invalid sound" (Db_messages.sound_in "/play nosuchsound"=None))

let test_rollback_and_timestamps () = with_seed (fun rt ->
  let pushes = ref 0 in
  let initial = Db_runtime.read rt M.count in
  (try ignore (Db_runtime.write rt (fun tx ->
    ignore (M.create tx ~now ~on_push:(fun ~room_id:_ ~message_id:_ -> incr pushes)
      (new_message "m2-rollback"));
    raise Abort)); with Abort -> ());
  check "rollback suppresses push" (!pushes=0);
  Db_runtime.read rt (fun db -> Alcotest.(check int) "rollback removes row" initial (M.count db));
  let message = Db_runtime.write rt (fun tx -> M.create tx ~now (new_message "m2-timestamp")) in
  Alcotest.(check string) "whole second omits fraction" "2026-10-08 12:00:00" message.created_at;
  let fractional = Authentication.now_time "2026-10-08T12:00:00.123456Z" in
  let message = Db_runtime.write rt (fun tx -> M.create tx ~now:fractional (new_message "m2-fractional")) in
  Alcotest.(check string) "fraction retained" "2026-10-08 12:00:00.123456" message.created_at)

let () = Alcotest.run "M2-T4 messages" [
  "models", [
    Alcotest.test_case "lifecycle and callbacks" `Quick test_lifecycle;
    Alcotest.test_case "search and permissions" `Quick test_search_and_permissions;
    Alcotest.test_case "sparse reachable fallback" `Quick test_sparse_reachable_fallback;
    Alcotest.test_case "mentionees" `Quick test_mentionees;
    Alcotest.test_case "pagination and search history" `Quick test_pagination_and_history;
    Alcotest.test_case "updated page and ban cleanup" `Quick test_updated_page_and_ban_cleanup;
    Alcotest.test_case "attachment and sound" `Quick test_attachment_and_sound;
    Alcotest.test_case "rollback and timestamps" `Quick test_rollback_and_timestamps;
  ]]

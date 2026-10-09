open Campfire
module R = Db_remaining
module P = R.Push_subscription
module B = R.Ban
module A = R.Attachment
module M = Db_messages.Message

let now = Authentication.now_time "2026-10-08T12:00:00Z"
let now_text = "2026-10-08T12:00:00Z"
let david = 127326141L
let jason = 149087659L
let kevin = 712064548L
let designers = 654632876L
let check label value = Alcotest.(check bool) label true value
let public _ = Some "142.250.185.206"
let private_ip _ = None
exception Intentional_rollback

let rec reference_root path remaining =
  if remaining=0 then failwith "reference seed not found" else
  let candidate=Filename.concat path "once-campfire-rust" in
  if Sys.file_exists (Filename.concat candidate "parity/.seed/default/db/production.sqlite3")
  then candidate else reference_root (Filename.dirname path) (remaining-1)

let with_seed variant f =
  let root=reference_root (Sys.getcwd ()) 8 in
  let source=Sqlite3.db_open ~mode:`READONLY
    (Filename.concat root ("parity/.seed/" ^ variant ^ "/db/production.sqlite3")) in
  let path=Filename.temp_file "campfire-m2-t5-" ".sqlite3" in
  Sys.remove path;
  let quoted=String.concat "''" (String.split_on_char '\'' path) in
  let rc=Sqlite3.exec source ("VACUUM INTO '" ^ quoted ^ "'") in
  ignore (Sqlite3.db_close source);
  if rc<>Sqlite3.Rc.OK then failwith "seed copy failed";
  let rt=Db_runtime.open_db ~readers:1 ~prepare:false path in
  Fun.protect ~finally:(fun () ->
    Db_runtime.close rt;
    List.iter (fun suffix -> if Sys.file_exists (path^suffix) then Sys.remove (path^suffix))
      ["";"-wal";"-shm"])
    (fun () -> f rt)

let count db table = Db_runtime.query_one db ("SELECT COUNT(*) FROM "^table) []
  (fun row -> Sqlite3.column_int row 0) |> Option.get

let test_seed_variants () =
  List.iter (fun variant -> with_seed variant (fun rt ->
    Db_runtime.read rt (fun db ->
      List.iter (fun table -> check (variant^":"^table^" readable") (count db table>=0))
        ["active_storage_blobs";"active_storage_attachments";
         "active_storage_variant_records";"push_subscriptions";"bans";"webhooks"])))
    ["default";"crowd";"restricted";"first_run";"custom_styles"]

let test_storage () = with_seed "default" (fun rt ->
  let template:R.Blob.t = {id=(-1L);key="m2-t5-key";filename="photo.png";
    content_type=Some "image/png";metadata=Some "{\"identified\":true}";
    service_name="local";byte_size=12L;checksum=Some "abc";created_at="ignored"} in
  let blob,attachment,variant=Db_runtime.write rt (fun tx ->
    let blob=R.Blob.create tx ~now template in
    let attachment=A.create tx ~now ~record_type:"Message" ~record_id:999L
      ~name:"attachment" ~blob_id:blob.id in
    let variant=R.Variant_record.create tx ~blob_id:blob.id ~variation_digest:"digest" in
    blob,attachment,variant) in
  check "blob assigned ID and timestamp" (blob.id>0L && blob.created_at=Db_time.to_db now);
  Db_runtime.read rt (fun db ->
    check "blob round trip" (R.Blob.find db blob.id=blob);
    check "attachment find_for" (A.find_for db ~record_type:"Message" ~record_id:999L
      ~name:"attachment"=Some attachment);
    check "attachment blob" (A.blob db attachment=blob);
    check "variant find_for" (R.Variant_record.find_for db ~blob_id:blob.id
      ~variation_digest:"digest"=Some variant));
  check "attached blob cannot purge" (try Db_runtime.write rt (fun tx ->
    R.Blob.destroy tx blob); false with Invalid_argument _ -> true);
  Db_runtime.write rt (fun tx -> A.delete tx attachment; R.Blob.destroy tx blob);
  Db_runtime.read rt (fun db ->
    check "attachment removed" (A.find_for db ~record_type:"Message" ~record_id:999L
      ~name:"attachment"=None);
    check "variant cascade cleanup" (R.Variant_record.find_for db ~blob_id:blob.id
      ~variation_digest:"digest"=None);
    check "blob removed" (Db_runtime.query_one db
      "SELECT id FROM active_storage_blobs WHERE id=?" [Sqlite3.Data.INT blob.id]
      (fun row -> Sqlite3.column_int64 row 0)=None)))

let subscription endpoint = P.new_ ~user_id:david ~endpoint:(Some endpoint)
  ~p256dh_key:(Some "key") ~auth_key:(Some "auth") ~user_agent:None
let endpoint_errors endpoint resolver = P.validate (subscription endpoint) resolver
  |> List.map snd
let test_push_validation () =
  List.iter (fun endpoint -> check ("allowed "^endpoint) (endpoint_errors endpoint public=[]))
    ["https://fcm.googleapis.com/fcm/send/token";
     "https://jmt17.google.com/fcm/send/token";
     "https://updates.push.services.mozilla.com/wpush/v2/token";
     "https://web.push.apple.com/QaBC123";
     "https://wns2-db5p.notify.windows.com/w/?token=abc"];
  List.iter (fun (endpoint,expected) -> check ("reject "^endpoint)
    (List.mem expected (endpoint_errors endpoint public)))
    ["", "can't be blank";
     "http://fcm.googleapis.com/x", "must use HTTPS";
     "https://fcm.googleapis.com:8443/x", "must use the default HTTPS port";
     "https://fcm.googleapis.com:abc/x", "is not a valid URL";
     "https://fcm.googleapis.com:/x", "is not a valid URL";
     "https://evilfcm.googleapis.com.attacker.example/x", "is not a permitted push service";
     "https://attacker.example.com/x", "is not a permitted push service"];
  check "private DNS rejected" (List.mem "resolves to a private or invalid IP address"
    (endpoint_errors "https://fcm.googleapis.com/x" private_ip));
  check "endpoint pin" (P.resolved_endpoint_ip
    (subscription "https://fcm.googleapis.com/x") public=Some "142.250.185.206");
  check "bad origin not resolved" (P.resolved_endpoint_ip
    (subscription "https://attacker.example.com/x") public=None);
  check "JSON escaped truncation" (P.truncate_json_string "\"\"\"" 5="\"…");
  check "Unicode truncation" (P.truncate_json_string "😀😀" 7="😀…")

let test_push_rows_and_recipients () = with_seed "default" (fun rt ->
  check "invalid create blocked" (try Db_runtime.write rt (fun tx ->
    ignore (P.create tx ~now ~resolve:public (subscription "http://fcm.googleapis.com/x")));
    false with Invalid_argument _ -> true);
  let created=Db_runtime.write rt (fun tx -> P.create tx ~now ~resolve:public
    (subscription "https://fcm.googleapis.com/m2-t5")) in
  Db_runtime.read rt (fun db ->
    check "push row found" (P.find db created.id=created);
    check "push lookup keys" (P.find_for_user_by_keys db ~user_id:david
      ~endpoint:"https://fcm.googleapis.com/m2-t5" ~p256dh_key:"key" ~auth_key:"auth"=Some created);
    check "push count and for_user" (P.count db>=Int64.of_int (List.length (P.for_user db david)));
    check "badge" (P.badge created db=Db_rooms.Membership.unread_count db david));
  Db_runtime.write rt (fun tx -> P.destroy_by_endpoint tx ~user_id:david
    ~endpoint:"https://fcm.googleapis.com/m2-t5");
  Db_runtime.read rt (fun db -> check "destroy by endpoint" (not (List.exists
    (fun (row:P.t) -> row.id=created.id) (P.for_user db david))));
  let message=Db_runtime.write rt (fun tx -> M.create tx ~now
    {M.room_id=designers;creator_id=david;client_message_id=Some "m2-t5-push";
     body=Some "Hi";attachment_blob_id=None}) in
  Db_runtime.read rt (fun db ->
    let room=Db_rooms.Room.find db designers in
    let payload=P.payload_for db room message in
    check "room payload" (payload.title="Designers" && payload.body="David: Hi" &&
      payload.path="/rooms/"^Int64.to_string designers);
    let everything=P.for_users_involved_in_everything db ~room_id:designers
      ~creator_id:david ~now:now_text in
    let mentions=P.for_mentioned_users db ~room_id:designers ~creator_id:david
      ~mentionee_ids:[kevin] ~now:now_text in
    check "recipient SQL excludes sender" (List.for_all (fun (row:P.t) -> row.user_id<>david)
      (everything@mentions));
    let _,everything2,_=P.pushes_for db message ~now:now_text in
    check "pushes_for scope" (everything=everything2));
  Db_runtime.write rt (fun tx -> M.destroy tx ~now message))

let test_bans () =
  List.iter (fun ip -> check ("public "^ip) (B.validate ip=[]))
    ["8.8.8.8";"2001:4860:4860::8888"];
  List.iter (fun ip -> check ("internal "^ip)
    (B.validate ip=["ip_address","cannot be a private or internal IP address"]))
    ["127.0.0.1";"10.1.2.3";"172.16.0.1";"192.168.1.1";
     "169.254.169.254";"::1";"fc00::1";"fd12::1";"fe80::1";
     "::ffff:10.0.0.1";"::ffff:127.0.0.1";"[::1]";"10.4.5.6/8"];
  check "bad IP" (B.validate "garbage"=["ip_address","is not a valid IP address"]);
  with_seed "default" (fun rt ->
    check "invalid ban create blocked" (try Db_runtime.write rt (fun tx ->
      ignore (B.create tx ~now ~user_id:david ~ip_address:"10.0.0.1")); false
      with Invalid_argument _ -> true);
    let created=Db_runtime.write rt (fun tx -> B.create tx ~now ~user_id:david
      ~ip_address:"8.8.8.8") in
    Db_runtime.read rt (fun db ->
      check "ban found" (List.mem created (B.for_user db david));
      check "ban lookup exact" (B.banned db "8.8.8.8" && not (B.banned db "8.8.4.4"))))

let test_webhook_and_events () = with_seed "default" (fun rt ->
  let events=ref [] in
  let sink event=events:=!events@[event] in
  let webhook=Db_runtime.write rt (fun tx ->
    let row=R.Webhook.create tx ~now ~user_id:jason ~url:(Some "https://example.com/hook") in
    R.Event.after_commit tx sink (R.Event.DisconnectUser {user_id=jason;reconnect=true});
    check "event waits for commit" (!events=[]);
    row) in
  check "event delivered" (!events=[R.Event.DisconnectUser {user_id=jason;reconnect=true}]);
  (try Db_runtime.write rt (fun tx ->
    R.Event.after_commit tx sink (R.Event.PurgeBlob {blob_id=42L});
    failwith "rollback") with Failure _ -> ());
  check "rollback suppresses event" (List.length !events=1);
  let updated=Db_runtime.write rt (fun tx -> R.Webhook.update_url tx ~now webhook
    "https://example.com/new") in
  Db_runtime.read rt (fun db -> check "webhook updated"
    (R.Webhook.find_by_user db jason=Some updated));
  let msg=Db_runtime.write rt (fun tx -> M.create tx ~now
    {M.room_id=designers;creator_id=david;client_message_id=Some "m2-t5-webhook";
     body=Some "Hi @Jason";attachment_blob_id=None}) in
  Db_runtime.read rt (fun db ->
    let payload=R.Webhook.payload updated db msg ~room_bot_messages_path:"/bots/1/messages"
      ~message_path:"/rooms/1/at/2" in
    check "recipient mention removed" (payload.body_plain="Hi");
    let json=R.Webhook.payload_json payload |> Yojson.Safe.from_string in
    check "typed payload serialized" (Yojson.Safe.Util.(json |> member "message" |>
      member "body" |> member "plain" |> to_string)="Hi");
    check "Unicode whitespace trim" (R.Webhook.unicode_trim "\194\160 Hi \227\128\128"="Hi"));
  Db_runtime.write rt (fun tx -> R.Webhook.destroy tx updated; M.destroy tx ~now msg);
  Db_runtime.read rt (fun db -> check "webhook destroyed" (R.Webhook.find_by_user db jason=None)))

let test_typed_hook_adapters () = with_seed "default" (fun rt ->
  let events=ref [] in
  let sink event=events:=!events@[event] in
  let msg=Db_runtime.write rt (fun tx ->
    let created=R.Hooks.create_message tx ~now ~sink
      {M.room_id=designers;creator_id=david;client_message_id=Some "m2-t5-hooks";
       body=Some "hook";attachment_blob_id=None} in
    check "push event not yet sent" (!events=[]);
    created) in
  check "push event after commit" (!events=[R.Event.PushMessage
    {room_id=designers;message_id=msg.id}]);
  let template:R.Blob.t = {id=0L;key="m2-t5-hook-blob";filename="hook.png";
    content_type=None;metadata=None;service_name="local";byte_size=1L;
    checksum=None;created_at=""} in
  let blob=Db_runtime.write rt (fun tx -> R.Blob.create tx ~now template) in
  Db_runtime.write rt (fun tx -> ignore (R.Hooks.replace_message_attachment tx ~now
    ~sink msg (Some blob.id)));
  Db_runtime.read rt (fun db -> match R.Hooks.message_attachment db msg with
    | Some (attachment, found_blob) ->
        check "typed message attachment" (attachment.blob_id=blob.id && found_blob=blob)
    | None -> Alcotest.fail "message attachment missing");
  Db_runtime.write rt (fun tx -> R.Hooks.destroy_message tx ~now ~sink msg);
  Db_runtime.read rt (fun db -> check "typed attachment removed"
    (R.Hooks.message_attachment db msg=None));
  check "purge event after destroy" (List.mem (R.Event.PurgeBlob {blob_id=blob.id}) !events);
  let bot=Db_runtime.read rt (fun db -> Db_accounts.User.find db 394959859L) in
  Db_runtime.write rt (fun tx -> R.Hooks.deliver_webhook_later tx ~message_id:42L ~sink bot);
  check "webhook event adapter" (List.mem
    (R.Event.DeliverWebhook {bot_id=bot.id;message_id=42L}) !events))

let test_ban_hook_transaction () = with_seed "default" (fun rt ->
  let events=ref [] in
  let sink event=events:=!events@[event] in
  let authored=Db_runtime.write rt (fun tx -> M.create tx ~now
    {M.room_id=designers;creator_id=kevin;client_message_id=Some "m2-t5-ban";
     body=Some "ban cleanup";attachment_blob_id=None}) in
  ignore (Db_runtime.write rt (fun tx -> Db_accounts.Session.start
    (Db_runtime.conn tx) ~now:now_text ~user_id:kevin ~user_agent:None
    ~ip_address:(Some "8.8.8.8")));
  (try Db_runtime.write rt (fun tx ->
    ignore (R.Hooks.ban_user tx ~now:now_text ~sink
      (Db_accounts.User.find (Db_runtime.conn tx) kevin));
    check "ban hooks wait for commit" (!events=[]);
    raise Intentional_rollback) with Intentional_rollback -> ());
  Db_runtime.read rt (fun db ->
    check "rolled-back ban absent" (not (B.banned db "8.8.8.8"));
    check "rolled-back session retained"
      (List.exists (fun (session:Db_accounts.Session.t) ->
         session.ip_address=Some "8.8.8.8")
        (Db_accounts.Session.for_user db kevin)));
  ignore (Db_runtime.write rt (fun tx -> R.Hooks.ban_user tx ~now:now_text ~sink
    (Db_accounts.User.find (Db_runtime.conn tx) kevin)));
  check "ban events after commit" (!events=[
    R.Event.DisconnectUser {user_id=kevin;reconnect=false};
    R.Event.RemoveBannedContent {user_id=kevin}]);
  Db_runtime.read rt (fun db ->
    check "validated ban persisted" (B.banned db "8.8.8.8");
    check "sessions revoked" (Db_accounts.Session.for_user db kevin=[]));
  let removed=Db_runtime.write rt (fun tx -> R.Hooks.remove_banned_content tx
    ~now ~sink (Db_accounts.User.find (Db_runtime.conn tx) kevin)) in
  check "banned content returned for broadcast" (List.exists
    (fun (message:M.t) -> message.id=authored.id) removed);
  Db_runtime.read rt (fun db ->
    check "banned content deleted" (M.find_by_id db authored.id=None);
    check "banned content removed from search"
      (not (List.exists (fun (message:M.t) -> message.id=authored.id)
        (M.search_in_room db designers "ban cleanup"))));
  )

let () = Alcotest.run "M2-T5 remaining models" [
  "seeds",[Alcotest.test_case "all pinned variants" `Quick test_seed_variants];
  "storage",[Alcotest.test_case "blob attachment variant lifecycle" `Quick test_storage];
  "push",[Alcotest.test_case "endpoint and truncation" `Quick test_push_validation;
           Alcotest.test_case "rows recipients payload" `Quick test_push_rows_and_recipients];
  "ban",[Alcotest.test_case "IP validation and row" `Quick test_bans];
  "webhook",[Alcotest.test_case "payload and events" `Quick test_webhook_and_events];
  "hooks",[Alcotest.test_case "typed model adapters" `Quick test_typed_hook_adapters;
           Alcotest.test_case "ban transaction and events" `Quick test_ban_hook_transaction];
]

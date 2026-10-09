open Campfire

let get json name = Yojson.Basic.Util.member name json
let string json name = get json name |> Yojson.Basic.Util.to_string

let expected () =
  let local="fixtures/web_push_expected.json" in
  Yojson.Basic.from_file (if Sys.file_exists local then local else "test/"^local)

let test_rfc_vector () =
  let decode s = match Web_push_crypto.decode64 s with Ok v -> v | Error _ -> failwith "base64" in
  let message = Web_push_crypto.encrypt_with
    ~message:(decode "V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24")
    ~server_private:(decode "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")
    ~p256dh:"BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
    ~auth:"BTBZMqHH6r4Tts7J_aSIgg"
    ~salt:(decode "DGv6ra1nlYgDCS1FRnbzlw")
    ~record_size:4096 ~padding:"\002" () in
  match message with
  | Error _ -> Alcotest.fail "RFC 8291 encryption failed"
  | Ok body -> Alcotest.(check string) "RFC 8291 ciphertext"
      "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
      (Web_push_crypto.encode64 body)

let test_gem_ciphertext () =
  let json=expected () in
  let decode name=match Web_push_crypto.decode64 (string json name) with
    | Ok value -> value | Error _ -> Alcotest.fail ("bad fixture "^name) in
  let ciphertext=decode "ciphertext" in
  match Web_push_crypto.decrypt ~ciphertext
    ~receiver_private:(decode "receiver_private_key") ~auth:(string json "auth") with
  | Error _ -> Alcotest.fail "Rails gem ciphertext did not decrypt"
  | Ok (size,plaintext) ->
    Alcotest.(check int) "gem record size" (String.length ciphertext-86) size;
    Alcotest.(check string) "gem plaintext" (string json "message"^"\002\000") plaintext

let test_vapid () =
  let json=expected () in
  let public_key="BEYXTBB5_jNhNzXDmx5KEU55Vbbd-u--Lk9rM5OFQvUkPIBwZJ9QzAq0zdEzFw6yTV8cTriz_qYBVicY02_VxTQ=" in
  let private_key="qfXLHghuG1rSHZUVo9SscNRI-0EIHRbIrfeGCqbAwak=" in
  let vapid=match Web_push_vapid.create
    ~subject:(string json "vapid_subject") ~public_key ~private_key with
    | Ok v -> v | Error _ -> Alcotest.fail "VAPID rejected fixture keys" in
  let header=Web_push_vapid.authorization vapid
    ~audience:"https://fcm.googleapis.com" ~now:1700000000 in
  let prefix="vapid t="^string json "jwt_header_segment"^"."^
    string json "jwt_payload_segment"^"." in
  Alcotest.(check bool) "claims/header" true (String.starts_with ~prefix header);
  Alcotest.(check bool) "public key" true
    (String.ends_with ~suffix:(",k="^string json "authorization_k") header);
  let token=String.sub header (String.length "vapid t=")
    (String.length header - String.length "vapid t=" - String.length (",k="^string json "authorization_k")) in
  let signature=List.nth_opt (String.split_on_char '.' token) 2 |> Option.get in
  let decoded=match Web_push_crypto.decode64 signature with Ok x -> x | Error _ -> Alcotest.fail "signature base64" in
  Alcotest.(check int) "raw ES256 signature size" 64 (String.length decoded);
  let digest=Mirage_crypto.Hash.SHA256.digest (Cstruct.of_string
    (string json "jwt_header_segment"^"."^string json "jwt_payload_segment")) in
  let public=match Web_push_crypto.decode64 public_key with Ok v -> v | Error _ -> assert false in
  let public=match Mirage_crypto_ec.P256.Dsa.pub_of_cstruct (Cstruct.of_string public) with
    | Ok v -> v | Error _ -> assert false in
  Alcotest.(check bool) "signature verifies" true
    (Mirage_crypto_ec.P256.Dsa.verify ~key:public
      (Cstruct.of_string (String.sub decoded 0 32),Cstruct.of_string (String.sub decoded 32 32)) digest);
  Alcotest.(check bool) "bad private key rejected" true
    (match Web_push_vapid.create ~subject:"x" ~public_key ~private_key:"bad!" with Error _ -> true | _ -> false)

let subscription id = {Db_remaining.Push_subscription.id;
  user_id=1L;endpoint=Some "https://fcm.googleapis.com/fcm/send/abc";
  p256dh_key=None;auth_key=None;user_agent=None;created_at="";updated_at=""}

let fixture_vapid () = match Web_push_vapid.create
  ~subject:"mailto:support@37signals.com"
  ~public_key:"BEYXTBB5_jNhNzXDmx5KEU55Vbbd-u--Lk9rM5OFQvUkPIBwZJ9QzAq0zdEzFw6yTV8cTriz_qYBVicY02_VxTQ="
  ~private_key:"qfXLHghuG1rSHZUVo9SscNRI-0EIHRbIrfeGCqbAwak=" with
  | Ok value -> value | Error _ -> failwith "fixture VAPID key"

let valid_subscription id =
  let json=expected () in
  { (subscription id) with
    p256dh_key=Some (string json "p256dh");
    auth_key=Some (string json "auth") }

let test_payload_and_safety () =
  let json=expected () in
  let n={Web_push.title="Designers <&> \"quotes\" é 😀";
    body="Kevin: line\nbreak\ttab \u{2028} \u{1f} / \\ ";
    path="/rooms/1";badge=3L;subscription=subscription 1L} in
  Alcotest.(check string) "Rails JSON" (string json "message") (Web_push.encoded_message n);
  Alcotest.(check bool) "private IPv4 denied" false (Web_push.public_ip "10.0.0.5");
  Alcotest.(check bool) "public IPv4 accepted" true (Web_push.public_ip "142.250.185.206");
  Alcotest.(check bool) "404 invalidates" true (Web_push.invalidates_subscription (Web_push.Gone 404));
  Alcotest.(check bool) "TLS failure retained" false (Web_push.invalidates_subscription (Web_push.Network "tls"))

let test_delivery_wire () =
  let captured_request=ref None in
  let n={Web_push.title="Designers <&> \"quotes\" é 😀";
    body="Kevin: line\nbreak\ttab \u{2028} \u{1f} / \\ ";
    path="/rooms/1";badge=3L;subscription=valid_subscription 1L} in
  let outbound req = captured_request:=Some req; Ok {Web_push.status=201;reason="Created"} in
  let result=Web_push.deliver ~resolve:(fun _ -> Some "142.250.185.206")
    ~outbound ~vapid:(fixture_vapid ()) ~now:1700000000 n in
  Alcotest.(check bool) "delivered" true (result=Ok (Some 201));
  let request=Option.get !captured_request in
  Alcotest.(check string) "pinned IP" "142.250.185.206" request.pinned_ip;
  Alcotest.(check bool) "whole delivery deadline" true
    (request.deadline > Unix.gettimeofday ()+.29.);
  let names=List.map fst request.headers in
  Alcotest.(check (list string)) "gem header order"
    ["Content-Type";"Ttl";"Urgency";"Content-Encoding";"Content-Length";"Authorization"] names;
  let json=expected () in
  let receiver=match Web_push_crypto.decode64 (string json "receiver_private_key") with
    | Ok bytes -> bytes | Error _ -> failwith "fixture receiver key" in
  (match Web_push_crypto.decrypt ~ciphertext:request.body
    ~receiver_private:receiver ~auth:(string json "auth") with
  | Ok (_,plaintext) -> Alcotest.(check string) "encrypted Rails payload"
      (string json "message"^"\002\000") plaintext
  | Error _ -> Alcotest.fail "notification ciphertext did not decrypt");
  captured_request:=None;
  let skipped=Web_push.deliver ~resolve:(fun _ -> Some "10.0.0.5")
    ~outbound ~vapid:(fixture_vapid ()) ~now:1700000000 n in
  Alcotest.(check bool) "private endpoint skipped" true (skipped=Ok None);
  Alcotest.(check bool) "no private dispatch" true (!captured_request=None)

let test_jobs_limits_and_isolation () =
  let mutex=Mutex.create () and gate=Condition.create () and open_gate=ref false in
  let started=ref 0 and webhooks=ref 0 and purges=ref 0 in
  let jobs=Jobs.create ~capacity:1 ~workers:1
    ~on_push:(fun ~room_id:_ ~message_id:_ ->
      Mutex.lock mutex; incr started; Condition.signal gate;
      while not !open_gate do Condition.wait gate mutex done;
      Mutex.unlock mutex)
    ~on_webhook:(fun ~bot_id:_ ~message_id:_ -> incr webhooks)
    ~on_remove_banned:(fun ~user_id:_ -> failwith "isolated")
    ~on_purge:(fun ~blob_id:_ -> incr purges) () in
  let sink=Jobs.event_sink jobs in
  sink (Db_remaining.Event.PushMessage {room_id=1L;message_id=1L});
  Mutex.lock mutex;
  while !started=0 do Condition.wait gate mutex done;
  Mutex.unlock mutex;
  sink (Db_remaining.Event.PushMessage {room_id=1L;message_id=2L});
  sink (Db_remaining.Event.PushMessage {room_id=1L;message_id=3L});
  sink (Db_remaining.Event.DeliverWebhook {bot_id=1L;message_id=1L});
  sink (Db_remaining.Event.RemoveBannedContent {user_id=1L});
  sink (Db_remaining.Event.PurgeBlob {blob_id=1L});
  let _,_,_,_,dropped=Jobs.stats jobs Jobs.Push_message in
  Alcotest.(check int) "bounded push queue" 1 dropped;
  Mutex.lock mutex; open_gate:=true;Condition.broadcast gate;Mutex.unlock mutex;
  Alcotest.(check bool) "drains" true
    (Jobs.shutdown jobs ~deadline:(Unix.gettimeofday ()+.2.));
  Alcotest.(check int) "other kind runs" 1 !webhooks;
  Alcotest.(check int) "purge runs" 1 !purges;
  let _,_,_,failures,_=Jobs.stats jobs Jobs.Remove_banned_content in
  Alcotest.(check int) "failure contained" 1 failures

let test_pool_limits () =
  let mutex=Mutex.create () and gate=Condition.create () and open_gate=ref false in
  let started=ref 0 in
  let pool=Web_push.create_pool ~max_active:1 ~max_queue:2
    ~resolve:(fun _ -> Some "142.250.185.206")
    ~outbound:(fun _ -> Mutex.lock mutex; incr started; Condition.signal gate;
      while not !open_gate do Condition.wait gate mutex done;
      Mutex.unlock mutex; Ok {Web_push.status=201;reason="Created"})
    ~vapid:(fixture_vapid ())
    ~invalidate:(fun _ -> ()) () in
  let n={Web_push.title="t";body="b";path="/";badge=0L;
    subscription=valid_subscription 1L} in
  ignore (Web_push.enqueue pool n);
  Mutex.lock mutex;while !started=0 do Condition.wait gate mutex done;Mutex.unlock mutex;
  ignore (Web_push.enqueue pool n);ignore (Web_push.enqueue pool n);
  Alcotest.(check bool) "full pool drops" false (Web_push.enqueue pool n);
  Alcotest.(check int) "pending cap" 3 (Web_push.pending pool);
  Alcotest.(check bool) "deadline expires while outbound stalls" false
    (Web_push.shutdown pool ~deadline:(Unix.gettimeofday () +. 0.005));
  Mutex.lock mutex;open_gate:=true;Condition.broadcast gate;Mutex.unlock mutex;
  Alcotest.(check bool) "pool drains" true (Web_push.shutdown pool ~deadline:(Unix.gettimeofday ()+.3.))

let test_pool_order_and_invalidation () =
  let conn=Sqlite3.db_open ":memory:" in
  ignore (Sqlite3.exec conn "CREATE TABLE memberships (user_id INTEGER, unread_at TEXT)");
  let delivered=ref [] and invalidated=ref [] in
  let pool=Web_push.create_pool ~max_active:1 ~max_queue:4
    ~resolve:(fun _ -> Some "142.250.185.206")
    ~outbound:(fun request ->
      delivered:= !delivered@[request.endpoint];
      if String.ends_with ~suffix:"/2" request.endpoint then
        Ok {Web_push.status=404;reason="Not Found"}
      else if String.ends_with ~suffix:"/3" request.endpoint then
        Ok {Web_push.status=503;reason="Service Unavailable"}
      else Ok {Web_push.status=201;reason="Created"})
    ~vapid:(fixture_vapid ())
    ~invalidate:(fun id -> invalidated:= !invalidated@[id]) () in
  let with_endpoint id = { (valid_subscription id) with
    endpoint=Some ("https://fcm.googleapis.com/fcm/send/"^Int64.to_string id)} in
  let payload={Db_remaining.Push_subscription.title="t";body="b";path="/rooms/1"} in
  Web_push.queue pool conn payload [with_endpoint 3L;with_endpoint 1L;with_endpoint 2L];
  Alcotest.(check bool) "pool drains" true
    (Web_push.shutdown pool ~deadline:(Unix.gettimeofday ()+.3.));
  Alcotest.(check (list string)) "subscription id order"
    ["https://fcm.googleapis.com/fcm/send/1";
     "https://fcm.googleapis.com/fcm/send/2";
     "https://fcm.googleapis.com/fcm/send/3"] !delivered;
  Alcotest.(check (list int64)) "only 404 invalidated" [2L] !invalidated;
  ignore (Sqlite3.db_close conn)

let () = Alcotest.run "M5-T3 jobs and Web Push" [
  "crypto",[Alcotest.test_case "RFC 8291 vector" `Quick test_rfc_vector;
    Alcotest.test_case "Rails gem ciphertext" `Quick test_gem_ciphertext;
    Alcotest.test_case "VAPID fixture" `Quick test_vapid];
  "wire",[Alcotest.test_case "Rails payload and safety" `Quick test_payload_and_safety;
    Alcotest.test_case "pinned delivery" `Quick test_delivery_wire];
  "limits",[Alcotest.test_case "jobs" `Quick test_jobs_limits_and_isolation;
    Alcotest.test_case "pool" `Quick test_pool_limits;
    Alcotest.test_case "order and invalidation" `Quick test_pool_order_and_invalidation]]

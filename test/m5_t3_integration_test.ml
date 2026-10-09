open Campfire
open Lwt.Infix

let now="2026-10-08T12:00:00Z"
let secret=String.make 64 'q'
let fixture_public="BEYXTBB5_jNhNzXDmx5KEU55Vbbd-u--Lk9rM5OFQvUkPIBwZJ9QzAq0zdEzFw6yTV8cTriz_qYBVicY02_VxTQ="
let fixture_private="qfXLHghuG1rSHZUVo9SscNRI-0EIHRbIrfeGCqbAwak="
let fixture_p256dh="BDaRUn_gvMok9AhEo1soNNypgpMDfe2K0hz6RMEIxxULWKfVUqodLAxtX1mrUMC4PGgk1RkZJTut7vJ2RMrxowo="
let fixture_auth="BCuqPYqblNIL9NEJ4WT1Yw=="
let check name expected actual = Alcotest.(check int) name expected actual
let status response=Cohttp.Code.code_of_status (Cohttp.Response.status response)
let contains source needle =
  let n=String.length needle in
  let rec loop i = i+n<=String.length source &&
    (String.sub source i n=needle || loop (i+1)) in
  loop 0

let queued_broadcasts cable subscriber =
  let delivered = Cable_ring.take_many cable.Cable_channels.hub [subscriber] ~limit:64 in
  let frames = match delivered with
    | `Frames frames | `Lagged frames -> frames in
  List.map snd frames

let rec reference_root path remaining =
  if remaining=0 then failwith "pinned seed not found" else
  let candidate=Filename.concat path "once-campfire-rust" in
  if Sys.file_exists (Filename.concat candidate "parity/.seed/default/db/production.sqlite3")
  then candidate else reference_root (Filename.dirname path) (remaining-1)

let with_seed f =
  let source=Filename.concat (reference_root (Sys.getcwd ()) 8)
    "parity/.seed/default/db/production.sqlite3" in
  let from=Sqlite3.db_open ~mode:`READONLY source in
  let path=Filename.temp_file "campfire-m5-jobs" ".sqlite3" in
  Sys.remove path;
  let quoted=String.concat "''" (String.split_on_char '\'' path) in
  let rc=Sqlite3.exec from ("VACUUM INTO '"^quoted^"'") in
  ignore (Sqlite3.db_close from);
  if rc<>Sqlite3.Rc.OK then failwith "could not copy pinned seed";
  let runtime=Db_runtime.open_db ~readers:2 ~prepare:false path in
  let root=Filename.temp_file "campfire-m5-storage" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let storage=Storage_disk.create ~root ~name:"local" in
  Fun.protect ~finally:(fun () ->
    Db_runtime.close runtime;
    List.iter (fun file -> if Sys.file_exists file then Sys.remove file)
      [path;path^"-wal";path^"-shm"];
    ignore (Sys.command ("rm -rf " ^ Filename.quote root)))
    (fun () -> f runtime storage)

let config ?(vapid=true) () =
  let base=match Config.from_lookup (function
    | "SECRET_KEY_BASE" -> Some secret
    | "DISABLE_SSL" -> Some "1"
    | _ -> None) with Ok value -> value | Error e -> failwith e in
  if vapid then {base with vapid_public_key=Some fixture_public;
    vapid_private_key=Some fixture_private;
    vapid_subject="mailto:support@37signals.com"} else base

let cable runtime = Cable_channels.create ~db:runtime ~secret_key_base:secret
  ~now:(fun () -> now) ()

let start ?(vapid=true) ?deliver_webhook ?outbound runtime storage cable =
  App_jobs.start ?deliver_webhook ?outbound ~config:(config ~vapid ())
    ~runtime ~storage ~cable ~resolve:(fun _ -> Some "142.250.185.206") ()

let with_app ?(vapid=true) ?deliver_webhook ?outbound runtime storage f =
  let cable=cable runtime in
  let app=start ~vapid ?deliver_webhook ?outbound runtime storage cable in
  Fun.protect ~finally:(fun () ->
    ignore (Lwt_main.run (Lwt_preemptive.detach (fun () ->
      App_jobs.shutdown app ~deadline:(Unix.gettimeofday ()+.1.)) ())))
    (fun () -> f app cable)

let with_tls_push_endpoint ?(status=201) ?(delay=0.) f =
  let root=Filename.temp_file "campfire-m5-push-tls" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let cert=Filename.concat root "server.pem"
  and key=Filename.concat root "server.key"
  and capture=Filename.concat root "capture.json" in
  let command=Printf.sprintf
    "openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj /CN=fcm.googleapis.com -addext subjectAltName=DNS:fcm.googleapis.com -keyout %s -out %s >/dev/null 2>&1"
    (Filename.quote key) (Filename.quote cert) in
  if Sys.command command<>0 then failwith "could not create local push TLS certificate";
  let script=if Sys.file_exists "test/support_push_tls.py"
    then "test/support_push_tls.py" else "support_push_tls.py" in
  let read_fd,write_fd=Unix.pipe () in
  let args=[|"python3";script;cert;key;capture;string_of_int status;
    string_of_float delay|] in
  let pid=Unix.create_process "python3" args Unix.stdin write_fd Unix.stderr in
  Unix.close write_fd;
  let input=Unix.in_channel_of_descr read_fd in
  Fun.protect ~finally:(fun () ->
    close_in_noerr input;
    (try Unix.kill pid Sys.sigterm with Unix.Unix_error (Unix.ESRCH,_,_) -> ());
    ignore (try Unix.waitpid [] pid with Unix.Unix_error (Unix.ECHILD,_,_) -> 0,Unix.WEXITED 0);
    List.iter (fun path -> if Sys.file_exists path then Sys.remove path)
      [cert;key;capture];
    Unix.rmdir root) (fun () ->
      let port=int_of_string (input_line input) in
      f ~port ~cert ~capture)

let local_tls_outbound ?deadline ~port ~cert (request:Web_push.request) =
  (* The production Web Push guard sees a public resolved address. Only this
     test transport remaps the socket to a disposable local TLS server. *)
  if request.pinned_ip<>"142.250.185.206" then Error "unexpected public pin" else
  let exchange=Outbound_http.web_push_exchange request in
  let url=Uri.of_string exchange.url |> fun uri ->
    Uri.to_string (Uri.with_port uri (Some port)) in
  let exchange={exchange with url;pinned_ip=Some "127.0.0.1";
    ca_bundle=Some cert;
    deadline=Option.value ~default:exchange.deadline deadline} in
  Result.map (fun (response:Outbound_http.response) ->
    {Web_push.status=response.status;reason=response.reason})
    (Outbound_http.perform exchange)

let captured_push path = Yojson.Basic.from_file path
let captured_header captured key =
  Yojson.Basic.Util.(captured |> member "headers" |> to_list)
  |> List.find_map (fun pair -> match Yojson.Basic.Util.to_list pair with
    | [name;value] when String.lowercase_ascii
        (Yojson.Basic.Util.to_string name)=String.lowercase_ascii key ->
        Some (Yojson.Basic.Util.to_string value)
    | _ -> None)

let send ~runtime ~app ~cable ~user_id ?(body="") meth path =
  let session=Db_runtime.write runtime (fun tx ->
    Db_accounts.Session.start (Db_runtime.conn tx) ~now ~user_id
      ~user_agent:None ~ip_address:None) in
  let cookie="session_token="^Authentication.issue_token_cookie
    ~secret_key_base:secret ~now session.token in
  let headers=Cohttp.Header.of_list [
    "host","chat.example.com";"origin","https://chat.example.com";
    "sec-fetch-site","same-origin";"cookie",cookie;
    "content-type","application/x-www-form-urlencoded";
    "accept","text/vnd.turbo-stream.html, text/html"] in
  let request=Cohttp.Request.make ~meth ~headers
    (Uri.of_string ("https://chat.example.com"^path)) in
  let response,body=Lwt_main.run (Http_app.handle ~runtime
    ~secret_key_base:secret ~now ~ssl:true ~force_ssl:true
    ~cable ~event_sink:(App_jobs.event_sink app)
    ~dispatch:App_dispatch.endpoint request (Cohttp_lwt.Body.of_string body)) in
  response,Lwt_main.run (Cohttp_lwt.Body.to_string body)

let test_vapid_config () =
  let missing=config ~vapid:false () in
  Alcotest.(check string) "default VAPID subject"
    "https://github.com/basecamp/once-campfire-rust" missing.vapid_subject;
  let domain=Config.from_lookup (function
    | "SECRET_KEY_BASE" -> Some secret
    | "TLS_DOMAIN" -> Some " chat.example.com,second.example "
    | _ -> None) |> Result.get_ok in
  Alcotest.(check string) "first TLS domain is subject"
    "https://chat.example.com" domain.vapid_subject;
  with_seed (fun runtime storage ->
    with_app ~vapid:false runtime storage (fun app _ ->
      Alcotest.(check bool) "missing keys disable push" true (app.push_pool=None));
    let bad={(config ()) with vapid_private_key=Some "bad!"} in
    let cable=cable runtime in
    let app=App_jobs.start ~config:bad ~runtime ~storage ~cable
      ~resolve:(fun _ -> Some "142.250.185.206")
      ~outbound:(fun _ -> failwith "no outbound") () in
    Alcotest.(check bool) "bad keys disable push" true (app.push_pool=None);
    ignore (App_jobs.shutdown app ~deadline:(Unix.gettimeofday ()+.1.)))

let test_purge_after_commit () = with_seed (fun runtime storage ->
  with_app ~vapid:false runtime storage (fun app _ ->
    let source=Filename.temp_file "campfire-m5-blob" ".txt" in
    let out=open_out_bin source in output_string out "purge-me";close_out out;
    let blob=Fun.protect ~finally:(fun () -> Sys.remove source) (fun () ->
      Storage_blob.create_and_upload runtime storage ~source ~filename:"a.txt"
        ~content_type:(Some "text/plain") ~now:(Db_accounts.now_time now)) in
    let path=Storage_disk.path_for storage blob.key in
    Alcotest.(check bool) "blob file exists" true (Sys.file_exists path);
    (try Db_runtime.write runtime (fun tx ->
       Db_remaining.Event.after_commit tx (App_jobs.event_sink app)
         (Db_remaining.Event.PurgeBlob {blob_id=blob.id});
       failwith "rollback") with Failure _ -> () | error -> raise error);
    Alcotest.(check bool) "rollback retains file" true (Sys.file_exists path);
    Db_runtime.write runtime (fun tx ->
      Db_remaining.Event.after_commit tx (App_jobs.event_sink app)
        (Db_remaining.Event.PurgeBlob {blob_id=blob.id}));
    Alcotest.(check bool) "jobs drain" true
      (Jobs.shutdown app.jobs ~deadline:(Unix.gettimeofday ()+.5.));
    Alcotest.(check bool) "committed purge removes file" false (Sys.file_exists path);
    let row=Db_runtime.read runtime (fun db ->
      Db_runtime.query_one db
        (Db_remaining.Blob.select^" WHERE id=?")
        [Sqlite3.Data.INT blob.id] Db_remaining.Blob.decode) in
    Alcotest.(check bool) "committed purge removes row" true (row=None)))

let test_notification_route () = with_seed (fun runtime storage ->
  Db_runtime.write runtime (fun tx ->
    ignore (Db_runtime.execute (Db_runtime.conn tx)
      "UPDATE push_subscriptions SET p256dh_key=?,auth_key=? WHERE id=56887440"
      [Sqlite3.Data.TEXT fixture_p256dh;Sqlite3.Data.TEXT fixture_auth]));
  let sent=ref [] in
  with_app ~outbound:(fun request ->
      sent:=request::!sent;Ok {Web_push.status=201;reason="Created"})
    runtime storage (fun app cable ->
      let path="/users/me/push_subscriptions/56887440/test_notifications" in
      let foreign,_=send ~runtime ~app ~cable ~user_id:712064548L `POST path in
      check "subscription scoped to owner" 404 (status foreign);
      let owner,_=send ~runtime ~app ~cable ~user_id:127326141L `POST path in
      check "inline test notification redirects" 302 (status owner);
      check "one outbound" 1 (List.length !sent);
      let request=List.hd !sent in
      Alcotest.(check string) "pinned address" "142.250.185.206" request.pinned_ip;
      let private_key=Web_push_crypto.decode64
        "Y1H_BKvKi4Ht2cE4HZ8AgD0nn8chE3zhgBtEODTn4I4=" |> Result.get_ok in
      let _,plain=Web_push_crypto.decrypt ~ciphertext:request.body
        ~receiver_private:private_key ~auth:fixture_auth |> Result.get_ok in
      let payload=Yojson.Basic.from_string (String.sub plain 0 (String.length plain-2)) in
      Alcotest.(check string) "test title" "Campfire Test"
        (Yojson.Basic.Util.(payload |> member "title" |> to_string));
      Alcotest.(check string) "absolute notification path"
        "https://chat.example.com/users/me/push_subscriptions"
        (Yojson.Basic.Util.(payload |> member "options" |> member "data"
          |> member "path" |> to_string)));
  with_app ~vapid:false runtime storage (fun app cable ->
    let response,_=send ~runtime ~app ~cable ~user_id:127326141L `POST
      "/users/me/push_subscriptions/56887440/test_notifications" in
    check "push off returns 500" 500 (status response));
  with_app ~outbound:(fun _ -> Ok {Web_push.status=410;reason="Gone"})
    runtime storage (fun app cable ->
      let response,_=send ~runtime ~app ~cable ~user_id:127326141L `POST
        "/users/me/push_subscriptions/56887440/test_notifications" in
      check "failed inline push returns 500" 500 (status response);
      let retained=Db_runtime.read runtime (fun db ->
        Db_remaining.Push_subscription.find db 56887440L) in
      Alcotest.(check int64) "inline failure leaves subscription"
        56887440L retained.id))

let test_http_webhook_reply () = with_seed (fun runtime storage ->
  let deliveries=ref [] in
  with_app ~vapid:false ~deliver_webhook:(fun url payload ->
      deliveries:=(url,payload)::!deliveries;
      Ok {Webhook.status=Some 200;reply=Webhook.Text "Bender says hello"})
    runtime storage (fun app cable ->
      let room=Db_runtime.read runtime (fun db -> Db_rooms.Room.find db 340026324L) in
      let subscriber=Cable_ring.subscribe cable.Cable_channels.hub
        ~stream:(Cable_broadcasts.message_stream room) ~identifier:"test" in
      let response,_=send ~runtime ~app ~cable ~user_id:712064548L
        ~body:"message%5Bbody%5D=Hi+Bender" `POST
        "/rooms/340026324/messages" in
      check "direct room message accepted" 200 (status response);
      Alcotest.(check bool) "webhook job drains" true
        (Jobs.shutdown app.jobs ~deadline:(Unix.gettimeofday ()+.5.));
      check "webhook delivered" 1 (List.length !deliveries);
      let url,_=List.hd !deliveries in
      Alcotest.(check string) "bot webhook URL" "http://example.com/bender" url;
      let replies=Db_runtime.read runtime (fun db ->
        Db_messages.Message.for_room db room.id
        |> List.filter (fun (m:Db_messages.Message.t) -> m.creator_id=394959859L)
        |> List.filter (fun (m:Db_messages.Message.t) ->
          Db_messages.Message.plain_text_body db m="Bender says hello")) in
      check "bot reply persisted" 1 (List.length replies);
      let frames=queued_broadcasts cable subscriber in
      Alcotest.(check bool) "reply broadcast" true
        (List.exists (fun frame -> contains frame "Bender says hello") frames)))

let test_http_attachment_reply () = with_seed (fun runtime storage ->
  with_app ~vapid:false ~deliver_webhook:(fun _ _ ->
      Ok {Webhook.status=Some 200;reply=Webhook.Attachment
        {data="bot attachment bytes";filename="attachment.text";
         content_type="text/plain"}})
    runtime storage (fun app cable ->
      let room=Db_runtime.read runtime (fun db -> Db_rooms.Room.find db 340026324L) in
      let subscriber=Cable_ring.subscribe cable.Cable_channels.hub
        ~stream:(Cable_broadcasts.message_stream room) ~identifier:"attachment" in
      let response,_=send ~runtime ~app ~cable ~user_id:712064548L
        ~body:"message%5Bbody%5D=Send+file" `POST
        "/rooms/340026324/messages" in
      check "message accepted" 200 (status response);
      Alcotest.(check bool) "attachment job drains" true
        (Jobs.shutdown app.jobs ~deadline:(Unix.gettimeofday ()+.5.));
      let attachment=Db_runtime.read runtime (fun db ->
        let found=Db_messages.Message.for_room db 340026324L
        |> List.find_opt (fun (m:Db_messages.Message.t) ->
          m.creator_id=394959859L &&
          Option.is_some (Db_messages.Message.attachment_blob_id db m)) in
        Option.bind found (fun message ->
          Db_remaining.Hooks.message_attachment db message)) in
      let _,blob=Option.get attachment in
      Alcotest.(check bool) "attachment persisted to disk" true
        (Sys.file_exists (Storage_disk.path_for storage blob.key));
      Alcotest.(check bool) "attachment analyzed" true
        (contains (Option.value ~default:"" blob.metadata) "analyzed");
      let frames=queued_broadcasts cable subscriber in
      Alcotest.(check bool) "attachment broadcast" true
        (List.exists (fun frame -> contains frame "attachment.text") frames)))

let test_webhook_canonicalization_failure () = with_seed (fun runtime storage ->
  let too_large=String.make (16*1024*1024+1) 'x' in
  let bot_count ()=Db_runtime.read runtime (fun db ->
    Db_messages.Message.for_room db 340026324L
    |> List.filter (fun (message:Db_messages.Message.t) ->
      message.creator_id=394959859L) |> List.length) in
  let before=bot_count () in
  with_app ~vapid:false ~deliver_webhook:(fun _ _ ->
      Ok {Webhook.status=Some 200;reply=Webhook.Text too_large})
    runtime storage (fun app cable ->
      let response,_=send ~runtime ~app ~cable ~user_id:712064548L
        ~body:"message%5Bbody%5D=Oversized+reply" `POST
        "/rooms/340026324/messages" in
      check "original message accepted" 200 (status response);
      Alcotest.(check bool) "failed job drains" true
        (Jobs.shutdown app.jobs ~deadline:(Unix.gettimeofday ()+.5.));
      let _,_,_,failures,_=Jobs.stats app.jobs Jobs.Deliver_webhook in
      check "canonicalization fails job" 1 failures;
      check "raw bot reply never persisted" before (bot_count ())))

let test_remove_banned_content () = with_seed (fun runtime storage ->
  with_app ~vapid:false runtime storage (fun app cable ->
    let room=Db_runtime.read runtime (fun db ->
      Db_rooms.Room.find db 654632876L) in
    let subscriber=Cable_ring.subscribe cable.Cable_channels.hub
      ~stream:(Cable_broadcasts.message_stream room) ~identifier:"remove" in
    let message=Db_runtime.write runtime (fun tx ->
      Db_remaining.Hooks.create_message tx ~sink:(App_jobs.event_sink app)
        ~now:(Db_accounts.now_time now)
        {Db_messages.Message.room_id=room.id;creator_id=773523955L;
         client_message_id=Some "m5-banned";body=Some "remove me";
         attachment_blob_id=None}) in
    Db_runtime.write runtime (fun tx ->
      Db_remaining.Event.after_commit tx (App_jobs.event_sink app)
        (Db_remaining.Event.RemoveBannedContent {user_id=773523955L}));
    Alcotest.(check bool) "cleanup job drains" true
      (Jobs.shutdown app.jobs ~deadline:(Unix.gettimeofday ()+.5.));
    Alcotest.(check bool) "banned message removed" true
      (Db_runtime.read runtime (fun db ->
        Db_messages.Message.find_by_id db message.id)=None);
    let frames=queued_broadcasts cable subscriber in
    Alcotest.(check bool) "remove broadcast" true
      (List.exists (fun frame -> contains frame "action=\\\"remove") frames)))

let test_seeded_push_job () = with_seed (fun runtime storage ->
  Db_runtime.write runtime (fun tx ->
    ignore (Db_runtime.execute (Db_runtime.conn tx)
      "UPDATE push_subscriptions SET p256dh_key=?,auth_key=? WHERE id IN (257765087,782661003)"
      [Sqlite3.Data.TEXT fixture_p256dh;Sqlite3.Data.TEXT fixture_auth]));
  let requests=ref [] in
  with_app ~outbound:(fun request ->
      requests:= !requests@[request];Ok {Web_push.status=201;reason="Created"})
    runtime storage (fun app cable ->
      let response,_=send ~runtime ~app ~cable ~user_id:127326141L
        ~body:"message%5Bbody%5D=Hello+designers" `POST
        "/rooms/654632876/messages" in
      check "message accepted" 200 (status response);
      Alcotest.(check bool) "jobs and push pool drain" true
        (App_jobs.shutdown app ~deadline:(Unix.gettimeofday ()+.5.));
      check "two recipient subscriptions" 2 (List.length !requests);
      Alcotest.(check (list string)) "subscription ID order"
        ["https://fcm.googleapis.com/fcm/send/456";
         "https://fcm.googleapis.com/fcm/send/567"]
        (List.map (fun request -> request.Web_push.endpoint) !requests)))

let test_seeded_firefox_subscription_retained () = with_seed (fun runtime _ ->
  let id=782661004L in
  let subscription=Db_runtime.read runtime (fun db ->
    Db_remaining.Push_subscription.find db id) in
  let vapid=Web_push_vapid.create ~subject:"mailto:support@37signals.com"
    ~public_key:fixture_public ~private_key:fixture_private
    |> Result.get_ok in
  let outbound_called=ref false and invalidated=ref false in
  let pool=Web_push.create_pool ~max_active:1 ~max_queue:1
    ~resolve:(fun _ -> Some "142.250.185.206")
    ~outbound:(fun _ -> outbound_called:=true;
      Ok {Web_push.status=201;reason="Created"}) ~vapid
    ~invalidate:(fun id ->
      invalidated:=true;
      Db_runtime.write runtime (fun tx ->
        let subscription=Db_remaining.Push_subscription.find
          (Db_runtime.conn tx) id in
        Db_remaining.Push_subscription.destroy tx subscription)) () in
  Alcotest.(check bool) "seeded Firefox queued" true
    (Web_push.enqueue pool {Web_push.title="Designers";body="bot message";
      path="/rooms/654632876";badge=0L;subscription});
  Alcotest.(check bool) "seeded Firefox delivery drains" true
    (Web_push.shutdown pool ~deadline:(Unix.gettimeofday ()+.5.));
  Alcotest.(check bool) "noncanonical key never reaches network" false
    !outbound_called;
  Alcotest.(check bool) "argument error does not invalidate" false
    !invalidated;
  let retained=Db_runtime.read runtime (fun db ->
    Db_remaining.Push_subscription.find db id) in
  Alcotest.(check int64) "Firefox subscription retained" id retained.id)

let test_live_job_webhook_wire () = with_seed (fun runtime storage ->
  let listener=Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_loopback,0));
  Unix.listen listener 1;
  let port=match Unix.getsockname listener with
    | Unix.ADDR_INET (_,port) -> port | _ -> assert false in
  let captured=ref None and server_error=ref None in
  let server=Thread.create (fun () ->
    try
      let ready,_,_=Unix.select [listener] [] [] 5. in
      if ready=[] then failwith "webhook job never connected";
      let peer,_=Unix.accept listener in
      let input=Unix.in_channel_of_descr peer in
      let request_line=String.trim (input_line input) in
      let rec headers acc =
        let line=input_line input |> String.trim in
        if line="" then List.rev acc else
        match String.index_opt line ':' with
        | None -> failwith ("invalid webhook header: "^line)
        | Some colon ->
          let key=String.sub line 0 colon in
          let value=String.sub line (colon+1) (String.length line-colon-1)
            |> String.trim in
          headers ((key,value)::acc) in
      let headers=headers [] in
      let length=List.assoc "Content-Length" headers |> int_of_string in
      let body=really_input_string input length in
      captured:=Some (request_line,headers,body);
      let response="HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok" in
      ignore (Unix.write_substring peer response 0 (String.length response));
      close_in input
    with error -> server_error:=Some (Printexc.to_string error)) () in
  Fun.protect ~finally:(fun () -> Unix.close listener;Thread.join server) (fun () ->
    Db_runtime.write runtime (fun tx ->
      ignore (Db_runtime.execute (Db_runtime.conn tx)
        "UPDATE webhooks SET url=? WHERE user_id=394959859"
        [Sqlite3.Data.TEXT (Printf.sprintf "http://127.0.0.1:%d/hook" port)]));
    with_app ~vapid:false runtime storage (fun app cable ->
      let response,_=send ~runtime ~app ~cable ~user_id:712064548L
        ~body:"message%5Bbody%5D=Live+webhook" `POST
        "/rooms/340026324/messages" in
      check "source message accepted" 200 (status response);
      let drained=Lwt_main.run (Lwt_preemptive.detach (fun () ->
        Jobs.shutdown app.jobs ~deadline:(Unix.gettimeofday ()+.3.)) ()) in
      Alcotest.(check bool) "live webhook job drains" true drained;
      (match !server_error with None -> () | Some error -> Alcotest.fail error);
      let request_line,headers,body=match !captured with
        | Some wire -> wire | None -> Alcotest.fail "no webhook wire captured" in
      Alcotest.(check string) "job request line" "POST /hook HTTP/1.1" request_line;
      Alcotest.(check (list string)) "job raw header order"
        ["Content-Type";"Accept-Encoding";"Accept";"User-Agent";
         "Host";"Connection";"Content-Length"]
        (List.map fst headers);
      Alcotest.(check string) "job Host"
        (Printf.sprintf "127.0.0.1:%d" port) (List.assoc "Host" headers);
      Alcotest.(check string) "job request content type"
        "application/json" (List.assoc "Content-Type" headers);
      Alcotest.(check bool) "seeded message payload"
        true (contains body "Live webhook");
      let bot_replies=Db_runtime.read runtime (fun db ->
        Db_messages.Message.for_room db 340026324L
        |> List.filter (fun (message:Db_messages.Message.t) ->
          message.creator_id=394959859L &&
          Db_messages.Message.plain_text_body db message="ok")) in
      check "ordered webhook reply persisted" 1 (List.length bot_replies))))

let set_push_endpoint runtime ~id endpoint =
  Db_runtime.write runtime (fun tx ->
    ignore (Db_runtime.execute (Db_runtime.conn tx)
      "UPDATE push_subscriptions SET endpoint=?,p256dh_key=?,auth_key=? WHERE id=?"
      [Sqlite3.Data.TEXT endpoint;Sqlite3.Data.TEXT fixture_p256dh;
       Sqlite3.Data.TEXT fixture_auth;Sqlite3.Data.INT id]))

let test_local_tls_notification () = with_seed (fun runtime storage ->
  with_tls_push_endpoint (fun ~port ~cert ~capture ->
    let endpoint="https://fcm.googleapis.com/m5-test" in
    set_push_endpoint runtime ~id:56887440L endpoint;
    let outbound=local_tls_outbound ~port ~cert in
    with_app ~outbound runtime storage (fun app cable ->
      let private_pin={Web_push.endpoint;pinned_ip="127.0.0.1";headers=[];
        body="";open_timeout=1.;read_timeout=1.;
        deadline=Unix.gettimeofday ()+.1.} in
      Alcotest.(check (result unit string)) "production adapter blocks local pin"
        (Error "private pinned IP")
        (Outbound_http.web_push_outbound private_pin |> Result.map (fun _ -> ()));
      let response,_=send ~runtime ~app ~cable ~user_id:127326141L `POST
        "/users/me/push_subscriptions/56887440/test_notifications" in
      check "live TLS test notification redirects" 302 (status response);
      let wire=captured_push capture in
      Alcotest.(check string) "TLS push request target"
        "POST /m5-test HTTP/1.1"
        Yojson.Basic.Util.(wire |> member "request_line" |> to_string);
      Alcotest.(check string) "original push Host"
        (Printf.sprintf "fcm.googleapis.com:%d" port)
        (Option.get (captured_header wire "Host"));
      Alcotest.(check string) "push content encoding" "aes128gcm"
        (Option.get (captured_header wire "Content-Encoding"));
      let authorization=Option.get (captured_header wire "Authorization") in
      let public_wire=Web_push_crypto.decode64 fixture_public
        |> Result.get_ok |> Web_push_crypto.encode64 in
      Alcotest.(check bool) "VAPID public key" true
        (contains authorization ("k="^public_wire));
      let token=String.split_on_char ',' authorization |> List.hd
        |> String.trim in
      Alcotest.(check bool) "VAPID token prefix" true
        (String.starts_with ~prefix:"vapid t=" token);
      let jwt=String.sub token 8 (String.length token-8) in
      let claims=match String.split_on_char '.' jwt with
        | [header;payload;signature] ->
          let signature=Web_push_crypto.decode64 signature |> Result.get_ok in
          Alcotest.(check int) "raw ES256 signature length" 64
            (String.length signature);
          let public=Web_push_crypto.decode64 fixture_public
            |> Result.get_ok |> Cstruct.of_string
            |> Mirage_crypto_ec.P256.Dsa.pub_of_cstruct |> Result.get_ok in
          let digest=Mirage_crypto.Hash.SHA256.digest
            (Cstruct.of_string (header^"."^payload)) in
          Alcotest.(check bool) "live VAPID ES256 signature" true
            (Mirage_crypto_ec.P256.Dsa.verify ~key:public
              (Cstruct.of_string (String.sub signature 0 32),
               Cstruct.of_string (String.sub signature 32 32)) digest);
          Web_push_crypto.decode64 payload |> Result.get_ok
          |> Yojson.Basic.from_string
        | _ -> Alcotest.fail "invalid VAPID JWT" in
      Alcotest.(check string) "VAPID original audience"
        "https://fcm.googleapis.com"
        Yojson.Basic.Util.(claims |> member "aud" |> to_string);
      Alcotest.(check string) "VAPID subject" "mailto:support@37signals.com"
        Yojson.Basic.Util.(claims |> member "sub" |> to_string);
      let expires=Yojson.Basic.Util.(claims |> member "exp" |> to_int) in
      Alcotest.(check bool) "VAPID exp within twelve hours" true
        (expires>int_of_float (Unix.gettimeofday ()) &&
         expires<=int_of_float (Unix.gettimeofday ()+.43200.));
      let ciphertext=Yojson.Basic.Util.(wire |> member "body_base64" |> to_string)
        |> Base64.decode_exn in
      let receiver_private=Web_push_crypto.decode64
        "Y1H_BKvKi4Ht2cE4HZ8AgD0nn8chE3zhgBtEODTn4I4=" |> Result.get_ok in
      let _,plain=Web_push_crypto.decrypt ~ciphertext
        ~receiver_private ~auth:fixture_auth |> Result.get_ok in
      let payload=Yojson.Basic.from_string
        (String.sub plain 0 (String.length plain-2)) in
      Alcotest.(check string) "decrypted notification title" "Campfire Test"
        Yojson.Basic.Util.(payload |> member "title" |> to_string))))

let test_local_tls_invalidation () = with_seed (fun runtime storage ->
  with_tls_push_endpoint ~status:410 (fun ~port ~cert ~capture ->
    set_push_endpoint runtime ~id:257765087L
      "https://fcm.googleapis.com/m5-gone";
    Db_runtime.write runtime (fun tx ->
      ignore (Db_runtime.execute (Db_runtime.conn tx)
        "UPDATE push_subscriptions SET endpoint=NULL WHERE id=782661003" []));
    let outbound=local_tls_outbound ~port ~cert in
    with_app ~outbound runtime storage (fun app cable ->
      let room=Db_runtime.read runtime (fun db -> Db_rooms.Room.find db 654632876L) in
      let subscriber=Cable_ring.subscribe cable.Cable_channels.hub
        ~stream:(Cable_broadcasts.message_stream room) ~identifier:"tls-push" in
      let response,_=send ~runtime ~app ~cable ~user_id:127326141L
        ~body:"message%5Bbody%5D=Local+TLS+push" `POST
        "/rooms/654632876/messages" in
      check "HTTP source message accepted" 200 (status response);
      let drained=Lwt_main.run (Lwt_preemptive.detach (fun () ->
        App_jobs.shutdown app ~deadline:(Unix.gettimeofday ()+.8.)) ()) in
      Alcotest.(check bool) "message job and push pool drain" true drained;
      let gone=Db_runtime.read runtime (fun db ->
        Db_runtime.query_one db
          (Db_remaining.Push_subscription.select^" WHERE id=?")
          [Sqlite3.Data.INT 257765087L]
          Db_remaining.Push_subscription.decode) in
      Alcotest.(check bool) "410 deletes subscription" true (gone=None);
      let frames=queued_broadcasts cable subscriber in
      Alcotest.(check bool) "source message also broadcasts" true
        (List.exists (fun frame -> contains frame "Local TLS push") frames);
      Alcotest.(check string) "background push reached TLS endpoint"
        "POST /m5-gone HTTP/1.1"
        Yojson.Basic.Util.(captured_push capture |> member "request_line" |> to_string))))

let test_local_tls_deadline () = with_seed (fun runtime storage ->
  with_tls_push_endpoint ~delay:0.5 (fun ~port ~cert ~capture:_ ->
    set_push_endpoint runtime ~id:56887440L
      "https://fcm.googleapis.com/m5-slow";
    let outbound request=local_tls_outbound ~port ~cert
      ~deadline:(Unix.gettimeofday () +. 0.15) request in
    with_app ~outbound runtime storage (fun app cable ->
      let before=Unix.gettimeofday () in
      let response,_=send ~runtime ~app ~cable ~user_id:127326141L `POST
        "/users/me/push_subscriptions/56887440/test_notifications" in
      let elapsed=Unix.gettimeofday ()-.before in
      check "TLS timeout returns 500" 500 (status response);
      Alcotest.(check bool) "absolute deadline bounds read" true (elapsed < 0.45);
      let retained=Db_runtime.read runtime (fun db ->
        Db_remaining.Push_subscription.find db 56887440L) in
      Alcotest.(check int64) "timeout retains subscription"
        56887440L retained.id)))

let websocket_frame content =
  let size=String.length content in
  let length=if size<126 then String.make 1 (Char.chr (0x80 lor size))
    else String.make 1 '\xfe' ^ String.init 2
      (function 0 -> Char.chr ((size lsr 8) land 255) | _ -> Char.chr (size land 255)) in
  let mask="\x12\x34\x56\x78" in
  "\x81"^length^mask^String.init size (fun i ->
    Char.chr (Char.code content.[i] lxor Char.code mask.[i mod 4]))

let websocket_read input =
  let read_exact size =
    let bytes=Bytes.create size in
    Lwt_io.read_into_exactly input bytes 0 size >|= fun () -> Bytes.to_string bytes in
  Lwt_io.read_char input >>= fun first ->
  Lwt_io.read_char input >>= fun second ->
  let count=Char.code second land 127 in
  (if count=126 then read_exact 2 >|= fun pair ->
     (Char.code pair.[0] lsl 8) lor Char.code pair.[1]
   else Lwt.return count) >>= fun count ->
  read_exact count >|= fun body -> Char.code first land 15,body

let test_shared_listener_push_and_cable () = with_seed (fun runtime storage ->
  with_tls_push_endpoint (fun ~port:push_port ~cert ~capture ->
    set_push_endpoint runtime ~id:257765087L
      "https://fcm.googleapis.com/m5-listener";
    Db_runtime.write runtime (fun tx ->
      ignore (Db_runtime.execute (Db_runtime.conn tx)
        "UPDATE push_subscriptions SET endpoint=NULL WHERE id=782661003" []));
    let outbound=local_tls_outbound ~port:push_port ~cert in
    with_app ~outbound runtime storage (fun app cable ->
      let room=Db_runtime.read runtime (fun db -> Db_rooms.Room.find db 654632876L) in
      let session=Db_runtime.write runtime (fun tx ->
        Db_accounts.Session.start (Db_runtime.conn tx) ~now ~user_id:127326141L
          ~user_agent:None ~ip_address:None) in
      let cookie="session_token="^Authentication.issue_token_cookie
        ~secret_key_base:secret ~now session.token in
      let probe=Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      Unix.bind probe (Unix.ADDR_INET (Unix.inet_addr_loopback,0));
      let listener_port=match Unix.getsockname probe with
        | Unix.ADDR_INET (_,port) -> port | _ -> assert false in
      Unix.close probe;
      let host=Printf.sprintf "127.0.0.1:%d" listener_port in
      let stop,wake_stop=Lwt.wait () in
      let server=Http_app.serve ~runtime ~secret_key_base:secret
        ~port:listener_port ~stop ~cable ~cable_run:(Cable_channels.run cable)
        ~event_sink:(App_jobs.event_sink app)
        ~dispatch:App_dispatch.endpoint () in
      let scenario () =
        Lwt.async (fun () -> server);
        Lwt_unix.sleep 0.03 >>= fun () ->
        Lwt_io.open_connection (Unix.ADDR_INET
          (Unix.inet_addr_loopback,listener_port)) >>= fun (input,output) ->
        let upgrade="GET /cable HTTP/1.1\r\nHost: "^host^
          "\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nOrigin: http://"^host^
          "\r\nCookie: "^cookie^
          "\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="^
          "\r\nSec-WebSocket-Protocol: actioncable-v1-json\r\n\r\n" in
        Lwt.finalize (fun () ->
          Lwt_io.write output upgrade >>= fun () -> Lwt_io.flush output >>= fun () ->
          Lwt_io.read_line input >>= fun response_line ->
          Alcotest.(check bool) "same listener upgrades Cable" true
            (String.starts_with ~prefix:"HTTP/1.1 101" response_line);
          let rec skip_headers ()=Lwt_io.read_line input >>= fun line ->
            if String.trim line="" then Lwt.return_unit else skip_headers () in
          skip_headers () >>= fun () ->
          websocket_read input >>= fun (_,welcome) ->
          Alcotest.(check bool) "Cable welcomes" true
            (contains welcome "welcome");
          let signed=Turbo_stream.signed_stream_name ~secret_key_base:secret
            [Cable_channels.room_param room;"messages"] in
          let identifier=Yojson.Basic.to_string (`Assoc [
            "channel",`String "RoomMessagesChannel";
            "signed_stream_name",`String signed]) in
          let subscribe=Yojson.Basic.to_string (`Assoc [
            "command",`String "subscribe";"identifier",`String identifier]) in
          Lwt_io.write output (websocket_frame subscribe) >>= fun () ->
          Lwt_io.flush output >>= fun () ->
          websocket_read input >>= fun (_,confirmed) ->
          Alcotest.(check bool) "Cable subscription confirmed" true
            (contains confirmed "confirm_subscription");
          let headers=Cohttp.Header.of_list ["cookie",cookie;
            "origin","http://"^host;"sec-fetch-site","same-origin";
            "accept","text/vnd.turbo-stream.html, text/html";
            "content-type","application/x-www-form-urlencoded"] in
          Cohttp_lwt_unix.Client.call ~headers
            ~body:(Cohttp_lwt.Body.of_string
              "message%5Bbody%5D=Shared+listener+push") `POST
            (Uri.of_string ("http://"^host^"/rooms/654632876/messages"))
          >>= fun (response,body) ->
          Cohttp_lwt.Body.drain_body body >>= fun () ->
          check "same listener accepts HTTP message" 200 (status response);
          websocket_read input >>= fun (_,frame) ->
          Alcotest.(check bool) "message reaches live Cable socket" true
            (contains frame "Shared listener push");
          Lwt_preemptive.detach (fun () ->
            App_jobs.shutdown app ~deadline:(Unix.gettimeofday ()+.8.)) ()
          >|= fun drained ->
          Alcotest.(check bool) "same request drains push job" true drained)
          (fun () -> Lwt_io.close output >>= fun () -> Lwt_io.close input) in
      Lwt_main.run (Lwt.finalize (fun () -> Lwt_unix.with_timeout 10. scenario)
        (fun () -> Lwt.wakeup_later wake_stop (); Lwt.return_unit));
      Alcotest.(check string) "shared listener triggers TLS push"
        "POST /m5-listener HTTP/1.1"
        Yojson.Basic.Util.(captured_push capture |> member "request_line" |> to_string))))

let () = Alcotest.run "M5-T3 integrated jobs" ([
  "config",[Alcotest.test_case "VAPID off and default" `Quick test_vapid_config];
  "storage",[Alcotest.test_case "PurgeBlob after commit" `Quick test_purge_after_commit];
  "bans",[Alcotest.test_case "remove content job" `Quick test_remove_banned_content];
  "push",[Alcotest.test_case "scoped test-notification route" `Quick test_notification_route;
    Alcotest.test_case "seeded message push" `Quick test_seeded_push_job;
    Alcotest.test_case "seeded Firefox key retained" `Quick
      test_seeded_firefox_subscription_retained];
  "webhook",[Alcotest.test_case "HTTP message to bot reply" `Quick test_http_webhook_reply;
    Alcotest.test_case "HTTP message to bot attachment" `Quick test_http_attachment_reply;
    Alcotest.test_case "bad reply fails safely" `Quick test_webhook_canonicalization_failure]] @
  (if Sys.getenv_opt "CAMPFIRE_LIVE_PUSH_TLS_TEST"=Some "1" then
    ["live push",[
      Alcotest.test_case "encrypted test notification" `Quick test_local_tls_notification;
      Alcotest.test_case "410 invalidation and Cable" `Quick test_local_tls_invalidation;
      Alcotest.test_case "deadline" `Quick test_local_tls_deadline;
      Alcotest.test_case "shared listener HTTP Cable and push" `Quick
        test_shared_listener_push_and_cable]] else []) @
  if Sys.getenv_opt "CAMPFIRE_LIVE_JOB_WIRE_TEST"=Some "1" then
    ["live webhook",[Alcotest.test_case "seeded job raw wire" `Quick
      test_live_job_webhook_wire]] else [])

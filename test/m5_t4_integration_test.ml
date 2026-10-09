open Lwt.Infix
open Campfire

let now="2026-10-09T12:00:00Z"
let secret=String.make 64 'q'
let status response=Cohttp.Code.code_of_status (Cohttp.Response.status response)
let contains haystack needle =
  let width=String.length needle in
  let rec find i = i+width<=String.length haystack &&
    (String.sub haystack i width=needle || find (i+1)) in
  find 0

let rec reference_root path remaining =
  if remaining=0 then failwith "pinned seed missing" else
  let root=Filename.concat path "once-campfire-rust" in
  if Sys.file_exists (Filename.concat root "parity/.seed/default/db/production.sqlite3")
  then root else reference_root (Filename.dirname path) (remaining-1)

let with_seed f =
  let source=Filename.concat (reference_root (Sys.getcwd ()) 8)
    "parity/.seed/default/db/production.sqlite3" in
  let from=Sqlite3.db_open ~mode:`READONLY source in
  let path=Filename.temp_file "campfire-m5-t4-integrated" ".sqlite3" in
  Sys.remove path;
  let escaped=String.concat "''" (String.split_on_char '\'' path) in
  let copied=Sqlite3.exec from ("VACUUM INTO '"^escaped^"'") in
  ignore (Sqlite3.db_close from);
  if copied<>Sqlite3.Rc.OK then failwith "seed copy failed";
  let runtime=Db_runtime.open_db ~readers:2 ~prepare:false path in
  let root=Filename.temp_file "campfire-m5-t4-storage" "" in
  Sys.remove root;Unix.mkdir root 0o700;
  let storage=Storage_disk.create ~root ~name:"local" in
  Fun.protect ~finally:(fun () ->
    Db_runtime.close runtime;
    List.iter (fun file -> if Sys.file_exists file then Sys.remove file)
      [path;path^"-wal";path^"-shm"];
    ignore (Sys.command ("rm -rf "^Filename.quote root)))
    (fun () -> f runtime storage)

let cookie runtime user_id =
  let session=Db_runtime.write runtime (fun tx ->
    Db_accounts.Session.start (Db_runtime.conn tx) ~now ~user_id
      ~user_agent:None ~ip_address:None) in
  "session_token="^Authentication.issue_token_cookie
    ~secret_key_base:secret ~now session.token

let config () =
  match Config.from_lookup (function
    | "SECRET_KEY_BASE" -> Some secret
    | "DISABLE_SSL" -> Some "1"
    | _ -> None) with
  | Error error -> failwith error
  | Ok config -> config

let app runtime storage cable deliver_webhook =
  let base=config () in
  App_jobs.start ~config:{base with vapid_public_key=None;vapid_private_key=None}
    ~runtime ~storage ~cable ~deliver_webhook ()

let send_in_process runtime app cable session_cookie ~room_id body =
  let headers=Cohttp.Header.of_list [
    "host","chat.example.com";"origin","https://chat.example.com";
    "sec-fetch-site","same-origin";"cookie",session_cookie;
    "content-type","application/x-www-form-urlencoded";
    "accept","text/vnd.turbo-stream.html, text/html"] in
  let uri=Uri.of_string (Printf.sprintf
    "https://chat.example.com/rooms/%Ld/messages" room_id) in
  let request=Cohttp.Request.make ~meth:`POST ~headers uri in
  let form=Uri.encoded_of_query ["message[body]",[body]] in
  let response,body=Lwt_main.run (Http_app.handle ~runtime
    ~secret_key_base:secret ~now ~ssl:true ~force_ssl:true ~cable
    ~event_sink:(App_jobs.event_sink app) ~dispatch:App_dispatch.endpoint
    request (Cohttp_lwt.Body.of_string form)) in
  status response,Lwt_main.run (Cohttp_lwt.Body.to_string body)

let test_non_direct_mentioned_bot () = with_seed (fun runtime storage ->
  let cable=Cable_channels.create ~db:runtime ~secret_key_base:secret
    ~now:(fun () -> now) () in
  let deliveries=ref [] in
  let deliver_webhook url payload =
    deliveries:= !deliveries@[url,payload];
    Ok {Webhook.status=Some 204;reply=Webhook.None_reply} in
  let jobs=app runtime storage cable deliver_webhook in
  Fun.protect ~finally:(fun () -> ignore (Lwt_main.run
    (Lwt_preemptive.detach (fun () -> App_jobs.shutdown jobs
      ~deadline:(Unix.gettimeofday ()+.1.)) ()))) (fun () ->
    let session_cookie=cookie runtime 127326141L in
    let room_id=486777696L in
    let plain_status,_=send_in_process runtime jobs cable session_cookie
      ~room_id "Hello room" in
    Alcotest.(check int) "plain room post" 200 plain_status;
    let gid=Global_id.make ~model_name:"User" ~id:"394959859" in
    let sgid=Global_id.attachable_sgid ~secret_key_base:secret ~gid in
    let html=Printf.sprintf
      "<p>Hi <action-text-attachment sgid=\"%s\" content-type=\"application/vnd.campfire.mention\"></action-text-attachment></p>"
      sgid in
    let mention_status,_=send_in_process runtime jobs cable session_cookie
      ~room_id html in
    Alcotest.(check int) "mentioned bot post" 200 mention_status;
    Alcotest.(check bool) "bot jobs drain" true (Lwt_main.run
      (Lwt_preemptive.detach (fun () -> Jobs.shutdown jobs.jobs
        ~deadline:(Unix.gettimeofday ()+.5.)) ()));
    Alcotest.(check int) "only mention delivers" 1 (List.length !deliveries);
    let url,payload=List.hd !deliveries in
    Alcotest.(check string) "Bender endpoint" "http://example.com/bender" url;
    Alcotest.(check bool) "mentions removed from bot plain body" true
      (contains payload "Hi" && not (contains payload "Bender Bot"))))

let test_bot_attachment_broadcast () = with_seed (fun runtime storage ->
  let cable=Cable_channels.create ~db:runtime ~secret_key_base:secret
    ~now:(fun () -> now) () in
  let room=Db_runtime.read runtime (fun db ->
    Db_rooms.Room.find db 340026324L) in
  let subscriber=Cable_ring.subscribe cable.Cable_channels.hub
    ~stream:(Cable_broadcasts.message_stream room) ~identifier:"attachment" in
  let deliver_webhook _ _ = Ok {Webhook.status=Some 200;
    reply=Webhook.Attachment {data="bot file bytes";
      filename="bot<&>.txt";content_type="text/plain"}} in
  let jobs=app runtime storage cable deliver_webhook in
  Fun.protect ~finally:(fun () -> ignore (Lwt_main.run
    (Lwt_preemptive.detach (fun () -> App_jobs.shutdown jobs
      ~deadline:(Unix.gettimeofday ()+.1.)) ()))) (fun () ->
    let session_cookie=cookie runtime 712064548L in
    let posted,_=send_in_process runtime jobs cable session_cookie
      ~room_id:room.id "Send a file" in
    Alcotest.(check int) "HTTP source message" 200 posted;
    Alcotest.(check bool) "attachment job drains" true (Lwt_main.run
      (Lwt_preemptive.detach (fun () -> Jobs.shutdown jobs.jobs
        ~deadline:(Unix.gettimeofday ()+.5.)) ()));
    let attachment=Db_runtime.read runtime (fun db ->
      Db_messages.Message.for_room db room.id
      |> List.find_map (fun (message:Db_messages.Message.t) ->
        if message.creator_id<>394959859L then None else
        Option.map (fun pair -> message,pair)
          (Db_remaining.Hooks.message_attachment db message))) in
    let message,(_,blob)=match attachment with
      | Some pair -> pair | None -> Alcotest.fail "bot attachment missing" in
    Alcotest.(check bool) "attachment bytes on disk" true
      (Sys.file_exists (Storage_disk.path_for storage blob.key));
    let html=Db_runtime.read runtime (fun db ->
      App_jobs.detached_message ~secret_key_base:secret db room message
      |> Views.message_presentation |> Views.render) in
    let delivery=match Cable_ring.take_many cable.Cable_channels.hub
      [subscriber] ~limit:64 with
      | `Frames frames | `Lagged frames -> List.map snd frames in
    let turbo=List.filter_map (fun frame ->
      try Some (match Yojson.Basic.from_string frame with
        | `String html -> html
        | value -> Yojson.Basic.Util.(value |> member "message" |> to_string))
      with _ -> None) delivery
      |> List.find_opt (fun frame -> contains frame "bot&lt;&amp;&gt;.txt") in
    let turbo=match turbo with
      | Some html -> html
      | None -> Alcotest.failf "bot attachment broadcast missing: %s"
          (String.concat "\n" delivery) in
    Alcotest.(check bool) "exact file presentation in Cable HTML" true
      (contains turbo html);
    Alcotest.(check bool) "file icon, download and share" true
      (contains html "common-file-text" && contains html "Download bot&lt;&amp;&gt;.txt"
       && contains html "Share bot&lt;&amp;&gt;.txt")))

let bind_loopback () =
  let socket=Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback,0));
  let port=match Unix.getsockname socket with
    | Unix.ADDR_INET (_,port) -> port | _ -> assert false in
  socket,port

let read_exact input count =
  let bytes=Bytes.create count in
  Lwt_io.read_into_exactly input bytes 0 count >|= fun () -> Bytes.to_string bytes

let read_frame input =
  Lwt_io.read_char input >>= fun first ->
  Lwt_io.read_char input >>= fun second ->
  let length=Char.code second land 127 in
  (if length=126 then read_exact input 2 >|= fun data ->
    (Char.code data.[0] lsl 8) lor Char.code data.[1]
   else if length=127 then read_exact input 8 >|= fun data ->
     String.fold_left (fun acc ch -> (acc lsl 8) lor Char.code ch) 0 data
   else Lwt.return length) >>= fun length ->
  read_exact input length >|= fun payload -> Char.code first land 15,payload

let client_frame content =
  let n=String.length content in
  let length=if n<126 then String.make 1 (Char.chr (0x80 lor n))
    else if n<65536 then "\xfe"^String.init 2 (fun i ->
      Char.chr ((n lsr (8*(1-i))) land 255))
    else failwith "subscription too long" in
  let mask="\x12\x34\x56\x78" in
  "\x81"^length^mask^String.init n (fun i ->
    Char.chr (Char.code content.[i] lxor Char.code mask.[i mod 4]))

let read_headers input =
  let rec loop () = Lwt_io.read_line input >>= fun line ->
    if String.trim line="" then Lwt.return_unit else loop () in
  loop ()

let test_shared_listener_http_webhook_cable () = with_seed (fun runtime storage ->
  let listener,webhook_port=bind_loopback () in
  Unix.listen listener 1;
  let webhook_request=ref None and webhook_error=ref None in
  let webhook_thread=Thread.create (fun () ->
    try
      let ready,_,_=Unix.select [listener] [] [] 8. in
      if ready=[] then failwith "webhook never connected";
      let peer,_=Unix.accept listener in
      let input=Unix.in_channel_of_descr peer in
      let request_line=input_line input |> String.trim in
      let rec headers acc =
        let line=input_line input |> String.trim in
        if line="" then List.rev acc else
        let colon=String.index line ':' in
        let name=String.sub line 0 colon in
        let value=String.sub line (colon+1) (String.length line-colon-1)
          |> String.trim in
        headers ((name,value)::acc) in
      let headers=headers [] in
      let length=List.assoc "Content-Length" headers |> int_of_string in
      let body=really_input_string input length in
      webhook_request:=Some (request_line,headers,body);
      let answer="Bot reply over shared listener" in
      let response=Printf.sprintf
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
        (String.length answer) answer in
      ignore (Unix.write_substring peer response 0 (String.length response));
      close_in input
    with error -> webhook_error:=Some (Printexc.to_string error)) () in
  Fun.protect ~finally:(fun () -> Unix.close listener;Thread.join webhook_thread)
    (fun () ->
      Db_runtime.write runtime (fun tx ->
        ignore (Db_runtime.execute (Db_runtime.conn tx)
          "UPDATE webhooks SET url=? WHERE user_id=394959859"
          [Sqlite3.Data.TEXT (Printf.sprintf
            "http://127.0.0.1:%d/hook" webhook_port)]));
      let server_socket,port=bind_loopback () in
      Unix.close server_socket;
      let host=Printf.sprintf "127.0.0.1:%d" port in
      let session_cookie=cookie runtime 712064548L in
      let cable=Cable_channels.create ~db:runtime ~secret_key_base:secret
        ~now:(fun () -> now) () in
      let jobs=app runtime storage cable (fun url payload ->
        Lwt_preemptive.run_in_main (fun () -> Webhook.deliver url payload)) in
      let stop,wake_stop=Lwt.wait () in
      let server=Http_app.serve ~runtime ~secret_key_base:secret
        ~port ~stop ~cable ~cable_run:(Cable_channels.run cable)
        ~event_sink:(App_jobs.event_sink jobs)
        ~dispatch:App_dispatch.endpoint () in
      Fun.protect ~finally:(fun () ->
        ignore (Lwt_main.run (Lwt_preemptive.detach (fun () ->
          App_jobs.shutdown jobs ~deadline:(Unix.gettimeofday ()+.3.)) ())))
        (fun () -> Lwt_main.run (Lwt.finalize (fun () ->
          Lwt_unix.with_timeout 12. (fun () ->
            Lwt.async (fun () -> server);
            Lwt_unix.sleep 0.04 >>= fun () ->
            Lwt_io.open_connection
              (Unix.ADDR_INET (Unix.inet_addr_loopback,port))
            >>= fun (input,output) ->
            let upgrade="GET /cable HTTP/1.1\r\nHost: "^host^
              "\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nOrigin: http://"^host^
              "\r\nCookie: "^session_cookie^
              "\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="^
              "\r\nSec-WebSocket-Protocol: actioncable-v1-json\r\n\r\n" in
            Lwt_io.write output upgrade >>= fun () -> Lwt_io.flush output >>= fun () ->
            Lwt_io.read_line input >>= fun status_line ->
            Alcotest.(check bool) "shared listener upgrades Cable" true
              (String.starts_with ~prefix:"HTTP/1.1 101" status_line);
            read_headers input >>= fun () ->
            read_frame input >>= fun (_,welcome) ->
            Alcotest.(check bool) "Cable welcome" true (contains welcome "welcome");
            let room=Db_runtime.read runtime (fun db ->
              Db_rooms.Room.find db 340026324L) in
            let signed=Turbo_stream.signed_stream_name ~secret_key_base:secret
              [Cable_channels.room_param room;"messages"] in
            let identifier=Rails_format.encode (`Assoc [
              "channel",`String "RoomMessagesChannel";
              "signed_stream_name",`String signed]) in
            let subscribe=Rails_format.encode (`Assoc [
              "command",`String "subscribe";"identifier",`String identifier]) in
            Lwt_io.write output (client_frame subscribe) >>= fun () ->
            Lwt_io.flush output >>= fun () ->
            read_frame input >>= fun (_,confirmation) ->
            Alcotest.(check bool) "room subscription confirmed" true
              (contains confirmation "confirm_subscription");
            let uri=Uri.of_string ("http://"^host^
              "/rooms/340026324/messages") in
            let headers=Cohttp.Header.of_list [
              "cookie",session_cookie;"origin","http://"^host;
              "sec-fetch-site","same-origin";
              "accept","text/vnd.turbo-stream.html, text/html";
              "content-type","application/x-www-form-urlencoded"] in
            Cohttp_lwt_unix.Client.call ~headers
              ~body:(Cohttp_lwt.Body.of_string
                "message%5Bbody%5D=Shared+listener+message") `POST uri
            >>= fun (response,body) ->
            Cohttp_lwt.Body.drain_body body >>= fun () ->
            Alcotest.(check int) "HTTP message accepted" 200 (status response);
            let rec wait_reply seen =
              if seen>8 then Alcotest.fail "Cable reply missing" else
              read_frame input >>= fun (_,payload) ->
              if contains payload "Bot reply over shared listener" then Lwt.return payload
              else wait_reply (seen+1) in
            wait_reply 0 >>= fun reply ->
            Alcotest.(check bool) "bot reply broadcast to socket" true
              (contains reply "turbo-stream");
            Lwt_io.close output >>= fun () -> Lwt_io.close input))
          (fun () -> Lwt.wakeup_later wake_stop ();Lwt.return_unit)));
      (match !webhook_error with None -> () | Some error -> Alcotest.fail error);
      let request_line,headers,body=match !webhook_request with
        | Some wire -> wire | None -> Alcotest.fail "missing webhook request" in
      Alcotest.(check string) "webhook request line" "POST /hook HTTP/1.1"
        request_line;
      Alcotest.(check (list string)) "ordered webhook headers"
        ["Content-Type";"Accept-Encoding";"Accept";"User-Agent";
         "Host";"Connection";"Content-Length"]
        (List.map fst headers);
      Alcotest.(check bool) "originating message in webhook payload" true
        (contains body "Shared listener message");
      let replies=Db_runtime.read runtime (fun db ->
        Db_messages.Message.for_room db 340026324L
        |> List.filter (fun (message:Db_messages.Message.t) ->
          message.creator_id=394959859L &&
          Db_messages.Message.plain_text_body db message=
            "Bot reply over shared listener")) in
      Alcotest.(check int) "bot reply persisted" 1 (List.length replies)))

let ()=Alcotest.run "M5-T4 integrated webhook routes" [
  "mentioned bot",[Alcotest.test_case "non-direct signed mention"
    `Quick test_non_direct_mentioned_bot];
  "attachment",[Alcotest.test_case "bot file rendered on Cable"
    `Quick test_bot_attachment_broadcast];
  "shared listener",[Alcotest.test_case "HTTP to webhook to Cable reply"
    `Quick test_shared_listener_http_webhook_cable]]

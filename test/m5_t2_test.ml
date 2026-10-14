open Lwt.Infix
open Campfire

let now = "2026-10-08T12:00:00Z"
let secret = String.make 64 'q'

let rec reference_root path remaining =
  if remaining = 0 then failwith "pinned Rails seed not found" else
  let candidate = Filename.concat path "once-campfire-rust" in
  if Sys.file_exists (Filename.concat candidate "parity/.seed/default/db/production.sqlite3")
  then candidate else reference_root (Filename.dirname path) (remaining-1)

let with_seed f =
  let path = Filename.concat (reference_root (Sys.getcwd ()) 8)
    "parity/.seed/default/db/production.sqlite3" in
  let source = Sqlite3.db_open ~mode:`READONLY path in
  let temp = Filename.temp_file "campfire-m5-t2-" ".sqlite3" in
  Sys.remove temp;
  let quoted = String.concat "''" (String.split_on_char '\'' temp) in
  let rc = Sqlite3.exec source ("VACUUM INTO '" ^ quoted ^ "'") in
  ignore (Sqlite3.db_close source);
  if rc <> Sqlite3.Rc.OK then failwith "could not copy seed";
  let db = Db_runtime.open_db ~prepare:false temp in
  Fun.protect ~finally:(fun () ->
    Db_runtime.close db;
    List.iter (fun name -> if Sys.file_exists name then Sys.remove name)
      [temp; temp^"-wal"; temp^"-shm"])
    (fun () -> f db)

let with_bus_broker f =
  let directory = Filename.temp_file "campfire-channel-bus-" "" in
  Sys.remove directory;
  Unix.mkdir directory 0o700;
  let path = Filename.concat directory "bus.sock" in
  let broker = Unix.fork () in
  if broker = 0 then (try Cable_bus.serve path with _ -> exit 1)
  else Fun.protect ~finally:(fun () ->
    (try Unix.kill broker Sys.sigterm with _ -> ());
    ignore (Unix.waitpid [] broker);
    if Sys.file_exists path then Unix.unlink path;
    Unix.rmdir directory) (fun () -> f path)

let check label expected actual = Alcotest.(check string) label expected actual
let frame opcode content =
  let n = String.length content in
  let len = if n < 126 then String.make 1 (Char.chr (0x80 lor n))
    else String.make 1 '\xfe' ^ String.init 2
      (function 0 -> Char.chr ((n lsr 8) land 255) | _ -> Char.chr (n land 255)) in
  let mask = "\x12\x34\x56\x78" in
  String.make 1 (Char.chr (0x80 lor opcode)) ^ len ^ mask ^
  String.init n (fun i -> Char.chr
    (Char.code content.[i] lxor Char.code mask.[i mod 4]))

let read_exact ic count =
  let buffer = Bytes.create count in
  Lwt_io.read_into_exactly ic buffer 0 count >|= fun () -> Bytes.to_string buffer
let read_frame_raw ic =
  Lwt_io.read_char ic >>= fun first -> Lwt_io.read_char ic >>= fun second ->
  let count = Char.code second land 127 in
  (if count = 126 then read_exact ic 2 >|= fun s ->
    (Char.code s.[0] lsl 8) lor Char.code s.[1]
   else if count = 127 then read_exact ic 8 >|= fun s ->
     String.fold_left (fun value byte ->
       (value lsl 8) lor Char.code byte) 0 s
  else Lwt.return count) >>= fun count ->
  read_exact ic count >|= fun data ->
  Char.code first land 0x80 <> 0, Char.code first land 15, data
let read_frame ic =
  read_frame_raw ic >>= fun (final, opcode, first) ->
  let buffer = Buffer.create (String.length first) in
  Buffer.add_string buffer first;
  let rec remainder () =
    read_frame_raw ic >>= fun (final, next_opcode, data) ->
    if next_opcode <> 0 then Alcotest.fail "expected continuation frame";
    Buffer.add_string buffer data;
    if final then Lwt.return (opcode, Buffer.contents buffer) else remainder () in
  if final then Lwt.return (opcode, first) else remainder ()

type client = { input : Lwt_io.input_channel; output : Lwt_io.output_channel }
let connect t ?cookie () =
  let headers = Cohttp.Header.of_list
    (["host","campfire.test";"origin","https://campfire.test";
      "connection","Upgrade";"upgrade","websocket";
      "sec-websocket-version","13";
      "sec-websocket-key","dGhlIHNhbXBsZSBub25jZQ=="]
     @ match cookie with None -> [] | Some cookie -> ["cookie",cookie]) in
  let request = Cohttp.Request.make ~meth:`GET ~headers (Uri.of_string "/cable") in
  Cable_transport.handle request ~run:(Cable_channels.run t request) >>= function
  | `Response _ -> Alcotest.fail "expected WebSocket upgrade"
  | `Expert (_, expert) ->
      let server_ic, client_oc = Lwt_io.pipe () in
      let client_ic, server_oc = Lwt_io.pipe () in
      Lwt.async (fun () -> expert server_ic server_oc);
      Lwt.return {input=client_ic;output=client_oc}

let send c value = Lwt_io.write c.output (frame 1 value) >>= fun () -> Lwt_io.flush c.output
let receive c = read_frame c.input >>= function
  | 1, value -> Lwt.return value
  | opcode, _ -> Alcotest.failf "unexpected opcode %d" opcode
let command cmd identifier =
  Rails_format.encode (`Assoc ["command",`String cmd;"identifier",`String identifier])
let subscribe c identifier = send c (command "subscribe" identifier)
let perform c identifier action =
  send c (Rails_format.encode (`Assoc ["command",`String "message";
    "identifier",`String identifier;
    "data",`String (Rails_format.encode (`Assoc ["action",`String action]))]))
let identifier channel fields = Rails_format.encode (`Assoc (("channel",`String channel)::fields))
let confirm id = "{\"identifier\":" ^ Rails_format.json_quote id ^
  ",\"type\":\"confirm_subscription\"}"
let reject id = "{\"identifier\":" ^ Rails_format.json_quote id ^
  ",\"type\":\"reject_subscription\"}"
let message id payload = "{\"identifier\":" ^ Rails_format.json_quote id ^
  ",\"message\":" ^ Rails_format.encode payload ^ "}"

let test_channels () = with_seed (fun db ->
  let user, room = Db_runtime.read db (fun conn ->
    let membership = Db_runtime.query_one conn
      "SELECT room_id,user_id FROM memberships LIMIT 1" []
      (fun row -> Sqlite3.column_int64 row 0, Sqlite3.column_int64 row 1)
      |> Option.get in
    let room_id, user_id = membership in
    Db_accounts.User.find conn user_id,
    Db_rooms.Room.find conn room_id) in
  let session = Db_runtime.write db (fun tx ->
    Db_accounts.Session.start (Db_runtime.conn tx) ~now ~user_id:user.id
      ~user_agent:None ~ip_address:None) in
  let cookie = "session_token=" ^ Authentication.issue_token_cookie
    ~secret_key_base:secret ~now session.token in
  let t = Cable_channels.create ~db ~secret_key_base:secret ~now:(fun () -> now) () in
  Lwt_main.run (Lwt_unix.with_timeout 5. (fun () ->
    connect t ~cookie () >>= fun a -> connect t ~cookie () >>= fun b ->
    receive a >>= fun welcome_a -> receive b >>= fun welcome_b ->
    check "welcome A" "{\"type\":\"welcome\"}" welcome_a;
    check "welcome B" "{\"type\":\"welcome\"}" welcome_b;
    let room_id = `Int (Int64.to_int room.id) in
    let typing = identifier "TypingNotificationsChannel" ["room_id",room_id] in
    subscribe a typing >>= fun () -> receive a >>= fun a_confirm ->
    check "typing A confirms" (confirm typing) a_confirm;
    subscribe b typing >>= fun () -> receive b >>= fun b_confirm ->
    check "typing B confirms" (confirm typing) b_confirm;
    perform a typing "start" >>= fun () ->
    receive a >>= fun a_typing -> receive b >>= fun b_typing ->
    let typed = message typing (`Assoc ["action",`String "start";
      "user",`Assoc ["id",`Int (Int64.to_int user.id);"name",`String user.name]]) in
    check "typist receives" typed a_typing;
    check "peer receives" typed b_typing;
    let signed = Turbo_stream.signed_stream_name ~secret_key_base:secret
      [Cable_channels.room_param room;"messages"] in
    let messages = identifier "RoomMessagesChannel" ["signed_stream_name",`String signed] in
    subscribe a messages >>= fun () -> receive a >>= fun message_confirm ->
    check "member messages" (confirm messages) message_confirm;
    let html = "<turbo-stream action=\"remove\" target=\"message_1\"></turbo-stream>" in
    let stream = Cable_channels.room_param room ^ ":messages" in
    ignore (Cable_channels.broadcast_json t ~stream (`String html));
    receive a >>= fun removal ->
    check "Turbo HTML escaped" (message messages (`String html)) removal;
    let outsider = identifier "RoomChannel" ["room_id",`Int (-1)] in
    subscribe a outsider >>= fun () -> receive a >>= fun rejection ->
    check "room rejected" (reject outsider) rejection;
    ignore (Cable_channels.disconnect_user t ~user_id:user.id ~reconnect:true);
    receive a >>= fun remote_a -> receive b >>= fun remote_b ->
    let expected = "{\"type\":\"disconnect\",\"reason\":\"remote\",\"reconnect\":true}" in
    check "remote A" expected remote_a;
    check "remote B" expected remote_b;
    Lwt.return_unit)))

let test_cross_worker_channels () = with_bus_broker (fun path -> with_seed (fun db ->
  let user,room = Db_runtime.read db (fun conn ->
    Db_accounts.User.find conn 127326141L,
    Db_rooms.Room.find conn 654632876L) in
  let session = Db_runtime.write db (fun tx ->
    Db_accounts.Session.start (Db_runtime.conn tx) ~now ~user_id:user.id
      ~user_agent:None ~ip_address:None) in
  let cookie = "session_token=" ^ Authentication.issue_token_cookie
    ~secret_key_base:secret ~now session.token in
  let make () = Cable_channels.create ~db ~secret_key_base:secret
    ~now:(fun () -> now) () in
  let first = make () and second = make () in
  let first_bus = Cable_bus.connect path
    ~receive:(Cable_channels.receive_remote first) in
  Fun.protect ~finally:(fun () -> Cable_bus.close first_bus) (fun () ->
    Cable_channels.attach_bus first first_bus;
    let second_bus = Cable_bus.connect path
      ~receive:(Cable_channels.receive_remote second) in
    Fun.protect ~finally:(fun () -> Cable_bus.close second_bus) (fun () ->
      Cable_channels.attach_bus second second_bus;
      Lwt_main.run (Lwt_unix.with_timeout 5. (fun () ->
        connect first ~cookie () >>= fun a ->
        connect second ~cookie () >>= fun b ->
        receive a >>= fun _ -> receive b >>= fun _ ->
        let typing = identifier "TypingNotificationsChannel"
          ["room_id",`Int (Int64.to_int room.id)] in
        subscribe a typing >>= fun () -> receive a >>= fun confirmed_a ->
        subscribe b typing >>= fun () -> receive b >>= fun confirmed_b ->
        check "first worker subscription" (confirm typing) confirmed_a;
        check "second worker subscription" (confirm typing) confirmed_b;
        perform a typing "start" >>= fun () ->
        receive a >>= fun local -> receive b >>= fun remote ->
        check "cross-worker typing frame" local remote;
        ignore (Cable_channels.disconnect_user first
          ~user_id:user.id ~reconnect:true);
        receive a >>= fun local_disconnect ->
        receive b >|= fun remote_disconnect ->
        check "cross-worker disconnect" local_disconnect remote_disconnect))))))

let test_unauthorized () = with_seed (fun db ->
  let t = Cable_channels.create ~db ~secret_key_base:secret ~now:(fun () -> now) () in
  Lwt_main.run (Lwt_unix.with_timeout 2. (fun () ->
    connect t () >>= fun c -> receive c >|= fun frame ->
    check "unauthorized" "{\"type\":\"disconnect\",\"reason\":\"unauthorized\",\"reconnect\":false}" frame)))

let test_presence_and_stream_guard () = with_seed (fun db ->
  let user, room = Db_runtime.read db (fun conn ->
    let room_id, user_id = Db_runtime.query_one conn
      "SELECT room_id,user_id FROM memberships LIMIT 1" []
      (fun row -> Sqlite3.column_int64 row 0, Sqlite3.column_int64 row 1)
      |> Option.get in
    Db_accounts.User.find conn user_id, Db_rooms.Room.find conn room_id) in
  let session = Db_runtime.write db (fun tx ->
    Db_accounts.Session.start (Db_runtime.conn tx) ~now ~user_id:user.id
      ~user_agent:None ~ip_address:None) in
  let cookie = "session_token=" ^ Authentication.issue_token_cookie
    ~secret_key_base:secret ~now session.token in
  let t = Cable_channels.create ~db ~secret_key_base:secret ~now:(fun () -> now) () in
  Lwt_main.run (Lwt_unix.with_timeout 5. (fun () ->
    connect t ~cookie () >>= fun c -> receive c >>= fun _ ->
    let reads = identifier "ReadRoomsChannel" [] in
    let presence = identifier "PresenceChannel"
      ["room_id",`String (Int64.to_string room.id)] in
    subscribe c reads >>= fun () -> receive c >>= fun reads_confirm ->
    check "reads confirm" (confirm reads) reads_confirm;
    subscribe c presence >>= fun () ->
    receive c >>= fun presence_confirm -> receive c >>= fun read_notice ->
    check "presence confirm" (confirm presence) presence_confirm;
    check "present emits read" (message reads (`Assoc
      ["room_id",`Int (Int64.to_int room.id)])) read_notice;
    let membership () = Db_runtime.read db (fun conn ->
      Db_rooms.Membership.find_by_room_and_user conn room.id user.id |> Option.get) in
    Alcotest.(check int) "present connection count" 1
      (Int64.to_int (membership ()).connections);
    let stream = Cable_channels.room_param room ^ ":messages" in
    let signed = Turbo_stream.signed_stream_name ~secret_key_base:secret
      [Cable_channels.room_param room;"messages"] in
    let turbo_guarded = identifier "Turbo::StreamsChannel"
      ["signed_stream_name",`String signed] in
    subscribe c turbo_guarded >>= fun () -> receive c >>= fun guarded_reply ->
    check "stock Turbo rejects room messages" (reject turbo_guarded) guarded_reply;
    let messages = identifier "RoomMessagesChannel"
      ["signed_stream_name",`String signed] in
    subscribe c messages >>= fun () -> receive c >>= fun message_reply ->
    check "specialized channel permits member" (confirm messages) message_reply;
    let forged = identifier "RoomMessagesChannel"
      ["signed_stream_name",`String (stream ^ "--0000")] in
    subscribe c forged >>= fun () -> receive c >>= fun forged_reply ->
    check "forged stream rejected" (reject forged) forged_reply;
    let rooms_signed = Turbo_stream.signed_stream_name ~secret_key_base:secret ["rooms"] in
    let turbo_rooms = identifier "Turbo::StreamsChannel"
      ["signed_stream_name",`String rooms_signed] in
    subscribe c turbo_rooms >>= fun () -> receive c >>= fun turbo_reply ->
    check "stock Turbo rooms" (confirm turbo_rooms) turbo_reply;
    Cable_broadcasts.room_remove t ~room;
    receive c >>= fun room_removed ->
    let room_tag = Cable_broadcasts.action_tag ~action:"remove"
      ~target:(Cable_broadcasts.room_dom_id room "list") () in
    check "room removal broadcast" (message turbo_rooms (`String room_tag)) room_removed;
    Cable_broadcasts.message_remove t ~room
      ~message:{Db_messages.Message.id=1L;room_id=room.id;creator_id=user.id;
        client_message_id="test-uuid";created_at=now;updated_at=now};
    receive c >>= fun message_removed ->
    let message_tag = "<turbo-stream action=\"remove\" target=\"message_test-uuid\"></turbo-stream>" in
    check "message removal broadcast" (message messages (`String message_tag))
      message_removed;
    send c (command "unsubscribe" presence) >>= fun () ->
    let rec await_absent attempts =
      if attempts = 0 then Alcotest.fail "presence did not disconnect"
      else if (membership ()).connections = 0L then Lwt.return_unit
      else Lwt_unix.sleep 0.01 >>= fun () -> await_absent (attempts-1) in
    await_absent 20)))

let test_after_commit_revocation () = with_seed (fun db ->
  let user = Db_runtime.read db (fun conn ->
    Db_runtime.query_one conn "SELECT id FROM users LIMIT 1" []
      (fun row -> Sqlite3.column_int64 row 0) |> Option.get) in
  let session = Db_runtime.write db (fun tx ->
    Db_accounts.Session.start (Db_runtime.conn tx) ~now ~user_id:user
      ~user_agent:None ~ip_address:None) in
  let cookie = "session_token=" ^ Authentication.issue_token_cookie
    ~secret_key_base:secret ~now session.token in
  let t = Cable_channels.create ~db ~secret_key_base:secret ~now:(fun () -> now) () in
  Lwt_main.run (Lwt_unix.with_timeout 5. (fun () ->
    connect t ~cookie () >>= fun c -> receive c >>= fun _ ->
    let event = Db_remaining.Event.DisconnectUser
      {user_id=user;reconnect=false} in
    Lwt.catch (fun () -> Db_runtime.write_async db (fun tx ->
       Db_remaining.Event.after_commit tx (Cable_channels.event_sink t) event;
       failwith "rollback")) (fun _ -> Lwt.return_unit) >>= fun () ->
    (* The rollback's callback must not run. A regular heartbeat subscription proves
       that the socket remains usable before the committed revocation. *)
    let heartbeat = identifier "HeartbeatChannel" [] in
    subscribe c heartbeat >>= fun () -> receive c >>= fun confirmed ->
    check "rollback keeps connection" (confirm heartbeat) confirmed;
    Db_runtime.write_async db (fun tx ->
      Db_remaining.Event.after_commit tx (Cable_channels.event_sink t) event)
    >>= fun () -> receive c >|= fun remote ->
    check "committed revocation"
      "{\"type\":\"disconnect\",\"reason\":\"remote\",\"reconnect\":false}"
      remote)))

let test_bounds () = with_seed (fun db ->
  let user_id = Db_runtime.read db (fun conn ->
    Db_runtime.query_one conn "SELECT id FROM users LIMIT 1" []
      (fun row -> Sqlite3.column_int64 row 0) |> Option.get) in
  let session = Db_runtime.write db (fun tx ->
    Db_accounts.Session.start (Db_runtime.conn tx) ~now ~user_id
      ~user_agent:None ~ip_address:None) in
  let cookie = "session_token=" ^ Authentication.issue_token_cookie
    ~secret_key_base:secret ~now session.token in
  let t = Cable_channels.create ~db ~secret_key_base:secret ~now:(fun () -> now) () in
  Lwt_main.run (Lwt_unix.with_timeout 5. (fun () ->
    connect t ~cookie () >>= fun c -> receive c >>= fun _ ->
    let id n = identifier "HeartbeatChannel" ["nonce",`Int n] in
    Lwt_list.iter_s (fun n ->
      subscribe c (id n) >>= fun () -> receive c >|= fun response ->
      check "bounded subscription confirm" (confirm (id n)) response)
      (List.init 64 Fun.id) >>= fun () ->
    subscribe c (id 64) >>= fun () ->
    send c (command "unsubscribe" (id 0)) >>= fun () ->
    subscribe c (id 64) >>= fun () -> receive c >>= fun accepted ->
    check "slot frees after unsubscribe" (confirm (id 64)) accepted;
    let huge = identifier "HeartbeatChannel" ["pad",`String (String.make 5000 'x')] in
    subscribe c huge >>= fun () ->
    let rooms = identifier "Turbo::StreamsChannel"
      ["signed_stream_name",`String
        (Turbo_stream.signed_stream_name ~secret_key_base:secret ["rooms"])] in
    (* This socket is full; a fresh socket receives the ring-overflow test. *)
    connect t ~cookie () >>= fun slow -> receive slow >>= fun _ ->
    subscribe slow rooms >>= fun () -> receive slow >>= fun confirmed ->
    check "slow stream confirmed" (confirm rooms) confirmed;
    for n=0 to 300 do
      ignore (Cable_channels.broadcast_json t ~stream:"rooms" (`Int n))
    done;
    receive slow >|= fun lagged ->
    check "bounded lagged close"
      "{\"type\":\"disconnect\",\"reason\":null,\"reconnect\":true}"
      lagged)))

let test_http_request_broadcasts () = with_seed (fun db ->
  let admin_id = 127326141L and member_id = 712064548L in
  let room = Db_runtime.read db (fun conn -> Db_rooms.Room.find conn 654632876L) in
  let session user_id = Db_runtime.write db (fun tx ->
    Db_accounts.Session.start (Db_runtime.conn tx) ~now ~user_id
      ~user_agent:None ~ip_address:None) in
  let cookie user_id = "session_token=" ^ Authentication.issue_token_cookie
    ~secret_key_base:secret ~now (session user_id).token in
  let admin_cookie = cookie admin_id and member_cookie = cookie member_id in
  let cable = Cable_channels.create ~db ~secret_key_base:secret
    ~now:(fun () -> now) () in
  let http ?(accept="text/vnd.turbo-stream.html, text/html")
      ~cookie ~meth ~path ~body () =
    let headers = Cohttp.Header.of_list [
      "host","campfire.test"; "origin","https://campfire.test";
      "sec-fetch-site","same-origin"; "cookie",cookie;
      "accept",accept;
      "content-type","application/x-www-form-urlencoded"] in
    let request = Cohttp.Request.make ~meth ~headers
      (Uri.of_string ("https://campfire.test" ^ path)) in
    Http_app.handle ~runtime:db ~secret_key_base:secret ~now
      ~ssl:true ~force_ssl:true ~cable
      ~event_sink:(Cable_channels.event_sink cable)
      ~dispatch:App_dispatch.endpoint request
      (Cohttp_lwt.Body.of_string body) >>= fun (response, body) ->
    Cohttp_lwt.Body.to_string body >|= fun rendered ->
    Cohttp.Code.code_of_status (Cohttp.Response.status response), rendered in
  Lwt_main.run (Lwt_unix.with_timeout 8. (fun () ->
    connect cable ~cookie:admin_cookie () >>= fun a ->
    connect cable ~cookie:member_cookie () >>= fun b ->
    receive a >>= fun _ -> receive b >>= fun _ ->
    let signed = Turbo_stream.signed_stream_name ~secret_key_base:secret
      [Cable_channels.room_param room;"messages"] in
    let messages = identifier "RoomMessagesChannel"
      ["signed_stream_name",`String signed] in
    let unreads = identifier "UnreadRoomsChannel" [] in
    http ~accept:"text/html" ~cookie:admin_cookie ~meth:`GET
      ~path:"/rooms/654632876" ~body:"" () >>= fun (room_status,room_html) ->
    Alcotest.(check int) "room page status" 200 room_status;
    let rec has_signed at =
      at + String.length signed <= String.length room_html &&
      (String.sub room_html at (String.length signed) = signed || has_signed (at+1)) in
    Alcotest.(check bool) "room page signs STI stream" true (has_signed 0);
    subscribe a messages >>= fun () -> receive a >>= fun confirmed_a ->
    check "admin room stream" (confirm messages) confirmed_a;
    subscribe b messages >>= fun () -> receive b >>= fun confirmed_b ->
    check "member room stream" (confirm messages) confirmed_b;
    subscribe b unreads >>= fun () -> receive b >>= fun confirmed_unreads ->
    check "member unread stream" (confirm unreads) confirmed_unreads;
    http ~cookie:admin_cookie ~meth:`POST
      ~path:"/rooms/654632876/messages"
      ~body:"message%5Bbody%5D=Live+Cable+message" () >>= fun (status,response_body) ->
    Alcotest.(check int) "HTTP message create" 200 status;
    receive a >>= fun append_a -> receive b >>= fun append_b ->
    let frame_payload frame = match Yojson.Basic.from_string frame with
      | `Assoc fields -> List.assoc "message" fields
      | _ -> Alcotest.fail "expected Cable message" in
    let append = match frame_payload append_a with
      | `String html -> html | _ -> Alcotest.fail "expected Turbo HTML" in
    Alcotest.(check bool) "admin gets append" true
      (String.starts_with ~prefix:"<turbo-stream action=\"append\"" append);
    Alcotest.(check string) "HTTP and Cable render same append"
      response_body append;
    Alcotest.(check bool) "member gets same append" true
      (append_a = append_b);
    receive b >>= fun unread ->
    Alcotest.(check (option int)) "member gets unread"
      (Some (Int64.to_int room.id))
      (match frame_payload unread with
       | `Assoc fields -> (match List.assoc_opt "roomId" fields with
         | Some (`Int id) -> Some id | _ -> None)
       | _ -> None);
    http ~cookie:admin_cookie ~meth:`PATCH
      ~path:"/rooms/closeds/654632876"
      ~body:"room%5Bname%5D=Designers&user_ids%5B%5D=127326141" () >>= fun (status,_) ->
    Alcotest.(check int) "HTTP membership change" 302 status;
    receive b >>= fun remote ->
    check "membership revoke"
      "{\"type\":\"disconnect\",\"reason\":\"remote\",\"reconnect\":true}"
      remote;
    connect cable ~cookie:member_cookie () >>= fun c -> receive c >>= fun _ ->
    subscribe c messages >>= fun () -> receive c >>= fun denied ->
    check "removed member cannot resubscribe" (reject messages) denied;
    http ~cookie:admin_cookie ~meth:`POST ~path:"/users/712064548/ban"
      ~body:"" () >>= fun (status,_) ->
    Alcotest.(check int) "HTTP ban" 302 status;
    receive c >>= fun banned ->
    check "ban disconnect"
      "{\"type\":\"disconnect\",\"reason\":\"remote\",\"reconnect\":false}"
      banned;
    connect cable ~cookie:member_cookie () >>= fun rejected ->
    receive rejected >|= fun unauthorized ->
    check "banned reconnect denied"
      "{\"type\":\"disconnect\",\"reason\":\"unauthorized\",\"reconnect\":false}"
      unauthorized)))

let test_live_http_to_two_sockets () = with_seed (fun db ->
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let port = match Unix.getsockname socket with
    | Unix.ADDR_INET (_, port) -> port | _ -> assert false in
  Unix.close socket;
  let session user_id = Db_runtime.write db (fun tx ->
    Db_accounts.Session.start (Db_runtime.conn tx) ~now ~user_id
      ~user_agent:None ~ip_address:None) in
  let cookie user_id = "session_token=" ^ Authentication.issue_token_cookie
    ~secret_key_base:secret ~now (session user_id).token in
  let admin_cookie = cookie 127326141L and member_cookie = cookie 712064548L in
  let room = Db_runtime.read db (fun conn -> Db_rooms.Room.find conn 654632876L) in
  let cable = Cable_channels.create ~db ~secret_key_base:secret
    ~now:(fun () -> now) () in
  let stop, wake_stop = Lwt.wait () in
  let server = Http_app.serve ~runtime:db ~secret_key_base:secret
    ~port ~stop ~cable ~cable_run:(Cable_channels.run cable)
    ~event_sink:(Cable_channels.event_sink cable)
    ~dispatch:App_dispatch.endpoint () in
  let host = Printf.sprintf "127.0.0.1:%d" port in
  let connect_live cookie =
    Lwt_io.open_connection (Unix.ADDR_INET (Unix.inet_addr_loopback, port))
    >>= fun (input, output) ->
    let request = "GET /cable HTTP/1.1\r\nHost: " ^ host ^
      "\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nOrigin: http://" ^ host ^
      "\r\nCookie: " ^ cookie ^
      "\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ^
      "Sec-WebSocket-Protocol: actioncable-v1-json\r\n\r\n" in
    Lwt_io.write output request >>= fun () -> Lwt_io.flush output >>= fun () ->
    Lwt_io.read_line input >>= fun status ->
    Alcotest.(check bool) "live Cable 101" true
      (String.starts_with ~prefix:"HTTP/1.1 101" status);
    let rec headers () = Lwt_io.read_line input >>= fun line ->
      if String.trim line = "" then Lwt.return_unit else headers () in
    headers () >|= fun () -> {input;output} in
  let http ~cookie ~meth ~path ~body =
    let uri = Uri.of_string ("http://" ^ host ^ path) in
    let headers = Cohttp.Header.of_list ["cookie",cookie;
      "origin","http://" ^ host;"sec-fetch-site","same-origin";
      "accept","text/vnd.turbo-stream.html, text/html";
      "content-type","application/x-www-form-urlencoded"] in
    Cohttp_lwt_unix.Client.call ~headers
      ~body:(Cohttp_lwt.Body.of_string body) meth uri
    >>= fun (response, body) ->
    Cohttp_lwt.Body.drain_body body >|= fun () ->
    Cohttp.Code.code_of_status (Cohttp.Response.status response) in
  Lwt_main.run (Lwt.finalize (fun () -> Lwt_unix.with_timeout 12. (fun () ->
    Lwt.async (fun () -> server);
    Lwt_unix.sleep 0.04 >>= fun () ->
    connect_live admin_cookie >>= fun a ->
    connect_live member_cookie >>= fun b ->
    receive a >>= fun _ -> receive b >>= fun _ ->
    let signed = Turbo_stream.signed_stream_name ~secret_key_base:secret
      [Cable_channels.room_param room;"messages"] in
    let messages = identifier "RoomMessagesChannel"
      ["signed_stream_name",`String signed] in
    subscribe a messages >>= fun () -> receive a >>= fun confirmed_a ->
    check "live admin subscription" (confirm messages) confirmed_a;
    subscribe b messages >>= fun () -> receive b >>= fun confirmed_b ->
    check "live member subscription" (confirm messages) confirmed_b;
    http ~cookie:admin_cookie ~meth:`POST
      ~path:"/rooms/654632876/messages"
      ~body:"message%5Bbody%5D=TCP+Cable+message" >>= fun status ->
    Alcotest.(check int) "live HTTP create" 200 status;
    receive a >>= fun append_a -> receive b >>= fun append_b ->
    Alcotest.(check string) "live peer gets same append" append_a append_b;
    Alcotest.(check bool) "live append action" true
      (String.contains append_a 'a' && String.contains append_a 'm');
    http ~cookie:admin_cookie ~meth:`PATCH
      ~path:"/rooms/closeds/654632876"
      ~body:"room%5Bname%5D=Designers&user_ids%5B%5D=127326141" >>= fun status ->
    Alcotest.(check int) "live HTTP revoke" 302 status;
    receive b >>= fun remote ->
    check "live remote revocation"
      "{\"type\":\"disconnect\",\"reason\":\"remote\",\"reconnect\":true}"
      remote;
    Lwt.return_unit))
    (fun () -> Lwt.wakeup_later wake_stop (); Lwt.return_unit)))

let () = Alcotest.run "M5 channels" [
  "socket", [Alcotest.test_case "cross-worker Cable frames" `Quick test_cross_worker_channels;
             Alcotest.test_case "two clients and remote disconnect" `Quick test_channels;
             Alcotest.test_case "unauthorized" `Quick test_unauthorized;
             Alcotest.test_case "presence and streams" `Quick test_presence_and_stream_guard;
             Alcotest.test_case "after-commit revocation" `Quick test_after_commit_revocation;
             Alcotest.test_case "subscription and delivery bounds" `Quick test_bounds;
             Alcotest.test_case "HTTP request broadcasts and revocations" `Quick test_http_request_broadcasts;
             Alcotest.test_case "live HTTP to two sockets" `Quick (fun () ->
               if Sys.getenv_opt "CAMPFIRE_LIVE_CABLE_TEST" = Some "1"
               then test_live_http_to_two_sockets ())]]

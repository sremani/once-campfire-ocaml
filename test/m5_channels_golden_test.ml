open Lwt.Infix
open Campfire

let rec root path n =
  if n=0 then failwith "pinned channel golden missing" else
  let candidate=Filename.concat path "once-campfire-rust" in
  if Sys.file_exists (Filename.concat candidate
    "crates/campfire/src/channels/tests/golden/reference.json")
  then candidate else root (Filename.dirname path) (n-1)
let reference = root (Sys.getcwd ()) 8
let fixture_path = Filename.concat reference
  "crates/campfire/src/channels/tests/golden/reference.json"
let env_path = Filename.concat reference "parity/.env.reference"
let now = "2026-10-09T12:00:00Z"

let secret () =
  let input=open_in env_path in
  Fun.protect ~finally:(fun () -> close_in input) (fun () ->
    let rec loop () = match input_line input with
    | line when String.starts_with ~prefix:"SECRET_KEY_BASE=" line ->
        String.sub line 16 (String.length line-16)
        |> String.trim |> String.split_on_char '"' |> String.concat ""
    | _ -> loop ()
    | exception End_of_file -> failwith "test secret missing" in loop ())

let assoc = function `Assoc fields -> fields | _ -> failwith "expected object"
let get key json = List.assoc key (assoc json)
let str key json = match get key json with `String value -> value | _ -> failwith key
let array key json = match get key json with `List values -> values | _ -> failwith key
let i64 key json = Int64.of_string (str key json)
let number n = `Int (Int64.to_int n)

let sql_value = function
  | `Null -> Sqlite3.Data.NULL
  | `Bool value -> Sqlite3.Data.INT (if value then 1L else 0L)
  | `Int value -> Sqlite3.Data.INT (Int64.of_int value)
  | `Float value -> Sqlite3.Data.FLOAT value
  | `String value -> Sqlite3.Data.TEXT value
  | other -> Sqlite3.Data.TEXT (Yojson.Basic.to_string other)

let with_fixture golden f =
  let path=Filename.temp_file "campfire-channel-app-golden-" ".sqlite3" in
  Sys.remove path;
  let db=Db_runtime.open_db ~readers:2 path in
  Fun.protect ~finally:(fun () ->
    Db_runtime.close db;
    List.iter (fun file -> if Sys.file_exists file then Sys.remove file)
      [path;path^"-wal";path^"-shm"])
    (fun () ->
      let rows=get "rows" (get "fixtures" golden) in
      Db_runtime.write db (fun tx ->
        let conn=Db_runtime.conn tx in
        List.iter (fun table ->
          List.iter (fun row ->
            let fields=assoc row in
            let columns=List.map (fun (key,_) -> "\"" ^ key ^ "\"") fields in
            let placeholders=List.map (fun _ -> "?") fields in
            let statement="INSERT INTO " ^ table ^ " (" ^
              String.concat "," columns ^ ") VALUES (" ^
              String.concat "," placeholders ^ ")" in
            ignore (Db_runtime.execute conn statement
              (List.map (fun (_,value) -> sql_value value) fields)))
            (array table rows))
          ["users";"rooms";"memberships";"sessions";"messages"]);
      f db)

let exact input count =
  if count=0 then Lwt.return "" else
  let bytes=Bytes.create count in
  Lwt_io.read_into_exactly input bytes 0 count >|= fun () -> Bytes.to_string bytes
let read_frame input =
  Lwt_io.read_char input >>= fun first -> Lwt_io.read_char input >>= fun second ->
  let n=Char.code second land 127 in
  (if n<126 then Lwt.return n
   else if n=126 then exact input 2 >|= fun bytes ->
     (Char.code bytes.[0] lsl 8) lor Char.code bytes.[1]
   else exact input 8 >|= fun bytes ->
     String.fold_left (fun n c -> (n lsl 8) lor Char.code c) 0 bytes)
  >>= fun count -> exact input count >|= fun payload ->
  Char.code first land 15,payload

let frame text =
  let n=String.length text in
  let length=if n<126 then String.make 1 (Char.chr (0x80 lor n))
    else if n<65536 then String.make 1 '\xfe' ^ String.init 2 (fun i ->
      Char.chr ((n lsr (8*(1-i))) land 255))
    else failwith "golden command too long" in
  let mask="\x12\x34\x56\x78" in
  "\x81" ^ length ^ mask ^ String.init n (fun i ->
    Char.chr (Char.code text.[i] lxor Char.code mask.[i mod 4]))

type client = {input:Lwt_io.input_channel;output:Lwt_io.output_channel;
  mutable closed:bool}
let send client value =
  Lwt_io.write client.output (frame value) >>= fun () ->
  Lwt_io.flush client.output
let connect port ?cookie () =
  Lwt_io.open_connection (Unix.ADDR_INET (Unix.inet_addr_loopback,port))
  >>= fun (input,output) ->
  let host=Printf.sprintf "127.0.0.1:%d" port in
  let request="GET /cable HTTP/1.1\r\nHost: " ^ host ^
    "\r\nConnection: Upgrade\r\nUpgrade: websocket" ^
    "\r\nOrigin: http://" ^ host ^
    "\r\nSec-WebSocket-Version: 13" ^
    "\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" ^
    "\r\nSec-WebSocket-Protocol: actioncable-v1-json, actioncable-unsupported" ^
    (match cookie with None -> "" | Some value -> "\r\nCookie: " ^ value) ^
    "\r\n\r\n" in
  Lwt_io.write output request >>= fun () -> Lwt_io.flush output >>= fun () ->
  Lwt_io.read_line input >>= fun status ->
  let rec headers () = Lwt_io.read_line input >>= fun line ->
    if String.trim line="" then Lwt.return_unit else headers () in
  headers () >|= fun () ->
  Alcotest.(check bool) "live upgrade" true
    (String.starts_with ~prefix:"HTTP/1.1 101" status);
  {input;output;closed=false}

let close_text payload =
  if String.length payload < 2 then "close None" else
  let code=(Char.code payload.[0] lsl 8) lor Char.code payload.[1] in
  let reason=String.sub payload 2 (String.length payload-2) in
  Printf.sprintf "close Some((%d, %S))" code reason

let collect client at_least =
  if client.closed then Lwt.return [] else
  let rec loop acc =
    let timeout=if List.length acc < at_least then 5. else 0.025 in
    Lwt.catch (fun () ->
      Lwt_unix.with_timeout timeout (fun () -> read_frame client.input)
      >>= function
      | 1,text when String.starts_with ~prefix:"{\"type\":\"ping\"" text -> loop acc
      | 1,text -> loop (text::acc)
      | 8,payload -> client.closed <- true;
          Lwt.return (List.rev (close_text payload::acc))
      | _ -> loop acc)
      (function
        | Lwt_unix.Timeout -> Lwt.return (List.rev acc)
        | End_of_file -> client.closed <- true; Lwt.return (List.rev acc)
        | error -> Lwt.fail error) in
  loop []

let encode = Rails_format.encode
let id channel fields = encode (`Assoc (("channel",`String channel)::fields))
let subscribe identifier = encode (`Assoc ["command",`String "subscribe";
  "identifier",`String identifier])
let perform identifier fields = encode (`Assoc ["command",`String "message";
  "identifier",`String identifier;"data",`String (encode (`Assoc fields))])
type step = Connect of string * string option | Send of string * string
  | Trigger of string

let script tokens =
  let token name=str name tokens in
  let room_id=i64 "ROOM_ID" tokens and closed_id=i64 "CLOSED_ID" tokens in
  let reads=id "ReadRoomsChannel" [] and unreads=id "UnreadRoomsChannel" [] in
  let presence=id "PresenceChannel" ["room_id",number room_id] in
  let room=id "RoomChannel" ["room_id",number room_id] in
  let typing=id "TypingNotificationsChannel" ["room_id",number room_id] in
  let messages=id "RoomMessagesChannel"
    ["signed_stream_name",`String (token "ROOM_MESSAGES_SIGNED")] in
  let turbo value=id "Turbo::StreamsChannel" ["signed_stream_name",`String value] in
  let guarded=turbo (token "ROOM_MESSAGES_SIGNED") in
  let rooms=turbo (token "ROOMS_SIGNED") in
  let sub socket identifier=Send (socket,subscribe identifier) in
  let act socket identifier fields=Send (socket,perform identifier fields) in
  [
    "connect A",Connect ("A",Some "A");
    "connect B",Connect ("B",Some "B");
    "connect without a cookie",Connect ("X",None);
    "A heartbeat",sub "A" (id "HeartbeatChannel" []);
    "A base channel",sub "A" (id "ApplicationCable::Channel" []);
    "A reads",sub "A" reads;
    "A unreads",sub "A" unreads;
    "A presence",sub "A" presence;
    "A presence in a room A isn't in",sub "A"
      (id "PresenceChannel" ["room_id",number closed_id]);
    "A presence with a non-numeric room",sub "A"
      (id "PresenceChannel" ["room_id",`String "abc"]);
    "A presence with a numeric string room",sub "A"
      (id "PresenceChannel" ["room_id",`String (Int64.to_string room_id)]);
    "A room",sub "A" room;
    "A room A isn't in",sub "A" (id "RoomChannel" ["room_id",number closed_id]);
    "A room without an id",sub "A" (id "RoomChannel" []);
    "A typing",sub "A" typing;
    "B typing",sub "B" typing;
    "A starts typing",act "A" typing ["action",`String "start"];
    "B stops typing",act "B" typing ["action",`String "stop";"extra",`Int 1];
    "A performs an unknown typing action",act "A" typing ["action",`String "dance"];
    "A room messages",sub "A" messages;
    "A room messages for a room A isn't in",sub "A"
      (id "RoomMessagesChannel" ["signed_stream_name",`String
        (token "CLOSED_MESSAGES_SIGNED")]);
    "A room messages without a name",sub "A" (id "RoomMessagesChannel" []);
    "A room messages with a forged name",sub "A"
      (id "RoomMessagesChannel" ["signed_stream_name",`String "InJvb21zIg==--0000"]);
    "A room messages with the rooms name",sub "A"
      (id "RoomMessagesChannel" ["signed_stream_name",`String (token "ROOMS_SIGNED")]);
    "A turbo rooms",sub "A" rooms;
    "A turbo own rooms",sub "A" (turbo (token "A_ROOMS_SIGNED"));
    "A turbo guarded room messages",sub "A" guarded;
    "A turbo forged",sub "A" (turbo "InJvb21zIg==--0000");
    "A presence present",act "A" presence ["action",`String "present"];
    "A presence refresh",act "A" presence ["action",`String "refresh"];
    "A unreads subscribed again",act "A" unreads ["action",`String "subscribed"];
    "unread fanout",Trigger "unread";
    "message removed",Trigger "remove_message";
    "B presence",sub "B" presence;
    "A typing again",act "A" typing ["action",`String "start"];
    "revoke A",Trigger "revoke";
    "reconnect A",Connect ("A2",Some "A");
    "A2 presence",sub "A2" presence;
    "A2 room",sub "A2" room;
    "A2 typing",sub "A2" typing;
    "A2 room messages",sub "A2" messages;
    "A2 turbo guarded room messages",sub "A2" guarded;
    "A2 turbo rooms",sub "A2" rooms;
    "A2 unreads",sub "A2" unreads;
    "B typing after A left",act "B" typing ["action",`String "start"];
    "deactivate B",Trigger "deactivate";
    "reconnect B",Connect ("B2",Some "B")
  ]

let trigger db cable tokens name =
  let room_id=i64 "ROOM_ID" tokens and message_id=i64 "MESSAGE_ID" tokens in
  match name with
  | "unread" ->
      Db_runtime.read_async db (fun conn ->
        let room=Db_rooms.Room.find conn room_id in
        let ids=Db_rooms.Membership.for_room conn room.id
          |> List.map (fun (member:Db_rooms.Membership.t) -> member.user_id) in
        Cable_broadcasts.unread_room cable ~room ~member_ids:ids)
  | "remove_message" ->
      Db_runtime.read_async db (fun conn ->
        let message=Db_messages.Message.find conn message_id in
        let room=Db_rooms.Room.find conn message.room_id in
        Cable_broadcasts.message_remove cable ~room ~message)
  | "revoke" ->
      let user_id=i64 "A_ID" tokens in
      Db_runtime.write_async db (fun tx ->
        let room=Db_rooms.Room.find (Db_runtime.conn tx) room_id in
        Db_remaining.Hooks.revoke_from tx room [user_id]
          ~sink:(Cable_channels.event_sink cable))
  | "deactivate" ->
      let user_id=i64 "B_ID" tokens in
      Db_runtime.write_async db (fun tx ->
        let user=Db_accounts.User.find (Db_runtime.conn tx) user_id in
        ignore (Db_remaining.Hooks.deactivate_user tx ~now
          ~sink:(Cable_channels.event_sink cable) user))
  | _ -> failwith ("unknown trigger " ^ name)

let test () =
  let golden=Yojson.Basic.from_file fixture_path in
  let fixtures=get "fixtures" golden in
  let tokens=get "tokens" fixtures and cookies=get "cookies" fixtures in
  let expected=array "steps" golden in
  let script=script tokens in
  Alcotest.(check int) "47 pinned application channel steps" 47 (List.length expected);
  Alcotest.(check int) "script length" 47 (List.length script);
  with_fixture golden (fun db ->
    let secret=secret () in
    let cable=Cable_channels.create ~db ~secret_key_base:secret
      ~now:(fun () -> now) () in
    let sock=Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback,0));
    let port=match Unix.getsockname sock with Unix.ADDR_INET (_,p) -> p
      | _ -> assert false in
    Unix.close sock;
    let stop,wake=Lwt.wait () in
    let server=Http_app.serve ~runtime:db ~secret_key_base:secret
      ~port ~stop ~cable ~cable_run:(Cable_channels.run cable)
      ~event_sink:(Cable_channels.event_sink cable)
      ~dispatch:App_dispatch.endpoint () in
    Lwt_main.run (Lwt.finalize (fun () ->
      Lwt.async (fun () -> server);
      Lwt_unix.sleep 0.03 >>= fun () ->
      let sockets=Hashtbl.create 5 in
      let run_step index (name,step) =
        let exchange=List.nth expected index in
        Alcotest.(check string) "scripted step name" (str "step" exchange) name;
        (match step with
         | Connect (socket,cookie) ->
             let cookie=Option.map (fun key -> str key cookies) cookie in
             connect port ?cookie () >|= fun client -> Hashtbl.add sockets socket client
         | Send (socket,text) -> send (Hashtbl.find sockets socket) text
         | Trigger event -> trigger db cable tokens event) >>= fun () ->
        let expected_frames=assoc (get "frames" exchange) in
        Hashtbl.to_seq sockets |> List.of_seq
        |> List.sort (fun (a,_) (b,_) -> String.compare a b)
        |> Lwt_list.map_s (fun (socket,client) ->
          let wanted=match List.assoc_opt socket expected_frames with
            | None -> [] | Some (`List frames) ->
                List.map (function `String s -> s | _ -> failwith "frame") frames
            | _ -> failwith "frames" in
          collect client (List.length wanted) >|= fun actual -> socket,wanted,actual)
        >|= fun frames ->
        List.iter (fun (socket,wanted,actual) ->
          Alcotest.(check (list string))
            (Printf.sprintf "step %d %s socket %s" (index+1) name socket)
            (List.sort String.compare wanted) (List.sort String.compare actual)) frames in
      Lwt_list.iteri_s run_step script)
      (fun () -> Lwt.wakeup_later wake (); Lwt.return_unit)))

let () = Alcotest.run "M5 application channels golden" [
  "live", [Alcotest.test_case "all 47 reference steps" `Slow
    (fun () -> if Sys.getenv_opt "CAMPFIRE_APP_CHANNEL_GOLDEN" = Some "1"
      then test ())]]

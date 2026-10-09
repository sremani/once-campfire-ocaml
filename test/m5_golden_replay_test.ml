open Lwt.Infix
open Campfire

let rec reference_root path remaining =
  if remaining = 0 then failwith "pinned Rust reference checkout not found" else
  let candidate = Filename.concat path "once-campfire-rust" in
  if Sys.file_exists (Filename.concat candidate "crates/cable/tests/golden/reference.json")
  then candidate else reference_root (Filename.dirname path) (remaining - 1)
let root = reference_root (Sys.getcwd ()) 8
let golden_path = Filename.concat root "crates/cable/tests/golden/reference.json"
let seed_path = Filename.concat root "parity/.seed/default/db/production.sqlite3"
let env_path = Filename.concat root "parity/.env.reference"
let now = "2026-10-08T12:00:00Z"

let fixture_secret () =
  let ic = open_in env_path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    let rec find () = match input_line ic with
      | line when String.starts_with ~prefix:"SECRET_KEY_BASE=" line ->
          let value = String.sub line 16 (String.length line - 16) in
          String.trim value |> String.split_on_char '"' |> String.concat ""
      | _ -> find ()
      | exception End_of_file -> failwith "pinned test secret missing" in
    find ())

let with_seed f =
  let source = Sqlite3.db_open ~mode:`READONLY seed_path in
  let temp = Filename.temp_file "campfire-cable-golden-" ".sqlite3" in
  Sys.remove temp;
  let quoted = String.concat "''" (String.split_on_char '\'' temp) in
  let rc = Sqlite3.exec source ("VACUUM INTO '" ^ quoted ^ "'") in
  ignore (Sqlite3.db_close source);
  if rc <> Sqlite3.Rc.OK then failwith "could not copy pinned Rails seed";
  let db = Db_runtime.open_db ~prepare:false temp in
  Fun.protect ~finally:(fun () ->
    Db_runtime.close db;
    List.iter (fun name -> if Sys.file_exists name then Sys.remove name)
      [temp; temp^"-wal"; temp^"-shm"])
    (fun () -> f db)

let field name = function `Assoc fields -> List.assoc name fields | _ -> failwith "expected object"
let string name json = match field name json with `String value -> value | _ -> failwith name
let list name json = match field name json with `List items -> items | _ -> failwith name
let string_list name json = List.map (function `String s -> s | _ -> failwith name) (list name json)
let assoc = function `Assoc fields -> fields | _ -> failwith "expected object"

let read_exact ic count =
  if count = 0 then Lwt.return "" else
  let data = Bytes.create count in
  Lwt_io.read_into_exactly ic data 0 count >|= fun () -> Bytes.to_string data

let read_frame ic =
  Lwt_io.read_char ic >>= fun first -> Lwt_io.read_char ic >>= fun second ->
  let b0 = Char.code first and b1 = Char.code second in
  let n = b1 land 127 in
  (if n = 126 then read_exact ic 2 >|= fun s ->
    (Char.code s.[0] lsl 8) lor Char.code s.[1]
   else if n = 127 then read_exact ic 8 >|= fun s ->
     String.fold_left (fun n byte -> (n lsl 8) lor Char.code byte) 0 s
   else Lwt.return n) >>= fun count ->
  read_exact ic count >|= fun payload -> b0 land 15, payload

let client_frame content =
  let n = String.length content in
  let header = if n < 126 then String.make 1 (Char.chr (0x80 lor n))
    else if n < 65536 then String.make 1 '\xfe' ^
      String.init 2 (fun i -> Char.chr ((n lsr (8 * (1-i))) land 255))
    else failwith "golden command exceeds 64 KiB" in
  let mask = "\x12\x34\x56\x78" in
  "\x81" ^ header ^ mask ^
  String.init n (fun i -> Char.chr (Char.code content.[i] lxor Char.code mask.[i mod 4]))

type client = { ic : Lwt_io.input_channel; oc : Lwt_io.output_channel }
let send c text = Lwt_io.write c.oc (client_frame text) >>= fun () -> Lwt_io.flush c.oc

let read_status ic =
  Lwt_io.read_line ic >>= fun status ->
  let rec headers acc = Lwt_io.read_line ic >>= fun line ->
    let line = String.trim line in
    if line = "" then Lwt.return (status, List.rev acc)
    else (match String.split_on_char ':' line with
      | name :: rest -> headers ((String.lowercase_ascii name, String.trim (String.concat ":" rest))::acc)
      | _ -> headers acc) in
  headers []

let read_http_body ic headers =
  match List.assoc_opt "transfer-encoding" headers with
  | Some value when String.lowercase_ascii value = "chunked" ->
      let out = Buffer.create 64 in
      let rec chunks () =
        Lwt_io.read_line ic >>= fun line ->
        let size = int_of_string ("0x" ^ String.trim line) in
        if size = 0 then Lwt_io.read_line ic >|= fun _ -> Buffer.contents out
        else read_exact ic size >>= fun data ->
          Buffer.add_string out data;
          read_exact ic 2 >>= fun _ -> chunks () in
      chunks ()
  | _ -> (match List.assoc_opt "content-length" headers with
      | Some length -> read_exact ic (int_of_string length)
      | None -> Lwt_io.read ic)

let connect port ~origin ?cookie () =
  let host = Printf.sprintf "127.0.0.1:%d" port in
  Lwt_io.open_connection (Unix.ADDR_INET (Unix.inet_addr_loopback, port)) >>= fun (ic, oc) ->
  let req = "GET /cable HTTP/1.1\r\nHost: " ^ host ^
    "\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nOrigin: " ^ origin ^
    "\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" ^
    "\r\nSec-WebSocket-Protocol: actioncable-v1-json, actioncable-unsupported" ^
    (match cookie with None -> "" | Some value -> "\r\nCookie: " ^ value) ^ "\r\n\r\n" in
  Lwt_io.write oc req >>= fun () -> Lwt_io.flush oc >>= fun () ->
  read_status ic >>= fun (status, headers) ->
  if String.starts_with ~prefix:"HTTP/1.1 101" status then
    let protocol = Option.value ~default:"" (List.assoc_opt "sec-websocket-protocol" headers) in
    Lwt.return (Some {ic;oc}, ["upgrade 101 protocol=" ^ protocol])
  else
    read_http_body ic headers >>= fun body ->
    Lwt_io.close oc >>= fun () -> Lwt_io.close ic >|= fun () ->
    None, ["http " ^ (if String.contains status '4' then "404" else status) ^ " " ^ body]

let normalize_ping text =
  let value = Yojson.Basic.from_string text in
  match field "message" value with
  | `Int timestamp ->
      let needle = string_of_int timestamp in
      let start = String.length "{\"type\":\"ping\",\"message\":" in
      String.sub text 0 start ^ "<unix>" ^
      String.sub text (start + String.length needle) (String.length text - start - String.length needle)
  | _ -> Alcotest.failf "Cable ping lacks Unix integer: %s" text

let collect c ~await_ping ~at_least =
  let expected_by = Unix.gettimeofday () +. 10. in
  let rec loop frames =
    let timeout = if List.length frames < at_least
      then max 0.01 (expected_by -. Unix.gettimeofday ())
      else if await_ping then 4. else 0.4 in
    Lwt.catch (fun () ->
      Lwt_unix.with_timeout timeout (fun () -> read_frame c.ic) >>= fun (opcode,payload) ->
      match opcode with
      | 1 when String.starts_with ~prefix:"{\"type\":\"ping\"" payload ->
          if await_ping then Lwt.return (List.rev (normalize_ping payload :: frames))
          else loop frames
      | 1 -> loop (payload::frames)
      | 8 ->
          let code = if String.length payload >= 2
            then (Char.code payload.[0] lsl 8) lor Char.code payload.[1] else 0 in
          let reason = if String.length payload > 2
            then String.sub payload 2 (String.length payload - 2) else "" in
          let close = if String.length payload = 0 then "close None"
            else Printf.sprintf "close Some((%d, %S))" code reason in
          loop (close::frames)
      | _ -> loop frames)
      (function
        | Lwt_unix.Timeout -> Lwt.return (List.rev frames)
        | End_of_file -> Lwt.return (List.rev ("end"::frames))
        | exn -> Lwt.fail exn) in
  loop []

let encode = Rails_format.encode
let identifier channel fields = encode (`Assoc (("channel",`String channel)::fields))
let command name id = encode (`Assoc ["command",`String name;"identifier",`String id])
let perform id data = encode (`Assoc ["command",`String "message";
  "identifier",`String id;"data",`String (encode data)])

let step_command tokens step =
  let room_id = int_of_string (string "ROOM_ID" tokens) in
  let closed_id = int_of_string (string "CLOSED_ROOM_ID" tokens) in
  let room id = identifier "RoomChannel" ["room_id",`Int id] in
  let typing = identifier "TypingNotificationsChannel" ["room_id",`Int room_id] in
  let turbo value = identifier "Turbo::StreamsChannel" ["signed_stream_name",`String value] in
  let subscribe id = command "subscribe" id in
  match step with
  | "subscribe heartbeat" | "subscribe heartbeat again" -> subscribe (identifier "HeartbeatChannel" [])
  | "subscribe member room" -> subscribe (room room_id)
  | "subscribe non-member room" -> subscribe (room closed_id)
  | "subscribe unknown channel" -> subscribe (identifier "NopeChannel" [])
  | "subscribe base channel" -> subscribe (identifier "ApplicationCable::Channel" [])
  | "subscribe turbo rooms" -> subscribe (turbo (string "ROOMS_SIGNED" tokens))
  | "subscribe turbo forged" -> subscribe (turbo "InJvb21zIg==--0000")
  | "subscribe turbo unsigned" -> subscribe (identifier "Turbo::StreamsChannel" [])
  | "subscribe turbo guarded room messages" -> subscribe (turbo (string "ROOM_MESSAGES_SIGNED" tokens))
  | "subscribe typing" -> subscribe typing
  | "perform typing start" -> perform typing (`Assoc ["action",`String "start"])
  | "perform unknown action" -> perform typing (`Assoc ["action",`String "dance"])
  | "perform default receive" -> perform typing (`Assoc ["text",`String "hi"])
  | "unsubscribe typing" -> command "unsubscribe" typing
  | "perform after unsubscribe" -> perform typing (`Assoc ["action",`String "start"])
  | "unknown command" -> encode (`Assoc ["command",`String "dance"])
  | "invalid json" -> "not json"
  | _ -> Alcotest.failf "unknown scripted step %s" step

let prepare_fixture db tokens =
  let user_id = Int64.of_string (string "USER_ID" tokens) in
  let room_id = Int64.of_string (string "ROOM_ID" tokens) in
  let closed_id = Int64.of_string (string "CLOSED_ROOM_ID" tokens) in
  let at = "2026-10-08 12:00:00" in
  Db_runtime.write db (fun tx ->
    let conn = Db_runtime.conn tx in
    ignore (Db_runtime.execute conn "UPDATE users SET name=? WHERE id=?"
      [Sqlite3.Data.TEXT (string "USER_NAME" tokens); Sqlite3.Data.INT user_id]);
    let add_room id kind creator name =
      ignore (Db_runtime.execute conn
        "INSERT INTO rooms (id,created_at,creator_id,name,type,updated_at) VALUES (?,?,?,?,?,?)"
        [Sqlite3.Data.INT id; Sqlite3.Data.TEXT at; Sqlite3.Data.INT creator;
         Sqlite3.Data.TEXT name; Sqlite3.Data.TEXT kind; Sqlite3.Data.TEXT at]) in
    add_room room_id "Rooms::Open" user_id "Golden";
    add_room closed_id "Rooms::Closed" 127326141L "Private";
    ignore (Db_runtime.execute conn
      "INSERT INTO memberships (created_at,involvement,room_id,updated_at,user_id) VALUES (?,?,?,?,?)"
      [Sqlite3.Data.TEXT at; Sqlite3.Data.TEXT "everything";
       Sqlite3.Data.INT room_id; Sqlite3.Data.TEXT at; Sqlite3.Data.INT user_id]));
  user_id

let assert_step session step expected actual =
  Alcotest.(check (list string)) (session ^ " / " ^ step) expected actual

let replay () = with_seed (fun db ->
  let golden = Yojson.Basic.from_file golden_path in
  let tokens = field "tokens" golden in
  let sessions = field "sessions" golden in
  let steps_count = assoc sessions |> List.fold_left (fun n (_,items) ->
    n + List.length (match items with `List xs -> xs | _ -> [])) 0 in
  Alcotest.(check int) "pinned golden scripted steps" 26 steps_count;
  let user_id = prepare_fixture db tokens in
  let secret = fixture_secret () in
  let session = Db_runtime.write db (fun tx ->
    Db_accounts.Session.start (Db_runtime.conn tx) ~now ~user_id
      ~user_agent:None ~ip_address:None) in
  let cookie = "session_token=" ^ Authentication.issue_token_cookie
    ~secret_key_base:secret ~now session.token in
  let cable = Cable_channels.create ~db ~secret_key_base:secret
    ~now:(fun () -> now) () in
  let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let port = match Unix.getsockname sock with Unix.ADDR_INET (_,p) -> p | _ -> assert false in
  Unix.close sock;
  let stop, wake = Lwt.wait () in
  let server = Http_app.serve ~runtime:db ~secret_key_base:secret
    ~port ~stop ~cable ~cable_run:(Cable_channels.run cable)
    ~event_sink:(Cable_channels.event_sink cable)
    ~dispatch:App_dispatch.endpoint () in
  let origin = Printf.sprintf "http://127.0.0.1:%d" port in
  Lwt_main.run (Lwt.finalize (fun () ->
    Lwt.async (fun () -> server);
    Lwt_unix.sleep 0.04 >>= fun () ->
    let replay_session session =
      let exchanges = list session sessions in
      let socket = ref None in
      let rec steps = function
        | [] -> Lwt.return_unit
        | exchange :: remaining ->
            let step = string "step" exchange in
            let expected = string_list "frames" exchange in
            let captured = match step with
              | "connect" ->
                  let origin = if session = "cross origin" then "http://evil.example" else origin in
                  connect port ~origin ?cookie:(if session = "unauthenticated" then None else Some cookie) ()
                  >>= fun (opened,initial) ->
                  socket := opened;
                  (match opened with None -> Lwt.return initial
                   | Some c -> collect c ~await_ping:false ~at_least:(max 0 (List.length expected - 1))
                       >|= fun frames -> initial @ frames)
              | "get" ->
                  Lwt_io.open_connection (Unix.ADDR_INET (Unix.inet_addr_loopback,port))
                  >>= fun (ic,oc) ->
                  let host = Printf.sprintf "127.0.0.1:%d" port in
                  Lwt_io.write oc ("GET /cable HTTP/1.1\r\nHost: " ^ host ^
                    "\r\nConnection: close\r\n\r\n") >>= fun () ->
                  Lwt_io.flush oc >>= fun () -> read_status ic >>= fun (status,headers) ->
                  read_http_body ic headers >>= fun body ->
                  Lwt_io.close oc >>= fun () -> Lwt_io.close ic >|= fun () ->
                  ["http " ^ (if String.contains status '4' then "404" else status) ^ " " ^
                    Option.value ~default:"" (List.assoc_opt "content-type" headers) ^ " " ^
                    body]
              | "ping" -> collect (Option.get !socket) ~await_ping:true ~at_least:0
              | "sign out" ->
                  ignore (Cable_channels.disconnect_user cable ~user_id ~reconnect:true);
                  collect (Option.get !socket) ~await_ping:false ~at_least:(List.length expected)
              | _ ->
                  let c = Option.get !socket in
                  send c (step_command tokens step) >>= fun () ->
                  collect c ~await_ping:false ~at_least:(List.length expected) in
            captured >>= fun actual ->
            assert_step session step expected actual;
            steps remaining in
      steps exchanges in
    Lwt_list.iter_s replay_session
      ["authenticated";"remote disconnect";"unauthenticated";"cross origin";"plain http"])
    (fun () -> Lwt.wakeup_later wake (); Lwt.return_unit)))

let () = Alcotest.run "M5 pinned Cable golden replay" [
  "reference", [Alcotest.test_case "all 26 scripted steps on same listener" `Slow
    (fun () -> if Sys.getenv_opt "CAMPFIRE_LIVE_CABLE_GOLDEN" = Some "1" then replay ())]
]

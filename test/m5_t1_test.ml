open Lwt.Infix
module Cable = Campfire.Cable_transport

external deflate_raw : string -> string = "campfire_cable_deflate"
external inflate_raw : string -> int -> string = "campfire_cable_inflate"

let request ?(origin="https://campfire.test") ?(version="13")
    ?(key="dGhlIHNhbXBsZSBub25jZQ==") ?(extensions="")
    ?(protocols="actioncable-v1-json") () =
  let headers = Cohttp.Header.of_list
    (["host", "campfire.test"; "connection", "keep-alive, Upgrade";
      "upgrade", "websocket"; "origin", origin; "sec-websocket-version", version;
      "sec-websocket-key", key; "sec-websocket-protocol", protocols]
    @ if extensions = "" then [] else ["sec-websocket-extensions", extensions]) in
  Cohttp.Request.make ~meth:`GET ~headers (Uri.of_string "/cable")

let response ?config req =
  Lwt_main.run (Cable.handle ?config req ~run:(fun _ -> Lwt.return_unit))

let response_code = function
  | `Response (r, _) | `Expert (r, _) -> Cohttp.Code.code_of_status (Cohttp.Response.status r)

let handshake () =
  let ok = response (request ~extensions:"permessage-deflate; client_max_window_bits" ()) in
  Alcotest.(check int) "upgrade" 101 (response_code ok);
  (match ok with `Expert (rsp, _) ->
    let headers = Cohttp.Response.headers rsp in
    Alcotest.(check (option string)) "RFC accept" (Some "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
      (Cohttp.Header.get headers "sec-websocket-accept");
    Alcotest.(check (option string)) "subprotocol" (Some "actioncable-v1-json")
      (Cohttp.Header.get headers "sec-websocket-protocol");
    Alcotest.(check (option string)) "deflate" (Some "permessage-deflate; server_no_context_takeover; client_no_context_takeover")
      (Cohttp.Header.get headers "sec-websocket-extensions")
  | _ -> Alcotest.fail "expected expert");
  List.iter (fun (name, req) ->
    Alcotest.(check int) name 404 (response_code (response req)))
    ["cross origin", request ~origin:"https://other.test" ();
      "wrong version", request ~version:"8" ();
      "bad key", request ~key:"abc" ();
      "missing key", request ~key:"" ()];
  let cfg = { Cable.default_config with assume_ssl = false } in
  Alcotest.(check int) "scheme enforced" 404 (response_code (response ~config:cfg (request ())));
  Alcotest.(check int) "HTTP same origin" 101
    (response_code (response ~config:cfg (request ~origin:"http://campfire.test" ())));
  let rsp = response (request ~protocols:"actioncable-unsupported, actioncable-v1-json" ()) in
  (match rsp with `Expert (r, _) ->
    Alcotest.(check (option string)) "client protocol order" (Some "actioncable-unsupported")
      (Cohttp.Header.get (Cohttp.Response.headers r) "sec-websocket-protocol")
  | _ -> Alcotest.fail "expected expert")

let int16 n = String.init 2 (function 0 -> Char.chr ((n lsr 8) land 255) | _ -> Char.chr (n land 255))
let frame ?(fin=true) ?(rsv1=false) opcode content =
  let n = String.length content in
  let b0 = (if fin then 0x80 else 0) lor (if rsv1 then 0x40 else 0) lor opcode in
  let head = String.make 1 (Char.chr b0) in
  let len = if n < 126 then String.make 1 (Char.chr (0x80 lor n))
    else if n <= 65535 then String.make 1 (Char.chr 0xfe) ^ int16 n
    else String.make 1 (Char.chr 0xff) ^
      String.init 8 (fun i -> Char.chr ((n lsr ((7 - i) * 8)) land 255)) in
  let mask = "\x12\x34\x56\x78" in
  let masked = String.init n (fun i -> Char.chr (Char.code content.[i] lxor Char.code mask.[i mod 4])) in
  head ^ len ^ mask ^ masked

let read_server_frame ic =
  Lwt_io.read_char ic >>= fun first -> Lwt_io.read_char ic >>= fun second ->
  let n = Char.code second land 0x7f in
  (if n = 126 then Lwt_io.read ~count:2 ic >|= fun s ->
     (Char.code s.[0] lsl 8) lor Char.code s.[1]
   else if n = 127 then Lwt_io.read ~count:8 ic >|= fun s ->
     let len = ref 0 in String.iter (fun c -> len := (!len lsl 8) lor Char.code c) s; !len
   else Lwt.return n) >>= fun len ->
  (if len = 0 then Lwt.return "" else Lwt_io.read ~count:len ic)
  >|= fun payload -> (Char.code first, Char.code second, payload)

let with_expert ?(extensions="") input run collect =
  let req = request ~extensions () in
  Lwt_main.run (Lwt_unix.with_timeout 3. (fun () -> Cable.handle req ~run >>= function
    | `Response _ -> Alcotest.fail "expected upgrade"
    | `Expert (_, expert) ->
      let server_ic, client_oc = Lwt_io.pipe () in
      let client_ic, server_oc = Lwt_io.pipe () in
      let server = expert server_ic server_oc in
      Lwt_io.write client_oc input >>= fun () -> Lwt_io.flush client_oc >>= fun () ->
      collect client_ic >>= fun result -> server >|= fun () -> result))

let text_fragment_ping () =
  let seen = ref [] in
  let input = frame ~fin:false 1 "hel" ^ frame 9 "p" ^ frame 0 "lo ☃"
    ^ frame 8 (int16 1001) in
  let run c = Cable.read c >>= fun msg ->
    seen := msg :: !seen;
    Cable.read c >|= fun msg -> seen := msg :: !seen in
  let pong, close = with_expert input run (fun ic ->
    read_server_frame ic >>= fun pong -> read_server_frame ic >|= fun close -> pong, close) in
  Alcotest.(check string) "fragmented text" "hello ☃"
    (match List.rev !seen with Cable.Text s :: _ -> s | _ -> "");
  Alcotest.(check int) "pong opcode" 10 (let b, _, _ = pong in b land 0xf);
  Alcotest.(check string) "pong payload" "p" (let _, _, s = pong in s);
  Alcotest.(check int) "close opcode" 8 (let b, _, _ = close in b land 0xf);
  Alcotest.(check string) "close code echoed" (int16 1001) (let _, _, s = close in s)

let compressed_roundtrip () =
  let large = String.concat "" (List.init 100 (fun _ -> "compressed message ")) in
  let received = ref None in
  let input = frame ~rsv1:true 1 (deflate_raw large) ^ frame 8 (int16 1000) in
  let run c = Cable.read c >>= fun msg ->
    received := Some msg;
    Cable.send_text c large in
  let outgoing = with_expert ~extensions:"permessage-deflate; client_max_window_bits"
      input run read_server_frame in
  Alcotest.(check string) "inflate inbound" large
    (match !received with Some (Cable.Text s) -> s | _ -> "");
  let b, _, compressed = outgoing in
  Alcotest.(check bool) "RSV1 on outbound" true (b land 0x40 <> 0);
  Alcotest.(check string) "outbound inflate" large (inflate_raw compressed (1 lsl 20))

let bounded_batch () =
  let texts = List.init 64 (fun n -> string_of_int n) in
  let run c =
    Cable.send_texts c texts >>= fun () ->
    Alcotest.(check bool) "65th frame refused" true
      (match Cable.send_texts c (texts @ ["extra"]) with
       | exception Invalid_argument _ -> true | _ -> false);
    Lwt.return_unit in
  let actual = with_expert "" run (fun ic ->
    Lwt_list.map_s (fun _ -> read_server_frame ic >|= fun (b,_,payload) ->
      Alcotest.(check int) "text opcode" 1 (b land 15); payload) texts) in
  Alcotest.(check (list string)) "64 frames in order" texts actual

let oversized_header () =
  (* Advertise 1 MiB + 1 bytes and send no payload; close must arrive immediately. *)
  let bad = "\x81\xff\x00\x00\x00\x00\x00\x10\x00\x01\x12\x34\x56\x78" in
  let run c = Cable.read c >|= fun _ -> () in
  let code = with_expert bad run (fun ic ->
    read_server_frame ic >|= fun (_, _, payload) -> payload) in
  Alcotest.(check string) "too large close" (int16 1009) code;
  let half = String.make ((1 lsl 19) + 1) 'a' in
  let continuation_header = "\x80\xff\x00\x00\x00\x00\x00\x08\x00\x01\x12\x34\x56\x78" in
  let code = with_expert (frame ~fin:false 1 half ^ continuation_header) run
    (fun ic -> read_server_frame ic >|= fun (_, _, payload) -> payload) in
  Alcotest.(check string) "fragment budget from header" (int16 1009) code

let malformed_frames () =
  let code_for ?(extensions="") bytes =
    with_expert ~extensions bytes
      (fun c -> Cable.read c >|= fun _ -> ())
      (fun ic -> read_server_frame ic >|= fun (_, _, payload) -> payload) in
  let errors = [
    "unmasked", "\x81\x02hi", int16 1003;
    "bad UTF-8", frame 1 "\xff\xfe", int16 1007;
    "stray continuation", frame 0 "x", int16 1002;
    "fragmented control", frame ~fin:false 9 "x", int16 1002;
    "reserved opcode", frame 3 "x", int16 1002;
    "compressed unnegotiated", frame ~rsv1:true 1 (deflate_raw "hi"), int16 1002;
    "compressed continuation", frame ~rsv1:true 0 "x", int16 1002;
    "unmasked wins over too large", "\x81\x7f", int16 1003;
  ] in
  List.iter (fun (name, bytes, expected) ->
    let got = try code_for bytes with exn -> Alcotest.failf "%s: %s" name (Printexc.to_string exn) in
    Alcotest.(check string) name expected got) errors;
  let too_large = String.make ((1 lsl 20) + 1) 'a' in
  Alcotest.(check string) "inflated too large" (int16 1009)
    (code_for ~extensions:"permessage-deflate" (frame ~rsv1:true 1 (deflate_raw too_large)));
  Alcotest.(check string) "invalid deflate" (int16 1002)
    (code_for ~extensions:"permessage-deflate" (frame ~rsv1:true 1 "\xff\xff\xff\xff"));
  Alcotest.(check string) "compressed control" (int16 1002)
    (code_for ~extensions:"permessage-deflate" (frame ~rsv1:true 9 "x"));
  let empty_reply = with_expert (frame 8 "")
    (fun c -> Cable.read c >|= fun _ -> ())
    (fun ic -> read_server_frame ic >|= fun (_, _, payload) -> payload) in
  Alcotest.(check string) "empty close reply" "" empty_reply

let live_listener () =
  let unused_port () =
    let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
    let port = match Unix.getsockname socket with Unix.ADDR_INET (_, port) -> port | _ -> assert false in
    Unix.close socket;
    port in
  let port = unused_port () in
  let plain_port = unused_port () in
  let path = Filename.temp_file "campfire-cable-listener-" ".sqlite3" in
  let runtime = Campfire.Db_runtime.open_db path in
  Fun.protect ~finally:(fun () -> Campfire.Db_runtime.close runtime; Sys.remove path) (fun () ->
  let stop, wake_stop = Lwt.wait () in
  let plain_stop, wake_plain_stop = Lwt.wait () in
  let seen_cookie = ref None in
  let run request c =
    seen_cookie := Cohttp.Header.get (Cohttp.Request.headers request) "cookie";
    Cable.send_text c "{\"type\":\"welcome\"}" >>= fun () -> Cable.send_close c in
  let dispatch endpoint = if endpoint = "welcome#show" then
    Some Campfire.Http_app.{ before_action = (fun _ -> Lwt.return (Ok ()));
      action = (fun _ -> Lwt.return (text ~status:200 "ordinary response")) }
    else None in
  let server = Campfire.Http_app.serve ~runtime ~secret_key_base:"unused" ~ssl:true
      ~port ~stop ~dispatch ~cable_run:run () in
  let plain_server = Campfire.Http_app.serve ~runtime ~secret_key_base:"unused"
      ~ssl:true ~port:plain_port ~stop:plain_stop ~dispatch () in
  let probe port origin =
    Lwt_io.open_connection (Unix.ADDR_INET (Unix.inet_addr_loopback, port)) >>= fun (ic, oc) ->
    let request = "GET /cable HTTP/1.1\r\nHost: campfire.test\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nOrigin: " ^ origin ^
      "\r\nCookie: session_token=test-fixture\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Protocol: actioncable-v1-json\r\n\r\n" in
    Lwt_io.write oc request >>= fun () -> Lwt_io.flush oc >>= fun () ->
    Lwt_io.read_line ic >>= fun status ->
    let rec headers () = Lwt_io.read_line ic >>= fun line ->
      if String.trim line = "" then Lwt.return_unit else headers () in
    headers () >>= fun () ->
    (if String.starts_with ~prefix:"HTTP/1.1 101" status
      then read_server_frame ic >|= fun (_, _, payload) -> status, Some payload
      else Lwt.return (status, None)) >>= fun result ->
    Lwt_io.close oc >>= fun () -> Lwt_io.close ic >|= fun () -> result in
  let probe_http () =
    Lwt_io.open_connection (Unix.ADDR_INET (Unix.inet_addr_loopback, port)) >>= fun (ic, oc) ->
    Lwt_io.write oc "GET / HTTP/1.1\r\nHost: campfire.test\r\nConnection: close\r\n\r\n"
    >>= fun () -> Lwt_io.flush oc >>= fun () -> Lwt_io.read_line ic >>= fun status ->
    Lwt_io.close oc >>= fun () -> Lwt_io.close ic >|= fun () -> status in
  Lwt_main.run (Lwt.finalize (fun () ->
    Lwt.async (fun () -> server);
    Lwt.async (fun () -> plain_server);
    Lwt_unix.sleep 0.02 >>= fun () ->
    probe port "https://campfire.test" >>= fun accepted ->
    probe port "https://other.test" >>= fun rejected ->
    probe plain_port "https://campfire.test" >>= fun unconfigured ->
    probe_http () >|= fun ordinary -> accepted, rejected, unconfigured, ordinary)
    (fun () -> Lwt.wakeup_later wake_stop (); Lwt.wakeup_later wake_plain_stop (); Lwt.return_unit))
  |> fun ((status, welcome), (rejected, _), (plain_cable, _), ordinary) ->
     Alcotest.(check bool) "live upgrade 101" true (String.starts_with ~prefix:"HTTP/1.1 101" status);
     Alcotest.(check (option string)) "live welcome" (Some "{\"type\":\"welcome\"}") welcome;
     Alcotest.(check (option string)) "upgrade request cookie reaches runner"
       (Some "session_token=test-fixture") !seen_cookie;
     Alcotest.(check bool) "live origin rejection" true (String.starts_with ~prefix:"HTTP/1.1 404" rejected);
     Alcotest.(check bool) "ordinary HTTP on same listener" true
       (String.starts_with ~prefix:"HTTP/1.1 200" ordinary);
     Alcotest.(check bool) "unconfigured cable remains 404" true
       (String.starts_with ~prefix:"HTTP/1.1 404" plain_cable))

let () = Alcotest.run "m5 cable transport" [
  "handshake", [Alcotest.test_case "origin, version, protocol and compression" `Quick handshake];
  "frames", [
    Alcotest.test_case "fragmented text, ping, close" `Quick text_fragment_ping;
    Alcotest.test_case "compressed messages" `Quick compressed_roundtrip;
    Alcotest.test_case "64-frame write batch" `Quick bounded_batch;
    Alcotest.test_case "oversized header before payload" `Quick oversized_header;
    Alcotest.test_case "malformed frame close codes" `Quick malformed_frames;
    Alcotest.test_case "live Cohttp handshake" `Quick (fun () ->
      if Sys.getenv_opt "CAMPFIRE_LIVE_CABLE_TEST" = Some "1" then live_listener ());
  ];
]

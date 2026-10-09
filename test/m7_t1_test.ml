open Alcotest
open Lwt.Infix

let config values =
  let get name = List.assoc_opt name values in
  Campfire.Front_config.from_lookup get

let request headers =
  Cohttp.Request.make ~meth:`GET
    ~headers:(Cohttp.Header.of_list headers) (Uri.of_string "/up")

let get request name = Cohttp.Header.get (Cohttp.Request.headers request) name

let defaults () =
  let c = config [] in
  check (triple int int int) "ports" (80,443,3000)
    (c.http_port,c.https_port,c.target_port);
  check string "loopback target" "127.0.0.1" c.target_bind;
  check bool "forward without TLS" true c.forward_headers;
  check int "idle timeout" 60 c.http_idle_timeout;
  check int "read timeout" 30 c.http_read_timeout;
  check int "cache bytes" (64 * 1024 * 1024) c.cache_size;
  check bool "gzip" true c.gzip_compression_enabled

let precedence () =
  let c = config ["HTTP_PORT","8080";"THRUSTER_HTTP_PORT","9090";
    "TLS_DOMAIN","chat.example.com";"HTTP_READ_TIMEOUT","5s"] in
  check int "prefixed port" 9090 c.http_port;
  check int "bad duration fallback" 30 c.http_read_timeout;
  check bool "TLS distrusts incoming forwarding" false c.forward_headers;
  let c = config ["TLS_DOMAIN","chat.example.com";"FORWARD_HEADERS","true"] in
  check bool "explicit forwarding" true c.forward_headers

let boundary () =
  let c = config ["TLS_DOMAIN","chat.example.com"] in
  let headers = ["host","chat.example.com:18443";"x-campfire-front","caddy";
    "x-forwarded-host","chat.example.com";
    "x-forwarded-for","203.0.113.5";"x-forwarded-proto","https";
    "x-campfire-original-forwarded-for","198.51.100.8";
    "x-campfire-original-forwarded-proto","http";
    "x-campfire-original-forwarded-host","evil.example"] in
  let normalized,ip,tls = Campfire.Front_proxy.prepare
    ~config:c ~peer:"127.0.0.1" (request headers) in
  check string "real peer" "203.0.113.5" ip;
  check (option bool) "TLS from proxy" (Some true) tls;
  check (option string) "real host and port" (Some "chat.example.com:18443")
    (get normalized "host");
  check (option string) "forwarded host and port" (Some "chat.example.com:18443")
    (get normalized "x-forwarded-host");
  check (option string) "private header removed" None
    (get normalized "x-campfire-original-forwarded-for");
  let untrusted,ip,tls = Campfire.Front_proxy.prepare
    ~config:c ~peer:"203.0.113.6" (request headers) in
  check string "untrusted peer" "203.0.113.6" ip;
  check (option bool) "untrusted TLS" None tls;
  check (option string) "untrusted unchanged" (Some "evil.example")
    (get untrusted "x-campfire-original-forwarded-host")

let forwarding_enabled () =
  let c = config ["FORWARD_HEADERS","true"] in
  let normalized,ip,tls = Campfire.Front_proxy.prepare ~config:c
    ~peer:"127.0.0.1" (request ["x-campfire-front","caddy";
      "x-forwarded-for","203.0.113.5";
      "x-campfire-original-forwarded-for","198.51.100.8";
      "x-campfire-original-forwarded-host","edge.example";
      "x-campfire-original-forwarded-proto","https"]) in
  check string "original forwarded peer" "198.51.100.8" ip;
  check (option string) "original host" (Some "edge.example") (get normalized "host");
  check (option bool) "original scheme" (Some true) tls

let config_text () =
  let c = config ["TLS_DOMAIN","chat.example.com";
    "HTTP_PORT","18080";"HTTPS_PORT","18443";
    "MAX_REQUEST_BODY","1024";
    "ACME_DIRECTORY","https://acme.test/directory";
    "EAB_KID","kid";"EAB_HMAC_KEY","secret"] in
  let text = Campfire.Front_config.caddyfile c in
  let contains needle =
    let re = Str.regexp_string needle in
    try ignore (Str.search_forward re text 0); true with Not_found -> false in
  check bool "canonical redirect" true
    (contains "redir https://chat.example.com{uri} permanent");
  check bool "body limit delegated to Cohttp" false (contains "max_size 1024");
  check bool "external header limit" true (contains "max_header_size 64KiB");
  check bool "ACME directory" true (contains "https://acme.test/directory");
  check bool "EAB" true (contains "eab \"kid\" \"secret\"");
  check bool "no duplicate gzip" false (contains "encode gzip");
  check bool "no duplicate cache" false (contains "cache {")

let issuer_keys () =
  let default = config [] in
  check string "Let's Encrypt storage key" "acme-v02.api.letsencrypt.org-directory"
    (Campfire.Front_config.acme_issuer_key default);
  let local = config ["ACME_DIRECTORY","https://127.0.0.1:14000/dir"] in
  check string "Pebble storage key" "127.0.0.1-14000-dir"
    (Campfire.Front_config.acme_issuer_key local)

let unsafe_domain () =
  let c = config ["TLS_DOMAIN","chat.example.com\nrespond hacked"] in
  let rejected = try ignore (Campfire.Front_config.caddyfile c); false
    with Invalid_argument _ -> true in
  check bool "invalid domain rejected" true rejected

let free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect ~finally:(fun () -> Unix.close socket) (fun () ->
    Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback,0));
    match Unix.getsockname socket with
    | Unix.ADDR_INET (_,port) -> port | _ -> assert false)

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path |> Array.iter (fun name ->
        remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path

let live_long_websocket () =
  if Sys.getenv_opt "CAMPFIRE_LIVE_M7_T1" <> Some "1" then () else
  let port = free_port () in
  let path = Filename.temp_file "campfire-front-timeout-" ".sqlite3" in
  let runtime = Campfire.Db_runtime.open_db path in
  Fun.protect ~finally:(fun () ->
    Campfire.Db_runtime.close runtime;
    Sys.remove path) (fun () ->
  let stop,wake_stop = Lwt.wait () in
  let limits = config ["HTTP_READ_TIMEOUT","1";
    "HTTP_WRITE_TIMEOUT","1";"HTTP_IDLE_TIMEOUT","1"] in
  let run _request connection =
    Campfire.Cable_transport.send_text connection "welcome" >>= fun () ->
    Campfire.Cable_transport.read connection >>= function
    | Campfire.Cable_transport.Text "ping" ->
        Campfire.Cable_transport.send_text connection "pong"
    | _ -> Lwt.return_unit in
  let server = Campfire.Http_app.serve ~runtime ~secret_key_base:"unused"
    ~port ~stop ~ssl:true ~front_config:limits ~cable_run:run
    ~dispatch:(fun _ -> None) () in
  let read_frame ic =
    Lwt_io.read_char ic >>= fun first ->
    Lwt_io.read_char ic >>= fun second ->
    let length = Char.code second land 0x7f in
    if length >= 126 then Alcotest.fail "unexpected extended frame"
    else Lwt_io.read ~count:length ic >|= fun body ->
      Char.code first,body in
  let probe port label =
    Lwt_io.open_connection (Unix.ADDR_INET (Unix.inet_addr_loopback,port))
    >>= fun (ic,oc) ->
    Lwt.finalize (fun () ->
      let request = "GET /cable HTTP/1.1\r\nHost: campfire.test\r\n" ^
        "Connection: Upgrade\r\nUpgrade: websocket\r\n" ^
        "Origin: " ^ (if label = "direct" then "https" else "http") ^
        "://campfire.test\r\n" ^
        "Sec-WebSocket-Version: 13\r\n" ^
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n" in
      Lwt_io.write oc request >>= fun () -> Lwt_io.flush oc >>= fun () ->
      Lwt_io.read_line ic >>= fun status ->
      let rec headers () = Lwt_io.read_line ic >>= fun line ->
        if String.trim line = "" then Lwt.return_unit else headers () in
      headers () >>= fun () ->
      check bool "upgrade accepted" true
        (String.starts_with ~prefix:"HTTP/1.1 101" status);
      read_frame ic >>= fun (_,welcome) ->
      check string "welcome" "welcome" welcome;
      Lwt_unix.sleep 2.2 >>= fun () ->
      let payload = "ping" and mask = "\x12\x34\x56\x78" in
      let frame = "\x81\x84" ^ mask ^ String.init 4 (fun i ->
        Char.chr (Char.code payload.[i] lxor Char.code mask.[i])) in
      Lwt_io.write oc frame >>= fun () -> Lwt_io.flush oc >>= fun () ->
      read_frame ic >|= fun (_,reply) ->
      check string (label ^ " survives three one-second deadlines") "pong" reply)
    (fun () ->
      Lwt.catch (fun () -> Lwt_io.close oc) (fun _ -> Lwt.return_unit)) in
  Lwt_main.run (Lwt.finalize (fun () ->
    Lwt.async (fun () -> server);
    Lwt_unix.sleep 0.03 >>= fun () ->
    Lwt_unix.with_timeout 5. (fun () -> probe port "direct") >>= fun () ->
    match Sys.getenv_opt "CAMPFIRE_CADDY_BIN" with
    | None -> Lwt.return_unit
    | Some caddy ->
        let front_port = free_port () in
        let storage = Filename.temp_file "campfire-front-ws-" "" in
        Sys.remove storage;
        Unix.mkdir storage 0o700;
        let config_path = Filename.concat storage "Caddyfile" in
        let front_config = config [
          "TARGET_PORT",string_of_int port;
          "HTTP_PORT",string_of_int front_port;
          "STORAGE_PATH",storage;
          "HTTP_READ_TIMEOUT","1";
          "HTTP_WRITE_TIMEOUT","1";
          "HTTP_IDLE_TIMEOUT","1"] in
        let output = open_out config_path in
        output_string output (Campfire.Front_config.caddyfile front_config);
        close_out output;
        let process = Lwt_process.open_process_none
          ~stdout:`Dev_null ~stderr:`Dev_null
          (caddy,[|caddy;"run";"--config";config_path;
            "--adapter";"caddyfile"|]) in
        Lwt.finalize (fun () ->
          Lwt_unix.sleep 0.15 >>= fun () ->
          Lwt_unix.with_timeout 5. (fun () -> probe front_port "Caddy front"))
          (fun () ->
            process#kill Sys.sigterm;
            process#status >>= fun _ ->
            remove_tree storage;
            Lwt.return_unit))
    (fun () -> Lwt.wakeup_later wake_stop (); Lwt.return_unit)))

let () = run "front server" [
  "config", [
    test_case "defaults" `Quick defaults;
    test_case "precedence" `Quick precedence;
    test_case "Caddy config" `Quick config_text;
    test_case "invalid domain" `Quick unsafe_domain;
    test_case "issuer storage keys" `Quick issuer_keys];
  "proxy boundary", [
    test_case "TLS strips spoofed forwarded values" `Quick boundary;
    test_case "explicit trust preserves edge values" `Quick forwarding_enabled];
  "live", [test_case "WebSocket outlives HTTP deadlines" `Quick live_long_websocket]
]

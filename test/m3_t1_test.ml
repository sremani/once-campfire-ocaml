open Campfire
open Lwt.Infix

let vectors () =
  let open Yojson.Basic.Util in
  let cases = Yojson.Basic.from_file "fixtures/params_vectors.json" |> to_list in
  Alcotest.(check int) "pinned Rails parser vector count" 2755 (List.length cases);
  List.iteri (fun i case ->
    let input = member "input" case |> to_string in
    let expected = member "output" case in
    let actual = Http_params.parse_nested input in
    if actual <> expected then
      Alcotest.failf "params vector %d input=%S expected=%s actual=%s"
        i input (Yojson.Basic.to_string expected) (Yojson.Basic.to_string actual)) cases

let parser_errors () =
  let is_invalid = function Error (Http_params.Invalid _) -> true | _ -> false in
  let is_type = function Error (Http_params.Type _) -> true | _ -> false in
  Alcotest.(check bool) "bad percent is rejected" true (is_invalid (Http_params.parse_query "a=%"));
  Alcotest.(check bool) "bad UTF-8 is rejected" true (is_invalid (Http_params.parse_query "a=%FF"));
  Alcotest.(check bool) "scalar to array conflict" true (is_type (Http_params.parse_query "a=1&a[]=2"));
  Alcotest.(check bool) "scalar to hash conflict" true (is_type (Http_params.parse_query "a=1&a[b]=2"));
  let deep = "a" ^ String.concat "" (List.init 100 (fun _ -> "[b]")) ^ "=1" in
  Alcotest.(check bool) "depth limit" true (Http_params.parse_query deep = Error Http_params.Too_deep);
  let too_many = String.concat "&" (List.init 4097 (fun _ -> "a=1")) in
  Alcotest.(check bool) "form parameter count" true
    (match Http_params.parse_form too_many with Error (Http_params.Limit _) -> true | _ -> false);
  Alcotest.(check bool) "form byte limit" true
    (match Http_params.parse_form (String.make (4 * 1024 * 1024 + 1) 'a') with
     | Error (Http_params.Limit _) -> true | _ -> false)

let body_contracts () =
  Alcotest.(check bool) "content-type-less POST is a form" true
    (Http_app.body_params ~method_:"POST" None "x=1" =
     Ok ["x", Http_params.Text "1"]);
  Alcotest.(check bool) "empty JSON is empty params" true
    (Http_app.body_params ~method_:"POST" (Some "application/json") "" = Ok []);
  Alcotest.(check bool) "multipart without boundary falls back to form" true
    (Http_app.body_params ~method_:"POST" (Some "multipart/form-data") "x=1" =
     Ok ["x", Http_params.Text "1"])

let parse_multipart_stream ?(limit=Int64.mul 10L (Int64.mul 1024L (Int64.mul 1024L 1024L)))
    ~content_type chunks =
  Lwt_main.run (Http_params.parse_multipart_stream ~content_type ~limit
    (Lwt_stream.of_list chunks))

let with_multipart ~content_type chunks f =
  match parse_multipart_stream ~content_type chunks with
  | Error _ -> Alcotest.fail "valid multipart body rejected"
  | Ok (params, paths) ->
      Fun.protect ~finally:(fun () -> Http_params.cleanup_uploads paths)
        (fun () -> f params paths)

let multipart () =
  let boundary = "----campfire" in
  let body = "------campfire\r\nContent-Disposition: form-data; name=\"_method\"\r\n\r\npatch\r\n" ^
    "------campfire\r\nContent-Disposition: form-data; name=\"user[name]\"\r\n\r\nJo\r\n" ^
    "------campfire\r\nContent-Disposition: form-data; name=\"user[avatar]\"; filename=\"me.png\"\r\n" ^
    "Content-Type: image/png\r\n\r\nPNG\000DATA\r\n------campfire-not-a-delimiter\r\nEND\r\n------campfire--\r\n" in
  let prefix = Option.get (Http_params.find_sub body "\r\n------campfire-not" 0) in
  let cut = prefix + String.length "\r\n------campfire" in
  with_multipart ~content_type:("multipart/form-data; boundary=" ^ boundary)
    [String.sub body 0 cut; String.sub body cut (String.length body - cut)]
    (fun params paths ->
      Alcotest.(check (option string)) "override" (Some "patch") (Http_params.find_string "_method" params);
      match Http_params.find "user" params with
      | Some (Http_params.Object user) ->
          Alcotest.(check (option string)) "name" (Some "Jo") (Http_params.find_string "name" user);
          (match Http_params.find "avatar" user with
           | Some (Http_params.File file) ->
               Alcotest.(check string) "filename" "me.png" file.filename;
               Alcotest.(check int64) "size" (Int64.of_int (String.length
                 "PNG\000DATA\r\n------campfire-not-a-delimiter\r\nEND")) file.size;
               Alcotest.(check bool) "request temp owned" true (List.mem file.path paths);
               let input = open_in_bin file.path in
               let contents = Fun.protect ~finally:(fun () -> close_in input)
                 (fun () -> really_input_string input (Int64.to_int file.size)) in
               Alcotest.(check string) "binary content and boundary prefix"
                 "PNG\000DATA\r\n------campfire-not-a-delimiter\r\nEND" contents
           | _ -> Alcotest.fail "file part missing")
      | _ -> Alcotest.fail "user map missing")

let multipart_errors () =
  let content_type = "multipart/form-data; boundary=B" in
  let malformed = "--B\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\nx\r\n--B--oops" in
  Alcotest.(check bool) "malformed closing delimiter" true
    (parse_multipart_stream ~content_type [malformed] = Error Http_params.Parse);
  let blank_file = "--B\r\nContent-Disposition: form-data; name=\"f\"; filename=\"\"\r\n\r\nignored\r\n--B--\r\n" in
  Alcotest.(check bool) "blank filename dropped" true
    (parse_multipart_stream ~content_type [blank_file] = Ok ([], []));
  let field = "--B\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\nx\r\n" in
  let too_many = String.concat "" (List.init 4097 (fun _ -> field)) ^ "--B--\r\n" in
  Alcotest.(check bool) "multipart part count" true
    (match parse_multipart_stream ~content_type [too_many] with
     | Error (Http_params.Limit _) -> true | _ -> false)

let large_stream_and_cleanup () =
  let content_type = "multipart/form-data; boundary=B" in
  let head = "--B\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"large.bin\"\r\n" ^
    "Content-Type: application/octet-stream\r\n\r\n" in
  let megabyte = String.make (1024 * 1024) 'x' in
  let chunks = head :: (List.init 129 (fun _ -> megabyte)) @ ["\r\n--B"; "--\r\n"] in
  with_multipart ~content_type chunks (fun params paths ->
    match Http_params.find "upload" params with
    | Some (Http_params.File file) ->
        Alcotest.(check int64) "streamed past old 128 MiB cap"
          (Int64.of_int (129 * 1024 * 1024)) file.size;
        Alcotest.(check int64) "disk-backed size" file.size
          (Int64.of_int (Unix.stat file.path).Unix.st_size);
        Alcotest.(check bool) "one owned temporary path" true (paths = [file.path])
    | _ -> Alcotest.fail "large file missing");
  let created = ref [] in
  let rejected = Lwt_main.run (Http_params.parse_multipart_stream
    ~on_temp:(fun path -> created := path :: !created)
    ~content_type ~limit:1024L
    (Lwt_stream.of_list [head; megabyte; "\r\n--B--\r\n"])) in
  Alcotest.(check bool) "configured whole stream limit" true
    (rejected = Error Http_params.Too_large);
  Alcotest.(check bool) "limit cleans opened temporary file" true
    (!created <> [] && List.for_all (fun path -> not (Sys.file_exists path)) !created);
  let created = ref [] in
  let malformed = Lwt_main.run (Http_params.parse_multipart_stream
    ~on_temp:(fun path -> created := path :: !created)
    ~content_type ~limit:100000L
    (Lwt_stream.of_list [head; "some bytes without a closing delimiter"])) in
  Alcotest.(check bool) "malformed stream rejected" true
    (malformed = Error Http_params.Parse);
  Alcotest.(check bool) "parse rejection cleans temporary file" true
    (!created <> [] && List.for_all (fun path -> not (Sys.file_exists path)) !created)

let in_process () =
  let path = Filename.temp_file "campfire-http-app-" ".sqlite3" in
  let runtime = Db_runtime.open_db path in
  Fun.protect ~finally:(fun () -> Db_runtime.close runtime; Sys.remove path) (fun () ->
    let dispatch endpoint = if endpoint = "sessions#update" then
      Some Http_app.{ before_action = before ~access:Public (); action = (fun ctx ->
        Lwt.return (json ~status:200 (`Assoc [
          "method", `String ctx.method_;
          "original_method", `String ctx.original_method;
          "params", Http_params.to_json ctx.params;
          "raw", `String ctx.raw_post])))}
      else None in
    let request = Cohttp.Request.make ~meth:`POST
      ~headers:(Cohttp.Header.of_list ["host", "chat.example.com";
        "content-type", "application/x-www-form-urlencoded";
        "sec-fetch-site", "same-origin"])
      (Uri.of_string "https://chat.example.com/session?b=query&id=q&controller=forged") in
    let response, body = Lwt_main.run (Http_app.handle ~runtime ~secret_key_base:"unused"
      ~now:"2026-10-08T12:00:00Z" ~ssl:true ~force_ssl:true ~dispatch request
      (Cohttp_lwt.Body.of_string "_method=patch&b=body&id=body")) in
    Alcotest.(check int) "dispatch status" 200
      (Cohttp.Code.code_of_status (Cohttp.Response.status response));
    let body = Lwt_main.run (Cohttp_lwt.Body.to_string body) |> Yojson.Basic.from_string in
    let open Yojson.Basic.Util in
    Alcotest.(check string) "method override" "PATCH" (member "method" body |> to_string);
    Alcotest.(check string) "original method" "POST" (member "original_method" body |> to_string);
    Alcotest.(check string) "query wins" "query" (member "params" body |> member "b" |> to_string);
    Alcotest.(check string) "controller path param wins" "sessions"
      (member "params" body |> member "controller" |> to_string);
    Alcotest.(check string) "action path param" "update"
      (member "params" body |> member "action" |> to_string);
    Alcotest.(check string) "raw body" "_method=patch&b=body&id=body" (member "raw" body |> to_string))

let configured_body_limit () =
  let path = Filename.temp_file "campfire-http-limit-" ".sqlite3" in
  let runtime = Db_runtime.open_db path in
  Fun.protect ~finally:(fun () -> Db_runtime.close runtime; Sys.remove path) (fun () ->
    let request = Cohttp.Request.make ~meth:`POST
      ~headers:(Cohttp.Header.of_list ["content-type", "application/octet-stream"])
      (Uri.of_string "http://localhost/session") in
    let response, _ = Lwt_main.run (Http_app.handle ~runtime ~secret_key_base:"unused"
      ~max_body_bytes:4 ~dispatch:(fun _ -> None) request
      (Cohttp_lwt.Body.of_string "12345")) in
    Alcotest.(check int) "configured cap returns 413" 413
      (Cohttp.Code.code_of_status (Cohttp.Response.status response));
    let multipart_request = Cohttp.Request.make ~meth:`POST
      ~headers:(Cohttp.Header.of_list ["content-type", "multipart/form-data; boundary=B"])
      (Uri.of_string "http://localhost/session") in
    let multipart_body = "--B\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\n" ^
      String.make (16 * 1024 * 1024 + 1) 'x' ^ "\r\n--B--\r\n" in
    let too_large, _ = Lwt_main.run (Http_app.handle ~runtime ~secret_key_base:"unused"
      ~dispatch:(fun _ -> None) multipart_request
      (Cohttp_lwt.Body.of_string multipart_body)) in
    Alcotest.(check int) "multipart text cap returns 413" 413
      (Cohttp.Code.code_of_status (Cohttp.Response.status too_large)))

let request_temp_lifetime () =
  let db_path = Filename.temp_file "campfire-upload-lifetime-" ".sqlite3" in
  let runtime = Db_runtime.open_db db_path in
  Fun.protect ~finally:(fun () -> Db_runtime.close runtime; Sys.remove db_path) (fun () ->
    let body = "--B\r\nContent-Disposition: form-data; name=\"f\"; filename=\"x.bin\"\r\n\r\n" ^
      "data\r\n--B--\r\n" in
    let request () = Cohttp.Request.make ~meth:`POST
      ~headers:(Cohttp.Header.of_list ["content-type", "multipart/form-data; boundary=B"])
      (Uri.of_string "http://localhost/session") in
    let captured = ref None in
    let file ctx = match Http_app.param ctx "f" with
      | Some (Http_params.File file) ->
          captured := Some file.path; file
      | _ -> Alcotest.fail "request file missing" in
    let assert_removed label = match !captured with
      | None -> Alcotest.fail "request path not captured"
      | Some path -> Alcotest.(check bool) label false (Sys.file_exists path) in
    let run before_action action =
      captured := None;
      let dispatch endpoint = if endpoint = "sessions#create" then
        Some Http_app.{ before_action; action } else None in
      Lwt_main.run (Http_app.handle ~runtime ~secret_key_base:"unused"
        ~dispatch (request ()) (Cohttp_lwt.Body.of_string body)) in
    let accepted, _ = run (fun c -> ignore (file c); Lwt.return (Ok ()))
      (fun c -> let file = file c in
        Alcotest.(check bool) "file exists inside handler" true (Sys.file_exists file.path);
        Lwt.return (Http_app.text ~status:200 "ok")) in
    Alcotest.(check int) "success" 200 (Cohttp.Code.code_of_status (Cohttp.Response.status accepted));
    assert_removed "success cleanup";
    let rejected, _ = run (fun c -> ignore (file c);
      Lwt.return (Error (Http_app.error ~status:403)))
      (fun _ -> Alcotest.fail "rejected action ran") in
    Alcotest.(check int) "rejection" 403 (Cohttp.Code.code_of_status (Cohttp.Response.status rejected));
    assert_removed "rejection cleanup";
    let failed, _ = run (fun c -> ignore (file c); Lwt.return (Ok ()))
      (fun _ -> failwith "controller failed") in
    Alcotest.(check int) "handler exception" 500 (Cohttp.Code.code_of_status (Cohttp.Response.status failed));
    assert_removed "exception cleanup")

let cancelled_upload_worker () =
  let db_path = Filename.temp_file "campfire-upload-cancel-" ".sqlite3" in
  let runtime = Db_runtime.open_db db_path in
  Fun.protect ~finally:(fun () -> Db_runtime.close runtime; Sys.remove db_path) (fun () ->
    let path = ref None and worker = ref None in
    let entered, signal = Lwt.wait () in
    let action c =
      let file = match Http_app.param c "f" with
        | Some (Http_params.File file) -> file
        | _ -> Alcotest.fail "request file missing" in
      path := Some file.path;
      let tracked = Http_app.track_upload_worker c
        (Lwt_preemptive.detach (fun path -> Thread.delay 0.15; Sys.file_exists path) file.path) in
      worker := Some tracked;
      Lwt.wakeup signal ();
      tracked >|= fun _ -> Http_app.text ~status:200 "ok" in
    let dispatch endpoint = if endpoint = "sessions#create" then
      Some Http_app.{ before_action = (fun _ -> Lwt.return (Ok ())); action }
      else None in
    let request = Cohttp.Request.make ~meth:`POST
      ~headers:(Cohttp.Header.of_list ["content-type", "multipart/form-data; boundary=B"])
      (Uri.of_string "http://localhost/session") in
    let body = "--B\r\nContent-Disposition: form-data; name=\"f\"; filename=\"x.bin\"\r\n\r\n" ^
      "data\r\n--B--\r\n" in
    let ongoing = Http_app.handle ~runtime ~secret_key_base:"unused" ~dispatch request
      (Cohttp_lwt.Body.of_string body) in
    Lwt_main.run (entered >>= fun () ->
      Lwt.cancel ongoing;
      Lwt_unix.sleep 0.03 >>= fun () ->
      let path = Option.get !path in
      Alcotest.(check bool) "temp remains while worker runs" true (Sys.file_exists path);
      let worker = Option.get !worker in
      worker >>= fun saw_file ->
      Alcotest.(check bool) "worker read live temp" true saw_file;
      Lwt_unix.sleep 0.03 >|= fun () ->
      Alcotest.(check bool) "temp removed after worker" false (Sys.file_exists path)))

let policy_bot_and_ban () =
  let path = Filename.temp_file "campfire-http-policy-" ".sqlite3" in
  let runtime = Db_runtime.open_db path in
  Fun.protect ~finally:(fun () -> Db_runtime.close runtime; Sys.remove path) (fun () ->
    let bot = Db_runtime.write runtime (fun tx ->
      let db = Db_runtime.conn tx in
      let bot = Db_accounts.User.create_bot db ~now:"2026-10-08T12:00:00Z" ~name:"Test bot" in
      ignore (Db_remaining.Ban.create tx
        ~now:(Authentication.now_time "2026-10-08T12:00:00Z")
        ~user_id:bot.id ~ip_address:"198.51.100.12"); bot) in
    let key = Db_accounts.User.bot_key bot in
    let action c =
      Alcotest.(check bool) "bot current user" true
        (match c.Http_app.current_user with Some user -> Db_accounts.User.is_bot user | None -> false);
      Lwt.return (Http_app.text ~status:200 "bot") in
    let dispatch access endpoint =
      if endpoint = "messages/by_bots#index" then
        Some Http_app.{ before_action = before ~access (); action }
      else if endpoint = "sessions#create" then
        Some Http_app.{ before_action = before ~access:Public (); action = (fun _ ->
          Lwt.return (text ~status:200 "public")) }
      else None in
    let request ~meth path = Cohttp.Request.make ~meth
      (Uri.of_string ("http://localhost" ^ path)) in
    let send ?(remote_ip="203.0.113.4") dispatch request =
      Lwt_main.run (Http_app.handle ~runtime ~secret_key_base:"unused"
        ~now:"2026-10-08T12:00:00Z" ~remote_ip ~dispatch request
        (Cohttp_lwt.Body.of_string "")) in
    let url = "/rooms/1/" ^ key ^ "/messages" in
    let allowed, _ = send (dispatch Http_app.Bot_allowed) (request ~meth:`GET url) in
    Alcotest.(check int) "valid bot key accepted" 200
      (Cohttp.Code.code_of_status (Cohttp.Response.status allowed));
    let denied, _ = send (dispatch Http_app.User) (request ~meth:`GET url) in
    Alcotest.(check int) "default policy denies bot" 403
      (Cohttp.Code.code_of_status (Cohttp.Response.status denied));
    let banned, _ = send ~remote_ip:"198.51.100.12" (dispatch Http_app.Public)
      (request ~meth:`POST "/session") in
    Alcotest.(check int) "public write checks ban" 429
      (Cohttp.Code.code_of_status (Cohttp.Response.status banned));
    Alcotest.(check (list string)) "banned write commits no cookies" []
      (Cohttp.Header.get_multi (Cohttp.Response.headers banned) "set-cookie"))

let actual_listener () =
  let socket = try Some (Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0)
    with Unix.Unix_error (Unix.EPERM, _, _) -> None in
  match socket with
  | None -> () (* Dune's restricted sandbox denies socket creation. *)
  | Some socket ->
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let port = match Unix.getsockname socket with
    | Unix.ADDR_INET (_, port) -> port
    | _ -> failwith "expected TCP socket" in
  Unix.close socket;
  let path = Filename.temp_file "campfire-http-listener-" ".sqlite3" in
  let runtime = Db_runtime.open_db path in
  Fun.protect ~finally:(fun () -> Db_runtime.close runtime; Sys.remove path) (fun () ->
    let handled = ref 0 in
    let dispatch endpoint = if endpoint = "welcome#show" then
      Some Http_app.{ before_action = before ~access:Public (); action = (fun _ ->
        incr handled;
        Lwt.return (text ~status:200 "live OCaml listener")) }
      else None in
    let stop, wake = Lwt.wait () in
    let server = Http_app.serve ~runtime ~secret_key_base:"unused" ~port ~stop ~dispatch () in
    let raw_request fill = Lwt_preemptive.detach (fun () ->
      let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      Fun.protect ~finally:(fun () -> Unix.close socket) (fun () ->
        Unix.setsockopt_float socket Unix.SO_RCVTIMEO 5.;
        Unix.setsockopt_float socket Unix.SO_SNDTIMEO 5.;
        Unix.connect socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nX-Fill: " ^
          String.make fill 'a' ^ "\r\nConnection: close\r\n\r\n" in
        let rec send at =
          if at < String.length request then
            try
              let count = Unix.write_substring socket request at
                (String.length request - at) in
              if count > 0 then send (at + count)
            with Unix.Unix_error ((Unix.EPIPE | Unix.ECONNRESET), _, _) -> () in
        send 0;
        (try Unix.shutdown socket Unix.SHUTDOWN_SEND with Unix.Unix_error _ -> ());
        let response = Buffer.create 256 and chunk = Bytes.create 4096 in
        let rec receive () =
          try
            let count = Unix.read socket chunk 0 (Bytes.length chunk) in
            if count > 0 then (Buffer.add_subbytes response chunk 0 count; receive ())
          with Unix.Unix_error ((Unix.ECONNRESET | Unix.EPIPE), _, _) -> () in
        receive ();
        Buffer.contents response)) () in
    let run =
      Lwt.async (fun () -> server);
      Lwt_unix.sleep 0.05 >>= fun () ->
      Cohttp_lwt_unix.Client.get
        (Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/" port)) >>= fun (response, body) ->
      Cohttp_lwt.Body.to_string body >>= fun body ->
      Cohttp_lwt_unix.Client.get
        (Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/cable" port))
      >>= fun (cable_response, cable_body) ->
      Cohttp_lwt.Body.drain_body cable_body >>= fun () ->
      raw_request 4096 >>= fun normal_wire ->
      let before_large = !handled in
      raw_request 66560 >>= fun large_wire ->
      raw_request 1_048_576 >>= fun huge_wire ->
      let after_large = !handled in
      Lwt.wakeup wake ();
      Lwt.return (Cohttp.Code.code_of_status (Cohttp.Response.status response), body,
        Cohttp.Code.code_of_status (Cohttp.Response.status cable_response),
        normal_wire,large_wire,huge_wire,before_large,after_large) in
    let status, body, cable_status,normal_wire,large_wire,huge_wire,
      before_large,after_large = Lwt_main.run run in
    Alcotest.(check int) "real TCP status" 200 status;
    Alcotest.(check string) "real TCP body" "live OCaml listener" body;
    Alcotest.(check int) "unconfigured Cable stays closed" 404 cable_status;
    Alcotest.(check bool) "normal raw request reaches target" true
      (String.starts_with ~prefix:"HTTP/1.1 200" normal_wire);
    Alcotest.(check string) "66,560-byte header rejected before response" "" large_wire;
    Alcotest.(check string) "1 MiB header rejected before response" "" huge_wire;
    Alcotest.(check int) "oversized headers never reach dispatch" before_large after_large)

let before_exception () =
  let path = Filename.temp_file "campfire-http-before-" ".sqlite3" in
  let runtime = Db_runtime.open_db path in
  Fun.protect ~finally:(fun () -> Db_runtime.close runtime; Sys.remove path) (fun () ->
    let dispatch endpoint = if endpoint = "welcome#show" then
      Some Http_app.{ before_action = (fun ctx ->
        Cookie_http.set ctx.cookies "leak" (Cookie_http.cookie "secret");
        failwith "before action failed");
        action = (fun _ -> Lwt.return (text ~status:200 "should not run")) }
      else None in
    let request = Cohttp.Request.make (Uri.of_string "http://localhost/") in
    let response, _ = Lwt_main.run (Http_app.handle ~runtime ~secret_key_base:"unused"
      ~dispatch request (Cohttp_lwt.Body.of_string "")) in
    Alcotest.(check int) "before exception becomes 500" 500
      (Cohttp.Code.code_of_status (Cohttp.Response.status response));
    Alcotest.(check (list string)) "failed before action commits no cookies" []
      (Cohttp.Header.get_multi (Cohttp.Response.headers response) "set-cookie"))

let public_exception_middleware () =
  let path = Filename.temp_file "campfire-http-exception-" ".sqlite3" in
  let runtime = Db_runtime.open_db path in
  Fun.protect ~finally:(fun () -> Db_runtime.close runtime; Sys.remove path) (fun () ->
    let front_cache = Http_cache.Front.create ~capacity:4096 ~max_item_size:1024 in
    let send ~status ~body =
      let before_action c =
        Http_app.set_header c "x-version" "test-version";
        Cookie_http.set c.Http_app.cookies "leak" (Cookie_http.cookie "secret");
        Lwt.return (Ok ()) in
      let action _ = Lwt.return (Http_app.respond ~status
        ~content_type:"text/html; charset=UTF-8"
        ~headers:["x-campfire-public-exception","1";
          "content-length",string_of_int (String.length body)] body) in
      let dispatch endpoint = if endpoint="sessions#create" then
        Some Http_app.{before_action;action} else None in
      let request=Cohttp.Request.make ~meth:`POST
        (Uri.of_string "http://localhost/session") in
      Lwt_main.run (Http_app.handle ~runtime ~secret_key_base:"unused"
        ~front_cache ~dispatch request (Cohttp_lwt.Body.of_string "")) in
    let empty,_=send ~status:400 ~body:"" in
    let headers=Cohttp.Response.headers empty in
    Alcotest.(check int) "empty public exception status" 400
      (Cohttp.Code.code_of_status (Cohttp.Response.status empty));
    Alcotest.(check (option string)) "public exception MIME"
      (Some "text/html; charset=UTF-8") (Cohttp.Header.get headers "content-type");
    Alcotest.(check (option string)) "public exception length"
      (Some "0") (Cohttp.Header.get headers "content-length");
    Alcotest.(check (list string)) "front adds one Vary on empty public 400"
      ["Accept-Encoding"] (Cohttp.Header.get_multi headers "vary");
    List.iter (fun name -> Alcotest.(check bool) ("public exception omits " ^ name)
      false (Cohttp.Header.mem headers name))
      ["x-version";"x-frame-options";"set-cookie";
       "cache-control";"x-campfire-public-exception"];
    let unacceptable,_=send ~status:406 ~body:"" in
    Alcotest.(check (list string)) "front adds one Vary on empty public 406"
      ["Accept-Encoding"]
      (Cohttp.Header.get_multi (Cohttp.Response.headers unacceptable) "vary");
    let nonempty,_=send ~status:404 ~body:"missing" in
    Alcotest.(check (list string)) "bypassed front appends nonempty exception Vary"
      ["Accept-Encoding";"Accept-Encoding"]
      (Cohttp.Header.get_multi (Cohttp.Response.headers nonempty) "vary"))

let formats () =
  let open Http_format in
  Alcotest.(check bool) "Turbo first" true
    (formats ~path:"/messages" ~accept:"text/vnd.turbo-stream.html, text/html;q=0.9" ~xhr:true () = [Turbo_stream; Html]);
  Alcotest.(check bool) "path format" true
    (formats ~path:"/messages.json" ~xhr:false () = [Json]);
  Alcotest.(check bool) "explicit format wins" true
    (formats ~format_param:"json" ~path:"/messages" ~accept:"text/html" ~xhr:false () = [Json]);
  let test accept expected =
    let actual = parse_accept accept in
    if actual <> Ok expected then Alcotest.failf "Accept %S" accept in
  test "text/html;q=0.5, application/json" [Json; Html];
  test "text/html;q=, application/json" [Html; Json];
  test "text/html; q=, application/json;q=0.5" [Html; Json];
  test "text/html;q=;x=1, application/json" [Json; Html];
  test "text/html;q=;q=0.9, application/json;q=0.5" [Json; Html];
  test "text/html;q=0.5.1, application/json;q=0.6" [Json; Html];
  test "text/html;q=0.5.1.2, application/json;q=0.49" [Html; Json];
  test "text/html;q=1e-1, application/json;q=0.5" [Json; Html];
  test "text/html;q=1_0, application/json;q=5" [Html; Json];
  test "text/html;q=+0.3, application/json;q=0.2" [Html; Json];
  test "text/html;q=0.5, application/json;q=+0x1" [Json; Html];
  test "text/html;q=0.5, application/json;q=0x1" [Html; Json];
  test "text/xml, application/rss+xml" [Xml; Other "application/rss+xml"];
  test "application/xml, application/rss+xml" [Other "application/rss+xml"; Xml];
  Alcotest.(check bool) "invalid MIME is rejected" true
    (parse_formats ~path:"/" ~xhr:false ~accept:"garbage" () = Error (Invalid_mime_type "garbage"));
  Alcotest.(check bool) "browser Accept falls back to HTML" true
    (formats ~path:"/" ~xhr:false
       ~accept:"text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8" () = [Html]);
  Alcotest.(check bool) "wildcard expands" true
    (match formats ~path:"/" ~xhr:false ~accept:"text/*" () with
     | Html :: Text :: Js :: _ -> true | _ -> false)

let gzip () =
  let open Http_gzip in
  Alcotest.(check bool) "gzip selected" true (select "gzip, deflate, br" = Gzip);
  Alcotest.(check bool) "identity selected" true (select "gzip;q=0" = Identity);
  Alcotest.(check bool) "wildcard gzip" true (select "*" = Gzip);
  Alcotest.(check bool) "explicit gzip beats implicit identity" true
    (select "gzip;q=.5" = Gzip);
  Alcotest.(check bool) "explicit identity quality" true
    (select "identity;q=0.5, gzip;q=0.1" = Identity);
  Alcotest.(check bool) "Rack malformed q prefix" true
    (select "gzip;q=0.5.1, identity;q=0.6" = Identity);
  Alcotest.(check bool) "unacceptable" true
    (select "gzip;q=0, identity;q=0" = Unacceptable);
  let request = Cohttp.Request.make ~headers:(Cohttp.Header.of_list ["accept-encoding", "gzip"])
    (Uri.of_string "http://localhost/session") in
  let response = Http_app.html ~status:200 "Hello Campfire" in
  let response, body = Lwt_main.run (apply request response) in
  Alcotest.(check (option string)) "content-encoding" (Some "gzip")
    (Cohttp.Header.get (Cohttp.Response.headers response) "content-encoding");
  Alcotest.(check (option string)) "vary" (Some "Accept-Encoding")
    (Cohttp.Header.get (Cohttp.Response.headers response) "vary");
  let compressed = Lwt_main.run (Cohttp_lwt.Body.to_string body) in
  Alcotest.(check string) "gzip magic" "\031\139" (String.sub compressed 0 2)

let () = Alcotest.run "M3 HTTP foundation" [
  "Rails params", [
    Alcotest.test_case "all 2755 pinned cases" `Quick vectors;
    Alcotest.test_case "parser errors and Rack limits" `Quick parser_errors;
    Alcotest.test_case "body fallback rules" `Quick body_contracts;
    Alcotest.test_case "multipart file and override" `Quick multipart;
    Alcotest.test_case "multipart delimiters and limits" `Quick multipart_errors;
    Alcotest.test_case "large streamed file and parser cleanup" `Quick large_stream_and_cleanup;
  ];
  "Cohttp", [
    Alcotest.test_case "route, body, query, method" `Quick in_process;
    Alcotest.test_case "configured body limit" `Quick configured_body_limit;
    Alcotest.test_case "request temp lifetime" `Quick request_temp_lifetime;
    Alcotest.test_case "cancelled upload worker barrier" `Quick cancelled_upload_worker;
    Alcotest.test_case "bot key and public ban policy" `Quick policy_bot_and_ban;
    Alcotest.test_case "real TCP listener" `Quick actual_listener;
    Alcotest.test_case "before action exception" `Quick before_exception;
    Alcotest.test_case "public exception middleware" `Quick public_exception_middleware;
    Alcotest.test_case "format negotiation" `Quick formats;
    Alcotest.test_case "gzip negotiation and member" `Quick gzip;
  ];
]

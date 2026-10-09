open Campfire

let status response = Cohttp.Code.code_of_status (Cohttp.Response.status response)
let header response key = Cohttp.Header.get (Cohttp.Response.headers response) key
let check label expected actual = Alcotest.(check int) label expected actual
let secret = String.make 64 'r'
let now = "2026-10-08T12:00:00Z"

let rec reference_root path remaining =
  if remaining=0 then failwith "pinned Rails seed not found" else
  let candidate = Filename.concat path "once-campfire-rust" in
  if Sys.file_exists (Filename.concat candidate "parity/.seed/default/db/production.sqlite3")
  then candidate else reference_root (Filename.dirname path) (remaining-1)

let with_seed ?(variant="default") f =
  let source = Filename.concat (reference_root (Sys.getcwd ()) 8)
    ("parity/.seed/" ^ variant ^ "/db/production.sqlite3") in
  let db = Sqlite3.db_open ~mode:`READONLY source in
  let temporary = Filename.temp_file "campfire-m3-t4-" ".sqlite3" in
  Sys.remove temporary;
  let quoted = String.concat "''" (String.split_on_char '\'' temporary) in
  let rc = Sqlite3.exec db ("VACUUM INTO '"^quoted^"'") in
  ignore (Sqlite3.db_close db);
  if rc<>Sqlite3.Rc.OK then failwith "cannot copy pinned seed";
  let runtime = Db_runtime.open_db ~readers:2 ~prepare:false temporary in
  Fun.protect ~finally:(fun () ->
    Db_runtime.close runtime;
    List.iter (fun path -> if Sys.file_exists path then Sys.remove path)
      [temporary;temporary^"-wal";temporary^"-shm"])
    (fun () -> f runtime)

let send ?cookie ?accept ?origin ?(remote_ip="127.0.0.1") ?(body="") runtime meth path =
  let headers = ["host","chat.example.com";"sec-fetch-site","same-origin"] in
  let headers = match cookie with None -> headers | Some x -> ("cookie",x)::headers in
  let headers = match accept with None -> headers | Some x -> ("accept",x)::headers in
  let headers = match origin with None -> headers | Some x -> ("origin",x)::headers in
  let headers = ("content-type","application/x-www-form-urlencoded")::headers in
  let request = Cohttp.Request.make ~meth ~headers:(Cohttp.Header.of_list headers)
    (Uri.of_string ("https://chat.example.com"^path)) in
  let response,body = Lwt_main.run (Http_app.handle ~runtime ~secret_key_base:secret
    ~now ~remote_ip ~ssl:true ~force_ssl:true ~dispatch:Controller_aux.endpoint
    request (Cohttp_lwt.Body.of_string body)) in
  response,Lwt_main.run (Cohttp_lwt.Body.to_string body)

let mint_session runtime =
  let row = Db_runtime.write runtime (fun tx -> Db_accounts.Session.start
    (Db_runtime.conn tx) ~now ~user_id:127326141L ~user_agent:None
    ~ip_address:(Some "127.0.0.1")) in
  "session_token=" ^ Authentication.issue_token_cookie
    ~secret_key_base:secret ~now row.token

let owns name = List.exists (fun prefix -> String.starts_with ~prefix name)
  ["pwa#";"qr_code#";"unfurl_links#";"rails/health#";
   "turbo/native/navigation#";"action_mailbox/";
   "rails/conductor/action_mailbox/";"active_storage/"]

let test_inventory () =
  let routes = List.filter (fun (_,_,name,_) -> owns name) Route_catalog.routes in
  check "31 auxiliary route rows" 31 (List.length routes);
  List.iter (fun (_,_,name,_) ->
    Alcotest.(check bool) ("handler for "^name) true
      (Option.is_some (Controller_aux.endpoint name))) routes;
  Alcotest.(check bool) "unknown endpoint" true
    (Controller_aux.endpoint "rooms#show" = None)

let test_pwa_and_health () = with_seed (fun runtime ->
  let worker,script = send runtime `GET "/service-worker.js" in
  check "service worker" 200 (status worker);
  Alcotest.(check (option string)) "worker MIME"
    (Some "text/javascript; charset=utf-8") (header worker "content-type");
  Alcotest.(check bool) "notification code" true
    (String.length script > 600 && String.contains script 'p');
  let no_js,_ = send runtime `GET "/service-worker.json" in
  check "worker format" 406 (status no_js);
  let manifest,raw = send runtime `GET "/webmanifest.json" in
  check "public manifest" 200 (status manifest);
  Alcotest.(check bool) "manifest uses exact multiline view renderer" true
    (String.starts_with ~prefix:"{\n  \"name\": \"37signals\",\n" raw &&
     String.ends_with ~suffix:"\n}\n" raw);
  let json = Yojson.Basic.from_string raw in
  let open Yojson.Basic.Util in
  Alcotest.(check string) "account name" "37signals"
    (json |> member "name" |> to_string);
  check "three icons" 3 (json |> member "icons" |> to_list |> List.length);
  check "three screenshots" 3
    (json |> member "screenshots" |> to_list |> List.length);
  let health,body = send runtime `GET "/up" in
  check "health HTML" 200 (status health);
  Alcotest.(check (option string)) "standalone health has no app version"
    None (header health "x-version");
  Alcotest.(check string) "health body"
    "<!DOCTYPE html><html><body style=\"background-color: green\"></body></html>" body;
  let health_json,body = send runtime `GET "/up.json" in
  check "health JSON" 200 (status health_json);
  let json = Yojson.Basic.from_string body in
  Alcotest.(check string) "health status" "up"
    (json |> member "status" |> to_string);
  Alcotest.(check string) "health timestamp" now
    (json |> member "timestamp" |> to_string))

let test_first_run_manifest () = with_seed ~variant:"first_run" (fun runtime ->
  let response,raw=send runtime `GET "/webmanifest.json" in
  check "first-run manifest" 200 (status response);
  let json=Yojson.Basic.from_string raw in
  let open Yojson.Basic.Util in
  Alcotest.(check string) "fallback account name" "Campfire"
    (json |> member "name" |> to_string);
  let first_icon=json |> member "icons" |> to_list |> List.hd in
  Alcotest.(check string) "logo has no account version"
    "/account/logo?size=small"
    (first_icon |> member "src" |> to_string))

let test_qr_and_turbo () = with_seed (fun runtime ->
  let id = Rails_format.urlsafe_encode "https://chat.example.com/join/ABCD" in
  let qr,svg = send runtime `GET ("/qr_code/"^id) in
  check "public QR" 200 (status qr);
  Alcotest.(check (option string)) "QR MIME"
    (Some "image/svg+xml; charset=utf-8") (header qr "content-type");
  Alcotest.(check bool) "QR rects" true
    (String.starts_with ~prefix:"<?xml version=\"1.0\"" svg &&
      String.contains svg '<' && String.length svg > 1000);
  Alcotest.(check (option string)) "public QR cache"
    (Some "max-age=31556952, public") (header qr "cache-control");
  let invalid,_ = send runtime `GET "/qr_code/a" in
  check "malformed base64 raises" 500 (status invalid);
  List.iter (fun (path,expected) ->
    let response,body = send runtime `GET path in
    check path 200 (status response);
    Alcotest.(check (option string)) (path ^ " has no app version") None
      (header response "x-version");
    Alcotest.(check string) path expected body)
    ["/recede_historical_location","Going back…";
     "/resume_historical_location","Staying put…";
     "/refresh_historical_location","Refreshing…"])

let test_qr_golden_audit () =
  let path = Filename.concat (reference_root (Sys.getcwd ()) 8)
    "crates/campfire/src/controllers/qr_code/testdata/rqrcode.json" in
  let channel = open_in_bin path in
  let raw = Fun.protect ~finally:(fun () -> close_in channel)
    (fun () -> really_input_string channel (in_channel_length channel)) in
  let vectors = Yojson.Basic.from_string raw |> Yojson.Basic.Util.to_list in
  check "pinned QR vectors" 39 (List.length vectors);
  let matches = List.fold_left (fun count vector ->
    let open Yojson.Basic.Util in
    let input = vector |> member "input_base64" |> to_string
      |> Rails_format.strict_decode |> Option.get in
    let expected = vector |> member "modules" |> to_string in
    match Controller_aux.qr_matrix input with
    | None -> count
    | Some matrix ->
        let width, data = Controller_aux.qr_compatible_matrix matrix in
        let actual = List.init width (fun row ->
          String.sub data (row*width) width) |> String.concat "\n" in
        if actual=expected then (
          (match vector |> member "svg" with
           | `String svg -> Alcotest.(check string) "exact SVG for matched matrix"
               svg (Controller_aux.qr_svg (width,data))
           | _ -> ());
          count+1) else count)
    0 vectors in
  check "exact RQRCode matrices after mask scoring" 39 matches

let read_file path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let sha256 body = Mirage_crypto.Hash.SHA256.digest (Cstruct.of_string body)
  |> Cstruct.to_hex_string

let test_qr_version_boundaries () =
  let open Yojson.Basic.Util in
  let fixture_path = if Sys.file_exists "fixtures/qr_version_boundaries.json"
    then "fixtures/qr_version_boundaries.json"
    else "test/fixtures/qr_version_boundaries.json" in
  let fixture = Yojson.Basic.from_string
    (read_file fixture_path) in
  let source = Filename.concat (reference_root (Sys.getcwd ()) 8)
    (fixture |> member "oracle_file" |> to_string) in
  Alcotest.(check string) "pinned Rust QR source"
    (fixture |> member "oracle_sha256" |> to_string)
    (sha256 (read_file source));
  let cases=fixture |> member "cases" |> to_list in
  check "boundary cases" 18 (List.length cases);
  Alcotest.(check bool) "payload above version 40 is rejected" true
    (Controller_aux.qr_matrix (String.make 3000 'a')=None);
  List.iter (fun case ->
    let mode=case |> member "mode" |> to_string in
    let length=case |> member "length" |> to_int in
    let version=case |> member "version" |> to_int in
    let unit=match mode with
      | "numeric" -> '1' | "alphanumeric" -> 'A' | "byte" -> 'a'
      | _ -> failwith "unknown QR mode" in
    let label=Printf.sprintf "%s/%d" mode length in
    let matrix=Option.get (Controller_aux.qr_matrix (String.make length unit))
      |> Controller_aux.qr_compatible_matrix in
    let width,_=matrix in
    check (label ^ " version") version ((width-17)/4);
    let svg=Controller_aux.qr_svg matrix in
    check (label ^ " SVG length")
      (case |> member "svg_bytes" |> to_int) (String.length svg);
    Alcotest.(check string) (label ^ " SVG SHA-256")
      (case |> member "svg_sha256" |> to_string) (sha256 svg)) cases

let test_mailbox_unfurl_and_storage () = with_seed (fun runtime ->
  let ingress,_ = send runtime `POST
    "/rails/action_mailbox/postmark/inbound_emails" in
  check "unconfigured ingress" 404 (status ingress);
  Alcotest.(check (option string)) "ingress MIME" (Some "text/html")
    (header ingress "content-type");
  Alcotest.(check (option string)) "ingress has no app version" None
    (header ingress "x-version");
  let conductor,_ = send runtime `GET
    "/rails/conductor/action_mailbox/inbound_emails" in
  check "conductor forbidden" 403 (status conductor);
  Alcotest.(check (option string)) "conductor before-action MIME"
    (Some "text/html") (header conductor "content-type");
  let cross_site,_ = send ~origin:"https://evil.example" runtime `POST
    "/rails/conductor/action_mailbox/inbound_emails" in
  check "conductor CSRF first" 422 (status cross_site);
  let absent,_ = send runtime `POST "/unfurl_link" in
  check "unfurl requires user" 302 (status absent);
  let cookie = mint_session runtime in
  let missing,_ = send ~cookie ~origin:"https://chat.example.com"
    runtime `POST "/unfurl_link" in
  check "missing URL" 400 (status missing);
  Alcotest.(check (option string)) "missing URL public exception MIME"
    (Some "text/html; charset=UTF-8") (header missing "content-type");
  Alcotest.(check (option string)) "missing URL has no cache default"
    None (header missing "cache-control");
  Alcotest.(check (option string)) "missing URL has no app version"
    None (header missing "x-version");
  Alcotest.(check (option string)) "missing URL has no refreshed cookie"
    None (header missing "set-cookie");
  let local,_ = send ~cookie ~origin:"https://chat.example.com"
    ~body:"url=http%3A%2F%2F127.0.0.1%2Fprivate"
    runtime `POST "/unfurl_link" in
  check "no OpenGraph result" 204 (status local);
  let blob,_ = send runtime `GET
    "/rails/active_storage/blobs/redirect/invalid/image.png" in
  check "public blob reaches adapter" 501 (status blob);
  let denied,_ = send runtime `POST "/rails/active_storage/direct_uploads" in
  check "direct upload auth" 401 (status denied);
  Alcotest.(check (option string)) "direct upload auth MIME"
    (Some "text/html") (header denied "content-type");
  let allowed,_ = send ~cookie ~origin:"https://chat.example.com"
    runtime `POST "/rails/active_storage/direct_uploads" in
  check "signed-in upload reaches adapter" 501 (status allowed);
  Controller_aux.register_storage (fun _ -> Some (fun _ ->
    Lwt.return (Http_app.text ~status:202 "registered")));
  let delegated,body = send runtime `GET
    "/rails/active_storage/blobs/redirect/invalid/image.png" in
  check "storage adapter invoked" 202 (status delegated);
  Alcotest.(check string) "adapter body" "registered" body;
  Controller_aux.register_storage (fun _ -> None))

let test_mailbox_and_storage_bypass_app_ban () = with_seed (fun runtime ->
  let remote_ip = "203.0.113.44" in
  Db_runtime.write runtime (fun tx ->
    ignore (Db_remaining.Ban.create tx ~now:(Authentication.now_time now)
      ~user_id:127326141L ~ip_address:remote_ip));
  let cookie = mint_session runtime in
  Db_runtime.write runtime (fun tx ->
    let rc = Sqlite3.exec (Db_runtime.conn tx)
      "UPDATE sessions SET last_active_at='2026-10-07 00:00:00' WHERE id=(SELECT MAX(id) FROM sessions)" in
    if rc <> Sqlite3.Rc.OK then failwith "cannot age storage test session");
  Controller_aux.register_storage (fun _ -> Some (fun _ ->
    Lwt.return (Http_app.text ~status:202 "storage reached")));
  Fun.protect ~finally:(fun () -> Controller_aux.register_storage (fun _ -> None))
    (fun () ->
      let ingress,_ = send ~remote_ip runtime `POST
        "/rails/action_mailbox/postmark/inbound_emails" in
      check "banned ingress still unconfigured" 404 (status ingress);
      let absent,_ = send ~remote_ip runtime `PUT
        "/rails/active_storage/disk/invalid" in
      check "storage still requires session" 401 (status absent);
      let disk,_ = send ~cookie ~remote_ip runtime `PUT
        "/rails/active_storage/disk/invalid" in
      check "signed disk reaches storage" 202 (status disk);
      let cross_site_disk,_ = send ~cookie ~remote_ip
        ~origin:"https://evil.example" runtime `PUT
        "/rails/active_storage/disk/invalid" in
      check "disk PUT does not run direct-upload CSRF" 202
        (status cross_site_disk);
      let direct,_ = send ~cookie ~remote_ip runtime `POST
        "/rails/active_storage/direct_uploads" in
      check "signed direct upload reaches storage" 202 (status direct);
      let cross_site_direct,_ = send ~cookie ~remote_ip
        ~origin:"https://evil.example" runtime `POST
        "/rails/active_storage/direct_uploads" in
      check "direct upload checks CSRF" 422 (status cross_site_direct);
      let last_active = Db_runtime.read runtime (fun db ->
        Db_runtime.query_one db
          "SELECT last_active_at FROM sessions ORDER BY id DESC LIMIT 1" []
          (fun row -> Sqlite3.column_text row 0)) in
      Alcotest.(check (option string)) "storage lookup does not refresh session"
        (Some "2026-10-07 00:00:00") last_active))

let test_direct_upload_parameter_missing () = with_seed (fun runtime ->
  let service=Storage_disk.create ~root:(Filename.get_temp_dir_name ())
    ~name:"local" in
  Storage_http.register service;
  Fun.protect ~finally:(fun () -> Controller_aux.register_storage (fun _ -> None))
    (fun () ->
      let cookie=mint_session runtime in
      let remote_ip="203.0.113.44" in
      Db_runtime.write runtime (fun tx ->
        ignore (Db_remaining.Ban.create tx ~now:(Authentication.now_time now)
          ~user_id:127326141L ~ip_address:remote_ip));
      List.iter (fun remote_ip ->
        let response,body=send ~cookie ~remote_ip runtime `POST
          "/rails/active_storage/direct_uploads" in
        check "missing blob parameter" 400 (status response);
        Alcotest.(check string) "public exception body" "" body;
        Alcotest.(check (option string)) "public exception MIME"
          (Some "text/html; charset=UTF-8") (header response "content-type");
        Alcotest.(check (option string)) "public exception length"
          (Some "0") (header response "content-length");
        Alcotest.(check (option string)) "public exception has no cache default"
          None (header response "cache-control");
        Alcotest.(check (option string)) "public exception has no security header"
          None (header response "x-frame-options"))
        ["127.0.0.1";remote_ip]))

let () = Alcotest.run "M3-T4 auxiliary HTTP" [
  "inventory", [Alcotest.test_case "all 31 routes" `Quick test_inventory];
  "pwa", [Alcotest.test_case "public PWA and health" `Quick test_pwa_and_health;
    Alcotest.test_case "first-run manifest fallback" `Quick test_first_run_manifest];
  "qr", [Alcotest.test_case "QR and Turbo" `Quick test_qr_and_turbo];
  "qr-vectors", [Alcotest.test_case "39 pinned QR matrices" `Quick
    test_qr_golden_audit;
    Alcotest.test_case "18 version boundaries" `Quick
      test_qr_version_boundaries];
  "policies", [Alcotest.test_case "mailbox, unfurl, storage" `Quick
    test_mailbox_unfurl_and_storage;
    Alcotest.test_case "storage and mailbox skip app ban" `Quick
      test_mailbox_and_storage_bypass_app_ban;
    Alcotest.test_case "direct-upload parameter exception" `Quick
      test_direct_upload_parameter_missing];
]

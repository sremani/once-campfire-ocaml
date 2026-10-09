open Campfire

let check label condition = if not condition then Alcotest.fail label
let field key json = Yojson.Basic.Util.member key json
let string key json = Yojson.Basic.Util.to_string (field key json)

let rec reference_root path remaining =
  if remaining = 0 then failwith "pinned Rust reference checkout not found"
  else
    let candidate = Filename.concat path "once-campfire-rust" in
    if Sys.file_exists (Filename.concat candidate "parity/.env.reference") then candidate
    else reference_root (Filename.dirname path) (remaining - 1)

let reference = reference_root (Sys.getcwd ()) 8

let secret_key_base () =
  let path = Filename.concat reference "parity/.env.reference" in
  let channel = open_in path in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
    let rec read () =
      match input_line channel with
      | line when String.starts_with ~prefix:"SECRET_KEY_BASE=" line ->
          String.sub line 16 (String.length line - 16)
      | _ -> read ()
      | exception End_of_file -> failwith "pinned reference secret missing"
    in read ())

let with_seed_copy f =
  let source_path = Filename.concat reference "parity/.seed/default/db/production.sqlite3" in
  let source = Sqlite3.db_open ~mode:`READONLY source_path in
  let temporary = Filename.temp_file "campfire-http-" ".sqlite3" in
  Sys.remove temporary;
  let quoted = String.concat "''" (String.split_on_char '\'' temporary) in
  (match Sqlite3.exec source ("VACUUM INTO '" ^ quoted ^ "'") with
   | Sqlite3.Rc.OK -> ()
   | rc -> failwith ("seed copy failed: " ^ Sqlite3.Rc.to_string rc));
  let db = Sqlite3.db_open temporary in
  Fun.protect ~finally:(fun () ->
    ignore (Sqlite3.db_close db);
    ignore (Sqlite3.db_close source);
    Sys.remove temporary) (fun () -> f db)

let session_row () =
  let fixture = Yojson.Basic.from_file "fixtures/campfire_sessions.json" in
  match field "sessions" fixture with
  | `List (first :: _) -> first
  | _ -> failwith "missing pinned session vector"

let request ?site ?origin ~meth ~cookie () =
  let headers = ["host", "chat.example.com"; "cookie", cookie] in
  let headers = match site with None -> headers | Some value -> ("sec-fetch-site", value) :: headers in
  let headers = match origin with None -> headers | Some value -> ("origin", value) :: headers in
  Cohttp.Request.make ~meth ~headers:(Cohttp.Header.of_list headers)
    (Uri.of_string "https://chat.example.com/whoami")

let send ?(remote_ip="198.51.100.12") db secret request =
  let response, body = Lwt_main.run
      (Http_boundary.handle ~db ~secret_key_base:secret ~now:"2026-10-08T12:00:00Z"
        ~remote_ip ~ssl:true ~force_ssl:true request
        (Cohttp_lwt.Body.of_string "")) in
  let text = Lwt_main.run (Cohttp_lwt.Body.to_string body) in
  response, text

let status response = Cohttp.Code.code_of_status (Cohttp.Response.status response)
let set_cookies response = Cohttp.Header.get_multi (Cohttp.Response.headers response) "set-cookie"

let banned_ip db =
  let stmt = Sqlite3.prepare db "SELECT ip_address FROM bans LIMIT 1" in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW -> Sqlite3.column_text stmt 0
    | _ -> failwith "seed needs a banned IP")

let test_http_boundary () =
  let vector = session_row () in
  let cookie = string "cookie_header" vector in
  let secret = secret_key_base () in
  with_seed_copy (fun db ->
    let forged, forged_body = send db secret
        (request ~meth:`POST ~cookie ~site:"cross-site" ()) in
    Alcotest.(check int) "cross-site actual response status" 422 (status forged);
    Alcotest.(check string) "error page" "<h1>Unprocessable</h1>" forged_body;
    Alcotest.(check (list string)) "forgery does not commit cookie" [] (set_cookies forged);

    let blocked, _ = send ~remote_ip:(banned_ip db) db secret
        (request ~meth:`POST ~cookie ~site:"same-origin" ()) in
    Alcotest.(check int) "banned IP actual response status" 429 (status blocked);
    Alcotest.(check (list string)) "ban does not commit cookie" [] (set_cookies blocked);

    let allowed, allowed_body = send db secret
        (request ~meth:`POST ~cookie ~site:"same-origin"
           ~origin:"https://chat.example.com" ()) in
    Alcotest.(check int) "same-origin actual response status" 200 (status allowed);
    let payload = Yojson.Basic.from_string allowed_body in
    Alcotest.(check string) "Rails cookie authenticated user"
      (string "user_name" vector) (string "name" payload);
    Alcotest.(check string) "Rails cookie authenticated ID"
      (string_of_int (Yojson.Basic.Util.to_int (field "user_id" vector)))
      (string "id" payload);
    let renewed = set_cookies allowed in
    check "stale seed session emits renewal through Cookie_http" (List.length renewed = 1);
    check "renewal has Rails attributes"
      (String.ends_with ~suffix:"; httponly; samesite=lax" (List.hd renewed));

    let read, read_body = send db secret (request ~meth:`GET ~cookie ()) in
    Alcotest.(check int) "GET authenticated" 200 (status read);
    Alcotest.(check string) "GET and POST identity agree"
      (string "name" payload) (string "name" (Yojson.Basic.from_string read_body));
    Alcotest.(check (list string)) "fresh session does not rewrite cookie" [] (set_cookies read);

    let anonymous, _ = send db secret (request ~meth:`GET ~cookie:"" ()) in
    Alcotest.(check int) "anonymous redirect status" 302 (status anonymous);
    Alcotest.(check (option string)) "anonymous login location"
      (Some "https://chat.example.com/session/new")
      (Cohttp.Header.get (Cohttp.Response.headers anonymous) "location"))

let () = Alcotest.run "M1-T4 Cohttp boundary" [
  "integration", [Alcotest.test_case "CSRF and pinned Rails auth" `Quick test_http_boundary]]

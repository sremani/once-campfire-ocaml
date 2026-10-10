open Campfire

let check label condition = if not condition then failwith label

let field key json = Yojson.Basic.Util.member key json
let string key json = Yojson.Basic.Util.to_string (field key json)
let first key json = match field key json with `List (first :: _) -> first | _ -> failwith key

let rec reference_root path remaining =
  if remaining = 0 then failwith "once-campfire-rust reference checkout not found"
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
      | exception End_of_file -> failwith "SECRET_KEY_BASE missing from parity environment"
    in read ())

let with_statement db query f =
  let stmt = Sqlite3.prepare db query in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () -> f stmt)

let exec db sql = match Sqlite3.exec db sql with
  | Sqlite3.Rc.OK -> ()
  | rc -> failwith ("SQLite mutation failed: " ^ Sqlite3.Rc.to_string rc)

let with_seed_copy f =
  let source_path = Filename.concat reference "parity/.seed/default/db/production.sqlite3" in
  let source = Sqlite3.db_open ~mode:`READONLY source_path in
  let temporary = Filename.temp_file "campfire-auth-" ".sqlite3" in
  Sys.remove temporary;
  let quoted = String.concat "''" (String.split_on_char '\'' temporary) in
  exec source ("VACUUM INTO '" ^ quoted ^ "'");
  let destination = Sqlite3.db_open temporary in
  Fun.protect ~finally:(fun () ->
    ignore (Sqlite3.db_close destination);
    ignore (Sqlite3.db_close source);
    Sys.remove temporary) (fun () ->
    f destination)

let restore db ~secret ~now ~method_ ~remote_ip ~user_agent header =
  match Authentication.restore ~db ~secret_key_base:secret ~now ~method_ ~remote_ip
    ~user_agent ~cookie_header:header with
  | Ok value -> value
  | Error error -> failwith ("session restore SQL error: " ^ error)

let authenticated label = function
  | Authentication.Authenticated value -> value
  | _ -> failwith label

let rejected label reason = function
  | Authentication.Unauthenticated actual when actual = reason -> ()
  | _ -> failwith label

let test_seed_continuity () =
  let secret = secret_key_base () in
  let vectors = Yojson.Basic.from_file "fixtures/campfire_sessions.json" in
  let vector = first "sessions" vectors in
  let header = string "cookie_header" vector in
  let token = string "token" vector in
  let now = "2026-10-08T12:00:00Z" in
  with_seed_copy (fun db ->
    let run = restore db ~secret ~now ~method_:"GET" ~remote_ip:"198.51.100.12"
      ~user_agent:(Some "OCaml continuity test") in
    let first = authenticated "Rails issued cookie should restore seed session" (run header) in
    check "seed user id" (first.user.id = Int64.of_int (Yojson.Basic.Util.to_int (field "user_id" vector)));
    check "seed user name" (first.user.name = string "user_name" vector);
    check "seed token" (first.session.token = token);
    check "stale seed session refreshes" (Option.is_some first.refreshed_token_cookie);
    let refreshed = Option.get first.refreshed_token_cookie in
    check "renewed cookie verifies" (Signed_cookie.verify ~secret_key_base:secret
      ~name:"session_token" ~raw:refreshed ~now = Some token);
    let again = authenticated "fresh seed session remains authenticated" (run header) in
    check "second request does not refresh" (again.refreshed_token_cookie = None);
    check "refresh stores IP" (again.session.ip_address = Some "198.51.100.12");
    check "refresh stores user agent" (again.session.user_agent = Some "OCaml continuity test");
    rejected "no cookie" Authentication.Missing_cookie (run "");
    let encrypted_only = Authentication.issue_rails_session ~secret_key_base:secret ~now
      (`Assoc ["session_id", `String token]) in
    rejected "encrypted CookieStore alone cannot authenticate"
      Authentication.Missing_cookie (run ("_campfire_session=" ^ Uri.pct_encode encrypted_only));
    rejected "forged signature" Authentication.Invalid_cookie (run "session_token=tampered--0000");
    rejected "valid but unknown token" Authentication.Revoked_session
      (run (string "cookie_header" (field "forged" vectors)));
    let expired = Authentication.issue_token_cookie ~secret_key_base:secret
      ~now:"2000-01-01T00:00:00Z" token in
    rejected "expired cookie" Authentication.Invalid_cookie (run ("session_token=" ^ expired));
    let duplicate = authenticated "first duplicate cookie wins" (run (header ^ "; session_token=bad")) in
    check "duplicate cookie points to same session" (duplicate.session.id = first.session.id);
    let across_headers = Authentication.restore_headers ~db ~secret_key_base:secret ~now
      ~method_:"GET" ~remote_ip:"198.51.100.12" ~user_agent:None
      ~cookie_headers:["unrelated=1"; header; "session_token=bad"] in
    ignore (authenticated "multiple Cookie headers preserve first session token"
      (match across_headers with Ok outcome -> outcome | Error error -> failwith error));
    exec db "UPDATE users SET status=1 WHERE id=127326141";
    rejected "deactivated user" Authentication.Inactive_user (run header);
    exec db "UPDATE users SET status=2 WHERE id=127326141";
    rejected "banned user" Authentication.Inactive_user (run header);
    exec db "UPDATE users SET status=0 WHERE id=127326141";
    exec db "DELETE FROM sessions WHERE id=481019661";
    rejected "revoked session" Authentication.Revoked_session (run header))

let test_bans () =
  let secret = secret_key_base () in
  let vectors = Yojson.Basic.from_file "fixtures/campfire_sessions.json" in
  let header = string "cookie_header" (first "sessions" vectors) in
  with_seed_copy (fun db ->
    let ip = with_statement db "SELECT ip_address FROM bans LIMIT 1" (fun stmt ->
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW -> Sqlite3.column_text stmt 0
      | _ -> failwith "seed needs a banned IP") in
    let run method_ = restore db ~secret ~now:"2026-10-08T12:00:00Z" ~method_
      ~remote_ip:ip ~user_agent:None header in
    (match run "POST" with Authentication.Banned_ip -> () | _ -> failwith "POST banned IP");
    ignore (authenticated "GET from banned IP is allowed" (run "GET"));
    ignore (authenticated "HEAD from banned IP is allowed" (run "HEAD")))

let test_readonly_fresh_session () =
  let secret = secret_key_base () in
  let vector = first "sessions"
    (Yojson.Basic.from_file "fixtures/campfire_sessions.json") in
  let header = string "cookie_header" vector in
  let now = "2026-10-08T12:00:00Z" in
  with_seed_copy (fun db ->
    let inspect () = Authentication.restore_headers_readonly ~db
      ~secret_key_base:secret ~now ~method_:"GET"
      ~remote_ip:"198.51.100.12" ~user_agent:None
      ~cookie_headers:[header] in
    exec db "PRAGMA query_only=ON";
    check "stale reader requests writer refresh"
      (inspect () = Ok Authentication.Refresh_due);
    exec db "PRAGMA query_only=OFF";
    ignore (authenticated "writer refreshes stale session"
      (restore db ~secret ~now ~method_:"GET" ~remote_ip:"198.51.100.12"
         ~user_agent:None header));
    exec db "PRAGMA query_only=ON";
    (match inspect () with
     | Ok (Authentication.Ready (Authentication.Authenticated identity)) ->
         check "fresh reader does not issue renewal"
           (identity.refreshed_token_cookie = None)
     | _ -> failwith "fresh read-only session should authenticate");
    exec db "PRAGMA query_only=OFF";
    exec db "DELETE FROM sessions WHERE id=481019661";
    exec db "PRAGMA query_only=ON";
    check "reader observes revocation"
      (inspect () = Ok (Authentication.Ready
        (Authentication.Unauthenticated Authentication.Revoked_session))))

let test_rails_cookiestore () =
  let vectors = Yojson.Basic.from_file "fixtures/rails_compat.json" in
  let secret = string "secret_key_base" vectors in
  let now = string "now" vectors in
  let vector = field "session" vectors in
  let raw = string "session_cookie_raw" vector in
  let expected = field "session" vector in
  let actual = Authentication.read_rails_session ~secret_key_base:secret ~now
    ("_campfire_session=" ^ Cookie_http.escape raw) in
  check "Rails encrypted CookieStore payload" (actual = Some expected);
  let issued = Authentication.issue_rails_session ~secret_key_base:secret ~now expected in
  check "OCaml issued CookieStore payload decodes" (Authentication.read_rails_session
    ~secret_key_base:secret ~now ("_campfire_session=" ^ Cookie_http.escape issued) = Some expected);
  let signed = Authentication.issue_token_cookie ~secret_key_base:secret ~now "hello" in
  check "issued signed cookie decodes" (Signed_cookie.verify ~secret_key_base:secret
    ~name:"session_token" ~raw:signed ~now = Some "hello");
  check "issued Rails token is byte-identical" (Authentication.issue_token_cookie
    ~secret_key_base:secret ~now (string "session_token_value" vector) =
    string "session_token_raw" vector);
  check "tampered CookieStore rejected" (Authentication.read_rails_session
    ~secret_key_base:secret ~now ("_campfire_session=" ^ raw ^ "x") = None)

let test_concurrent_key_rotation () =
  let now = "2026-10-08T12:00:00Z" in
  let count = 24 in
  let secrets = Array.init count (fun i -> Printf.sprintf "fixture-secret-%d" i) in
  let signed = Array.make count "" in
  let encrypted = Array.make count "" in
  let completed = Array.make count false in
  let workers = Array.init count (fun i -> Thread.create (fun () ->
    try
      let secret_key_base = secrets.(i) in
      let value = Printf.sprintf "fixture-session-%d" i in
      let raw = Signed_cookie.generate ~secret_key_base ~name:"session_token"
        ~value ~expires_at:None in
      let payload = `Assoc ["worker", `Int i] in
      let sealed = Encrypted_cookie.encrypt_with_iv ~secret_key_base
        ~name:"_campfire_session" ~value:payload ~expires_at:None
        ~iv:(String.make 12 (Char.chr (i + 1))) in
      let ok = ref true in
      for _ = 1 to 8 do
        ok := !ok &&
          Signed_cookie.verify ~secret_key_base ~name:"session_token"
            ~raw ~now = Some value &&
          Encrypted_cookie.decrypt ~secret_key_base ~name:"_campfire_session"
            ~raw:sealed ~now = Some payload
      done;
      signed.(i) <- raw;
      encrypted.(i) <- sealed;
      completed.(i) <- !ok
    with _ -> completed.(i) <- false) ()) in
  Array.iter Thread.join workers;
  check "parallel signed and encrypted cookie verification"
    (Array.for_all Fun.id completed);
  for i = 0 to count - 1 do
    let wrong = secrets.((i + 1) mod count) in
    check "rotated secret rejects signed cookie"
      (Signed_cookie.verify ~secret_key_base:wrong ~name:"session_token"
        ~raw:signed.(i) ~now = None);
    check "rotated secret rejects encrypted cookie"
      (Encrypted_cookie.decrypt ~secret_key_base:wrong
        ~name:"_campfire_session" ~raw:encrypted.(i) ~now = None)
  done

let () =
  Alcotest.run "M1-T3 Rails sessions" [
    "seed", [Alcotest.test_case "Rails cookie authenticates and refreshes" `Quick test_seed_continuity;
             Alcotest.test_case "fresh GET uses read-only session path" `Quick test_readonly_fresh_session;
             Alcotest.test_case "unsafe methods block banned IPs" `Quick test_bans];
    "cookies", [Alcotest.test_case "encrypted Rails CookieStore continuity" `Quick test_rails_cookiestore];
    "rotation", [Alcotest.test_case "concurrent derived keys isolate secrets" `Quick test_concurrent_key_rotation];
  ]

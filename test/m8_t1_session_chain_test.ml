open Campfire

let check label condition = Alcotest.(check bool) label true condition
let status response = Cohttp.Code.code_of_status (Cohttp.Response.status response)
let now = "2026-10-08T12:00:00Z"
let secret = String.make 64 't'

let rec reference_root path remaining =
  if remaining = 0 then failwith "pinned Rust seed not found";
  let candidate = Filename.concat path "once-campfire-rust" in
  if Sys.file_exists (Filename.concat candidate "parity/.seed/default/db/production.sqlite3")
  then candidate else reference_root (Filename.dirname path) (remaining - 1)

let with_seed f =
  let root = reference_root (Sys.getcwd ()) 8 in
  let seed = Filename.concat root "parity/.seed/default/db/production.sqlite3" in
  let source = Sqlite3.db_open ~mode:`READONLY seed in
  let temporary = Filename.temp_file "campfire-m8-session-" ".sqlite3" in
  Sys.remove temporary;
  let quoted = String.concat "''" (String.split_on_char '\'' temporary) in
  let rc = Sqlite3.exec source ("VACUUM INTO '" ^ quoted ^ "'") in
  ignore (Sqlite3.db_close source);
  if rc <> Sqlite3.Rc.OK then failwith "could not copy pinned seed";
  let runtime = Db_runtime.open_db ~readers:1 ~prepare:false temporary in
  Fun.protect ~finally:(fun () ->
    Db_runtime.close runtime;
    List.iter (fun path -> if Sys.file_exists path then Sys.remove path)
      [temporary; temporary ^ "-wal"; temporary ^ "-shm"])
    (fun () -> f runtime)

let json_value name ctx =
  Option.value (Http_app.session_get ctx name) ~default:`Null

let public_action ctx =
  let response = match ctx.Http_app.route.Routes.endpoint with
  | "sessions#new" when Http_app.param_string ctx "notice" = Some "1" ->
      Http_app.session_set ctx "flash"
        (`Assoc ["flashes", `Assoc ["notice", `String "✓"];
                 "discard", `List []]);
      Http_app.redirect (Http_app.base_url ctx ^ "/session/new")
  | "sessions#new" ->
      let notice = Option.value (List.assoc_opt "notice" (Http_app.flash ctx)) ~default:`Null in
      Http_app.json ~status:200 (`Assoc ["notice", notice])
  | "sessions#show" ->
      Http_app.json ~status:200 (`Assoc ["value", json_value "value" ctx;
        "id", json_value "session_id" ctx])
  | "sessions#create" ->
      Http_app.session_set ctx "value"
        (`String (Option.value (Http_app.param_string ctx "value") ~default:""));
      Http_app.json ~status:200 (`Assoc [])
  | "sessions#destroy" ->
      Http_app.reset_session ctx;
      Http_app.json ~status:200 (`Assoc [])
  | _ -> Http_app.json ~status:200 (`Assoc []) in
  Lwt.return response

let dispatch endpoint =
  let before_action = match endpoint with
  | "accounts#edit" -> Http_app.before ~access:User ~csrf:false ()
  | _ -> Http_app.before ~access:Public ~csrf:false () in
  Some Http_app.{before_action; action=public_action}

let send ?cookie ?(body="") runtime meth path =
  let headers = ["host", "chat.example.com";
    "content-type", "application/x-www-form-urlencoded";
    "origin", "https://chat.example.com";
    "sec-fetch-site", "same-origin"] in
  let headers = match cookie with None -> headers | Some value -> ("cookie",value)::headers in
  let request = Cohttp.Request.make ~meth ~headers:(Cohttp.Header.of_list headers)
    (Uri.of_string ("https://chat.example.com" ^ path)) in
  let response, body = Lwt_main.run (Http_app.handle ~runtime
    ~secret_key_base:secret ~now ~ssl:true ~force_ssl:true ~dispatch request
      (Cohttp_lwt.Body.of_string body)) in
  response, Lwt_main.run (Cohttp_lwt.Body.to_string body)

let cookies response = Cohttp.Header.get_multi (Cohttp.Response.headers response) "set-cookie"
let cookie_named name response =
  List.find_opt (String.starts_with ~prefix:(name ^ "=")) (cookies response)
let cookie_pair raw = List.hd (String.split_on_char ';' raw)
let body_json (_, body) = Yojson.Basic.from_string body
let field name response = Yojson.Basic.Util.member name (body_json response)

let test_session_changes () = with_seed (fun runtime ->
  let untouched = send runtime `GET "/session" in
  Alcotest.(check int) "untouched status" 200 (status (fst untouched));
  Alcotest.(check (list string)) "untouched sends no cookie" [] (cookies (fst untouched));
  let set = send ~body:"value=%2Frooms%2F1" runtime `POST "/session" in
  Alcotest.(check int) "set status" 200 (status (fst set));
  let raw = Option.get (cookie_named "_campfire_session" (fst set)) in
  let saved = cookie_pair raw in
  let read = send ~cookie:saved runtime `GET "/session" in
  Alcotest.(check (option string)) "read value" (Some "/rooms/1")
    (Yojson.Basic.Util.to_string_option (field "value" read));
  Alcotest.(check (list string)) "read sends no cookie" [] (cookies (fst read));
  let id = Yojson.Basic.Util.to_string (field "id" read) in
  Alcotest.(check int) "session id length" 32 (String.length id);
  let noop = send ~cookie:saved runtime `GET "/session/new" in
  Alcotest.(check (list string)) "noop sends no cookie" [] (cookies (fst noop));
  let same = send ~cookie:saved ~body:"value=%2Frooms%2F1" runtime `POST "/session" in
  Alcotest.(check (list string)) "same write sends no cookie" [] (cookies (fst same));
  let again = send ~cookie:saved runtime `GET "/session" in
  Alcotest.(check string) "same session id" id
    (Yojson.Basic.Util.to_string (field "id" again));
  let reset = send ~cookie:saved runtime `DELETE "/session" in
  let deleted = Option.get (cookie_named "_campfire_session" (fst reset)) in
  check "reset deletes cookie" (String.starts_with ~prefix:"_campfire_session=;" deleted);
  let after = send ~cookie:(cookie_pair deleted) runtime `GET "/session" in
  check "reset clears value" (field "value" after = `Null);
  check "reset changes session id"
    (Yojson.Basic.Util.to_string (field "id" after) <> id);
  let bogus = send ~cookie:"_campfire_session=garbage" runtime `GET "/session" in
  check "tampered cookie clears value" (field "value" bogus = `Null);
  Alcotest.(check int) "tampered cookie does not fail" 200 (status (fst bogus)))

let test_flash_redirect () = with_seed (fun runtime ->
  let redirect = send runtime `GET "/session/new?notice=1" in
  Alcotest.(check int) "flash redirect" 302 (status (fst redirect));
  Alcotest.(check (option string)) "redirect target"
    (Some "https://chat.example.com/session/new")
    (Cohttp.Header.get (Cohttp.Response.headers (fst redirect)) "location");
  let saved = cookie_pair (Option.get (cookie_named "_campfire_session" (fst redirect))) in
  let shown = send ~cookie:saved runtime `GET "/session/new" in
  Alcotest.(check (option string)) "notice after redirect" (Some "✓")
    (Yojson.Basic.Util.to_string_option (field "notice" shown));
  let deleted = Option.get (cookie_named "_campfire_session" (fst shown)) in
  check "flash only cookie deleted" (String.starts_with ~prefix:"_campfire_session=;" deleted);
  let gone = send ~cookie:(cookie_pair deleted) runtime `GET "/session/new" in
  check "notice consumed" (field "notice" gone = `Null))

let test_auth_revocation () = with_seed (fun runtime ->
  let session = Db_runtime.write runtime (fun tx ->
    let db = Db_runtime.conn tx in
    let user = Option.get (Db_accounts.User.find_by_email_address db "david@37signals.com") in
    Db_accounts.Session.start db ~now ~user_id:user.id
      ~user_agent:None ~ip_address:(Some "127.0.0.1")) in
  let token = "session_token=" ^ Authentication.issue_token_cookie
    ~secret_key_base:secret ~now session.token in
  let good = send ~cookie:token runtime `GET "/account/edit" in
  Alcotest.(check int) "signed token authenticates" 200 (status (fst good));
  Db_runtime.write runtime (fun tx ->
    Db_accounts.Session.destroy (Db_runtime.conn tx) session);
  let revoked = send ~cookie:token runtime `GET "/account/edit" in
  Alcotest.(check int) "revoked token redirects" 302 (status (fst revoked));
  Alcotest.(check (option string)) "revoked sign-in location"
    (Some "https://chat.example.com/session/new")
    (Cohttp.Header.get (Cohttp.Response.headers (fst revoked)) "location");
  let malformed = send ~cookie:"session_token=garbage" runtime `GET "/account/edit" in
  Alcotest.(check int) "malformed token redirects" 302 (status (fst malformed)))

let contains haystack needle =
  let n = String.length needle in
  let rec loop at = at + n <= String.length haystack &&
    (String.sub haystack at n = needle || loop (at+1)) in
  loop 0

let test_h2_idle_configuration () =
  let config = Front_config.from_lookup (function
    | "H2C_ENABLED" -> Some "true"
    | "HTTP_IDLE_TIMEOUT" -> Some "2"
    | "HTTP_READ_TIMEOUT" -> Some "1"
    | _ -> None) in
  let file = Front_config.caddyfile config in
  check "h2c enabled" (contains file "protocols h1 h2c");
  check "idle deadline distinct from read deadline"
    (contains file "read_header 1s" && contains file "idle 2s");
  let disabled = Front_config.caddyfile {config with h2c_enabled=false} in
  check "h2c disabled" (contains disabled "protocols h1\n" &&
    not (contains disabled "protocols h1 h2c"))

let () = Alcotest.run "M8-T1 action chain" [
  "session", [
    Alcotest.test_case "writes only on change and rejects malformed" `Quick test_session_changes;
    Alcotest.test_case "flash crosses one redirect" `Quick test_flash_redirect;
    Alcotest.test_case "signed auth revocation" `Quick test_auth_revocation;
  ];
  "front", [Alcotest.test_case "h2c idle configuration" `Quick test_h2_idle_configuration]
]

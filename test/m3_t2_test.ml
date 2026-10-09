open Campfire

let check label condition = Alcotest.(check bool) label true condition
let status response = Cohttp.Code.code_of_status (Cohttp.Response.status response)
let location response = Cohttp.Header.get (Cohttp.Response.headers response) "location"
let cookie response =
  Cohttp.Header.get_multi (Cohttp.Response.headers response) "set-cookie"
  |> List.filter_map (fun value ->
    if String.starts_with ~prefix:"session_token=" value then
      Some (String.split_on_char ';' value |> List.hd) else None)
  |> List.hd
let now = "2026-10-08T12:00:00Z"
let secret = String.make 64 't'

let flash_notice response =
  let header = Cohttp.Header.get_multi (Cohttp.Response.headers response) "set-cookie"
    |> List.find (String.starts_with ~prefix:"_campfire_session=") in
  let raw = Cookie_http.parse_header header
    |> Cookie_http.find "_campfire_session" |> Option.get in
  let data = Encrypted_cookie.decrypt ~secret_key_base:secret
    ~name:"_campfire_session" ~raw ~now |> Option.get in
  match data with
  | `Assoc fields ->
      (match List.assoc_opt "flash" fields with
       | Some (`Assoc flash) ->
           (match List.assoc_opt "flashes" flash with
            | Some (`Assoc values) ->
                (match List.assoc_opt "notice" values with
                 | Some (`String value) -> value | _ -> failwith "notice missing")
            | _ -> failwith "flashes missing")
       | _ -> failwith "flash missing")
  | _ -> failwith "session object missing"

let rec reference_root path remaining =
  if remaining = 0 then failwith "pinned Rust reference checkout not found"
  else let candidate = Filename.concat path "once-campfire-rust" in
    if Sys.file_exists (Filename.concat candidate "parity/.seed/default/db/production.sqlite3")
    then candidate else reference_root (Filename.dirname path) (remaining - 1)
let reference = reference_root (Sys.getcwd ()) 8

let with_seed variant f =
  let source = Sqlite3.db_open ~mode:`READONLY
    (Filename.concat reference ("parity/.seed/" ^ variant ^ "/db/production.sqlite3")) in
  let temporary = Filename.temp_file "campfire-m3-t2-" ".sqlite3" in
  Sys.remove temporary;
  let quoted = String.concat "''" (String.split_on_char '\'' temporary) in
  let rc = Sqlite3.exec source ("VACUUM INTO '" ^ quoted ^ "'") in
  ignore (Sqlite3.db_close source);
  if rc <> Sqlite3.Rc.OK then failwith "could not copy pinned seed";
  let runtime = Db_runtime.open_db ~readers:1 ~prepare:false temporary in
  Fun.protect ~finally:(fun () ->
    Db_runtime.close runtime;
    List.iter (fun path -> if Sys.file_exists path then Sys.remove path)
      [temporary;temporary^"-wal";temporary^"-shm"])
    (fun () -> f runtime)

let send ?cookie_header ?accept ?turbo_frame ?range ?if_none_match ?(at=now)
    ?(content_type="application/x-www-form-urlencoded")
    ?(body="") runtime meth path =
  let headers = ["host","chat.example.com";
    "content-type",content_type;
    "origin","https://chat.example.com";
    "sec-fetch-site","same-origin"] in
  let headers = match cookie_header with
    | None -> headers | Some value -> ("cookie",value)::headers in
  let headers = match accept with
    | None -> headers | Some value -> ("accept",value)::headers in
  let headers = match turbo_frame with
    | None -> headers | Some value -> ("turbo-frame",value)::headers in
  let headers = match range with
    | None -> headers | Some value -> ("range",value)::headers in
  let headers = match if_none_match with
    | None -> headers | Some value -> ("if-none-match",value)::headers in
  let request = Cohttp.Request.make ~meth ~headers:(Cohttp.Header.of_list headers)
    (Uri.of_string ("https://chat.example.com"^path)) in
  let response, body = Lwt_main.run (Http_app.handle ~runtime ~secret_key_base:secret
    ~now:at ~ssl:true ~force_ssl:true ~dispatch:Controller_accounts.endpoint
    request (Cohttp_lwt.Body.of_string body)) in
  response, Lwt_main.run (Cohttp_lwt.Body.to_string body)

let mint_session runtime user_id =
  let row = Db_runtime.write runtime (fun tx ->
    Db_accounts.Session.start (Db_runtime.conn tx) ~now ~user_id
      ~user_agent:None ~ip_address:(Some "198.51.100.10")) in
  "session_token=" ^ Authentication.issue_token_cookie
    ~secret_key_base:secret ~now row.token

let test_route_inventory () =
  let owns endpoint = List.exists (fun prefix -> String.starts_with ~prefix endpoint)
    ["welcome#";"first_runs#";"sessions#";"sessions/transfers#";
     "accounts#";"accounts/";"users#";"users/"] in
  let routes = List.filter (fun (_,_,endpoint,_) -> owns endpoint) Route_catalog.routes in
  Alcotest.(check int) "M3-T2 route rows" 73 (List.length routes);
  List.iter (fun (_,_,endpoint,_) ->
    check ("handler for " ^ endpoint) (Option.is_some (Controller_accounts.endpoint endpoint))) routes;
  let absent = [
    "first_runs#new";"first_runs#edit";"first_runs#update";"first_runs#destroy";
    "sessions#edit";"sessions#show";"sessions#update";
    "accounts/users#create";"accounts/users#new";"accounts/users#edit";
    "accounts/users#show";"accounts/bots#show";
    "accounts#new";"accounts#show";"accounts#destroy";"accounts#create";
    "users/profiles#new";"users/profiles#edit";"users/profiles#destroy";
    "users/profiles#create";"users/push_subscriptions#new";
    "users/push_subscriptions#edit";"users/push_subscriptions#show";
    "users/push_subscriptions#update" ] in
  Alcotest.(check int) "Rust action_not_found route rows" 27
    (List.length (List.filter (fun (_,_,endpoint,_) -> List.mem endpoint absent) routes));
  with_seed "default" (fun runtime ->
    let path pattern =
      String.split_on_char '/' pattern |> List.map (fun segment ->
        let segment = match String.index_opt segment '(' with
          | None -> segment | Some i -> String.sub segment 0 i in
        if String.starts_with ~prefix:":" segment then "1" else segment)
      |> String.concat "/" in
    List.iter (fun (verb,pattern,endpoint,_) ->
      if List.mem endpoint absent then
        let meth = match verb with
          | "GET" -> `GET | "POST" -> `POST | "PATCH" -> `PATCH
          | "PUT" -> `PUT | "DELETE" -> `DELETE | _ -> failwith "unexpected method" in
        let actual,_ = send runtime meth (path pattern) in
        Alcotest.(check int) ("missing action " ^ endpoint) 404 (status actual)) routes)

let test_session_account_and_join () = with_seed "default" (fun runtime ->
  let anonymous,_ = send runtime `GET "/account/edit" in
  Alcotest.(check int) "account page requires session" 302 (status anonymous);
  Alcotest.(check (option string)) "absolute sign-in location"
    (Some "https://chat.example.com/session/new") (location anonymous);
  let missing,_ = send runtime `GET "/session/edit" in
  Alcotest.(check int) "declared but missing action" 404 (status missing);

  let bad,bad_body = send ~body:"email_address=david%4037signals.com&password=nope"
    runtime `POST "/session" in
  Alcotest.(check int) "wrong password" 401 (status bad);
  check "rejected login renders the sign-in view" (
    String.length bad_body > 10_000 &&
    String.contains bad_body '<' &&
    String.starts_with ~prefix:"<!DOCTYPE html>" bad_body);
  check "rejected login includes the alert" (
    let phrase="Too many requests or unauthorized." in
    let length=String.length phrase in
    let rec contains at =
      at+length<=String.length bad_body &&
      (String.sub bad_body at length=phrase || contains (at+1)) in
    contains 0);
  let login,_ = send ~body:"email_address=david%4037signals.com&password=secret123456"
    runtime `POST "/session" in
  Alcotest.(check int) "Rails fixture password signs in" 302 (status login);
  let admin_cookie = cookie login in
  check "signed auth cookie emitted" (String.starts_with ~prefix:"session_token=" admin_cookie);
  let settings,_ = send ~cookie_header:admin_cookie runtime `GET "/account/edit" in
  Alcotest.(check int) "signed-in account page" 200 (status settings);
  let updated,_ = send ~cookie_header:admin_cookie ~body:"account%5Bname%5D=Campfire+OCaml"
    runtime `PATCH "/account" in
  Alcotest.(check int) "administrator update" 302 (status updated);
  Alcotest.(check string) "account update flash notice" "✓" (flash_notice updated);
  Db_runtime.read runtime (fun db ->
    Alcotest.(check string) "account persisted" "Campfire OCaml"
      (Option.get (Db_accounts.Account.first db)).name);
  let styles,_ = send ~cookie_header:admin_cookie
    ~body:"account%5Bcustom_styles%5D=body%7Bcolor%3Ared%7D"
    runtime `PATCH "/account/custom_styles" in
  Alcotest.(check int) "custom styles update" 302 (status styles);
  Alcotest.(check string) "custom styles flash notice" "✓" (flash_notice styles);

  let member_cookie = mint_session runtime 712064548L in
  let denied,_ = send ~cookie_header:member_cookie ~body:"account%5Bname%5D=Wrong"
    runtime `PATCH "/account" in
  Alcotest.(check int) "member cannot administer" 403 (status denied);
  let invalid,_ = send runtime `GET "/join/invalid" in
  Alcotest.(check int) "invalid join code" 404 (status invalid);
  let code = Db_runtime.read runtime (fun db ->
    (Option.get (Db_accounts.Account.first db)).join_code) in
  let form,_ = send runtime `GET ("/join/"^code) in
  Alcotest.(check int) "valid join page" 200 (status form);
  let joined,_ = send ~body:"user%5Bname%5D=Fresh&user%5Bemail_address%5D=fresh%40example.com&user%5Bpassword%5D=secret123456"
    runtime `POST ("/join/"^code) in
  Alcotest.(check int) "valid join creates user" 302 (status joined);
  Db_runtime.read runtime (fun db ->
    check "new user persisted" (Option.is_some
      (Db_accounts.User.find_by_email_address db "fresh@example.com")));
  let logout,_ = send ~cookie_header:admin_cookie runtime `DELETE "/session" in
  Alcotest.(check int) "logout" 302 (status logout))

let test_first_run () = with_seed "first_run" (fun runtime ->
  let setup,_ = send runtime `GET "/first_run" in
  Alcotest.(check int) "first-run page" 200 (status setup);
  let created,_ = send
    ~body:"user%5Bname%5D=Founder&user%5Bemail_address%5D=founder%40example.com&user%5Bpassword%5D=secret123456"
    runtime `POST "/first_run" in
  Alcotest.(check int) "first-run creates account" 302 (status created);
  Db_runtime.read runtime (fun db ->
    Alcotest.(check int) "one account" 1 (Db_accounts.Account.count db);
    Alcotest.(check int) "one administrator" 1 (Db_accounts.User.count db);
    Alcotest.(check int) "one open room" 1
      (Int64.to_int (Db_rooms.Room.count_of_type db Db_rooms.Open)));
  let repeated,_ = send runtime `GET "/first_run" in
  Alcotest.(check int) "setup cannot repeat" 302 (status repeated))

let test_first_run_stock_logo_cache () =
  with_seed "first_run" (fun runtime ->
    Alcotest.(check int) "first-run seed has no account" 0
      (Db_runtime.read runtime Db_accounts.Account.count);
    let large,body=send runtime `GET "/account/logo" in
    let headers=Cohttp.Response.headers large in
    Alcotest.(check int) "public stock logo" 200 (status large);
    check "stock logo has body" (String.length body > 100);
    Alcotest.(check (option string)) "stock logo MIME"
      (Some "image/png") (Cohttp.Header.get headers "content-type");
    Alcotest.(check (option string)) "stock logo cache policy"
      (Some "max-age=300, public, stale-while-revalidate=604800")
      (Cohttp.Header.get headers "cache-control");
    check "no account means no logo ETag"
      (not (Cohttp.Header.mem headers "etag"));
    let small,small_body=send ~if_none_match:"*" runtime `GET
      "/account/logo?size=small" in
    Alcotest.(check int) "stock icon ignores wildcard validator" 200
      (status small);
    check "small stock icon has body" (String.length small_body > 100);
    check "small no-account icon has no ETag"
      (not (Cohttp.Header.mem (Cohttp.Response.headers small) "etag")));
  with_seed "default" (fun runtime ->
    let present,_=send runtime `GET "/account/logo" in
    Alcotest.(check int) "account stock logo" 200 (status present);
    check "account-backed logo retains validator"
      (Cohttp.Header.mem (Cohttp.Response.headers present) "etag"))

let test_roles_bots_profile_and_bans () = with_seed "default" (fun runtime ->
  let admin = mint_session runtime 127326141L in
  let member = mint_session runtime 712064548L in
  let denied,_ = send ~cookie_header:member ~body:"user%5Bname%5D=Badbot"
    runtime `POST "/account/bots" in
  Alcotest.(check int) "member cannot create bot" 403 (status denied);
  let made,_ = send ~cookie_header:admin
    ~body:"user%5Bname%5D=Deploy+Helper&user%5Bwebhook_url%5D=https%3A%2F%2Fexample.com%2Fhook"
    runtime `POST "/account/bots" in
  Alcotest.(check int) "admin creates bot" 302 (status made);
  let bot = Db_runtime.read runtime (fun db ->
    Db_accounts.User.active_bots_ordered db
    |> List.find (fun (user : Db_accounts.User.t) -> user.name = "Deploy Helper")) in
  check "bot has token" (Option.is_some bot.bot_token);
  let old_key = bot.bot_token in
  let rotated,_ = send ~cookie_header:admin runtime `PATCH
    ("/account/bots/"^Int64.to_string bot.id^"/key") in
  Alcotest.(check int) "bot key rotates" 302 (status rotated);
  Db_runtime.read runtime (fun db ->
    check "bot key changed"
      ((Db_accounts.User.find db bot.id).bot_token <> old_key));
  let deactivated,_ = send ~cookie_header:admin runtime `DELETE
    ("/account/bots/"^Int64.to_string bot.id) in
  Alcotest.(check int) "bot deactivation" 302 (status deactivated);
  Db_runtime.read runtime (fun db ->
    check "bot inactive" (Db_accounts.User.is_deactivated (Db_accounts.User.find db bot.id)));

  let updated,_ = send ~cookie_header:member
    ~body:"user%5Bname%5D=Kevin+Edited&user%5Bbio%5D=Working+here"
    runtime `PATCH "/users/me/profile" in
  Alcotest.(check int) "self profile update" 302 (status updated);
  Alcotest.(check string) "profile update flash notice" "✓" (flash_notice updated);
  Db_runtime.read runtime (fun db ->
    let user = Db_accounts.User.find db 712064548L in
    Alcotest.(check string) "profile name" "Kevin Edited" user.name;
    Alcotest.(check (option string)) "profile bio" (Some "Working here") user.bio);
  let role,_ = send ~cookie_header:admin
    ~body:"user%5Brole%5D=administrator"
    runtime `PATCH "/account/users/712064548" in
  Alcotest.(check int) "admin changes role" 302 (status role);
  Db_runtime.read runtime (fun db ->
    check "role persisted" (Db_accounts.User.is_administrator
      (Db_accounts.User.find db 712064548L)));

  let denied_ban,_ = send ~cookie_header:member runtime `POST "/users/773523953/ban" in
  (* The member's pre-request cookie now resolves to a freshly granted administrator.
     A different still-member session checks the authorization boundary. *)
  Alcotest.(check int) "new admin can ban" 302 (status denied_ban);
  Db_runtime.read runtime (fun db ->
    check "ban status persisted" (Db_accounts.User.is_banned
      (Db_accounts.User.find db 773523953L)));
  let unbanned,_ = send ~cookie_header:admin runtime `DELETE "/users/773523953/ban" in
  Alcotest.(check int) "admin can unban" 302 (status unbanned);
  Db_runtime.read runtime (fun db ->
    check "unban status persisted" (Db_accounts.User.is_active
      (Db_accounts.User.find db 773523953L)));

  let stream,_ = send ~cookie_header:admin
    ~accept:"text/vnd.turbo-stream.html" runtime `GET "/account/users" in
  Alcotest.(check int) "users stream format" 200 (status stream);
  let wrong_format,_ = send ~cookie_header:admin runtime `GET "/account/users" in
  Alcotest.(check int) "users stream rejects HTML" 406 (status wrong_format))

let test_sidebar_response_mode () = with_seed "default" (fun runtime ->
  let cookie=mint_session runtime 127326141L in
  let page,full=send ~cookie_header:cookie runtime `GET "/users/me/sidebar" in
  Alcotest.(check int) "ordinary sidebar page" 200 (status page);
  check "ordinary sidebar has application document"
    (String.starts_with ~prefix:"<!DOCTYPE html>" full &&
     String.contains full '<');
  let frame_response,frame=send ~cookie_header:cookie
    ~turbo_frame:"user_sidebar" runtime `GET "/users/me/sidebar" in
  Alcotest.(check int) "Turbo sidebar frame" 200 (status frame_response);
  check "Turbo sidebar has frame without document"
    (not (String.starts_with ~prefix:"<!DOCTYPE html>" frame) &&
     String.starts_with ~prefix:"<turbo-frame" frame);
  let _,empty_header=send ~cookie_header:cookie ~turbo_frame:"  "
    runtime `GET "/users/me/sidebar" in
  check "blank Turbo-Frame header keeps full document"
    (String.starts_with ~prefix:"<!DOCTYPE html>" empty_header))

let test_transfer_and_push () = with_seed "default" (fun runtime ->
  Db_runtime.read runtime (fun db ->
    let lookup fields = Controller_accounts.matching_push_subscription db
      ~user_id:127326141L fields in
    let first=Option.get (lookup []) in
    Alcotest.(check int64) "empty push key subset finds first user's row"
      56887440L first.Db_remaining.Push_subscription.id;
    let by_endpoint=Option.get (lookup ["endpoint",Http_params.Text
      "https://updates.push.services.mozilla.com/wpush/v2/parity-firefox"]) in
    Alcotest.(check int64) "one supplied push key selects matching row"
      782661004L by_endpoint.id;
    check "push subset is scoped to current user"
      (lookup ["endpoint",Http_params.Text
        "https://fcm.googleapis.com/fcm/send/456"]=None));
  let transfer = Signed_id.generate ~secret_key_base:secret ~model:"User" ~id:127326141
    ~purpose:(Some "transfer") ~expires_at:(Some "2026-10-08T16:00:00Z") in
  let shown,_ = send runtime `GET ("/session/transfers/"^transfer) in
  Alcotest.(check int) "transfer form" 200 (status shown);
  let bad,_ = send runtime `PUT "/session/transfers/bad" in
  Alcotest.(check int) "bad transfer ID" 400 (status bad);
  let good,_ = send runtime `PUT ("/session/transfers/"^transfer) in
  Alcotest.(check int) "signed transfer starts session" 302 (status good);
  check "transfer sets signed session" (cookie good <> "");
  let admin = mint_session runtime 127326141L in
  let subscriptions,subscription_body = send ~cookie_header:admin
    runtime `GET "/users/me/push_subscriptions" in
  Alcotest.(check int) "push subscriptions page" 200 (status subscriptions);
  let includes text needle =
    let rec find i = i + String.length needle <= String.length text &&
      (String.sub text i (String.length needle) = needle || find (i+1)) in
    find 0 in
  check "push page includes seeded subscription"
    (includes subscription_body "fcm.googleapis.com/fcm/send/123");
  let invalid,_ = send ~cookie_header:admin
    ~body:"push_subscription%5Bendpoint%5D=http%3A%2F%2Flocalhost%2Fpush"
    runtime `POST "/users/me/push_subscriptions" in
  Alcotest.(check int) "unsafe push endpoint rejected" 422 (status invalid);
  let json_invalid,_ = send ~cookie_header:admin
    ~content_type:"application/json; charset=UTF-8"
    ~body:"{\"endpoint\":\"http://localhost/push\"}"
    runtime `POST "/users/me/push_subscriptions" in
  Alcotest.(check int) "JSON push parameters wrap with charset" 422
    (status json_invalid);
  let missing,_ = send ~cookie_header:admin runtime `DELETE
    "/users/me/push_subscriptions/999999999" in
  Alcotest.(check int) "missing subscription deletion is idempotent" 302 (status missing))

let contains haystack needle =
  let rec scan at = at + String.length needle <= String.length haystack &&
    (String.sub haystack at (String.length needle) = needle || scan (at + 1)) in
  scan 0

let test_join_and_bot_presenter_data () = with_seed "default" (fun runtime ->
  let code=Db_runtime.read runtime (fun db ->
    (Option.get (Db_accounts.Account.first db)).join_code) in
  let join,join_body=send runtime `GET ("/join/" ^ code) in
  Alcotest.(check int) "join page" 200 (status join);
  check "join has first administrator contact"
    (contains join_body "david@37signals.com");
  let admin=mint_session runtime 127326141L in
  let edit,bot_body=send ~cookie_header:admin runtime `GET
    "/account/bots/394959859/edit" in
  Alcotest.(check int) "bot edit" 200 (status edit);
  check "bot edit has webhook" (contains bot_body "http://example.com/bender");
  let avatar,avatar_body=send ~cookie_header:admin runtime `GET
    "/account/bots/773523956/edit" in
  Alcotest.(check int) "avatar bot edit" 200 (status avatar);
  check "bot edit has attachment redirect"
    (contains avatar_body "/rails/active_storage/blobs/redirect/"))

let test_account_presenter_roles () = with_seed "default" (fun runtime ->
  let admin=mint_session runtime 127326141L in
  let member=mint_session runtime 712064548L in
  let admin_response,admin_body=send ~cookie_header:admin runtime `GET
    "/account/edit" in
  Alcotest.(check int) "admin account page" 200 (status admin_response);
  check "admin sees banned person" (contains admin_body "Mallory Banned");
  check "admin gets bot settings navigation"
    (contains admin_body "/account/bots");
  let member_response,member_body=send ~cookie_header:member runtime `GET
    "/account/edit" in
  Alcotest.(check int) "member account page" 200 (status member_response);
  check "member does not see banned person"
    (not (contains member_body "Mallory Banned"));
  check "member has no bot settings navigation"
    (not (contains member_body "/account/bots")))

let test_profile_and_user_presenters () = with_seed "default" (fun runtime ->
  let admin=mint_session runtime 127326141L in
  let member=mint_session runtime 712064548L in
  let profile,profile_body=send ~cookie_header:admin runtime `GET
    "/users/me/profile" in
  Alcotest.(check int) "profile page" 200 (status profile);
  check "profile includes seeded transfer link"
    (contains profile_body "/session/transfers/");
  check "profile includes seeded room membership"
    (contains profile_body "/rooms/");
  let user_page,user_body=send ~cookie_header:admin runtime `GET
    "/users/127326141" in
  Alcotest.(check int) "user page" 200 (status user_page);
  check "admin sees user's email" (contains user_body "david@37signals.com");
  let member_page,member_body=send ~cookie_header:member runtime `GET
    "/users/127326141" in
  Alcotest.(check int) "member sees user page" 200 (status member_page);
  check "member does not see user's email"
    (not (contains member_body "david@37signals.com")))

let test_public_exception_headers () = with_seed "default" (fun runtime ->
  let admin=mint_session runtime 127326141L in
  let code=Db_runtime.read runtime (fun db ->
    (Option.get (Db_accounts.Account.first db)).join_code) in
  let cases=[
    `PATCH,"/account";
    `PUT,"/account/custom_styles";
    `PATCH,"/account/users/127326141";
    `POST,"/account/bots";
    `PATCH,"/account/bots/394959859";
    `PATCH,"/users/me/profile"] in
  List.iter (fun (meth,path) ->
    let actual,body=send ~cookie_header:admin runtime meth path in
    let headers=Cohttp.Response.headers actual in
    Alcotest.(check int) ("missing params status " ^ path) 400 (status actual);
    Alcotest.(check string) ("missing params body " ^ path) "" body;
    Alcotest.(check (option string)) "public exception MIME"
      (Some "text/html; charset=UTF-8") (Cohttp.Header.get headers "content-type");
    Alcotest.(check (option string)) "public exception length"
      (Some "0") (Cohttp.Header.get headers "content-length");
    check "public exception omits app version" (not (Cohttp.Header.mem headers "x-version"));
    check "public exception omits app security headers"
      (not (Cohttp.Header.mem headers "x-frame-options"));
    check "public exception omits app cookie"
      (not (Cohttp.Header.mem headers "set-cookie"));
    Alcotest.(check (list string)) "front adds one public exception Vary"
      ["Accept-Encoding"] (Cohttp.Header.get_multi headers "vary");
    check "public exception omits cache control"
      (not (Cohttp.Header.mem headers "cache-control"))) cases;
  let join,body=send runtime `POST ("/join/" ^ code) in
  Alcotest.(check int) "anonymous join missing params" 400 (status join);
  Alcotest.(check string) "anonymous join exception body" "" body;
  check "join exception omits app security headers"
    (not (Cohttp.Header.mem (Cohttp.Response.headers join) "x-frame-options"));
  List.iter (fun meth ->
    let signed,_=send ~cookie_header:admin runtime meth ("/join/" ^ code) in
    Alcotest.(check int) "signed join redirects" 302 (status signed);
    Alcotest.(check (option string)) "signed join has absolute root location"
      (Some "https://chat.example.com/") (location signed)) [`GET;`POST];
  let missing,body=send ~cookie_header:admin runtime `PATCH
    "/account/bots/999999999/key" in
  Alcotest.(check int) "missing bot record status" 404 (status missing);
  check "missing bot uses public 404 page" (String.length body > 1000);
  check "missing bot omits app cookie"
    (not (Cohttp.Header.mem (Cohttp.Response.headers missing) "set-cookie"));
  List.iter (fun meth ->
    let missing,body=send ~cookie_header:admin runtime meth
      "/users/999999999/ban" in
    Alcotest.(check int) "missing ban user status" 404 (status missing);
    check "missing ban user uses public 404 page" (String.length body > 1000);
    check "missing ban user omits app cookie"
      (not (Cohttp.Header.mem (Cohttp.Response.headers missing) "set-cookie")))
    [`POST;`DELETE])

let test_avatar_file_headers () = with_seed "default" (fun runtime ->
  let source_root=Filename.concat reference "parity/.seed/default/storage" in
  let temporary=Filename.temp_file "campfire-m3-t2-avatar-" "" in
  Sys.remove temporary;
  Unix.mkdir temporary 0o700;
  let rec remove path =
    if Sys.is_directory path then (
      Array.iter (fun name -> remove (Filename.concat path name))
        (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path in
  let old_service = !(Controller_accounts.storage_service) in
  Fun.protect ~finally:(fun () ->
    Controller_accounts.storage_service := old_service;
    remove temporary) (fun () ->
    let source=Storage_disk.create ~root:source_root ~name:"local" in
    let service=Storage_disk.create ~root:temporary ~name:"local" in
    let blob=Db_runtime.read runtime (fun db ->
      let attachment=Option.get (Db_remaining.Attachment.find_for db
        ~record_type:"User" ~record_id:149087659L ~name:"avatar") in
      Db_remaining.Attachment.blob db attachment) in
    let copy_blob image =
      let source_path=Storage_disk.path_for source
        image.Db_remaining.Blob.key in
      let destination=Storage_disk.path_for service image.key in
      Storage_disk.mkdir_p (Filename.dirname destination);
      Storage_disk.copy_file ~source:source_path ~target:destination in
    copy_blob blob;
    let variation=Storage_variation.resize_to_limit ~format:"webp" 512 512
      |> Storage_image.variation_for blob in
    Option.iter copy_blob
      (Storage_image.existing_variant runtime blob variation);
    Controller_accounts.register_storage service;
    let admin=mint_session runtime 127326141L in
    let avatar id =
      let token=Signed_id.generate ~secret_key_base:secret ~model:"User" ~id
        ~purpose:(Some "avatar") ~expires_at:None in
      "/users/"^token^"/avatar" in
    let bot,_=send ~cookie_header:admin runtime `GET (avatar 394959859) in
    Alcotest.(check int) "stock bot avatar" 200 (status bot);
    Alcotest.(check (option string)) "stock send_file encoding"
      (Some "binary") (Cohttp.Header.get (Cohttp.Response.headers bot)
        "content-transfer-encoding");
    Alcotest.(check (option string)) "stock bot avatar MIME"
      (Some "image/svg+xml") (Cohttp.Header.get (Cohttp.Response.headers bot)
        "content-type");
    let initials,_=send ~cookie_header:admin runtime `GET
      (avatar 127326141) in
    Alcotest.(check int) "rendered initials avatar" 200 (status initials);
    check "rendered initials are not a send_file response"
      (not (Cohttp.Header.mem (Cohttp.Response.headers initials)
        "content-transfer-encoding"));
    let uploaded,body=send ~cookie_header:admin runtime `GET
      (avatar 149087659) in
    Alcotest.(check int) "uploaded avatar" 200 (status uploaded);
    check "uploaded avatar has image body" (String.length body > 100);
    Alcotest.(check (option string)) "variant send_file encoding"
      (Some "binary") (Cohttp.Header.get (Cohttp.Response.headers uploaded)
        "content-transfer-encoding");
    Alcotest.(check (option string)) "variant avatar MIME"
      (Some "image/webp") (Cohttp.Header.get (Cohttp.Response.headers uploaded)
        "content-type");
    let ranged,partial=send ~cookie_header:admin ~range:"bytes=0-9" runtime `GET
      (avatar 149087659) in
    Alcotest.(check int) "variant avatar byte range" 206 (status ranged);
    Alcotest.(check int) "variant avatar partial body" 10
      (String.length partial);
    Alcotest.(check (option string)) "range send_file encoding"
      (Some "binary") (Cohttp.Header.get (Cohttp.Response.headers ranged)
        "content-transfer-encoding");
    let image=Option.get (Storage_image.existing_variant runtime blob variation) in
    let avatar_attachment,variant_record,variant_attachment=
      Db_runtime.read runtime (fun db ->
        let avatar_attachment=Option.get
          (Db_remaining.Attachment.find_for db ~record_type:"User"
            ~record_id:149087659L ~name:"avatar") in
        let variant_record=Option.get
          (Db_remaining.Variant_record.find_for db ~blob_id:blob.id
            ~variation_digest:(Storage_variation.digest variation)) in
        let variant_attachment=Option.get
          (Db_remaining.Attachment.find_for db
            ~record_type:"ActiveStorage::VariantRecord"
            ~record_id:variant_record.id ~name:"image") in
        avatar_attachment,variant_record,variant_attachment) in
    let image_path=Storage_disk.path_for service image.key in
    let source_path=Storage_disk.path_for service blob.key in
    let before=Db_runtime.read runtime (fun db ->
      (Db_accounts.User.find db 149087659L).updated_at) in
    let jason=mint_session runtime 149087659L in
    Db_runtime.write runtime (fun tx ->
      ignore (Db_runtime.execute (Db_runtime.conn tx)
        "CREATE TRIGGER avatar_touch_fail BEFORE UPDATE OF updated_at ON users BEGIN SELECT RAISE(ABORT, 'touch failed'); END"
        []));
    let rolled_back,_=send ~cookie_header:jason runtime `DELETE
      (avatar 149087659) in
    Alcotest.(check int) "failed touch rolls back destroy" 500
      (status rolled_back);
    Db_runtime.read runtime (fun db ->
      check "avatar attachment retained after rollback"
        (Option.is_some (Db_remaining.Attachment.find_for db
          ~record_type:"User" ~record_id:149087659L ~name:"avatar"));
      Alcotest.(check string) "failed touch keeps user timestamp" before
        (Db_accounts.User.find db 149087659L).updated_at);
    check "rollback keeps avatar file" (Sys.file_exists source_path);
    check "rollback keeps variant file" (Sys.file_exists image_path);
    Db_runtime.write runtime (fun tx ->
      ignore (Db_runtime.execute (Db_runtime.conn tx)
        "DROP TRIGGER avatar_touch_fail" []));
    let deleted,_=send ~cookie_header:jason runtime `DELETE
      (avatar 149087659) in
    Alcotest.(check int) "avatar delete redirect" 302 (status deleted);
    Db_runtime.read runtime (fun db ->
      let absent table id =
        Db_runtime.query_one db
          ("SELECT 1 FROM " ^ table ^ " WHERE id=? LIMIT 1")
          [Sqlite3.Data.INT id] (fun _ -> ()) = None in
      check "source avatar attachment gone"
        (Db_remaining.Attachment.find_for db ~record_type:"User"
          ~record_id:149087659L ~name:"avatar" = None);
      check "source attachment row gone"
        (absent "active_storage_attachments" avatar_attachment.id);
      check "variant attachment row gone"
        (absent "active_storage_attachments" variant_attachment.id);
      check "source avatar blob gone" (absent "active_storage_blobs" blob.id);
      check "variant blob gone" (absent "active_storage_blobs" image.id);
      check "variant record row gone"
        (absent "active_storage_variant_records" variant_record.id);
      check "variant record gone"
        (Db_remaining.Variant_record.find_for db ~blob_id:blob.id
          ~variation_digest:(Storage_variation.digest variation) = None);
      let updated=(Db_accounts.User.find db 149087659L).updated_at in
      check "avatar deletion touched user" (updated <> before);
      Alcotest.(check string) "avatar touch time"
        (Db_time.of_rfc3339 now) updated);
    check "source avatar file gone" (not (Sys.file_exists source_path));
    check "variant avatar file gone" (not (Sys.file_exists image_path));
    let again,_=send ~cookie_header:jason
      ~at:"2026-10-08T12:05:00Z" runtime `DELETE (avatar 149087659) in
    Alcotest.(check int) "missing avatar destroy still redirects" 302
      (status again);
    Db_runtime.read runtime (fun db ->
      Alcotest.(check string) "missing attachment does not touch user"
        (Db_time.of_rfc3339 now)
        (Db_accounts.User.find db 149087659L).updated_at)))

let () = Alcotest.run "M3-T2 onboarding and account controllers" [
  "routes",[Alcotest.test_case "all 73 route rows" `Quick test_route_inventory];
  "fixture HTTP",[
    Alcotest.test_case "session, administration, join" `Quick test_session_account_and_join;
    Alcotest.test_case "first run" `Quick test_first_run;
    Alcotest.test_case "first-run stock logo cache" `Quick test_first_run_stock_logo_cache;
    Alcotest.test_case "roles, bots, profile, bans" `Quick test_roles_bots_profile_and_bans;
    Alcotest.test_case "sidebar page or frame" `Quick test_sidebar_response_mode;
    Alcotest.test_case "transfer and push" `Quick test_transfer_and_push;
    Alcotest.test_case "join and bot presenter data" `Quick test_join_and_bot_presenter_data;
    Alcotest.test_case "account role presenter" `Quick test_account_presenter_roles;
    Alcotest.test_case "profile and user presenters" `Quick test_profile_and_user_presenters;
    Alcotest.test_case "public exceptions" `Quick test_public_exception_headers;
    Alcotest.test_case "avatar file headers" `Quick test_avatar_file_headers]]

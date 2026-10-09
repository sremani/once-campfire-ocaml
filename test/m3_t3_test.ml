open Campfire

let check label condition = Alcotest.(check bool) label true condition
let status response = Cohttp.Code.code_of_status (Cohttp.Response.status response)
let header response key = Cohttp.Header.get (Cohttp.Response.headers response) key
let now = "2026-10-08T12:00:00Z"
let secret = String.make 64 'r'

let rec reference_root path remaining =
  if remaining=0 then failwith "pinned Rails seed not found" else
  let candidate = Filename.concat path "once-campfire-rust" in
  if Sys.file_exists (Filename.concat candidate "parity/.seed/default/db/production.sqlite3")
  then candidate else reference_root (Filename.dirname path) (remaining-1)
let reference = reference_root (Sys.getcwd ()) 8

let with_seed variant f =
  let source = Sqlite3.db_open ~mode:`READONLY
    (Filename.concat reference ("parity/.seed/"^variant^"/db/production.sqlite3")) in
  let temporary = Filename.temp_file "campfire-m3-t3-" ".sqlite3" in
  Sys.remove temporary;
  let quoted = String.concat "''" (String.split_on_char '\'' temporary) in
  let rc = Sqlite3.exec source ("VACUUM INTO '"^quoted^"'") in
  ignore (Sqlite3.db_close source);
  if rc<>Sqlite3.Rc.OK then failwith "could not copy Rails seed";
  let runtime = Db_runtime.open_db ~readers:2 ~prepare:false temporary in
  Fun.protect ~finally:(fun () ->
    Db_runtime.close runtime;
    List.iter (fun path -> if Sys.file_exists path then Sys.remove path)
      [temporary;temporary^"-wal";temporary^"-shm"])
    (fun () -> f runtime)

let send ?cookie ?accept ?turbo_frame ?(content_type="application/x-www-form-urlencoded")
    ?(body="") runtime meth path =
  let headers = ["host","chat.example.com";"origin","https://chat.example.com";
    "sec-fetch-site","same-origin";"content-type",content_type] in
  let headers = match cookie with None -> headers | Some value -> ("cookie",value)::headers in
  let headers = match accept with None -> headers | Some value -> ("accept",value)::headers in
  let headers = match turbo_frame with None -> headers
    | Some value -> ("turbo-frame",value)::headers in
  let request = Cohttp.Request.make ~meth ~headers:(Cohttp.Header.of_list headers)
    (Uri.of_string ("https://chat.example.com"^path)) in
  let response,body = Lwt_main.run (Http_app.handle ~runtime ~secret_key_base:secret
    ~now ~ssl:true ~force_ssl:true ~dispatch:Controller_rooms.endpoint
    request (Cohttp_lwt.Body.of_string body)) in
  response,Lwt_main.run (Cohttp_lwt.Body.to_string body)

let mint_session runtime user_id =
  let row = Db_runtime.write runtime (fun tx -> Db_accounts.Session.start
    (Db_runtime.conn tx) ~now ~user_id ~user_agent:None
    ~ip_address:(Some "198.51.100.33")) in
  "session_token=" ^ Authentication.issue_token_cookie
    ~secret_key_base:secret ~now row.token

let contains haystack needle =
  let rec at i =
    i + String.length needle <= String.length haystack &&
    (String.sub haystack i (String.length needle) = needle || at (i+1)) in
  at 0

let test_form_and_search_presenter_inputs () = with_seed "default" (fun runtime ->
  let cookie = mint_session runtime 127326141L in
  let room_form,body = send ~cookie runtime `GET "/rooms/closeds/new" in
  Alcotest.(check int) "closed room form" 200 (status room_form);
  check "new room has pinned default name" (contains body "value=\"New room\"");
  check "closed room offers member controls" (contains body "name=\"user_ids[]\"");
  let cookie = cookie ^ "; last_room=654632876" in
  let recorded,_ = send ~cookie ~body:"q=Controller+Recent%21"
    runtime `POST "/searches" in
  Alcotest.(check int) "recent search recorded" 302 (status recorded);
  let search,body = send ~cookie runtime `GET "/searches" in
  Alcotest.(check int) "search page" 200 (status search);
  check "recent query supplied to view" (contains body "Controller Recent");
  check "return room supplied to view" (contains body "href=\"/rooms/654632876\""))

let test_custom_logo_page_context () = with_seed "custom_styles" (fun runtime ->
  let cookie = mint_session runtime 127326141L in
  let pages = [
    "room show", "/rooms/654632876";
    "room form", "/rooms/opens/new";
    "message edit", "/rooms/654632876/messages/908005739/edit";
    "search", "/searches";
  ] in
  List.iter (fun (label,path) ->
    let response,body = send ~cookie runtime `GET path in
    Alcotest.(check int) (label ^ " status") 200 (status response);
    check (label ^ " custom logo class")
      (contains body "account-has-logo");
    if label="room show" then (
      check "room nav uses exact pinned custom-logo markup"
        (contains body (String.concat "" [
          "<nav id=\"nav\">\n\n  ";
          "<figure class=\"account-logo avatar \">";
          "<img alt=\"Account logo\" ";
          "src=\"/account/logo?v=20260221160000\" ";
          "width=\"300\" height=\"300\" /></figure>\n\n  ";
          "<span class=\"btn btn--reversed btn--faux room--current\">"
        ])))) pages)

let test_inventory () =
  Alcotest.(check string) "Ruby Unicode search word classes"
    "héllo wörld_1 ２ 日本語 ‿ a b ️   é"
    (Search_words.sanitize "héllo wörld_1 ２ 日本語 ‿ a-b ️ ❤ é");
  let owns endpoint = List.exists (fun prefix -> String.starts_with ~prefix endpoint)
    ["rooms#";"rooms/";"messages#";"messages/";"searches#";"autocompletable/"] in
  let routes = List.filter (fun (_,_,endpoint,_) -> owns endpoint) Route_catalog.routes in
  Alcotest.(check int) "owned route rows" 73 (List.length routes);
  List.iter (fun (_,_,endpoint,_) ->
    check ("endpoint "^endpoint) (Option.is_some (Controller_rooms.endpoint endpoint))) routes;
  let absent = ["rooms#create";"rooms#new";"rooms#edit";"rooms#update";
    "rooms/directs#update";"messages#new";"messages/boosts#edit";
    "messages/boosts#show";"messages/boosts#update"] in
  Alcotest.(check int) "13 action_not_found rows" 13
    (List.length (List.filter (fun (_,_,endpoint,_) -> List.mem endpoint absent) routes));
  with_seed "default" (fun runtime ->
    let missing,_ = send runtime `POST "/rooms" in
    Alcotest.(check int) "declared action_not_found" 404 (status missing);
    let controller,_ = send runtime `GET "/rooms/201306877/settings" in
    Alcotest.(check int) "missing settings controller" 500 (status controller))

let test_rooms_and_messages () = with_seed "default" (fun runtime ->
  let admin = mint_session runtime 127326141L in
  let member = mint_session runtime 712064548L in
  let anonymous,_ = send runtime `GET "/rooms/486777696" in
  Alcotest.(check int) "room requires session" 302 (status anonymous);
  let shown,_ = send ~cookie:admin runtime `GET "/rooms/654632876" in
  Alcotest.(check int) "member room" 200 (status shown);
  check "last room cookie" (Cohttp.Header.get_multi (Cohttp.Response.headers shown) "set-cookie"
    |> List.exists (String.starts_with ~prefix:"last_room=654632876"));
  let inaccessible,_ = send ~cookie:member runtime `GET "/rooms/104393281" in
  Alcotest.(check int) "inaccessible room redirects" 302 (status inaccessible);
  let created,_ = send ~cookie:admin ~body:"room%5Bname%5D=OCaml+Room"
    runtime `POST "/rooms/opens" in
  Alcotest.(check int) "open room created" 302 (status created);
  let created_id = Db_runtime.read runtime (fun db ->
    Db_rooms.Room.all db |> List.find (fun r -> r.Db_rooms.Room.name=Some "OCaml Room")
    |> fun r -> r.Db_rooms.Room.id) in
  let location = Option.get (header created "location") in
  Alcotest.(check string) "open room redirect"
    ("https://chat.example.com/rooms/"^Int64.to_string created_id) location;
  let message,_ = send ~cookie:admin ~accept:"text/vnd.turbo-stream.html"
    ~body:"message%5Bbody%5D=OCaml+search+needle"
    runtime `POST "/rooms/654632876/messages" in
  Alcotest.(check int) "message create stream" 200 (status message);
  check "Turbo create varies on Accept"
    (Cohttp.Header.get_multi (Cohttp.Response.headers message) "vary"
     |> List.concat_map (String.split_on_char ',')
     |> List.exists (fun value -> String.trim value="Accept"));
  let id = Db_runtime.read runtime (fun db ->
    Db_messages.Message.last db |> Option.get |> fun m -> m.Db_messages.Message.id) in
  let denied,_ = send ~cookie:member ~body:"message%5Bbody%5D=Wrong"
    runtime `PATCH (Printf.sprintf "/rooms/654632876/messages/%Ld" id) in
  Alcotest.(check int) "other member cannot edit" 403 (status denied);
  let updated,_ = send ~cookie:admin ~body:"message%5Bbody%5D=Revised"
    runtime `PATCH (Printf.sprintf "/rooms/654632876/messages/%Ld" id) in
  Alcotest.(check int) "creator edits" 302 (status updated);
  let search,_ = send ~cookie:admin runtime `GET "/searches?q=Revised" in
  Alcotest.(check int) "search page" 200 (status search);
  let boost,_ = send ~cookie:member ~body:"boost%5Bcontent%5D=%F0%9F%94%A5"
    runtime `POST (Printf.sprintf "/messages/%Ld/boosts" id) in
  Alcotest.(check int) "reachable boost" 302 (status boost);
  let deleted,_ = send ~cookie:admin ~accept:"text/vnd.turbo-stream.html"
    runtime `DELETE (Printf.sprintf "/rooms/654632876/messages/%Ld" id) in
  Alcotest.(check int) "message destroy stream" 200 (status deleted);
  Db_runtime.read runtime (fun db ->
    check "destroyed row" (Db_messages.Message.find_by_id db id=None));
  let involvement,_ = send ~cookie:member ~body:"involvement=nothing"
    runtime `PATCH "/rooms/654632876/involvement" in
  Alcotest.(check int) "involvement update" 302 (status involvement))

let test_room_permalink_pagination () = with_seed "default" (fun runtime ->
  let cookie=mint_session runtime 127326141L in
  let first,body=send ~cookie runtime `GET "/rooms/486777696/@933434510" in
  Alcotest.(check int) "first-message permalink" 200 (status first);
  check "permalink includes first message"
    (contains body "data-message-id=\"933434510\"");
  check "permalink starts around requested message"
    (not (contains body "data-message-id=\"933434601\""));
  let middle,body=send ~cookie runtime `GET "/rooms/486777696/@933434570" in
  Alcotest.(check int) "middle-message permalink" 200 (status middle);
  check "permalink includes middle message"
    (contains body "data-message-id=\"933434570\"");
  check "permalink includes older neighboring page"
    (contains body "data-message-id=\"933434530\"");
  let missing,body=send ~cookie runtime `GET "/rooms/486777696/@999999999" in
  Alcotest.(check int) "missing-message permalink" 200 (status missing);
  check "missing permalink falls back to latest page"
    (contains body "data-message-id=\"933434601\""))

let test_bot_and_search () = with_seed "default" (fun runtime ->
  let key = "394959859-BenderBot123" in
  let room = "/rooms/486777696/"^key^"/messages" in
  let listed,_ = send runtime `GET room in
  Alcotest.(check int) "bot key lists messages" 200 (status listed);
  check "count header" (Option.is_some (header listed "x-total-count"));
  let bad,_ = send runtime `GET "/rooms/486777696/394959859-bad/messages" in
  Alcotest.(check int) "invalid bot key" 302 (status bad);
  let empty,_ = send ~content_type:"text/plain" runtime `POST room in
  Alcotest.(check int) "empty bot message" 422 (status empty);
  let posted,body = send ~content_type:"text/plain" ~body:"Bot API message"
    runtime `POST room in
  Alcotest.(check int) "bot message created" 201 (status posted);
  Alcotest.(check (option string)) "bot create head content type"
    (Some "application/json") (header posted "content-type");
  Alcotest.(check string) "bot create head body" "" body;
  check "bot location" (Option.is_some (header posted "location"));
  let admin = mint_session runtime 127326141L in
  let recorded,_ = send ~cookie:admin ~body:"q=Bot+API%21"
    runtime `POST "/searches" in
  Alcotest.(check int) "search recorded" 302 (status recorded);
  Alcotest.(check (option string)) "sanitized search redirect"
    (Some "https://chat.example.com/searches?q=Bot+API+") (header recorded "location");
  let cleared,_ = send ~cookie:admin runtime `DELETE "/searches/clear" in
  Alcotest.(check int) "searches cleared" 302 (status cleared);
  Db_runtime.read runtime (fun db ->
    Alcotest.(check int) "no recent searches" 0
      (Db_messages.Search.count_for_user db 127326141L)))

let test_restricted_autocomplete_and_paging () =
  with_seed "restricted" (fun runtime ->
    let member = mint_session runtime 712064548L in
    let admin = mint_session runtime 127326141L in
    List.iter (fun path ->
      let blocked,body = send ~cookie:member runtime `GET path in
      Alcotest.(check int) "restricted room form" 403 (status blocked);
      Alcotest.(check string) "restricted room form body" "" body;
      Alcotest.(check (option string)) "restricted room form bare MIME"
        (Some "text/html") (header blocked "content-type"))
      ["/rooms/opens/new";"/rooms/closeds/new"];
    let blocked,body = send ~cookie:member ~body:"room%5Bname%5D=Nope"
      runtime `POST "/rooms/opens" in
    Alcotest.(check int) "restricted member room creation" 403 (status blocked);
    Alcotest.(check string) "restricted creation body" "" body;
    Alcotest.(check (option string)) "restricted creation bare MIME"
      (Some "text/html") (header blocked "content-type");
    let allowed,_ = send ~cookie:admin ~body:"room%5Bname%5D=Yes"
      runtime `POST "/rooms/opens" in
    Alcotest.(check int) "restricted administrator creates" 302 (status allowed));
  with_seed "default" (fun runtime ->
    let admin = mint_session runtime 127326141L in
    let bad_page,_ = send ~cookie:admin runtime `GET
      "/rooms/654632876/messages?before=not-a-number" in
    Alcotest.(check int) "invalid page cursor" 404 (status bad_page);
    let filtered,body = send ~cookie:admin runtime `GET
      "/autocompletable/users.json?filter=Kevin" in
    Alcotest.(check int) "JSON autocomplete" 200 (status filtered);
    Alcotest.(check (option string)) "autocomplete total"
      (Some "1") (header filtered "x-total-count");
    let users = Yojson.Basic.from_string body |> Yojson.Basic.Util.to_list in
    Alcotest.(check int) "one matching active user" 1 (List.length users);
    check "signed GlobalID present"
      (Yojson.Basic.Util.member "sgid" (List.hd users) |>
       Yojson.Basic.Util.to_string |> fun s -> String.length s>20);
    let hidden,_ = send ~cookie:(mint_session runtime 712064548L)
      runtime `GET "/autocompletable/users.json?room_id=104393281" in
    Alcotest.(check int) "room autocomplete requires membership" 404 (status hidden));
  with_seed "crowd" (fun runtime ->
    let admin = mint_session runtime 127326141L in
    let first,_ = send ~cookie:admin runtime `GET "/autocompletable/users.json" in
    Alcotest.(check int) "crowd autocomplete" 200 (status first);
    Alcotest.(check (option string)) "absolute next link without duplicate host"
      (Some "<https://chat.example.com/autocompletable/users.json?page=2>; rel=\"next\"")
      (header first "link");
    let second,_ = send ~cookie:admin runtime `GET
      "/autocompletable/users.json?page=2" in
    Alcotest.(check int) "second crowd page" 200 (status second);
    Alcotest.(check (option string)) "next link replaces page"
      (Some "<https://chat.example.com/autocompletable/users.json?page=3>; rel=\"next\"")
      (header second "link");
    let filtered,_ = send ~cookie:admin runtime `GET
      "/autocompletable/users.json?query=j" in
    Alcotest.(check (option string)) "next link preserves query"
      (Some "<https://chat.example.com/autocompletable/users.json?page=2&query=j>; rel=\"next\"")
      (header filtered "link"))

let test_bot_lifecycle () = with_seed "default" (fun runtime ->
  let key = "394959859-BenderBot123" in
  let base = "/rooms/486777696/"^key^"/messages" in
  let created,_ = send ~content_type:"text/plain" ~body:"First bot text"
    runtime `POST base in
  Alcotest.(check int) "bot creates" 201 (status created);
  let location = Option.get (header created "location") in
  let id = String.split_on_char '/' location |> List.rev |> List.hd
    |> Int64.of_string in
  let updated,body = send ~content_type:"text/plain" ~body:"Second bot text"
    runtime `PATCH (base^"/"^Int64.to_string id) in
  Alcotest.(check int) "bot updates" 200 (status updated);
  let message = Yojson.Basic.from_string body in
  Alcotest.(check string) "JSON body updated" "Second bot text"
    (Yojson.Basic.Util.member "body" message |>
     Yojson.Basic.Util.member "plain_text" |> Yojson.Basic.Util.to_string);
  let boosted,body = send ~content_type:"text/plain" ~body:"nice"
    runtime `POST ("/rooms/486777696/"^key^"/messages/"^Int64.to_string id^"/boosts") in
  Alcotest.(check int) "bot boosts" 201 (status boosted);
  Alcotest.(check string) "boost JSON content" "nice"
    (Yojson.Basic.from_string body |> Yojson.Basic.Util.member "content" |>
     Yojson.Basic.Util.to_string);
  let destroyed,_ = send runtime `DELETE (base^"/"^Int64.to_string id) in
  Alcotest.(check int) "bot destroys" 204 (status destroyed);
  Db_runtime.read runtime (fun db ->
    check "bot message deleted" (Db_messages.Message.find_by_id db id=None)))

let test_http_exception_shapes () = with_seed "default" (fun runtime ->
  let admin = mint_session runtime 127326141L in
  let redirect_response,_ = send ~cookie:admin runtime `GET "/rooms/opens" in
  Alcotest.(check int) "room scope redirects" 302 (status redirect_response);
  check "scope redirect persists flash"
    (Cohttp.Header.get_multi (Cohttp.Response.headers redirect_response) "set-cookie"
     |> List.exists (String.starts_with ~prefix:"_campfire_session="));
  let missing,body = send ~cookie:admin runtime `POST "/rooms/opens" in
  Alcotest.(check int) "room param required" 400 (status missing);
  Alcotest.(check string) "public bad request body" "" body;
  check "public exception does not commit cookie"
    (Cohttp.Header.get_multi (Cohttp.Response.headers missing) "set-cookie"=[]);
  let missing_message,body = send ~cookie:admin runtime `GET
    "/rooms/486777696/messages/309456473" in
  Alcotest.(check int) "message outside room" 404 (status missing_message);
  check "public 404 page" (String.length body>4000);
  let key="394959859-BenderBot123" in
  let base="/rooms/486777696/"^key^"/messages" in
  let boost,_ = send runtime `POST (base^"/309456473/boosts") in
  Alcotest.(check int) "bot boost missing message" 404 (status boost);
  Alcotest.(check (option string)) "bare HTML head MIME"
    (Some "text/html") (header boost "content-type");
  let update,body = send runtime `PATCH (base^"/309456473") in
  Alcotest.(check int) "bot update missing message" 404 (status update);
  Alcotest.(check string) "JSON public exception body"
    "{\"status\":404,\"error\":\"Not Found\"}" body)

let test_autocomplete_format_negotiation () = with_seed "default" (fun runtime ->
  let cookie = mint_session runtime 127326141L in
  let path = "/autocompletable/users?room_id=654632876&filter=a" in
  let html,html_body = send ~cookie ~accept:"*/*" runtime `GET path in
  Alcotest.(check int) "wildcard autocomplete status" 200 (status html);
  check "wildcard selects HTML prompt items"
    (String.starts_with ~prefix:"text/html" (Option.value (header html "content-type") ~default:"")
     && contains html_body "<lexxy-prompt-item");
  let json,json_body = send ~cookie ~accept:"application/json" runtime `GET path in
  Alcotest.(check int) "explicit JSON autocomplete status" 200 (status json);
  check "explicit JSON remains JSON"
    (String.starts_with ~prefix:"application/json" (Option.value (header json "content-type") ~default:"")
     && String.starts_with ~prefix:"[" json_body))

let test_content_pages () = with_seed "default" (fun runtime ->
  let admin = mint_session runtime 127326141L in
  let message,message_body = send ~cookie:admin runtime `GET
    "/rooms/654632876/messages/933434505" in
  Alcotest.(check int) "message permalink" 200 (status message);
  check "message permalink has application layout"
    (String.starts_with ~prefix:"<!DOCTYPE html>" message_body);
  check "message permalink has stylesheet preload" (header message "link"<>None);
  let direct,direct_body = send ~cookie:admin ~turbo_frame:"direct_rooms_control"
    runtime `GET "/rooms/directs/new" in
  Alcotest.(check int) "direct form frame" 200 (status direct);
  check "direct form frame omits application layout"
    (String.starts_with ~prefix:"<html>\n  <head>\n    \n  </head>\n  <body>\n    " direct_body);
  check "direct frame has no stylesheet preload" (header direct "link"=None);
  let direct_edit,direct_edit_body = send ~cookie:admin runtime `GET
    "/rooms/directs/186869642/edit" in
  Alcotest.(check int) "direct room edit" 200 (status direct_edit);
  check "direct edit names the other member"
    (contains direct_edit_body "Edit settings for Jason");
  check "direct edit offers members and delete action"
    (contains direct_edit_body "directs--edit"
     && contains direct_edit_body "Delete Ping"
     && contains direct_edit_body "/rooms/directs/186869642");
  check "direct edit omits open room fields"
    (not (contains direct_edit_body "name=\"room[name]\""));
  let group_edit,group_edit_body = send ~cookie:admin runtime `GET
    "/rooms/directs/699448329/edit" in
  Alcotest.(check int) "group direct edit" 200 (status group_edit);
  check "group direct edit uses Rails sentence title"
    (contains group_edit_body "Edit settings for Jason, Kevin, and JZ");
  let broken_room,broken_body = send ~cookie:admin runtime `GET
    "/rooms/699448328" in
  Alcotest.(check int) "missing-creator room" 200 (status broken_room);
  check "missing creator renders the pinned failed-message placeholder"
    (contains broken_body "Failed to load message content"
     && not (contains broken_body "data-message-id=\"933434637\""));
  let autocomplete,body = send ~cookie:admin runtime `GET
    "/autocompletable/users" in
  Alcotest.(check int) "autocomplete HTML" 200 (status autocomplete);
  check "mention picker carries signed attachable IDs"
    (contains body "<lexxy-prompt-item search=" && contains body " sgid=");
  check "mention picker has editor template"
    (contains body "<template type=\"editor\">");
  let involvement,body = send ~cookie:admin runtime `GET
    "/rooms/486777696/involvement" in
  Alcotest.(check int) "involvement page" 200 (status involvement);
  check "involvement notification control"
    (contains body "data-turbo-frame-url-param=\"/rooms/486777696/involvement\""
     && contains body "notification-bell-");
  let boosts,body = send ~cookie:admin runtime `GET
    "/messages/309456473/boosts" in
  Alcotest.(check int) "boost list page" 200 (status boosts);
  check "boost list frame"
    (contains body "id=\"boosting_message_" &&
     contains body "data-controller=\"turbo-streaming\"");
  let new_boost,body = send ~cookie:admin runtime `GET
    "/messages/309456473/boosts/new" in
  Alcotest.(check int) "new boost page" 200 (status new_boost);
  check "new boost form"
    (contains body "name=\"boost[content]\""
     && contains body "action=\"/messages/309456473/boosts\"");
  let frame,frame_body = send ~cookie:admin ~turbo_frame:"new_boost_message_309456473"
    runtime `GET "/messages/309456473/boosts/new" in
  Alcotest.(check int) "new boost frame" 200 (status frame);
  check "boost frame omits application layout"
    (String.starts_with ~prefix:"<html>\n  <head>\n    \n  </head>\n  <body>\n    " frame_body
     && not (contains frame_body "rel=\"stylesheet\""));
  check "boost frame has no stylesheet preload" (header frame "link"=None);
  let tail,tail_body = send ~cookie:admin runtime `GET
    "/rooms/654632876/messages?after=607264868" in
  Alcotest.(check int) "empty message poll" 204 (status tail);
  Alcotest.(check (option string)) "empty poll omits content type" None
    (header tail "content-type");
  Alcotest.(check string) "empty poll body" "" tail_body;
  let missing_room,body = send ~cookie:admin runtime `POST "/messages" in
  Alcotest.(check int) "missing room composition page" 200 (status missing_room);
  check "deleted room explanation"
    (contains body "id=\"composer-frame\""
     && contains body "This room was deleted."))

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path |> Array.iter (fun name ->
        remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path

let multipart_upload ~boundary ~name ~filename ~content_type contents =
  "--"^boundary^"\r\nContent-Disposition: form-data; name=\""^name^
  "\"; filename=\""^filename^"\"\r\nContent-Type: "^content_type^
  "\r\n\r\n"^contents^"\r\n--"^boundary^"--\r\n"

let test_multipart_attachment () = with_seed "default" (fun runtime ->
  let root=Filename.temp_file "campfire-m3-upload-" "" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
    let service=Storage_disk.create ~root ~name:"local" in
    Controller_rooms.register_storage service;
    let png=String.init 69 (fun i -> Char.chr (List.nth [
      137;80;78;71;13;10;26;10;0;0;0;13;73;72;68;82;0;0;0;4;0;0;0;3;
      8;2;0;0;0;59;150;57;145;0;0;0;16;73;68;65;84;120;156;99;248;
      207;192;0;71;12;56;57;0;245;49;11;245;53;123;251;130;0;0;0;
      0;73;69;78;68;174;66;96;130] i)) in
    let boundary="campfire-m3-attachment" in
    let content_type="multipart/form-data; boundary="^boundary in
    let attachment db message =
      match Db_remaining.Hooks.message_attachment db message with
      | Some (_,blob) -> blob
      | _ -> failwith "message attachment missing" in
    let admin=mint_session runtime 127326141L in
    let moon_path=if Sys.file_exists "fixtures/storage_prefix/moon.jpg" then
      "fixtures/storage_prefix/moon.jpg" else
      "test/fixtures/storage_prefix/moon.jpg" in
    let vips_available=try Storage_vips.version ()="8.16.1"
      with Failure _ -> false in
    let ic=open_in_bin moon_path in
    let moon=Fun.protect ~finally:(fun () -> close_in ic)
      (fun () -> really_input_string ic (in_channel_length ic)) in
    let moon_created,moon_body=send ~cookie:admin
      ~accept:"text/vnd.turbo-stream.html" ~content_type
      ~body:(multipart_upload ~boundary ~name:"message[attachment]"
        ~filename:"moon.jpg" ~content_type:"image/jpeg" moon)
      runtime `POST "/rooms/654632876/messages" in
    Alcotest.(check int) "analyzed image upload" 200 (status moon_created);
    let moon_blob=Db_runtime.read runtime (fun db ->
      let message=Option.get (Db_messages.Message.last db) in
      attachment db message) in
    let metadata=Yojson.Basic.from_string
      (Option.value moon_blob.metadata ~default:"{}") in
    let open Yojson.Basic.Util in
    if vips_available then (
      Alcotest.(check int) "uploaded image width" 640
        (metadata |> member "width" |> to_int);
      Alcotest.(check int) "uploaded image height" 640
        (metadata |> member "height" |> to_int);
      check "first Turbo render includes image dimensions"
        (contains moon_body "width=\"640\""
         && contains moon_body "height=\"640\""));
    let created,_=send ~cookie:admin ~accept:"text/vnd.turbo-stream.html"
      ~content_type ~body:(multipart_upload ~boundary
        ~name:"message[attachment]" ~filename:"red.png"
        ~content_type:"image/png" png)
      runtime `POST "/rooms/654632876/messages" in
    Alcotest.(check int) "browser attachment created" 200 (status created);
    let browser_message,blob=Db_runtime.read runtime (fun db ->
      let message=Option.get (Db_messages.Message.last db) in
      message,attachment db message) in
    Alcotest.(check string) "stored filename" "red.png" blob.filename;
    Alcotest.(check int64) "stored byte size" (Int64.of_int (String.length png)) blob.byte_size;
    let stored=Storage_disk.path_for service blob.key in
    check "stored file exists" (Sys.file_exists stored);
    let ic=open_in_bin stored in
    let stored_bytes=Fun.protect ~finally:(fun () -> close_in ic)
      (fun () -> really_input_string ic (in_channel_length ic)) in
    Alcotest.(check string) "stored bytes" png stored_bytes;
    let removed,_=send ~cookie:admin
      ~body:"message%5Battachment%5D=" runtime `PATCH
      (Printf.sprintf "/rooms/654632876/messages/%Ld" browser_message.id) in
    Alcotest.(check int) "browser attachment removed" 302 (status removed);
    Db_runtime.read runtime (fun db ->
      check "browser attachment row removed"
        (Db_remaining.Hooks.message_attachment db browser_message=None));
    let bot_path="/rooms/486777696/394959859-BenderBot123/messages" in
    let bot_created,_=send ~content_type
      ~body:(multipart_upload ~boundary ~name:"attachment"
        ~filename:"bot.png" ~content_type:"image/png" png)
      runtime `POST bot_path in
    Alcotest.(check int) "bot attachment created" 201 (status bot_created);
    let bot_message,first_blob=Db_runtime.read runtime (fun db ->
      let message=Option.get (Db_messages.Message.last db) in
      let blob=attachment db message in
      message,blob) in
    Alcotest.(check string) "bot attachment filename" "bot.png" first_blob.filename;
    let bot_path=bot_path^"/"^Int64.to_string bot_message.id in
    let replaced,_=send ~content_type
      ~body:(multipart_upload ~boundary ~name:"attachment"
        ~filename:"again.png" ~content_type:"image/png" png)
      runtime `PATCH bot_path in
    Alcotest.(check int) "bot attachment replaced" 200 (status replaced);
    Db_runtime.read runtime (fun db ->
      let blob=attachment db bot_message in
      Alcotest.(check string) "replacement filename" "again.png" blob.filename;
      check "replacement changed blob" (blob.id<>first_blob.id));
    let removed,_=send ~body:"attachment=" runtime `PATCH bot_path in
    Alcotest.(check int) "bot attachment removed" 200 (status removed);
    Db_runtime.read runtime (fun db ->
      check "bot attachment row removed"
        (Db_remaining.Hooks.message_attachment db bot_message=None))))

let () = Alcotest.run "M3 room and message controllers" [
  "routes",[Alcotest.test_case "inventory" `Quick test_inventory];
  "http",[
    Alcotest.test_case "rooms and messages" `Quick test_rooms_and_messages;
    Alcotest.test_case "room permalink pagination" `Quick test_room_permalink_pagination;
    Alcotest.test_case "bot and search" `Quick test_bot_and_search;
    Alcotest.test_case "restricted, autocomplete, paging" `Quick test_restricted_autocomplete_and_paging;
    Alcotest.test_case "autocomplete wildcard format" `Quick test_autocomplete_format_negotiation;
    Alcotest.test_case "bot lifecycle" `Quick test_bot_lifecycle;
    Alcotest.test_case "form and search presenter inputs" `Quick test_form_and_search_presenter_inputs;
    Alcotest.test_case "custom logo page context" `Quick test_custom_logo_page_context;
    Alcotest.test_case "exception response shapes" `Quick test_http_exception_shapes;
    Alcotest.test_case "content pages" `Quick test_content_pages;
    Alcotest.test_case "multipart attachment" `Quick test_multipart_attachment]]

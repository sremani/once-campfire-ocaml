open Campfire

let secret = String.make 64 'r'
let now = "2026-10-08T12:00:00Z"
let check label condition = Alcotest.(check bool) label true condition
let status response = Cohttp.Code.code_of_status (Cohttp.Response.status response)
let header response name = Cohttp.Header.get (Cohttp.Response.headers response) name
let contains text part =
  let size=String.length part in
  let rec loop i = i+size<=String.length text &&
    (String.sub text i size=part || loop (i+1)) in loop 0

let rec reference_root path remaining =
  if remaining=0 then failwith "pinned Rails seed not found" else
  let candidate=Filename.concat path "once-campfire-rust" in
  if Sys.file_exists (Filename.concat candidate
      "parity/.seed/default/db/production.sqlite3") then candidate
  else reference_root (Filename.dirname path) (remaining-1)
let reference=reference_root (Sys.getcwd ()) 8

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path |> Array.iter (fun name ->
        remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path

let with_seed f =
  let source=Sqlite3.db_open ~mode:`READONLY
    (Filename.concat reference "parity/.seed/default/db/production.sqlite3") in
  let temporary=Filename.temp_file "campfire-m4-integration-" ".sqlite3" in
  Sys.remove temporary;
  let quoted=String.concat "''" (String.split_on_char '\'' temporary) in
  let rc=Sqlite3.exec source ("VACUUM INTO '"^quoted^"'") in
  ignore (Sqlite3.db_close source);
  if rc<>Sqlite3.Rc.OK then failwith "seed copy failed";
  let runtime=Db_runtime.open_db ~readers:2 ~prepare:false temporary in
  let storage=Filename.temp_file "campfire-m4-storage-" "" in
  Sys.remove storage;Unix.mkdir storage 0o700;
  let service=Storage_disk.create ~root:storage ~name:"local" in
  Controller_accounts.register_storage service;
  Controller_rooms.register_storage service;
  Fun.protect ~finally:(fun () ->
    Db_runtime.close runtime;
    remove_tree storage;
    List.iter remove_tree [temporary;temporary^"-wal";temporary^"-shm"])
    (fun () -> f runtime service)

let send ?cookie ?accept ?if_none_match ?(content_type="application/x-www-form-urlencoded")
    ?(body="") runtime meth path =
  let headers=["host","chat.example.com";
    "origin","https://chat.example.com";"sec-fetch-site","same-origin";
    "content-type",content_type] in
  let add key = function None -> Fun.id | Some value ->
    fun headers -> (key,value)::headers in
  let headers=headers |> add "cookie" cookie |> add "accept" accept
    |> add "if-none-match" if_none_match in
  let request=Cohttp.Request.make ~meth ~headers:(Cohttp.Header.of_list headers)
    (Uri.of_string ("https://chat.example.com"^path)) in
  let response,body=Lwt_main.run (Http_app.handle ~runtime
    ~secret_key_base:secret ~now ~ssl:true ~force_ssl:true
    ~dispatch:App_dispatch.endpoint request (Cohttp_lwt.Body.of_string body)) in
  response,Lwt_main.run (Cohttp_lwt.Body.to_string body)

let session runtime =
  let row=Db_runtime.write runtime (fun tx -> Db_accounts.Session.start
    (Db_runtime.conn tx) ~now ~user_id:127326141L ~user_agent:None
    ~ip_address:(Some "198.51.100.33")) in
  "session_token=" ^ Authentication.issue_token_cookie
    ~secret_key_base:secret ~now row.token

let test_rich_text_route () = with_seed (fun runtime _ ->
  let cookie=session runtime in
  let markup="<p>Hi <strong>buddy</strong> <img src=x onerror=alert(1)></p>" in
  let body="message%5Bbody%5D="^Uri.pct_encode markup in
  let created,html=send ~cookie ~accept:"text/vnd.turbo-stream.html"
    ~body runtime `POST "/rooms/654632876/messages" in
  Alcotest.(check int) "message stream" 200 (status created);
  check "format retained" (contains html "<strong>buddy</strong>");
  check "unsafe image removed" (not (contains html "onerror") &&
    not (contains html "<img src=\"x\""));
  let message=Db_runtime.read runtime (fun db ->
    Option.get (Db_messages.Message.last db)) in
  let shown,html=send ~cookie runtime `GET
    (Printf.sprintf "/rooms/654632876/messages/%Ld" message.id) in
  Alcotest.(check int) "rendered message" 200 (status shown);
  check "show keeps rich text" (contains html "<strong>buddy</strong>");
  let searched,html=send ~cookie runtime `GET "/searches?q=buddy" in
  Alcotest.(check int) "search indexed" 200 (status searched);
  check "search includes rich message" (contains html "buddy"))

let test_request_host_and_gid_fallback () = with_seed (fun runtime _ ->
  let cookie=session runtime in
  let user=Db_runtime.read runtime (fun db ->
    Option.get (Db_accounts.User.find_by_id db 127326141L)) in
  let gid=Global_id.make ~model_name:"User" ~id:(Int64.to_string user.id) in
  let valid=Global_id.attachable_sgid ~secret_key_base:secret ~gid in
  let last=String.length valid-1 in
  let tampered=String.sub valid 0 last ^
    (if valid.[last]='x' then "y" else "x") in
  Alcotest.(check bool) "signature is invalid" true
    (Global_id.locate_signed ~secret_key_base:secret ~raw:tampered
      ~purpose:"attachable" ~now () = None);
  let markup="<p><action-text-attachment sgid=\""^tampered^
    "\" content-type=\"application/vnd.campfire.mention\"></action-text-attachment></p>" in
  let created,_=send ~cookie ~accept:"text/vnd.turbo-stream.html"
    ~body:("message%5Bbody%5D="^Uri.pct_encode markup)
    runtime `POST "/rooms/654632876/messages" in
  Alcotest.(check int) "fallback message created" 200 (status created);
  let message=Db_runtime.read runtime (fun db ->
    Option.get (Db_messages.Message.last db)) in
  let shown,html=send ~cookie runtime `GET
    (Printf.sprintf "/rooms/654632876/messages/%Ld" message.id) in
  Alcotest.(check int) "fallback mention shown" 200 (status shown);
  check "decoded GID renders current user" (contains html "class=\"mention\"" &&
    contains html user.name);
  let indexed=Db_runtime.read runtime (fun db ->
    Db_messages.Message.search_in_room db 654632876L user.name
    |> List.exists (fun (row : Db_messages.Message.t) -> row.id=message.id)) in
  check "decoded GID reaches FTS" indexed;
  let og="<action-text-attachment content-type=\"application/vnd.actiontext.opengraph-embed\" "^
    "href=\"https://chat.example.com/rooms/1\" filename=\"Self host\"></action-text-attachment>" in
  let created,_=send ~cookie ~accept:"text/vnd.turbo-stream.html"
    ~body:("message%5Bbody%5D="^Uri.pct_encode og)
    runtime `POST "/rooms/654632876/messages" in
  Alcotest.(check int) "embed message created" 200 (status created);
  let embed=Db_runtime.read runtime (fun db ->
    Option.get (Db_messages.Message.last db)) in
  let shown,html=send ~cookie runtime `GET
    (Printf.sprintf "/rooms/654632876/messages/%Ld" embed.id) in
  Alcotest.(check int) "embed shown" 200 (status shown);
  check "same request Host keeps embed title unlinked"
    (contains html "Self host" &&
     not (contains html "rel=\"noreferrer\" target=\"_blank\" href=\"https://chat.example.com/rooms/1\"")))

let test_stock_media_and_signatures () = with_seed (fun runtime _ ->
  let logo,bytes=send runtime `GET "/account/logo?size=small" in
  Alcotest.(check int) "stock logo" 200 (status logo);
  Alcotest.(check (option string)) "logo MIME" (Some "image/png")
    (header logo "content-type");
  check "PNG signature" (String.starts_with ~prefix:"\137PNG" bytes);
  let etag=Option.get (header logo "etag") in
  let unchanged,body=send ~if_none_match:etag runtime `GET
    "/account/logo?size=small" in
  Alcotest.(check int) "logo conditional" 304 (status unchanged);
  Alcotest.(check string) "empty 304" "" body;
  let cookie=session runtime in
  let bad,body=send ~cookie runtime `GET "/users/bogus/avatar" in
  Alcotest.(check int) "bad avatar token" 404 (status bad);
  Alcotest.(check string) "empty invalid avatar" "" body;
  let token=Signed_id.generate ~secret_key_base:secret ~model:"User"
    ~id:127326141 ~purpose:(Some "avatar") ~expires_at:None in
  let avatar,svg=send ~cookie runtime `GET ("/users/"^token^"/avatar") in
  Alcotest.(check int) "initials avatar" 200 (status avatar);
  Alcotest.(check (option string)) "avatar MIME"
    (Some "image/svg+xml; charset=utf-8") (header avatar "content-type");
  check "initial D" (contains svg "\n      D\n    </text>");
  let etag=Option.get (header avatar "etag") in
  let unchanged,body=send ~cookie ~if_none_match:etag runtime `GET
    ("/users/"^token^"/avatar") in
  Alcotest.(check int) "avatar conditional" 304 (status unchanged);
  Alcotest.(check string) "empty avatar 304" "" body)

let test_processed_media_and_attachment () = with_seed (fun runtime service ->
  let source=Filename.concat reference "reference/test/fixtures/files/moon.jpg" in
  let now_time=Db_accounts.now_time now in
  let blob=Storage_blob.create_and_upload runtime service ~source
    ~filename:"moon.jpg" ~content_type:(Some "image/jpeg") ~now:now_time in
  let account_id=Db_runtime.read runtime (fun db ->
    (Option.get (Db_accounts.Account.first db)).id) in
  Db_runtime.write runtime (fun tx ->
    ignore (Db_remaining.Attachment.create tx ~now:now_time
      ~record_type:"Account" ~record_id:account_id ~name:"logo" ~blob_id:blob.id);
    ignore (Db_remaining.Attachment.create tx ~now:now_time
      ~record_type:"User" ~record_id:127326141L ~name:"avatar" ~blob_id:blob.id));
  let cookie=session runtime in
  let vips_available=try Storage_vips.version ()="8.16.1"
    with Failure _ -> false in
  if vips_available then (
    let logo,bytes=send runtime `GET "/account/logo?size=small" in
    Alcotest.(check int) "processed logo" 200 (status logo);
    check "variant PNG" (String.starts_with ~prefix:"\137PNG" bytes);
    let token=Signed_id.generate ~secret_key_base:secret ~model:"User"
      ~id:127326141 ~purpose:(Some "avatar") ~expires_at:None in
    let avatar,bytes=send ~cookie runtime `GET ("/users/"^token^"/avatar") in
    Alcotest.(check int) "processed avatar" 200 (status avatar);
    Alcotest.(check (option string)) "avatar variant MIME"
      (Some "image/webp") (header avatar "content-type");
    check "variant WebP" (String.length bytes>12 &&
      String.sub bytes 0 4="RIFF" && String.sub bytes 8 4="WEBP"));
  let message=Db_runtime.write runtime (fun tx ->
    Db_messages.Message.create tx ~now:now_time
      {Db_messages.Message.room_id=654632876L;creator_id=127326141L;
       client_message_id=Some "m4-attachment";body=None;
       attachment_blob_id=Some blob.id}) in
  let shown,html=send ~cookie runtime `GET
    (Printf.sprintf "/rooms/654632876/messages/%Ld" message.id) in
  Alcotest.(check int) "attached message" 200 (status shown);
  check "signed blob link" (contains html "/rails/active_storage/blobs/redirect/");
  check "signed preview link" (contains html
    "/rails/active_storage/representations/redirect/");
  check "attachment no longer unrenderable" (not (contains html
    "This message could not be displayed")))

let test_pinned_rails_media_headers () = with_seed (fun runtime service ->
  let open Yojson.Basic.Util in
  let fixture path=if Sys.file_exists path then path else "test/"^path in
  let secret_key_base=Yojson.Basic.from_file (fixture "fixtures/rails_compat.json")
    |> member "secret_key_base" |> to_string in
  let cookie=Yojson.Basic.from_file (fixture "fixtures/campfire_sessions.json")
    |> member "sessions" |> to_list |> List.hd
    |> member "cookie_header" |> to_string in
  let labels=Yojson.Basic.from_file (Filename.concat reference
    "parity/.seed/default/labels.json") in
  let avatar_token name=labels |> member ("avatar_tokens."^name) |> to_string in
  let send ?(headers=[]) path =
    let request=Cohttp.Request.make
      ~headers:(Cohttp.Header.of_list
        (["host","campfire.test";"origin","http://campfire.test";
          "sec-fetch-site","same-origin";"cookie",cookie] @ headers))
      (Uri.of_string ("http://campfire.test"^path)) in
    let response,body=Lwt_main.run (Http_app.handle ~runtime
      ~secret_key_base ~now:"2026-09-26T12:00:00Z"
      ~dispatch:App_dispatch.endpoint request Cohttp_lwt.Body.empty) in
    response,Lwt_main.run (Cohttp_lwt.Body.to_string body) in
  Alcotest.(check string) "Rails six-digit cache version"
    "accounts/873240054-20260101160000000000"
    (Controller_accounts.cache_key "accounts" 873240054L "2026-01-01 16:00:00");
  Alcotest.(check string) "fractional cache version"
    "users/9-20260101160000123456"
    (Controller_accounts.cache_key "users" 9L "2026-01-01 16:00:00.123456");
  let logo_etag=Some "W/\"ba406155241302571a06615e754be1d0\"" in
  List.iter (fun path ->
    let response,_=send path in
    Alcotest.(check int) (path^" status") 200 (status response);
    Alcotest.(check (option string)) (path^" Rails ETag") logo_etag
      (header response "etag");
    Alcotest.(check (option string)) (path^" no Last-Modified") None
      (header response "last-modified"))
    ["/account/logo";"/account/logo?size=small"];
  let logo_304,empty=send ~headers:["if-none-match",Option.get logo_etag]
    "/account/logo" in
  Alcotest.(check int) "logo 304" 304 (status logo_304);
  Alcotest.(check string) "empty logo 304" "" empty;
  let david_path="/users/"^avatar_token "david"^"/avatar" in
  let david,svg=send david_path in
  Alcotest.(check int) "David avatar" 200 (status david);
  Alcotest.(check (option string)) "David Rails ETag"
    (Some "W/\"6bd452b9114127dff5c3f46f079f7a4a\"")
    (header david "etag");
  Alcotest.(check (option string)) "David no Last-Modified" None
    (header david "last-modified");
  Alcotest.(check int) "David SVG length" 630 (String.length svg);
  let variant=Db_runtime.read runtime (fun db ->
    Db_remaining.Blob.find db 2L) in
  let pinned_service=Storage_disk.create ~name:"local"
    ~root:(Filename.concat reference "parity/.seed/default/storage") in
  Storage_disk.upload_file service ~key:variant.key
    ~source:(Storage_disk.path_for pinned_service variant.key) ();
  let jason_path="/users/"^avatar_token "jason"^"/avatar" in
  let jason,bytes=send jason_path in
  Alcotest.(check int) "Jason avatar" 200 (status jason);
  Alcotest.(check (option string)) "Jason Rails ETag"
    (Some "W/\"a8565eaf5bbc1ba87057ffc990e3f157\"")
    (header jason "etag");
  Alcotest.(check (option string)) "Jason storage-key disposition"
    (Some (Storage_disk.disposition "inline" variant.key))
    (header jason "content-disposition");
  Alcotest.(check (option string)) "Jason no Last-Modified" None
    (header jason "last-modified");
  Alcotest.(check bool) "Jason WebP" true
    (String.length bytes>12 && String.sub bytes 0 4="RIFF" &&
      String.sub bytes 8 4="WEBP"))

let ()=Alcotest.run "M4 HTTP rendering integration" [
  "routes",[
    Alcotest.test_case "rich text, FTS, and safe DOM" `Quick test_rich_text_route;
    Alcotest.test_case "request Host and decoded GID" `Quick
      test_request_host_and_gid_fallback;
    Alcotest.test_case "stock media and signed avatars" `Quick
      test_stock_media_and_signatures;
    Alcotest.test_case "processed media and attachment DOM" `Quick
      test_processed_media_and_attachment;
    Alcotest.test_case "pinned Rails media response headers" `Quick
      test_pinned_rails_media_headers]]

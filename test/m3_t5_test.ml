open Alcotest

module C = Campfire.Http_cache

let headers pairs = Cohttp.Header.of_list pairs
let request ?(meth=`GET) ?(headers=[]) path =
  Cohttp.Request.make ~meth ~headers:(Cohttp.Header.of_list headers) (Uri.of_string path)
let response ?(status=200) ?(headers=[]) () =
  Cohttp.Response.make ~status:(Cohttp.Code.status_of_code status)
    ~headers:(Cohttp.Header.of_list headers) ()
let get response name = Cohttp.Header.get (Cohttp.Response.headers response) name
let code response = Cohttp.Code.code_of_status (Cohttp.Response.status response)

let finish ?digestible ?control request response body =
  Lwt_main.run (C.finish ?digestible ?control ~request
    (response, Cohttp_lwt.Body.of_string body))
let body_text (_, body) = Lwt_main.run (Cohttp_lwt.Body.to_string body)

let rack_and_conditionals () =
  let req=request "/rooms/1" in
  let result=finish req (response ()) "hello" in
  let reply=fst result in
  check (option string) "rack weak sha256" (Some "W/\"2cf24dba5fb0a30e26e83b2ac5b9e29e\"")
    (get reply "etag");
  check (option string) "private default"
    (Some "max-age=0, private, must-revalidate") (get reply "cache-control");
  let req=request ~headers:["if-none-match","\"wrong\", W/\"2cf24dba5fb0a30e26e83b2ac5b9e29e\""] "/rooms/1" in
  let result=finish req (response ~headers:["content-type","text/html"] ()) "hello" in
  check int "conditional 304" 304 (code (fst result));
  check string "304 body" "" (body_text result);
  check (option string) "304 removes type" None (get (fst result) "content-type");
  let req=request ~meth:`HEAD "/rooms/1" in
  let result=finish req (response ()) "hello" in
  check int "head 200" 200 (code (fst result));
  check string "head body" "" (body_text result);
  check (option string) "head retains etag" (get reply "etag") (get (fst result) "etag");
  let result=finish (request "/") (response ()) "" in
  check (option string) "empty no etag" None (get (fst result) "etag");
  check (option string) "empty no-cache" (Some "no-cache") (get (fst result) "cache-control")

let explicit_freshness () =
  let etag=C.combined_etag (Some "users/1-2024") in
  let req=request ~headers:["if-none-match",etag;"if-modified-since","Sat, 01 Jan 2050 00:00:00 GMT"] "/user/1" in
  let h,control,fresh=C.fresh_when ~validator:"users/1-2024" req (headers []) in
  check bool "matching etag" true fresh;
  check (option string) "weak digest" (Some etag) (Cohttp.Header.get h "etag");
  check (option string) "validator default" (Some "max-age=0, private, must-revalidate")
    (C.apply_control control h |> fun h -> Cohttp.Header.get h "cache-control");
  let req=request ~headers:["if-none-match","\"mismatch\"";
    "if-modified-since","Sat, 01 Jan 2050 00:00:00 GMT"] "/user/1" in
  check bool "if-none-match takes precedence" false (C.is_fresh req h);
  let modified=Option.get (Ptime.of_date_time ((2024,1,1),((0,0,0),0))) in
  let req=request ~headers:["if-modified-since","Mon, 01 Jan 2024 00:00:00 GMT"] "/" in
  let h,_,fresh=C.fresh_when ~last_modified:modified req (headers []) in
  check bool "last modified parsed" true fresh;
  check (option string) "last modified format" (Some "Mon, 01 Jan 2024 00:00:00 GMT")
    (Cohttp.Header.get h "last-modified");
  let req=request ~headers:["if-modified-since","garbage"] "/" in
  check bool "malformed date" false (C.is_fresh req h)

let rendered_message_freshness () =
  let open Lwt.Infix in
  let body="<div id=\"message_1\">hello</div>" in
  let req=request "/rooms/1/messages" in
  let render req =
    let result=Lwt_main.run (C.rendered_freshness ~request:req
      ~template:"messages/index" (response (),Cohttp_lwt.Body.of_string body)) in
    fst result,body_text result in
  let plain,plain_body=render req in
  check string "rendered body preserved" body plain_body;
  let raw_digest=C.hex (C.sha256 body) in
  check (option string) "content and template ETag"
    (Some (C.combined_etag ~template:"messages/index" (Some raw_digest)))
    (get plain "etag");
  check (option string) "no Last-Modified for foreign edits" None
    (get plain "last-modified");
  let frame,_=render (request ~headers:["turbo-frame","messages"]
    "/rooms/1/messages") in
  check (option string) "frame validator isolated"
    (Some (C.combined_etag ~frame:true ~template:"messages/index"
      (Some raw_digest))) (get frame "etag");
  let blank_frame,_=render (request ~headers:["turbo-frame","  "]
    "/rooms/1/messages") in
  check (option string) "blank frame uses ordinary validator"
    (get plain "etag") (get blank_frame "etag");
  let req=request ~headers:["if-none-match",Option.get (get plain "etag")]
    "/rooms/1/messages" in
  let prepared=C.rendered_freshness ~request:req ~template:"messages/index"
    (response (),Cohttp_lwt.Body.of_string body) in
  let result=Lwt_main.run (prepared >>= C.finish ~request:req) in
  check int "rendered conditional 304" 304 (code (fst result));
  check string "rendered 304 body" "" (body_text result)

let cache_control () =
  let c={C.empty_control with max_age=Some 300;public=true;
    stale_while_revalidate=Some 604800} in
  check (option string) "expires format"
    (Some "max-age=300, public, stale-while-revalidate=604800")
    (C.control_header c);
  let c={C.empty_control with no_store=true;private_=true;must_understand=true} in
  check (option string) "no-store normalization"
    (Some "private, must-understand, no-store") (C.control_header c);
  let now=Option.get (Ptime.of_date_time ((2024,1,1),((0,0,0),0))) in
  let h,c=C.expires_in ~now 300 ~public:true (headers []) in
  check (option string) "date" (Some "Mon, 01 Jan 2024 00:00:00 GMT")
    (Cohttp.Header.get h "date");
  check (option string) "public expiration" (Some "max-age=300, public")
    (C.control_header c)

let front_eligibility () =
  let module F=C.Front in
  let public pairs = F.lifetime 200 (headers pairs) in
  check (option int) "public age" (Some 300)
    (public ["cache-control","max-age=300, public"]);
  check (option int) "s-max-age precedence" (Some 10)
    (public ["cache-control","public, s-max-age=10, max-age=99"]);
  check (option int) "private excluded" None
    (public ["cache-control","max-age=300, private"]);
  check (option int) "no-cache excluded" None
    (public ["cache-control","public, no-cache, max-age=300"]);
  check (option int) "vary star excluded" None
    (public ["cache-control","public, max-age=300";"vary","*"]);
  check bool "GET allowed" true (F.request_allowed (request "/"));
  check bool "range bypass" false
    (F.request_allowed (request ~headers:["range","bytes=0-1"] "/"));
  check bool "oversized uri bypass" false
    (F.request_allowed (request ("/" ^ String.make 2048 'x')))

let front_store () =
  let module F=C.Front in
  let cache=F.create ~capacity:2000 ~max_item_size:1000 in
  let h=headers ["cache-control","public, max-age=10";
    "vary","Accept-Encoding";"etag","\"abc\"";"set-cookie","secret"] in
  let gzip=request ~headers:["host","campfire.test";"accept-encoding","gzip"] "/a?q=1" in
  let plain=request ~headers:["host","campfire.test"] "/a?q=1" in
  check bool "stored" true
    (F.store cache ~now:0. ~generation:1L gzip ~status:200 ~headers:h ~body:"hello");
  let item=Option.get (F.find cache ~now:1. ~generation:1L gzip) in
  check string "body" "hello" item.F.body;
  check (option string) "cookie stripped" None (Cohttp.Header.get item.headers "set-cookie");
  check bool "front conditional" true
    (F.was_not_modified (request ~headers:["if-none-match","\"abc\""] "/a") item);
  check bool "variant isolated" true
    (Option.is_none (F.find cache ~now:1. ~generation:1L plain));
  check bool "generation invalidated" true
    (Option.is_none (F.find cache ~now:1. ~generation:2L gzip));
  check bool "expired" true
    (Option.is_none (F.find cache ~now:11. ~generation:1L gzip));
  check bool "large item rejected" false
    (F.store cache ~now:0. ~generation:1L gzip ~status:200 ~headers:h
      ~body:(String.make 1000 'x'))

let private_cache () =
  let module P=C.Private in
  let make ?(extra=[]) () = request ~headers:(
    ["host","campfire.test";"cookie","session=one";"accept-encoding","gzip"] @ extra)
    "/rooms/1?before=2" in
  let req=make () in
  check bool "eligible endpoint" true
    (P.eligible_request ~endpoint:"rooms#show" ~original_method:"GET" ~raw_post:"" req);
  check bool "other endpoint excluded" false
    (P.eligible_request ~endpoint:"users#show" ~original_method:"GET" ~raw_post:"" req);
  check bool "pragma bypass" false
    (P.eligible_request ~endpoint:"rooms#show" ~original_method:"GET" ~raw_post:""
      (make ~extra:["pragma","No-Cache"] ()));
  let ticket req = Option.get (P.key ~generation:7L ~endpoint:"rooms#show"
    ~user_id:1L ~session_id:9L ~origin:"http://campfire.test/" req) in
  let first=ticket req in
  let traced=ticket (make ~extra:["x-request-id","trace-1";
    "if-none-match","W/\"old\""] ()) in
  check string "trace and validators omitted" first.key traced.key;
  let different_user=Option.get (P.key ~generation:7L ~endpoint:"rooms#show"
    ~user_id:2L ~session_id:9L ~origin:"http://campfire.test/" req) in
  check bool "identity isolated" true (first.key<>different_user.key);
  let different_cookie=ticket (make ~extra:["cookie","session=two"] ()) in
  check bool "cookies isolated" true (first.key<>different_cookie.key);
  let cache=P.create ~capacity:2048 in
  let h=headers ["etag","W/\"abc\"";"set-cookie","session=refreshed";
    "date","Mon, 01 Jan 2024 00:00:00 GMT";"x-request-id","trace-1"] in
  check bool "stored" true
    (P.store cache ~now:0. ~generation:7L first ~status:200 ~headers:h ~body:"room");
  let item=Option.get (P.lookup cache ~now:1. ~generation:7L first) in
  check string "stored body" "room" item.body;
  check (option string) "completed body length stored" (Some "4")
    (Cohttp.Header.get item.headers "content-length");
  check (option string) "cookie not replayed" None (Cohttp.Header.get item.headers "set-cookie");
  check (option string) "trace not replayed" None (Cohttp.Header.get item.headers "x-request-id");
  check bool "generation denied" true (Option.is_none (P.lookup cache ~now:1. ~generation:8L first));
  check bool "old render cannot enter new generation" false
    (P.store cache ~now:2. ~generation:8L first ~status:200 ~headers:h ~body:"stale");
  check bool "TTL" true (Option.is_none (P.lookup cache ~now:16. ~generation:7L first));
  check bool "oversized body" false
    (P.store cache ~now:0. ~generation:7L first ~status:200 ~headers:h
      ~body:(String.make (P.max_body+1) 'x'));
  check bool "no-store" false
    (P.store cache ~now:0. ~generation:7L first ~status:200
      ~headers:(headers ["cache-control","no-store"]) ~body:"room")

let streamed_head_length () =
  let open Lwt.Infix in
  let path=Filename.temp_file "campfire-head-" ".bin" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
    let bytes=String.init 8193 (fun i -> Char.chr (i land 255)) in
    let out=open_out_bin path in
    Fun.protect ~finally:(fun () -> close_out out) (fun () ->
      output_string out bytes);
    let served=Campfire.Storage_file_server.serve ~method_:"HEAD" ~path
      ~content_type:"application/octet-stream" ~disposition:"inline" () in
    let response=Cohttp.Response.make
      ~status:(Cohttp.Code.status_of_code served.status)
      ~headers:(headers served.headers) () in
    let request=request ~meth:`HEAD
      ~headers:["accept-encoding","gzip"] "/rails/active_storage/disk/test" in
    let result=Lwt_main.run (C.finish ~digestible:false ~request
      (response,Campfire.Storage_file_server.stream served.body)
      >>= Campfire.Http_gzip.apply request) in
    check int "streamed HEAD status" 200 (code (fst result));
    check string "streamed HEAD body" "" (body_text result);
    check (option string) "streamed HEAD file length" (Some "8193")
      (get (fst result) "content-length");
    check (option string) "streamed HEAD no encoding" None
      (get (fst result) "content-encoding");
    check bool "streamed HEAD retains Last-Modified" true
      (Option.is_some (get (fst result) "last-modified")))

let public_route_cache () =
  let path=Filename.temp_file "campfire-public-cache-" ".sqlite3" in
  let runtime=Campfire.Db_runtime.open_db path in
  Fun.protect ~finally:(fun () ->
    Campfire.Db_runtime.close runtime;
    List.iter (fun file -> if Sys.file_exists file then Sys.remove file)
      [path;path^"-wal";path^"-shm"]) (fun () ->
    let cache=C.Front.create ~capacity:(2*1024*1024)
      ~max_item_size:(1024*1024) in
    let path="/qr_code/" ^ Campfire.Rails_format.urlsafe_encode "cache test" in
    let send ?(extra=[]) () =
      let headers=headers (("host","chat.example.com")::extra) in
      let request=Cohttp.Request.make ~headers (Uri.of_string path) in
      let result=Lwt_main.run (Campfire.Http_app.handle ~runtime
        ~secret_key_base:(String.make 64 'q') ~front_cache:cache
        ~dispatch:Campfire.App_dispatch.endpoint request Cohttp_lwt.Body.empty) in
      fst result,body_text result in
    let first,body=send () in
    check int "public QR 200" 200 (code first);
    check (option string) "front miss" (Some "miss") (get first "x-cache");
    check bool "SVG body" true (String.length body>100);
    let second,again=send () in
    check (option string) "front hit" (Some "hit") (get second "x-cache");
    check string "cached bytes" body again;
    let etag=Option.get (get first "etag") in
    let fresh,fresh_body=send ~extra:["if-none-match",etag] () in
    check int "front conditional hit" 304 (code fresh);
    check string "front 304 body" "" fresh_body;
    let range,_=send ~extra:["range","bytes=0-1"] () in
    check (option string) "range bypass" (Some "bypass") (get range "x-cache"))

let rec reference_root path remaining =
  if remaining=0 then failwith "pinned Rails seed not found" else
  let candidate=Filename.concat path "once-campfire-rust" in
  if Sys.file_exists (Filename.concat candidate
      "parity/.seed/default/db/production.sqlite3") then candidate
  else reference_root (Filename.dirname path) (remaining-1)

let private_route_invalidation () =
  let source_path=Filename.concat (reference_root (Sys.getcwd ()) 8)
    "parity/.seed/default/db/production.sqlite3" in
  let source=Sqlite3.db_open ~mode:`READONLY source_path in
  let path=Filename.temp_file "campfire-private-cache-" ".sqlite3" in
  Sys.remove path;
  let quoted=String.concat "''" (String.split_on_char '\'' path) in
  let rc=Sqlite3.exec source ("VACUUM INTO '"^quoted^"'") in
  ignore (Sqlite3.db_close source);
  if rc<>Sqlite3.Rc.OK then failwith "could not copy pinned seed";
  let runtime=Campfire.Db_runtime.open_db ~prepare:false path in
  let secret=String.make 64 'q' and now="2026-10-08T12:00:00Z" in
  Fun.protect ~finally:(fun () ->
    Campfire.Db_runtime.close runtime;
    List.iter (fun file -> if Sys.file_exists file then Sys.remove file)
      [path;path^"-wal";path^"-shm"]) (fun () ->
    let session=Campfire.Db_runtime.write runtime (fun tx ->
      Campfire.Db_accounts.Session.start (Campfire.Db_runtime.conn tx)
        ~now ~user_id:127326141L ~user_agent:None ~ip_address:None) in
    let cookie="session_token=" ^ Campfire.Authentication.issue_token_cookie
      ~secret_key_base:secret ~now session.token in
    let cache=Option.get (Campfire.Http_app.create_private_cache
      ~capacity:(4*1024*1024) runtime) in
    Fun.protect ~finally:(fun () -> Campfire.Http_app.close_private_cache cache)
      (fun () ->
        let send ?(meth=`GET) ?(extra=[]) ?(path="/rooms/654632876") () =
          let headers=headers (["host","chat.example.com";"cookie",cookie;
            "origin","https://chat.example.com";"accept","text/html"] @ extra) in
          let req=Cohttp.Request.make ~meth ~headers
            (Uri.of_string ("https://chat.example.com"^path)) in
          let result=Lwt_main.run (Campfire.Http_app.handle ~runtime
            ~secret_key_base:secret ~private_cache:cache ~now ~ssl:true
            ~dispatch:Campfire.App_dispatch.endpoint req Cohttp_lwt.Body.empty) in
          fst result,body_text result in
        let initial,body=send () in
        check int "private room 200" 200 (code initial);
        check (option string) "plain GET length"
          (Some (string_of_int (String.length body)))
          (get initial "content-length");
        check int "private item stored" 1 (Hashtbl.length cache.store.items);
        let etag=Option.get (get initial "etag") in
        let gzip,gzip_body=send ~extra:["accept-encoding","gzip";
          "cache-control","no-store"] () in
        check int "gzip GET 200" 200 (code gzip);
        check (option string) "gzip GET encoding" (Some "gzip")
          (get gzip "content-encoding");
        check (option string) "gzip GET omits length" None
          (get gzip "content-length");
        check (option string) "gzip and identity share validator" (Some etag)
          (get gzip "etag");
        check string "gzip member header" "\031\139"
          (String.sub gzip_body 0 2);
        let conditional,conditional_body=send ~extra:["if-none-match",etag] () in
        check int "private conditional GET" 304 (code conditional);
        check string "private conditional body" "" conditional_body;
        let head,head_body=send ~meth:`HEAD () in
        check int "private HEAD" 200 (code head);
        check string "private HEAD body" "" head_body;
        check (option string) "private HEAD ETag" (Some etag) (get head "etag");
        check (option string) "plain HEAD representation length"
          (get initial "content-length") (get head "content-length");
        let gzip_head,gzip_head_body=send ~meth:`HEAD
          ~extra:["accept-encoding","gzip";"cache-control","no-store"] () in
        check int "gzip advertised HEAD" 200 (code gzip_head);
        check string "gzip advertised HEAD body" "" gzip_head_body;
        check (option string) "HEAD does not encode" None
          (get gzip_head "content-encoding");
        check (option string) "HEAD length is identity length"
          (get initial "content-length") (get gzip_head "content-length");
        let fresh_head,fresh_head_body=send ~meth:`HEAD
          ~extra:["accept-encoding","gzip";"cache-control","no-store";
            "if-none-match",etag] () in
        check int "conditional HEAD 304" 304 (code fresh_head);
        check string "conditional HEAD empty" "" fresh_head_body;
        check (option string) "304 has no type" None
          (get fresh_head "content-type");
        check (option string) "304 has no length" None
          (get fresh_head "content-length");
        let cached_gzip_first,cached_gzip_body=send
          ~extra:["accept-encoding","gzip"] () in
        let cached_gzip_second,cached_gzip_again=send
          ~extra:["accept-encoding","gzip"] () in
        check (option string) "private gzip miss completed length"
          (Some (string_of_int (String.length cached_gzip_body)))
          (get cached_gzip_first "content-length");
        check string "private gzip hit bytes" cached_gzip_body
          cached_gzip_again;
        check (option string) "private gzip stored length"
          (Some (string_of_int (String.length cached_gzip_body)))
          (get cached_gzip_second "content-length");
        let cached_gzip_head,cached_gzip_head_body=send ~meth:`HEAD
          ~extra:["accept-encoding","gzip"] () in
        check string "private gzip HEAD empty" "" cached_gzip_head_body;
        check (option string) "private gzip HEAD stored length"
          (get cached_gzip_second "content-length")
          (get cached_gzip_head "content-length");
        check (option string) "private gzip HEAD validator"
          (get cached_gzip_first "etag") (get cached_gzip_head "etag");
        let index_path="/rooms/654632876/messages" in
        let index,index_body=send ~path:index_path () in
        check int "messages index 200" 200 (code index);
        let index_etag=Option.get (get index "etag") in
        check bool "messages index weak validator" true
          (String.starts_with ~prefix:"W/\"" index_etag);
        check (option string) "messages body/template validator"
          (Some (C.combined_etag ~template:"messages/index"
            (Some (C.hex (C.sha256 index_body)))))
          (get index "etag");
        check (option string) "messages index no Last-Modified" None
          (get index "last-modified");
        let index_fresh,index_fresh_body=send ~path:index_path
          ~extra:["if-none-match",index_etag] () in
        check int "messages index conditional GET" 304 (code index_fresh);
        check string "messages index 304 empty" "" index_fresh_body;
        let index_head,index_head_body=send ~path:index_path ~meth:`HEAD () in
        check int "messages index HEAD" 200 (code index_head);
        check string "messages index HEAD empty" "" index_head_body;
        check (option string) "messages HEAD ETag" (Some index_etag)
          (get index_head "etag");
        check (option string) "messages HEAD identity length"
          (get index "content-length") (get index_head "content-length");
        let ims,_=send ~path:index_path ~extra:["if-modified-since",
          "Sat, 01 Jan 2050 00:00:00 GMT"] () in
        check int "messages IMS cannot 304" 200 (code ims);
        check (option string) "room has no Last-Modified" None
          (get initial "last-modified");
        Hashtbl.iter (fun key item -> Hashtbl.replace cache.store.items key
          {item with body="private cache sentinel"}) cache.store.items;
        let _,hit=send () in
        check string "private route uses stored response" "private cache sentinel" hit;
        let rec contains source wanted at =
          at+String.length wanted<=String.length source &&
          (String.sub source at (String.length wanted)=wanted ||
           contains source wanted (at+1)) in
        check bool "old room name" true (contains body "Designers" 0);
        Campfire.Db_runtime.write runtime (fun tx ->
          let db=Campfire.Db_runtime.conn tx in
          let room=Campfire.Db_rooms.Room.find db 654632876L in
          ignore (Campfire.Db_rooms.Room.update tx ~now room
            ~name:(Some "Cache Changed") ()));
        let changed,new_body=send () in
        check int "changed room 200" 200 (code changed);
        check bool "observer invalidates on commit" true
          (contains new_body "Cache Changed" 0);
        let stale,stale_body=send ~extra:["if-none-match",etag] () in
        check int "old validator cannot 304 after commit" 200 (code stale);
        check bool "stale validator returns changed body" true
          (contains stale_body "Cache Changed" 0);
        check bool "new validator differs after commit" true
          (get stale "etag"<>Some etag);
        let since,_=send ~extra:["if-modified-since",
          "Sat, 01 Jan 2050 00:00:00 GMT"] () in
        check int "room has no timestamp validator" 200 (code since);
        check (option string) "no fabricated Last-Modified" None
          (get since "last-modified");
        let sidebar="/users/me/sidebar" in
        let sidebar_response,sidebar_body=send ~path:sidebar () in
        check int "private sidebar 200" 200 (code sidebar_response);
        check bool "sidebar contains changed room" true
          (contains sidebar_body "Cache Changed" 0);
        Hashtbl.iter (fun key item -> Hashtbl.replace cache.store.items key
          {item with body="sidebar cache sentinel"}) cache.store.items;
        let _,sidebar_hit=send ~path:sidebar () in
        check string "private sidebar uses stored response"
          "sidebar cache sentinel" sidebar_hit;
        Campfire.Db_runtime.write runtime (fun tx ->
          Campfire.Db_accounts.Session.destroy
            (Campfire.Db_runtime.conn tx) session);
        let revoked,revoked_body=send () in
        check int "revoked session bypasses cache" 302 (code revoked);
        check bool "revoked body is not cached page" false
          (contains revoked_body "Cache Changed" 0);
        let sidebar_revoked,_=send ~path:sidebar () in
        check int "revoked session bypasses sidebar cache" 302
          (code sidebar_revoked)))

let () = run "m3-t5-cache" [
  "response", [
    test_case "Rack ETag and conditional GET" `Quick rack_and_conditionals;
    test_case "fresh_when and HTTP dates" `Quick explicit_freshness;
    test_case "message content and template validator" `Quick rendered_message_freshness;
    test_case "Cache-Control normalization" `Quick cache_control;
    test_case "streamed file HEAD length" `Quick streamed_head_length;
  ];
  "front", [
    test_case "eligibility and request bypass" `Quick front_eligibility;
    test_case "variant, limits and invalidation" `Quick front_store;
    test_case "public QR route cache" `Quick public_route_cache;
  ];
  "private", [
    test_case "authorization gate, keys, invalidation and limits" `Quick private_cache;
    test_case "room route invalidates on SQLite commit" `Quick private_route_invalidation;
  ];
]

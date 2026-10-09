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

let large_finite_body () =
  let pieces=List.init 48 (fun i -> String.make 65537 (Char.chr (65+i mod 26))) in
  let body=Cohttp_lwt.Body.of_string_list pieces in
  let req=request "/large" in
  let reply,finished=Lwt_main.run (C.finish ~request:req (response (),body)) in
  let expected=String.concat "" pieces in
  check (option string) "large finite digest" (C.rack_etag expected) (get reply "etag");
  check bool "finite chunks stay separate" true
    (match finished with `Strings _ -> true | _ -> false);
  check string "finite chunks preserve bytes" expected
    (Lwt_main.run (Cohttp_lwt.Body.to_string finished));
  let head,_=Lwt_main.run (C.finish ~request:(request ~meth:`HEAD "/large")
    (response (),body)) in
  check (option string) "large HEAD validator" (get reply "etag") (get head "etag");
  check (option string) "large HEAD length" (Some (string_of_int (String.length expected)))
    (get head "content-length")

let page_part_vectors () =
  let message n = Printf.sprintf "<div id=\"message_%d\" class=\"message\">%s</div>\n"
    n (String.concat "" (List.init (40+n mod 7)
      (fun _ -> "<button>Boost</button> hello there "))) in
  let page build =
    let text=Buffer.create 1024 and fragments=ref [] in
    let append s = Buffer.add_string text s in
    let fragment s = fragments := (Buffer.length text,s) :: !fragments in
    build append fragment;
    C.Page_parts.of_offsets ~text:(Buffer.contents text) (List.rev !fragments) in
  let whole=page (fun append fragment ->
    append "<html><head>layout</head><body>";
    for n=0 to 29 do append "  "; fragment (message n) done;
    append "</body></html>") in
  check (option string) "Rust whole page-part ETag"
    (Some "79e220089f196fbabb4a04d3a545749e") whole;
  let mixed=page (fun append fragment ->
    append "<p>"; fragment (message 0); append (String.make 300 'x');
    fragment (message 1); append "  "; fragment "<i>small</i>";
    append "  "; fragment (message 2); append "</p>") in
  check (option string) "Rust mixed page-part ETag"
    (Some "ca77a29a2de60cdd36f203de61f1f9cb") mixed;
  check (option string) "invalid renderer offset rejected" None
    (C.Page_parts.of_offsets ~text:"hello" [6,message 0])

let page_part_gzip_framing () =
  let message n = Printf.sprintf "<div id=\"message_%d\" class=\"message\">%s</div>\n"
    n (String.concat "" (List.init (40+n mod 7)
      (fun _ -> "<button>Boost</button> hello there "))) in
  let text=Buffer.create 1024 and fragments=ref [] and plain=Buffer.create 40000 in
  let add value = Buffer.add_string text value; Buffer.add_string plain value in
  add "<html><head>layout</head><body>";
  for n=0 to 29 do
    add "  ";
    let fragment=message n in
    fragments := (Buffer.length text,fragment) :: !fragments;
    Buffer.add_string plain fragment
  done;
  add "</body></html>";
  let parts=Option.get (C.Page_parts.splice ~text:(Buffer.contents text)
    (List.rev !fragments)) in
  let encoded=C.Page_parts.gzip ~mtime:7 parts in
  check string "Rust-style gzip header and mtime"
    "\031\139\008\000\007\000\000\000\000\003"
    (String.sub encoded 0 10);
  let inflater=Campfire.Webhook_transport.inflater_create true in
  let decoded=match Campfire.Webhook_transport.inflater_feed inflater encoded
      (Buffer.length plain) true with
    | Ok bytes -> bytes | Error why -> fail why in
  check string "sync-flushed parts inflate to recorded body"
    (Buffer.contents plain) decoded;
  let flush="\000\000\255\255" in
  let rec count_flush offset count =
    if offset+4>String.length encoded then count
    else if String.sub encoded offset 4=flush then count_flush (offset+4) (count+1)
    else count_flush (offset+1) count in
  check bool "each of 32 parts ends on a sync-flush boundary" true
    (count_flush 10 0 >= List.length parts);
  check string "system libz piecewise fixture"
    "08ef761b5374d9b4e2ebb35d2f4743a893b47150dc53d0304ce383e7aef428bd"
    (C.hex (C.sha256 encoded));
  let req=request ~headers:["accept-encoding","gzip"] "/rooms/1" in
  let reply,body=Lwt_main.run (Campfire.Http_gzip.apply ~parts req
    (response ~headers:["etag","W/\"recorded\""] (),
      C.Page_parts.body parts)) in
  check (option string) "middleware keeps identity validator"
    (Some "W/\"recorded\"") (get reply "etag");
  check string "middleware selects partwise member" (C.Page_parts.gzip parts)
    (Lwt_main.run (Cohttp_lwt.Body.to_string body));
  let mixed_text=Buffer.create 1024 and mixed_plain=Buffer.create 6000 in
  let mixed_fragments=ref [] in
  let add_mixed value =
    Buffer.add_string mixed_text value; Buffer.add_string mixed_plain value in
  let fragment_mixed value =
    mixed_fragments := (Buffer.length mixed_text,value) :: !mixed_fragments;
    Buffer.add_string mixed_plain value in
  add_mixed "<p>"; fragment_mixed (message 0);
  add_mixed (String.make 300 'x'); fragment_mixed (message 1);
  add_mixed "  "; fragment_mixed "<i>small</i>";
  add_mixed "  "; fragment_mixed (message 2); add_mixed "</p>";
  let mixed=Option.get (C.Page_parts.splice
    ~text:(Buffer.contents mixed_text) (List.rev !mixed_fragments)) in
  let mixed_gzip=C.Page_parts.gzip ~mtime:7 mixed in
  check string "libz mixed glue/short-fragment fixture"
    "ae2b0e23a3dda641230abe9f52a7f229bc1dfb554d93f6acdf534eba3f125614"
    (C.hex (C.sha256 mixed_gzip));
  let inflater=Campfire.Webhook_transport.inflater_create true in
  let mixed_decoded=match Campfire.Webhook_transport.inflater_feed inflater
      mixed_gzip (Buffer.length mixed_plain) true with
    | Ok bytes -> bytes | Error why -> fail why in
  check string "mixed glue/short-fragment decompression"
    (Buffer.contents mixed_plain) mixed_decoded

let recorded_part_transport () =
  let open Lwt.Infix in
  let text=Buffer.create 1024 and plain=Buffer.create 45000 in
  let fragments=ref [] in
  let add value = Buffer.add_string text value; Buffer.add_string plain value in
  add "<main>";
  for n=0 to 39 do
    add "  ";
    let fragment=Printf.sprintf "<article id=\"%d\">%s</article>" n
      (String.make 1100 (Char.chr (65+n mod 26))) in
    fragments := (Buffer.length text,fragment) :: !fragments;
    Buffer.add_string plain fragment
  done;
  add "</main>";
  let page : Campfire.Views.recorded_page = {
    body=Buffer.contents plain; text=Buffer.contents text;
    fragments=List.rev !fragments } in
  let reply,body,validator=Campfire.Controller_rooms.recorded_html page in
  check (option string) "recorded page ETag" (Some ("W/\""^validator^"\""))
    (get reply "etag");
  check bool "identity response has over 40 frames" true
    (match body with `Strings parts -> List.length parts > 40 | _ -> false);
  check string "part frames reconstruct exact body" page.body
    (Lwt_main.run (Cohttp_lwt.Body.to_string body));
  let head_req=request ~meth:`HEAD "/rooms/1" in
  let head=Lwt_main.run (C.finish ~request:head_req
    (Campfire.Controller_rooms.recorded_html page |> fun (reply,body,_) -> reply,body)) in
  check string "part HEAD empty" "" (body_text head);
  check (option string) "part HEAD validator" (get reply "etag")
    (get (fst head) "etag");
  check (option string) "part HEAD length" (Some (string_of_int (String.length page.body)))
    (get (fst head) "content-length");
  let head_gzip_req=request ~meth:`HEAD
    ~headers:["accept-encoding","gzip"] "/rooms/1" in
  let head_gzip=Lwt_main.run (C.finish ~request:head_gzip_req
    (Campfire.Controller_rooms.recorded_html page |> fun (reply,body,_) -> reply,body)
    >>= Campfire.Http_gzip.apply head_gzip_req) in
  check string "part gzip HEAD body empty" "" (body_text head_gzip);
  check (option string) "part gzip HEAD encoding" (Some "gzip")
    (get (fst head_gzip) "content-encoding");
  check (option string) "part gzip HEAD has no length" None
    (get (fst head_gzip) "content-length");
  check (option string) "part gzip HEAD validator" (get reply "etag")
    (get (fst head_gzip) "etag");
  let gzip_req=request ~headers:["accept-encoding","gzip"] "/rooms/1" in
  let gzip=Lwt_main.run (C.finish ~request:gzip_req
    (Campfire.Controller_rooms.recorded_html page |> fun (reply,body,_) -> reply,body)
    >>= Campfire.Http_gzip.apply gzip_req) in
  check (option string) "part gzip validator" (get reply "etag")
    (get (fst gzip) "etag");
  check (option string) "part gzip encoding" (Some "gzip")
    (get (fst gzip) "content-encoding");
  check string "part gzip member" "\031\139"
    (String.sub (body_text gzip) 0 2)

let rendered_vary_rules () =
  let vary=Campfire.Http_format.should_apply_vary_header in
  check bool "explicit Accept makes rendered page vary" true
    (vary ~accept:"text/html" ~xhr:false ());
  check bool "browser wildcard Accept does not vary" false
    (vary ~accept:"text/html,\t*/*" ~xhr:false ());
  check bool "format param takes precedence" false
    (vary ~format_param:"html" ~accept:"text/html" ~xhr:false ());
  check bool "XHR content type can select format" true
    (vary ~content_type:"application/json" ~xhr:true ());
  check bool "empty XHR content type cannot select format" false
    (vary ~content_type:"" ~xhr:true ())

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
  check bool "malformed date" false (C.is_fresh req h);
  let flash=C.flash_etaggers ["notice",`String "hello";
    "alert",`String "Room not found"] in
  check (list string) "Rust flash Debug etaggers"
    ["alert=Some(String(\"Room not found\"))";
     "notice=Some(String(\"hello\"))"] flash;
  check bool "flash changes template validator" true
    (C.combined_etag ~template:"messages/index" ~flash (Some "parts") <>
     C.combined_etag ~template:"messages/index" (Some "parts"))

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
    let gzip_request=request ~meth:`HEAD
      ~headers:["accept-encoding","gzip"] "/rails/active_storage/disk/test" in
    let result=Lwt_main.run (C.finish ~digestible:false ~request:gzip_request
      (response,Campfire.Storage_file_server.stream served.body)
      >>= Campfire.Http_gzip.apply gzip_request) in
    check int "streamed HEAD status" 200 (code (fst result));
    check string "streamed HEAD body" "" (body_text result);
    check (option string) "streamed gzip HEAD has no identity length" None
      (get (fst result) "content-length");
    check (option string) "streamed gzip HEAD encoding" (Some "gzip")
      (get (fst result) "content-encoding");
    check bool "streamed HEAD retains Last-Modified" true
      (Option.is_some (get (fst result) "last-modified"));
    let identity_request=request ~meth:`HEAD
      ~headers:["accept-encoding","identity"] "/rails/active_storage/disk/test" in
    let identity=Lwt_main.run (C.finish ~digestible:false ~request:identity_request
      (response,Campfire.Storage_file_server.stream served.body)
      >>= Campfire.Http_gzip.apply identity_request) in
    check string "streamed identity HEAD body empty" "" (body_text identity);
    check (option string) "streamed identity HEAD file length" (Some "8193")
      (get (fst identity) "content-length");
    check (option string) "streamed identity HEAD no encoding" None
      (get (fst identity) "content-encoding"))

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
    check (option string) "range bypass" (Some "bypass") (get range "x-cache");
    let logo () =
      let request=Cohttp.Request.make
        ~headers:(headers ["host","chat.example.com"])
        (Uri.of_string "/account/logo") in
      let result=Lwt_main.run (Campfire.Http_app.handle ~runtime
        ~secret_key_base:(String.make 64 'q') ~front_cache:cache
        ~dispatch:Campfire.App_dispatch.endpoint request Cohttp_lwt.Body.empty) in
      fst result,body_text result in
    let first_logo,logo_bytes=logo () in
    check int "streamed stock logo 200" 200 (code first_logo);
    check bool "streamed stock logo has bytes" true (String.length logo_bytes>100);
    check (option string) "streamed logo first miss" (Some "miss")
      (get first_logo "x-cache");
    let second_logo,cached_logo=logo () in
    check (option string) "streamed logo cache hit" (Some "hit")
      (get second_logo "x-cache");
    check string "cached streamed logo bytes" logo_bytes cached_logo)

let bypassed_write_vary_order () =
  let path=Filename.temp_file "campfire-vary-order-" ".sqlite3" in
  let runtime=Campfire.Db_runtime.open_db path in
  Fun.protect ~finally:(fun () ->
    Campfire.Db_runtime.close runtime;
    List.iter (fun file -> if Sys.file_exists file then Sys.remove file)
      [path;path^"-wal";path^"-shm"]) (fun () ->
    let cache=C.Front.create ~capacity:4096 ~max_item_size:1024 in
    let action _ = Lwt.return (Campfire.Http_app.respond ~status:200
      ~content_type:"text/vnd.turbo-stream.html; charset=utf-8"
      ~headers:["vary","Accept,Accept-Encoding"] "<turbo-stream></turbo-stream>") in
    let dispatch endpoint = if endpoint="sessions#create" then
      Some Campfire.Http_app.{ before_action=(fun _ -> Lwt.return (Ok ()));
        action } else None in
    let req=request ~meth:`POST ~headers:["host","chat.example.com";
      "accept","text/vnd.turbo-stream.html";
      "content-type","application/x-www-form-urlencoded";
      "origin","http://chat.example.com";"sec-fetch-site","same-origin"]
      "/session" in
    let reply,_=Lwt_main.run (Campfire.Http_app.handle ~runtime
      ~secret_key_base:"unused" ~front_cache:cache ~dispatch req
      Cohttp_lwt.Body.empty) in
    check int "bypassed write 200" 200 (code reply);
    check (list string) "front Vary precedes app Vary on POST"
      ["Accept-Encoding";"Accept,Accept-Encoding"]
      (Cohttp.Header.get_multi (Cohttp.Response.headers reply) "vary"))

let rec reference_root path remaining =
  if remaining=0 then failwith "pinned Rails seed not found" else
  let candidate=Filename.concat path "once-campfire-rust" in
  if Sys.file_exists (Filename.concat candidate
      "parity/.seed/default/db/production.sqlite3") then candidate
  else reference_root (Filename.dirname path) (remaining-1)

let public_media_cache_date () =
  let source_path=Filename.concat (reference_root (Sys.getcwd ()) 8)
    "parity/.seed/default/db/production.sqlite3" in
  let source=Sqlite3.db_open ~mode:`READONLY source_path in
  let path=Filename.temp_file "campfire-logo-cache-" ".sqlite3" in
  Sys.remove path;
  let quoted=String.concat "''" (String.split_on_char '\'' path) in
  let rc=Sqlite3.exec source ("VACUUM INTO '"^quoted^"'") in
  ignore (Sqlite3.db_close source);
  if rc<>Sqlite3.Rc.OK then failwith "could not copy pinned seed";
  let runtime=Campfire.Db_runtime.open_db ~prepare:false path in
  Fun.protect ~finally:(fun () ->
    Campfire.Db_runtime.close runtime;
    List.iter (fun file -> if Sys.file_exists file then Sys.remove file)
      [path;path^"-wal";path^"-shm"]) (fun () ->
    let cache=C.Front.create ~capacity:(2*1024*1024)
      ~max_item_size:(1024*1024) in
    let date="Mon, 02 Mar 2026 16:00:00 GMT" in
    let send ?(extra=[]) () =
      let request=Cohttp.Request.make
        ~headers:(headers (["host","chat.example.com"]@extra))
        (Uri.of_string "/account/logo") in
      Lwt_main.run (Campfire.Http_app.handle ~runtime
        ~secret_key_base:(String.make 64 'q') ~front_cache:cache
        ~now:"2026-03-02T16:00:00Z"
        ~dispatch:Campfire.App_dispatch.endpoint request Cohttp_lwt.Body.empty) in
    let first=send () in
    check int "seeded logo 200" 200 (code (fst first));
    check (option string) "logo miss keeps frozen Date" (Some date)
      (get (fst first) "date");
    check (option string) "logo first miss" (Some "miss")
      (get (fst first) "x-cache");
    let hit=send () in
    check (option string) "logo repeat hit" (Some "hit")
      (get (fst hit) "x-cache");
    check (option string) "logo hit keeps frozen Date" (Some date)
      (get (fst hit) "date");
    let etag=Option.get (get (fst first) "etag") in
    let conditional=send ~extra:["if-none-match",etag] () in
    check int "conditional logo hit 304" 304 (code (fst conditional));
    check (option string) "conditional logo cache hit" (Some "hit")
      (get (fst conditional) "x-cache");
    check (option string) "conditional hit preserves frozen Date" (Some date)
      (get (fst conditional) "date"))

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
        let send ?(meth=`GET) ?(extra=[]) ?cookie_header ?(path="/rooms/654632876") () =
          let cookie_header=Option.value cookie_header ~default:cookie in
          let headers=headers (["host","chat.example.com";"cookie",cookie_header;
            "origin","https://chat.example.com";"accept","text/html"] @ extra) in
          let req=Cohttp.Request.make ~meth ~headers
            (Uri.of_string ("https://chat.example.com"^path)) in
          let result=Lwt_main.run (Campfire.Http_app.handle ~runtime
            ~secret_key_base:secret ~private_cache:cache ~now ~ssl:true
            ~dispatch:Campfire.App_dispatch.endpoint req Cohttp_lwt.Body.empty) in
          fst result,body_text result in
        let initial,body=send () in
        check int "private room 200" 200 (code initial);
        check bool "rendered room varies on Accept" true
          (Option.value (get initial "vary") ~default:"" |>
           fun vary -> String.split_on_char ',' vary |>
             List.exists (fun item -> String.trim item="Accept"));
        check (option string) "plain GET length"
          (Some (string_of_int (String.length body)))
          (get initial "content-length");
        check int "private item stored" 1 (Hashtbl.length cache.store.items);
        check bool "room uses page-part validator" true
          (get initial "etag" <> C.rack_etag body);
        let uncached_req=Cohttp.Request.make
          ~headers:(headers ["host","chat.example.com";"cookie",cookie;
            "origin","https://chat.example.com";"accept","text/html";
            "cache-control","no-store"])
          (Uri.of_string "https://chat.example.com/rooms/654632876") in
        let uncached_reply,uncached_body=Lwt_main.run
          (Campfire.Http_app.handle ~runtime ~secret_key_base:secret
             ~private_cache:cache ~now ~ssl:true
             ~dispatch:Campfire.App_dispatch.endpoint uncached_req
             Cohttp_lwt.Body.empty) in
        let frames=match uncached_body with
          | `Strings parts -> List.length parts | _ -> 0 in
        check bool (Printf.sprintf "no-store room preserves part frames (%d)" frames)
          true (frames > 1);
        check (option string) "no-store parts keep validator"
          (get initial "etag") (get uncached_reply "etag");
        check string "no-store part bytes" body
          (Lwt_main.run (Cohttp_lwt.Body.to_string uncached_body));
        let all_talk_req=Cohttp.Request.make
          ~headers:(headers ["host","chat.example.com";"cookie",cookie;
            "origin","https://chat.example.com";"accept","text/html";
            "cache-control","no-store"])
          (Uri.of_string "https://chat.example.com/rooms/486777696") in
        let all_talk_reply,all_talk_body=Lwt_main.run
          (Campfire.Http_app.handle ~runtime ~secret_key_base:secret
             ~private_cache:cache ~now ~ssl:true
             ~dispatch:Campfire.App_dispatch.endpoint all_talk_req
             Cohttp_lwt.Body.empty) in
        check int "seeded 40-message room 200" 200 (code all_talk_reply);
        let all_talk_frames=match all_talk_body with
          | `Strings parts -> List.length parts | _ -> 0 in
        check bool (Printf.sprintf "seeded no-store room frames (%d)" all_talk_frames)
          true (all_talk_frames > 40);
        let all_talk_bytes=Lwt_main.run (Cohttp_lwt.Body.to_string all_talk_body) in
        check (option string) "seeded part content length"
          (Some (string_of_int (String.length all_talk_bytes)))
          (get all_talk_reply "content-length");
        let gzip_room,gzip_room_bytes=send ~path:"/rooms/486777696"
          ~extra:["accept-encoding","gzip";"cache-control","no-store"] () in
        check (option string) "seeded recorded room gzip"
          (Some "gzip") (get gzip_room "content-encoding");
        let inflate bytes expected =
          let decoder=Campfire.Webhook_transport.inflater_create true in
          match Campfire.Webhook_transport.inflater_feed decoder bytes expected true with
          | Ok decoded -> decoded | Error why -> fail why in
        check string "seeded room partwise gzip decodes to identity"
          all_talk_bytes (inflate gzip_room_bytes (String.length all_talk_bytes));
        let flush="\000\000\255\255" in
        let rec sync_flushes body at count =
          if at+4>String.length body then count
          else if String.sub body at 4=flush then
            sync_flushes body (at+4) (count+1)
          else sync_flushes body (at+1) count in
        check bool "seeded room gzip retains part boundaries" true
          (sync_flushes gzip_room_bytes 10 0 > 40);
        check int "no-store bypasses private admission" 1
          (Hashtbl.length cache.store.items);
        let rec contains source wanted at =
          at+String.length wanted<=String.length source &&
          (String.sub source at (String.length wanted)=wanted ||
           contains source wanted (at+1)) in
        let denied,_=send ~path:"/rooms/0" () in
        check int "denied room redirects with flash" 302 (code denied);
        let flash_cookie=Cohttp.Header.get_multi (Cohttp.Response.headers denied)
          "set-cookie" |> List.find_opt
            (String.starts_with ~prefix:"_campfire_session=")
          |> Option.get |> String.split_on_char ';' |> List.hd in
        let flashed_cookie=cookie ^ "; " ^ flash_cookie in
        let health,_=send ~path:"/up" ~cookie_header:flashed_cookie () in
        check int "health does not consume flash" 200 (code health);
        check bool "health does not write flash cookie" false
          (Cohttp.Header.get_multi (Cohttp.Response.headers health) "set-cookie"
           |> List.exists (String.starts_with ~prefix:"_campfire_session="));
        let flashed,flashed_body=send ~cookie_header:flashed_cookie () in
        check int "flashed room 200" 200 (code flashed);
        check bool "flash rendered through cache path" true
          (contains flashed_body "Room not found or inaccessible" 0);
        check bool "flash consumption writes cookie" true
          (Cohttp.Header.get_multi (Cohttp.Response.headers flashed) "set-cookie"
           |> List.exists (String.starts_with ~prefix:"_campfire_session="));
        check int "flashed response not admitted" 1 (Hashtbl.length cache.store.items);
        let _,clean_body=send () in
        check bool "clean cached room has no alert" false
          (contains clean_body "Room not found or inaccessible" 0);
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
        check (option string) "gzip HEAD selects representation" (Some "gzip")
          (get gzip_head "content-encoding");
        check (option string) "gzip HEAD omits identity length" None
          (get gzip_head "content-length");
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
        let flashed_index,flashed_index_body=send ~path:index_path
          ~cookie_header:flashed_cookie () in
        check int "flashed message index 200" 200 (code flashed_index);
        check string "bare index body unaffected by flash" index_body
          flashed_index_body;
        check bool "flash etagger isolates bare index validator" true
          (get flashed_index "etag" <> Some index_etag);
        let all_talk_index_req=Cohttp.Request.make
          ~headers:(headers ["host","chat.example.com";"cookie",cookie;
            "origin","https://chat.example.com";"accept","text/html";
            "cache-control","no-store"])
          (Uri.of_string "https://chat.example.com/rooms/486777696/messages") in
        let all_talk_index,all_talk_index_body=Lwt_main.run
          (Campfire.Http_app.handle ~runtime ~secret_key_base:secret
             ~private_cache:cache ~now ~ssl:true
             ~dispatch:Campfire.App_dispatch.endpoint all_talk_index_req
             Cohttp_lwt.Body.empty) in
        check int "seeded no-store index 200" 200 (code all_talk_index);
        let index_frames=match all_talk_index_body with
          | `Strings parts -> List.length parts | _ -> 0 in
        check bool (Printf.sprintf "seeded no-store index frames (%d)" index_frames)
          true (index_frames > 40);
        let all_talk_index_bytes=Lwt_main.run
          (Cohttp_lwt.Body.to_string all_talk_index_body) in
        check (option string) "seeded index part length"
          (Some (string_of_int (String.length all_talk_index_bytes)))
          (get all_talk_index "content-length");
        let gzip_index,gzip_index_bytes=send
          ~path:"/rooms/486777696/messages"
          ~extra:["accept-encoding","gzip";"cache-control","no-store"] () in
        check (option string) "seeded recorded index gzip"
          (Some "gzip") (get gzip_index "content-encoding");
        check string "seeded index partwise gzip decodes to identity"
          all_talk_index_bytes
          (inflate gzip_index_bytes (String.length all_talk_index_bytes));
        check bool "seeded index gzip retains part boundaries" true
          (sync_flushes gzip_index_bytes 10 0 > 40);
        check bool "messages use page-part/template validator" true
          (get index "etag" <>
           Some (C.combined_etag ~template:"messages/index"
             (Some (C.hex (C.sha256 index_body)))));
        check (option string) "messages index no Last-Modified" None
          (get index "last-modified");
        let index_fresh,index_fresh_body=send ~path:index_path
          ~extra:["if-none-match",index_etag] () in
        check int "messages index conditional GET" 304 (code index_fresh);
        check string "messages index 304 empty" "" index_fresh_body;
        let index_uncached_fresh,_=send ~path:index_path
          ~extra:["cache-control","no-store";"if-none-match",index_etag] () in
        check int "uncached message index conditional 304" 304
          (code index_uncached_fresh);
        check (option string) "early fresh_when 304 varies only on encoding"
          (Some "Accept-Encoding") (get index_uncached_fresh "vary");
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
        check bool "rendered sidebar varies on Accept" true
          (Option.value (get sidebar_response "vary") ~default:"" |>
           fun vary -> String.split_on_char ',' vary |>
             List.exists (fun item -> String.trim item="Accept"));
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
    test_case "large finite body preserves chunking and validator" `Quick large_finite_body;
    test_case "pinned Rust page-part ETag vectors" `Quick page_part_vectors;
    test_case "page-part sync-flushed gzip wire framing" `Quick page_part_gzip_framing;
    test_case "recorded page part transport and HEAD/gzip" `Quick recorded_part_transport;
    test_case "rendered Accept Vary rules" `Quick rendered_vary_rules;
    test_case "fresh_when and HTTP dates" `Quick explicit_freshness;
    test_case "message content and template validator" `Quick rendered_message_freshness;
    test_case "Cache-Control normalization" `Quick cache_control;
    test_case "streamed file HEAD length" `Quick streamed_head_length;
  ];
  "front", [
    test_case "eligibility and request bypass" `Quick front_eligibility;
    test_case "bypassed write Vary field order" `Quick bypassed_write_vary_order;
    test_case "variant, limits and invalidation" `Quick front_store;
    test_case "public QR route cache" `Quick public_route_cache;
    test_case "cached media preserves application Date" `Quick public_media_cache_date;
  ];
  "private", [
    test_case "authorization gate, keys, invalidation and limits" `Quick private_cache;
    test_case "room route invalidates on SQLite commit" `Quick private_route_invalidation;
  ];
]

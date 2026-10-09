open Campfire
open Yojson.Basic.Util

module B = Storage_blob
module D = Storage_disk
module M = Storage_media
module V = Storage_variation

let upstream =
  match Sys.getenv_opt "CAMPFIRE_RUST_ROOT" with
  | Some path -> path
  | None ->
      let rec find dir =
        let candidate = Filename.concat dir "once-campfire-rust" in
        if Sys.file_exists (Filename.concat candidate "Cargo.toml") then candidate
        else let parent = Filename.dirname dir in
          if parent = dir then failwith "set CAMPFIRE_RUST_ROOT to the pinned Rust checkout"
          else find parent in
      find (Sys.getcwd ())
let vectors = lazy (Yojson.Basic.from_file "fixtures/storage.json")
let secret = lazy (Yojson.Basic.from_file "fixtures/rails_compat.json"
  |> member "secret_key_base" |> to_string)
let field value name = member name value
let string value = to_string value
let list value = to_list value
let optional_list = function `Null -> [] | value -> list value
let check = Alcotest.(check string)
let fixture name = Filename.concat upstream ("reference/test/fixtures/files/" ^ name)
let golden name = Filename.concat upstream ("vectors/storage/" ^ name)
let read_file path =
  let input=open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr input)
    (fun () -> really_input_string input (in_channel_length input))
let rec remove path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Array.iter (fun child -> remove (Filename.concat path child)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
let rec file_count path =
  if not (Sys.file_exists path) then 0
  else if Sys.is_directory path then
    Array.fold_left (fun total child -> total + file_count
      (Filename.concat path child)) 0 (Sys.readdir path)
  else 1
let temp_dir () =
  let path=Filename.temp_file "campfire-m6-t4-" "" in
  Sys.remove path;Unix.mkdir path 0o700;path

let with_seed f =
  let root=temp_dir () in
  let database=Filename.concat root "production.sqlite3" in
  let seed=Filename.concat upstream "parity/.seed/default/db/production.sqlite3" in
  let source=Sqlite3.db_open ~mode:`READONLY seed in
  let escaped=String.concat "''" (String.split_on_char '\'' database) in
  let result=Sqlite3.exec source ("VACUUM INTO '" ^ escaped ^ "'") in
  ignore (Sqlite3.db_close source);
  if result<>Sqlite3.Rc.OK then Alcotest.fail "could not copy pinned seed";
  let runtime=Db_runtime.open_db ~readers:4 ~prepare:false database in
  let service=D.create ~root:(Filename.concat root "files") ~name:"local" in
  Fun.protect ~finally:(fun () -> Db_runtime.close runtime;remove root)
    (fun () -> f runtime service)

let rec typed = function
  | `Null -> V.Nil | `Bool value -> V.Bool value
  | `Int value -> V.Int (Int64.of_int value)
  | `List items -> V.Array (List.map typed items)
  | `Assoc ["sym",`String value] -> V.Symbol value
  | `Assoc ["str",`String value] -> V.Str value
  | `Assoc ["hash",`List entries] ->
      V.Hash (List.map (function
        | `List [`String key;value] -> key,typed value
        | _ -> Alcotest.fail "malformed typed variation") entries)
  | _ -> Alcotest.fail "malformed typed variation"
let variation value = match typed (field value "transformations_typed") with
  | V.Hash items -> items
  | _ -> Alcotest.fail "expected variation hash"
let optional_string = function `String value -> Some value | `Null -> None | _ -> Alcotest.fail "expected string or null"
let source_blob runtime service item =
  let filename=field item "fixture" |> string in
  let descriptor=field item "blob" in
  let declared=match field item "declared_type" with
    | `Null -> optional_string (field descriptor "content_type")
    | value -> optional_string value in
  let now=Authentication.now_time "2026-09-26T12:00:00Z" in
  let blob=B.create_and_upload runtime service ~source:(fixture filename)
    ~filename:(field descriptor "filename" |> string) ~content_type:declared ~now in
  M.analyze runtime service blob

let json_equal name expected actual =
  check name (Rails_format.encode (Yojson.Safe.from_string expected))
    (Rails_format.encode (Yojson.Safe.from_string actual))

let verify_blob service ~label ~expected ~actual ~file =
  check (label ^ " filename") (field expected "filename" |> string) actual.Db_remaining.Blob.filename;
  Alcotest.(check (option string)) (label ^ " MIME")
    (optional_string (field expected "content_type")) actual.content_type;
  check (label ^ " service") (field expected "service_name" |> string) actual.service_name;
  Alcotest.(check int64) (label ^ " size")
    (Int64.of_int (field expected "byte_size" |> to_int)) actual.byte_size;
  Alcotest.(check (option string)) (label ^ " checksum")
    (optional_string (field expected "checksum")) actual.checksum;
  json_equal (label ^ " metadata")
    (field expected "metadata" |> string)
    (Option.get actual.metadata);
  let saved=read_file (D.path_for service actual.key) in
  let reference=read_file file in
  check (label ^ " exact bytes") reference saved;
  Alcotest.(check (option string)) (label ^ " stored checksum")
    actual.checksum (Some (D.checksum_bytes saved))

let count runtime table = Db_runtime.read runtime (fun db ->
  Db_runtime.query_one db ("SELECT COUNT(*) FROM " ^ table) []
    (fun row -> Sqlite3.column_int row 0) |> Option.get)

let verify_variant_relation runtime source variation result =
  let digest=V.digest (Storage_image.variation_for source variation) in
  Db_runtime.read runtime (fun db ->
    let record=Db_remaining.Variant_record.find_for db
      ~blob_id:source.Db_remaining.Blob.id ~variation_digest:digest
      |> Option.get in
    let attachment=Db_remaining.Attachment.find_for db
      ~record_type:"ActiveStorage::VariantRecord" ~record_id:record.id
      ~name:"image" |> Option.get in
    Alcotest.(check int64) "tracked variant attachment"
      result.Db_remaining.Blob.id attachment.blob_id)

let strict_versions () =
  check "libvips version" (field (field (Lazy.force vectors) "versions") "libvips" |> string)
    (Storage_vips.version ());
  let actual=M.run ~timeout:5. "ffmpeg" ["-version"]
    |> String.split_on_char '\n' |> List.hd |> String.trim in
  check "ffmpeg version" (field (field (Lazy.force vectors) "versions") "ffmpeg" |> string) actual

let corpus_inventory () =
  let originals=ref 0 and derivatives=ref 0 in
  List.iter (fun kind ->
    List.iter (fun item ->
      incr originals;
      let source=field item "fixture" |> string in
      Alcotest.(check bool) (source ^ " fixture present") true
        (Sys.file_exists (fixture source));
      List.iter (fun sample ->
        incr derivatives;
        let label=field sample "label" |> string in
        let bytes=read_file (golden (field sample "file" |> string)) in
        let expected=field sample "blob" in
        Alcotest.(check int) (label ^ " golden size")
          (field expected "byte_size" |> to_int) (String.length bytes);
        check (label ^ " golden checksum")
          (field expected "checksum" |> string) (D.checksum_bytes bytes))
        (field item "variants" |> optional_list);
      match field item "preview_image" with
      | `Assoc _ as preview ->
          incr derivatives;
          let bytes=read_file (golden (field preview "file" |> string)) in
          let expected=field preview "blob" in
          Alcotest.(check int) "video preview golden size"
            (field expected "byte_size" |> to_int) (String.length bytes);
          check "video preview golden checksum"
            (field expected "checksum" |> string) (D.checksum_bytes bytes)
      | _ -> ())
      (field (Lazy.force vectors) kind |> list))
    ["messages";"avatars";"logos"];
  Alcotest.(check int) "pinned original count" 8 !originals;
  Alcotest.(check int) "pinned derivative count" 11 !derivatives

let full_pipeline () =
  strict_versions ();
  with_seed (fun runtime service ->
    let now=Authentication.now_time "2026-09-26T12:00:00Z" in
    let baseline_variants=count runtime "active_storage_variant_records" in
    let source_count=ref 0 and derivative_count=ref 0 in
    List.iter (fun kind ->
      List.iter (fun item ->
        let filename=field item "fixture" |> string in
        let blob=source_blob runtime service item in
        incr source_count;
        verify_blob service ~label:(kind ^ "/" ^ filename)
          ~expected:(field item "blob") ~actual:blob ~file:(fixture filename);
        (match field item "variable" with
         | `Bool expected -> Alcotest.(check bool) "variable" expected
             (Storage_image.is_variable blob)
         | _ -> ());
        (match field item "previewable" with
         | `Bool expected -> Alcotest.(check bool) "previewable" expected
             (String.starts_with ~prefix:"video/"
               (Option.value blob.content_type ~default:""))
         | _ -> ());
        let variant_source=if filename="alpha-centuri.mov" then (
          let preview=M.preview_image runtime service blob ~now in
          verify_blob service ~label:"video preview"
            ~expected:(field (field item "preview_image") "blob")
            ~actual:preview
            ~file:(golden (field (field item "preview_image") "file" |> string));
          Db_runtime.read runtime (fun db ->
            let attachment=Db_remaining.Attachment.find_for db
              ~record_type:"ActiveStorage::Blob" ~record_id:blob.id
              ~name:"preview_image" |> Option.get in
            Alcotest.(check int64) "preview attachment" preview.id attachment.blob_id);
          preview)
        else blob in
        List.iter (fun sample ->
          let name=field sample "label" |> string in
          let transformations=variation sample in
          let process ()=M.process_representation runtime service blob transformations ~now
            |> Option.get in
          let result=if kind="messages" && filename="moon.jpg" then (
            let outputs=Array.make 8 None in
            let workers=Array.init 8 (fun index -> Thread.create (fun () ->
              outputs.(index)<-(try Some (Ok (process ())) with exn ->
                Some (Error (Printexc.to_string exn)))) ()) in
            Array.iter Thread.join workers;
            let first=match outputs.(0) with Some (Ok result) -> result
              | Some (Error reason) -> Alcotest.fail reason
              | None -> Alcotest.fail "concurrent variant worker did not finish" in
            Array.iter (function
              | Some (Ok next) -> Alcotest.(check int64)
                  "concurrent first transform winner"
                  first.Db_remaining.Blob.id next.Db_remaining.Blob.id
              | Some (Error reason) -> Alcotest.fail reason
              | None -> Alcotest.fail "concurrent variant worker did not finish") outputs;
            Alcotest.(check int) "no abandoned concurrent variants" 2
              (file_count service.root);
            first)
          else process () in
          incr derivative_count;
          verify_blob service ~label:name ~expected:(field sample "blob")
            ~actual:result ~file:(golden (field sample "file" |> string));
          check (name ^ " digest") (field sample "variation_digest" |> string)
            (V.digest (Storage_image.variation_for variant_source transformations));
          verify_variant_relation runtime variant_source transformations result;
          let reused=M.process_representation runtime service blob transformations ~now
            |> Option.get in
          Alcotest.(check int64) (name ^ " cached winner") result.id reused.id)
          (field item "variants" |> optional_list))
        (field (Lazy.force vectors) kind |> list))
      ["messages";"avatars";"logos"];
    Alcotest.(check int) "all original fixtures" 8 !source_count;
    Alcotest.(check int) "all golden variants" 10 !derivative_count;
    Alcotest.(check int) "new variant rows" 10
      (count runtime "active_storage_variant_records" - baseline_variants))

let request runtime ?(method_=`GET) ?(headers=[]) path =
  let headers=Cohttp.Header.of_list
    (["host","campfire.test";"sec-fetch-site","same-origin";
      "origin","http://campfire.test"]@headers) in
  let request=Cohttp.Request.make ~meth:method_ ~headers
    (Uri.of_string ("http://campfire.test" ^ path)) in
  let response,body=Lwt_main.run (Http_app.handle ~runtime
    ~secret_key_base:(Lazy.force secret) ~now:"2026-09-26T12:00:00Z"
    ~dispatch:Controller_aux.endpoint request Cohttp_lwt.Body.empty) in
  let body=Lwt_main.run (Cohttp_lwt.Body.to_string body) in
  response,body
let status response = Cohttp.Response.status response |> Cohttp.Code.code_of_status
let header response name = Cohttp.Header.get (Cohttp.Response.headers response) name
let path_of_url value =
  let uri=Uri.of_string value in
  Uri.path uri ^ (match Uri.verbatim_query uri with None -> "" | Some q -> "?" ^ q)

let signed_http_routes () =
  strict_versions ();
  with_seed (fun runtime service ->
    Storage_http.register service;
    Storage_http.register_representation (fun context blob json ->
      let variation=V.of_json (Yojson.Safe.from_string
        (Yojson.Basic.to_string json)) in
      Lwt_preemptive.detach (fun () ->
        M.process_representation runtime service blob variation
          ~now:(Authentication.now_time context.Http_app.now)) ());
    let samples=field (Lazy.force vectors) "messages" |> list
      |> List.filter (fun item ->
        List.mem (field item "fixture" |> string) ["moon.jpg";"alpha-centuri.mov"]) in
    List.iter (fun item ->
      let source=field item "fixture" |> string in
      let blob=source_blob runtime service item in
      let blob_path=B.blob_path "redirect" ~secret_key_base:(Lazy.force secret) blob () in
      let redirect,_=request runtime blob_path in
      Alcotest.(check int) (source ^ " redirect") 302 (status redirect);
      let location=header redirect "location" |> Option.get in
      Alcotest.(check bool) "signed disk location" true
        (String.starts_with ~prefix:"http://campfire.test/rails/active_storage/disk/" location);
      Alcotest.(check (option string)) "redirect cache" (Some "max-age=300, private")
        (header redirect "cache-control");
      let disk_path=path_of_url location in
      let disk,bytes=request runtime disk_path in
      Alcotest.(check int) (source ^ " disk GET") 200 (status disk);
      check (source ^ " disk bytes") (read_file (fixture source)) bytes;
      Alcotest.(check (option string)) "disk public cache" (Some "max-age=3600, public")
        (header disk "cache-control");
      let invalid,_=request runtime
        "/rails/active_storage/disk/invalid-token/moon.jpg" in
      Alcotest.(check int) "invalid disk token" 404 (status invalid);
      Alcotest.(check (option string)) "invalid disk MIME"
        (Some "image/jpeg") (header invalid "content-type");
      Alcotest.(check (option string)) "invalid disk public cache"
        (Some "max-age=3600, public") (header invalid "cache-control");
      let missing_path=D.disk_url_path service
        ~secret_key_base:(Lazy.force secret) ~key:"missing-disk-file"
        ~filename:"moon.jpg" ~content_type:(Some "image/jpeg")
        ~disposition:"inline" () in
      let missing,_=request runtime missing_path in
      Alcotest.(check int) "signed missing disk file" 404 (status missing);
      Alcotest.(check (option string)) "missing disk MIME"
        (Some "image/jpeg") (header missing "content-type");
      Alcotest.(check (option string)) "missing disk public cache"
        (Some "max-age=3600, public") (header missing "cache-control");
      let ranged,portion=request runtime ~headers:["range","bytes=0-9"] disk_path in
      Alcotest.(check int) "disk range" 206 (status ranged);
      check "disk range bytes" (String.sub bytes 0 10) portion;
      Alcotest.(check (option string)) "disk content-range"
        (Some (Printf.sprintf "bytes 0-9/%d" (String.length bytes)))
        (header ranged "content-range");
      let stamp=header disk "last-modified" |> Option.get in
      let fresh,_=request runtime ~headers:["if-modified-since",stamp] disk_path in
      Alcotest.(check int) "disk conditional" 304 (status fresh);
      let proxy_path=B.blob_path "proxy" ~secret_key_base:(Lazy.force secret) blob () in
      let proxy,proxy_bytes=request runtime proxy_path in
      Alcotest.(check int) (source ^ " proxy") 200 (status proxy);
      check (source ^ " proxy bytes") bytes proxy_bytes;
      Alcotest.(check (option string)) "proxy immutable cache"
        (Some "max-age=3155695200, public, immutable")
        (header proxy "cache-control");
      Alcotest.(check (option string)) "proxy ETag"
        (Some (Http_cache.combined_etag (Some proxy_path)))
        (header proxy "etag");
      Alcotest.(check (option string)) "proxy fixed Last-Modified"
        (Some "Sat, 01 Jan 2011 00:00:00 GMT")
        (header proxy "last-modified");
      Alcotest.(check (option string)) "proxy accepts ranges"
        (Some "bytes") (header proxy "accept-ranges");
      let cached,_=request runtime ~headers:["if-none-match",
        Option.get (header proxy "etag")] proxy_path in
      Alcotest.(check int) "proxy conditional ETag" 304 (status cached);
      let cached,_=request runtime ~headers:["if-modified-since",
        "Sat, 01 Jan 2011 00:00:00 GMT"] proxy_path in
      Alcotest.(check int) "proxy conditional date" 304 (status cached);
      let proxy_range,part=request runtime ~headers:["range","bytes=0-9"] proxy_path in
      Alcotest.(check int) "proxy range" 206 (status proxy_range);
      check "proxy range bytes" (String.sub bytes 0 10) part;
      Alcotest.(check (option string)) "proxy range cache" (Some "no-cache")
        (header proxy_range "cache-control");
      let invalid,body=request runtime ~headers:["range","bytes=999999999-"] proxy_path in
      Alcotest.(check int) "proxy invalid range" 416 (status invalid);
      check "proxy invalid range body" "" body;
      let sample=field item "variants" |> list |> List.hd in
      let variation=variation sample in
      let representation kind=B.representation_path kind
        ~secret_key_base:(Lazy.force secret) blob variation in
      let represented=representation "redirect" in
      let variant_redirect,_=request runtime represented in
      Alcotest.(check int) "representation redirect" 302 (status variant_redirect);
      let expected=read_file (golden (field sample "file" |> string)) in
      let variant_disk=header variant_redirect "location" |> Option.get |> path_of_url in
      let served,variant_bytes=request runtime variant_disk in
      Alcotest.(check int) "representation disk" 200 (status served);
      check "representation exact bytes" expected variant_bytes;
      let variant_proxy,proxy_bytes=request runtime (representation "proxy") in
      Alcotest.(check int) "representation proxy" 200 (status variant_proxy);
      check "representation proxy bytes" expected proxy_bytes;
      Alcotest.(check (option string)) "representation immutable cache"
        (Some "max-age=3155695200, public, immutable")
        (header variant_proxy "cache-control");
      Alcotest.(check (option string)) "representation ETag"
        (Some (Http_cache.combined_etag (Some (representation "proxy"))))
        (header variant_proxy "etag");
      Alcotest.(check (option string)) "representation fixed Last-Modified"
        (Some "Sat, 01 Jan 2011 00:00:00 GMT")
        (header variant_proxy "last-modified");
      let cached,_=request runtime ~headers:["if-none-match",
        Option.get (header variant_proxy "etag")] (representation "proxy") in
      Alcotest.(check int) "representation conditional" 304 (status cached);
      Alcotest.(check (option string)) "representation 304 has no disposition"
        None (header cached "content-disposition");
      let ranged,whole=request runtime ~headers:["range","bytes=0-9"]
        (representation "proxy") in
      Alcotest.(check int) "representation ignores range" 200 (status ranged);
      check "representation range body" expected whole;
      let bad_path=String.split_on_char '/' represented
        |> List.mapi (fun index part -> if index=6 then part ^ "x" else part)
        |> String.concat "/" in
      let bad,_=request runtime bad_path in
      Alcotest.(check int) "malformed representation URL" 404 (status bad)) samples)

let missing_signed_blob_public_error () = with_seed (fun runtime service ->
  Storage_http.register service;
  let existing=Db_runtime.read runtime (fun db ->
    Db_runtime.query_one db
      (Db_remaining.Blob.select ^ " LIMIT 1") [] Db_remaining.Blob.decode
      |> Option.get) in
  let missing={ existing with Db_remaining.Blob.id=999999999L;
    filename="missing.png" } in
  let secret_key_base=Lazy.force secret in
  let blob_redirect=B.blob_path "redirect" ~secret_key_base missing () in
  let blob_proxy=B.blob_path "proxy" ~secret_key_base missing () in
  let blob_alias=String.concat "/" (List.filteri (fun index _ -> index<>4)
    (String.split_on_char '/' blob_redirect)) in
  let representation_redirect=B.representation_path "redirect"
    ~secret_key_base missing [] in
  let representation_proxy=B.representation_path "proxy"
    ~secret_key_base missing [] in
  let representation_alias=String.concat "/"
    (List.filteri (fun index _ -> index<>4)
      (String.split_on_char '/' representation_redirect)) in
  let expected=Assets.file "/404.html" |> Option.get in
  List.iter (fun (label,path) ->
    let response,body=request runtime path in
    Alcotest.(check int) (label ^ " public 404") 404 (status response);
    check (label ^ " public exception body") expected body;
    Alcotest.(check (option string)) (label ^ " public MIME")
      (Some "text/html; charset=UTF-8") (header response "content-type"))
    ["blob redirect",blob_redirect;"blob proxy",blob_proxy;
     "blob alias",blob_alias;
     "representation redirect",representation_redirect;
     "representation proxy",representation_proxy;
     "representation alias",representation_alias];
  let invalid,body=request runtime
    "/rails/active_storage/blobs/redirect/invalid/missing.png" in
  Alcotest.(check int) "bad signature remains 404" 404 (status invalid);
  check "bad signature remains empty" "" body)

let () =
  let cases=["pinned corpus inventory",`Quick,corpus_inventory;
    "valid signed missing blob public error",`Quick,missing_signed_blob_public_error] in
  let cases=if Sys.getenv_opt "CAMPFIRE_REQUIRE_MEDIA_VECTORS"=Some "1" then
    cases @ ["complete pinned storage pipeline",`Slow,full_pipeline;
             "signed storage HTTP",`Slow,signed_http_routes] else cases in
  Alcotest.run "M6-T4 storage differential" ["storage",cases]

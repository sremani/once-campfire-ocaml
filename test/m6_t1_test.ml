open Yojson.Basic.Util
module D = Campfire.Storage_disk
module B = Campfire.Storage_blob

let vectors = lazy (Yojson.Basic.from_file "fixtures/storage.json")
let secret = lazy (Yojson.Basic.from_file "fixtures/rails_compat.json"
  |> member "secret_key_base" |> to_string)
let field value name = member name value
let str value = to_string value
let check name expected actual = Alcotest.(check string) name expected actual

let test_vectors () =
  let service = D.create ~root:"/tmp/unused" ~name:"local" in
  let v = field (Lazy.force vectors) "verifier" in
  let secret_key_base = Lazy.force secret in
  let filename = "weird & <name> ünï.png" in
  let key = "abcdefghijklmnopqrstuvwxyz12" in
  let path content_type disposition = D.disk_url_path service ~secret_key_base
    ~key ~filename ~content_type ~disposition () in
  check "disk URL" (str (field v "disk_url_path"))
    (path (Some "image/png") "inline");
  check "nil content type" (str (field v "disk_url_path_nil_type"))
    (path None "attachment");
  check "direct-upload URL" (str (field v "direct_upload_path"))
    (D.direct_upload_path service ~secret_key_base ~key
      ~content_type:(Some "image/png") ~content_length:42L
      ~checksum:"abc==" ~expires_at:"2026-09-26T12:45:14.841Z");
  let encoded = List.nth
    (String.split_on_char '/' (str (field v "disk_url_path"))) 4 in
  (match D.decode_key service ~secret_key_base ~now:"2026-09-26T12:00:00Z" encoded with
   | None -> Alcotest.fail "signed disk key rejected"
   | Some d -> check "decoded key" key d.key);
  let token = String.split_on_char '/' (str (field v "direct_upload_path"))
    |> List.rev |> List.hd in
  (match D.decode_token service ~secret_key_base ~now:"2020-01-01T00:00:00Z" token with
   | None -> Alcotest.fail "signed direct-upload token rejected"
   | Some t -> Alcotest.(check int64) "token length" 42L t.content_length);
  Alcotest.(check bool) "token tampering" true
    (D.decode_token service ~secret_key_base ~now:"2020-01-01T00:00:00Z"
      (token ^ "x") = None);
  Alcotest.(check bool) "token expired" true
    (D.decode_token service ~secret_key_base
      ~now:"2026-09-26T12:45:14.841Z" token = None);
  Alcotest.(check bool) "key tampering" true
    (D.decode_key service ~secret_key_base ~now:"2026-09-26T12:00:00Z"
      (encoded ^ "x") = None);
  let foreign = D.create ~root:"/tmp/unused" ~name:"other" in
  Alcotest.(check bool) "wrong service" true
    (D.decode_key foreign ~secret_key_base ~now:"2026-09-26T12:00:00Z"
      encoded = None);
  Alcotest.(check bool) "key traversal" true
    (try ignore (D.path_for service "../../etc/passwd"); false with D.Invalid_key -> true)

let decode_hex text =
  String.init (String.length text / 2) (fun i ->
    Char.chr (int_of_string ("0x" ^ String.sub text (2*i) 2)))
let encode_hex text =
  String.to_seq text |> List.of_seq
  |> List.map (fun c -> Printf.sprintf "%02x" (Char.code c))
  |> String.concat ""

let test_filenames () =
  field (Lazy.force vectors) "filenames" |> to_list |> List.iter (fun item ->
    let raw = decode_hex (str (field item "input_hex")) in
    let sanitized = D.sanitize_filename raw in
    check "sanitized" (str (field item "sanitized")) sanitized;
    check "escaped" (str (field item "escaped_path"))
      (D.escape_path sanitized);
    if Campfire.Http_params.valid_utf8 raw then begin
      check "basename" (str (field item "base_hex"))
        (encode_hex (Campfire.Storage_marcel.base_without_extension raw));
      check "extension" (str (field item "extension_hex"))
        (encode_hex (Campfire.Storage_marcel.extension raw))
    end;
    check "inline" (str (field item "inline"))
      (D.disposition "inline" raw);
    check "attachment" (str (field item "attachment"))
      (D.disposition "attachment" raw))

let test_marcel () =
  let samples = field (Lazy.force vectors) "marcel" |> to_list in
  Alcotest.(check int) "pinned samples" 51 (List.length samples);
  List.iter (fun sample ->
    let data = match field sample "fixture" with
      | `String filename ->
          let input = open_in_bin ("fixtures/storage_prefix/" ^ filename) in
          Fun.protect ~finally:(fun () -> close_in_noerr input)
            (fun () -> really_input_string input (in_channel_length input))
      | _ -> decode_hex (str (field sample "data_hex")) in
    let name = match field sample "name" with `String x -> Some x | _ -> None in
    let declared = match field sample "declared_type" with
      | `String x -> Some x | _ -> None in
    check "Marcel identified MIME" (str (field sample "content_type"))
      (Campfire.Storage_marcel.identify data ~name ~declared)) samples

let test_blob_routes () =
  let secret_key_base = Lazy.force secret in
  field (Lazy.force vectors) "messages" |> to_list |> List.iter (fun item ->
    let b = field item "blob" in
    let blob : Campfire.Db_remaining.Blob.t = {
      id = Int64.of_int (field b "id" |> to_int);
      key = field b "key" |> str;
      filename = field b "filename" |> str;
      content_type = (match field b "content_type" with `String x -> Some x | _ -> None);
      metadata = Some (field b "metadata" |> str);
      service_name = field b "service_name" |> str;
      byte_size = Int64.of_int (field b "byte_size" |> to_int);
      checksum = (match field b "checksum" with `String x -> Some x | _ -> None);
      created_at = "" } in
    check "blob redirect" (str (field item "rails_blob_path"))
      (B.blob_path "redirect" ~secret_key_base blob ());
    check "blob proxy" (str (field item "rails_blob_proxy_path"))
      (B.blob_path "proxy" ~secret_key_base blob ());
    check "blob download" (str (field item "rails_blob_download_path"))
      (B.blob_path "redirect" ~secret_key_base blob ~disposition:"attachment" ());
    let signed = B.signed_id ~secret_key_base blob.id in
    Alcotest.(check (option int64)) "signed blob id" (Some blob.id)
      (B.verify_signed_id ~secret_key_base ~now:"2026-09-26T12:00:00Z" signed))

let with_tmp f =
  let root = Filename.temp_file "campfire-storage-" "" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () ->
    ignore (Sys.command ("rm -rf " ^ Filename.quote root))) (fun () -> f root)

let test_stream_and_cleanup () = with_tmp (fun root ->
  let service = D.create ~root ~name:"local" in
  let key = "abcdefghijklmnopqrstuvwx1234" in
  let source = Filename.temp_file "campfire-source-" "" in
  Fun.protect ~finally:(fun () -> Sys.remove source) (fun () ->
    let out = open_out_bin source in
    output_string out (String.make (2 * 1024 * 1024) 'x'); close_out out;
    let checksum = D.checksum_file source in
    D.upload_file service ~key ~source ~checksum ();
    check "stream checksum" checksum (D.checksum_file (D.path_for service key));
    let bad = D.checksum_bytes "wrong" in
    Alcotest.(check bool) "checksum mismatch" true
      (try D.upload_file service ~key ~source ~checksum:bad (); false
       with D.Integrity -> true);
    check "good file preserved" checksum (D.checksum_file (D.path_for service key));
    let abandoned = "abcdefgh12345678901234567890" in
    D.with_staged service ~key:abandoned ~source (fun _ -> ());
    Alcotest.(check bool) "abandoned stage deleted" false (D.exists service abandoned);
    D.open_verified service ~key ~checksum:(Some checksum) (fun path ->
      check "verified open" checksum (D.checksum_file path));
    Alcotest.(check bool) "open temp cleaned" true
      (try D.open_verified service ~key ~checksum:(Some bad) (fun _ -> ()); false
       with D.Integrity -> true)))

let test_file_server () = with_tmp (fun root ->
  let path=Filename.concat root "sample" in
  let output=open_out_bin path in
  output_string output "0123456789";close_out output;
  let serve ?range ?if_modified_since method_ =
    Campfire.Storage_file_server.serve ~method_ ?range ?if_modified_since
      ~path ~content_type:"text/plain" ~disposition:"inline" () in
  let full=serve "GET" in
  Alcotest.(check int) "full status" 200 full.status;
  check "full length" "10" (List.assoc "content-length" full.headers);
  let ranged=serve ~range:"bytes=2-4" "GET" in
  Alcotest.(check int) "range status" 206 ranged.status;
  check "range length" "3" (List.assoc "content-length" ranged.headers);
  check "range header" "bytes 2-4/10" (List.assoc "content-range" ranged.headers);
  let body=Lwt_main.run (Cohttp_lwt.Body.to_string
    (Campfire.Storage_file_server.stream ranged.body)) in
  check "stream range" "234" body;
  let unsat=serve ~range:"bytes=99-100" "GET" in
  Alcotest.(check int) "unsatisfiable" 416 unsat.status;
  let head=serve "HEAD" in
  Alcotest.(check bool) "head has no body" true (head.body=[]);
  let not_modified=serve ~if_modified_since:(List.assoc "last-modified" full.headers) "GET" in
  Alcotest.(check int) "not modified" 304 not_modified.status)

let test_blob_row_lifecycle () = with_tmp (fun root ->
  let service=D.create ~root:(Filename.concat root "files") ~name:"local" in
  let runtime=Campfire.Db_runtime.open_db
    (Filename.concat root "test.sqlite3") in
  Fun.protect ~finally:(fun () -> Campfire.Db_runtime.close runtime) (fun () ->
    let source=Filename.concat root "upload.txt" in
    let out=open_out_bin source in output_string out "hello";close_out out;
    let now=Campfire.Authentication.now_time "2026-09-26T12:00:00Z" in
    let key=ref "" in
    let failed=try
      B.stage_file service ~source ~filename:"upload.txt"
        ~content_type:(Some "application/octet-stream")
        (fun prepared _staged ->
          key:=prepared.key;
          Campfire.Db_runtime.write runtime (fun tx ->
            ignore (B.insert tx ~now prepared);
            if prepared.byte_size>0L then raise Exit));
      false with Exit -> true in
    Alcotest.(check bool) "write rolled back" true failed;
    Alcotest.(check bool) "rolled-back stage removed" false (D.exists service !key);
    let count=Campfire.Db_runtime.read runtime (fun db ->
      Campfire.Db_runtime.query_one db
        "SELECT COUNT(*) FROM active_storage_blobs" []
        (fun row -> Sqlite3.column_int row 0) |> Option.get) in
    Alcotest.(check int) "no row after rollback" 0 count;
    let saved=B.create_and_upload runtime service ~source
      ~filename:"upload.txt" ~content_type:(Some "application/octet-stream") ~now in
    Alcotest.(check bool) "committed file retained" true
      (D.exists service saved.key);
    Alcotest.(check (option string)) "Marcel identified text"
      (Some "text/plain") saved.content_type;
    B.open_verified service saved (fun temp ->
      check "verified blob" (D.checksum_bytes "hello") (D.checksum_file temp);
      Alcotest.(check bool) "Active Storage tempfile name" true
        (String.starts_with
          ~prefix:("ActiveStorage-" ^ Int64.to_string saved.id ^ "-")
          (Filename.basename temp) && String.ends_with ~suffix:".txt" temp));
    B.purge runtime service saved;
    Alcotest.(check bool) "purged file absent" false (D.exists service saved.key);
    let original=B.create_direct runtime service ~filename:"original.png"
      ~content_type:(Some "image/png") ~metadata:"{}" ~byte_size:8L
      ~checksum:(D.checksum_bytes "original") ~now in
    D.upload_bytes service ~key:original.key ~bytes:"original" ();
    let child=B.create_and_upload runtime service ~source
      ~filename:"child.txt" ~content_type:(Some "text/plain") ~now in
    let legacy=Filename.concat service.root
      (Filename.concat "va" (Filename.concat "ri"
        (Filename.concat "variants" original.key))) in
    D.mkdir_p legacy;
    let legacy_file=Filename.concat legacy "old" in
    let out=open_out_bin legacy_file in output_string out "old";close_out out;
    Campfire.Db_runtime.write runtime (fun tx ->
      let variant=Campfire.Db_remaining.Variant_record.create tx
        ~blob_id:original.id ~variation_digest:"digest" in
      ignore (Campfire.Db_remaining.Attachment.create tx ~now
        ~record_type:"ActiveStorage::VariantRecord" ~record_id:variant.id
        ~name:"image" ~blob_id:child.id));
    B.purge runtime service original;
    Alcotest.(check bool) "original file purged" false (D.exists service original.key);
    Alcotest.(check bool) "dependent image purged" false (D.exists service child.key);
    Alcotest.(check bool) "legacy variants purged" false
      (Sys.file_exists legacy_file)))

let test_concurrent_uploads () = with_tmp (fun root ->
  let service=D.create ~root:(Filename.concat root "files") ~name:"local" in
  let runtime=Campfire.Db_runtime.open_db
    (Filename.concat root "test.sqlite3") in
  Fun.protect ~finally:(fun () -> Campfire.Db_runtime.close runtime) (fun () ->
    let source=Filename.concat root "upload.txt" in
    let output=open_out_bin source in output_string output "same bytes";close_out output;
    let now=Campfire.Authentication.now_time "2026-09-26T12:00:00Z" in
    let uploads=Array.init 8 (fun _ -> ref None) in
    let workers=Array.map (fun slot -> Thread.create (fun () ->
      slot:=Some (B.create_and_upload runtime service ~source
        ~filename:"upload.txt" ~content_type:(Some "text/plain") ~now)) ()) uploads in
    Array.iter Thread.join workers;
    let keys=Array.to_list uploads |> List.map (fun slot ->
      let blob : Campfire.Db_remaining.Blob.t = Option.get !slot in
      Alcotest.(check bool) "concurrent file retained" true
        (D.exists service blob.key);
      blob.key) in
    Alcotest.(check int) "unique concurrent keys" 8
      (List.sort_uniq String.compare keys |> List.length)))

let rec reference_root path remaining =
  if remaining=0 then failwith "pinned Rails seed not found" else
  let candidate=Filename.concat path "once-campfire-rust" in
  if Sys.file_exists (Filename.concat candidate
    "parity/.seed/default/db/production.sqlite3") then candidate
  else reference_root (Filename.dirname path) (remaining-1)

let test_original_fixture_rows () =
  let root=reference_root (Sys.getcwd ()) 8 in
  let service=D.create ~root:"/tmp/unused" ~name:"local" in
  List.iter (fun group ->
    field (Lazy.force vectors) group |> to_list |> List.iter (fun item ->
      let blob=field item "blob" in
      let fixture=str (field item "fixture") in
      let source=Filename.concat root
        ("reference/test/fixtures/files/" ^ fixture) in
      let filename=str (field blob "filename") in
      let declared=match field item "declared_type" with
        | `String x -> Some x | _ -> None in
      let prepared=B.prepare service ~key:"abcdefghijklmnopqrstuvwxyz12"
        ~source ~filename ~content_type:declared in
      Alcotest.(check (option string)) (fixture ^ " MIME")
        (Some (str (field blob "content_type"))) prepared.content_type;
      Alcotest.(check int64) (fixture ^ " size")
        (Int64.of_int (field blob "byte_size" |> to_int)) prepared.byte_size;
      check (fixture ^ " MD5") (str (field blob "checksum")) prepared.checksum))
    ["messages";"avatars";"logos"]

let test_http_routes () =
  let seed=Filename.concat (reference_root (Sys.getcwd ()) 8)
    "parity/.seed/default" in
  let db_source=Sqlite3.db_open ~mode:`READONLY
    (Filename.concat seed "db/production.sqlite3") in
  let temp=Filename.temp_file "campfire-storage-http-" ".sqlite3" in
  Sys.remove temp;
  let escaped=String.concat "''" (String.split_on_char '\'' temp) in
  let rc=Sqlite3.exec db_source ("VACUUM INTO '"^escaped^"'") in
  ignore (Sqlite3.db_close db_source);
  if rc<>Sqlite3.Rc.OK then failwith "cannot copy seed";
  let runtime=Campfire.Db_runtime.open_db ~prepare:false temp in
  Fun.protect ~finally:(fun () ->
    Campfire.Db_runtime.close runtime;
    List.iter (fun name -> if Sys.file_exists name then Sys.remove name)
      [temp;temp^"-wal";temp^"-shm"])
    (fun () ->
      let service=D.create ~root:(Filename.concat seed "storage") ~name:"local" in
      Campfire.Storage_http.register service;
      let blob=Campfire.Db_runtime.read runtime (fun db ->
        Campfire.Db_runtime.query_one db
          (Campfire.Db_remaining.Blob.select ^ " LIMIT 1") []
          Campfire.Db_remaining.Blob.decode |> Option.get) in
      let secret_key_base=Lazy.force secret in
      let send ?(body="") ?(method_=`GET) ?range ?cookie
          ?content_type ?length path =
        let headers=["host","campfire.test";"sec-fetch-site","same-origin";
          "origin","http://campfire.test"] in
        let headers=match range with None -> headers | Some x -> ("range",x)::headers in
        let headers=match cookie with None -> headers | Some x -> ("cookie",x)::headers in
        let headers=match content_type with None -> headers
          | Some x -> ("content-type",x)::headers in
        let headers=match length with None -> headers
          | Some x -> ("content-length",string_of_int x)::headers in
        let headers=Cohttp.Header.of_list headers in
        let request=Cohttp.Request.make ~meth:method_ ~headers
          (Uri.of_string ("http://campfire.test"^path)) in
        let response,content=Lwt_main.run (Campfire.Http_app.handle
          ~runtime ~secret_key_base ~now:"2026-09-26T12:00:00Z"
          ~dispatch:Campfire.Controller_aux.endpoint request
          (Cohttp_lwt.Body.of_string body)) in
        response,Lwt_main.run (Cohttp_lwt.Body.to_string content) in
      let path=B.blob_path "redirect" ~secret_key_base blob () in
      let redirect,_=send path in
      Alcotest.(check int) "redirect status" 302
        (Cohttp.Code.code_of_status (Cohttp.Response.status redirect));
      let location=Cohttp.Header.get (Cohttp.Response.headers redirect) "location"
        |> Option.get in
      let disk_path=String.sub location (String.length "http://campfire.test")
        (String.length location-String.length "http://campfire.test") in
      let disk,bytes=send disk_path in
      Alcotest.(check int) "disk status" 200
        (Cohttp.Code.code_of_status (Cohttp.Response.status disk));
      Alcotest.(check int) "existing file size" (Int64.to_int blob.byte_size)
        (String.length bytes);
      Alcotest.(check (option string)) "seed checksum"
        blob.checksum (Some (D.checksum_bytes bytes));
      let ranged,part=send ~range:"bytes=0-9" disk_path in
      Alcotest.(check int) "disk range" 206
        (Cohttp.Code.code_of_status (Cohttp.Response.status ranged));
      check "first ten bytes" (String.sub bytes 0 10) part;
      let marker=match String.index_opt path '-' with
        | Some at -> at | None -> failwith "signed ID has no separator" in
      let tampered=String.sub path 0 marker ^ "x" ^
        String.sub path marker (String.length path-marker) in
      let bad,_=send tampered in
      Alcotest.(check int) "tampered path" 404
        (Cohttp.Code.code_of_status (Cohttp.Response.status bad));
      let put,_=send ~method_:`PUT ~body:"x"
        "/rails/active_storage/disk/anything" in
      Alcotest.(check int) "anonymous upload" 401
        (Cohttp.Code.code_of_status (Cohttp.Response.status put));
      with_tmp (fun root ->
        let service=D.create ~root ~name:"local" in
        Campfire.Storage_http.register service;
        let user_id=Campfire.Db_runtime.read runtime (fun db ->
          Campfire.Db_runtime.query_one db
            "SELECT id FROM users LIMIT 1" []
            (fun row -> Sqlite3.column_int64 row 0) |> Option.get) in
        let now="2026-09-26T12:00:00Z" in
        let session=Campfire.Db_runtime.write runtime (fun tx ->
          Campfire.Db_accounts.Session.start (Campfire.Db_runtime.conn tx)
            ~now ~user_id ~user_agent:None ~ip_address:(Some "127.0.0.1")) in
        let cookie="session_token=" ^
          Campfire.Authentication.issue_token_cookie ~secret_key_base ~now
            session.token in
        let checksum=D.checksum_bytes "hello" in
        let too_large=Yojson.Basic.to_string (`Assoc ["blob",`Assoc [
          "filename",`String "huge.txt";"byte_size",`Int 16_777_217;
          "checksum",`String checksum;"content_type",`String "text/plain"]]) in
        let oversized,_=send ~method_:`POST ~cookie
          ~content_type:"application/json" ~body:too_large
          "/rails/active_storage/direct_uploads" in
        Alcotest.(check int) "direct URL size cap" 413
          (Cohttp.Code.code_of_status (Cohttp.Response.status oversized));
        let payload=Yojson.Basic.to_string (`Assoc ["blob",`Assoc [
          "filename",`String "hello.txt";"byte_size",`Int 5;
          "checksum",`String checksum;"content_type",`String "text/plain"]]) in
        let created,raw=send ~method_:`POST ~cookie
          ~content_type:"application/json" ~body:payload
          "/rails/active_storage/direct_uploads" in
        Alcotest.(check int) "direct POST" 200
          (Cohttp.Code.code_of_status (Cohttp.Response.status created));
        let uploaded=Yojson.Basic.from_string raw in
        let url=uploaded |> member "direct_upload" |> member "url" |> str in
        let path=String.sub url (String.length "http://campfire.test")
          (String.length url-String.length "http://campfire.test") in
        let put,_=send ~method_:`PUT ~cookie ~content_type:"text/plain"
          ~length:5 ~body:"hello" path in
        Alcotest.(check int) "direct PUT" 204
          (Cohttp.Code.code_of_status (Cohttp.Response.status put));
        let key=uploaded |> member "key" |> str in
        check "direct bytes" checksum (D.checksum_file (D.path_for service key));
        let bad_created,bad_raw=send ~method_:`POST ~cookie
          ~content_type:"application/json" ~body:payload
          "/rails/active_storage/direct_uploads" in
        Alcotest.(check int) "second direct POST" 200
          (Cohttp.Code.code_of_status (Cohttp.Response.status bad_created));
        let bad_json=Yojson.Basic.from_string bad_raw in
        let bad_url=bad_json |> member "direct_upload" |> member "url" |> str in
        let bad_path=String.sub bad_url (String.length "http://campfire.test")
          (String.length bad_url-String.length "http://campfire.test") in
        let wrong_type,_=send ~method_:`PUT ~cookie
          ~content_type:"image/png" ~length:5 ~body:"hello" bad_path in
        Alcotest.(check int) "content type rejected" 422
          (Cohttp.Code.code_of_status (Cohttp.Response.status wrong_type));
        let wrong_length,_=send ~method_:`PUT ~cookie
          ~content_type:"text/plain" ~length:4 ~body:"hello" bad_path in
        Alcotest.(check int) "content length rejected" 422
          (Cohttp.Code.code_of_status (Cohttp.Response.status wrong_length));
        let bad_put,_=send ~method_:`PUT ~cookie ~content_type:"text/plain"
          ~length:5 ~body:"wrong" bad_path in
        Alcotest.(check int) "checksum rejected" 422
          (Cohttp.Code.code_of_status (Cohttp.Response.status bad_put));
        let bad_key=bad_json |> member "key" |> str in
        Alcotest.(check bool) "failed file absent" false
          (D.exists service bad_key)))

let () = Alcotest.run "storage disk" [
  "vectors", [Alcotest.test_case "signed URLs" `Quick test_vectors;
               Alcotest.test_case "filenames" `Quick test_filenames;
               Alcotest.test_case "Marcel" `Quick test_marcel;
               Alcotest.test_case "original blob rows" `Quick test_original_fixture_rows;
               Alcotest.test_case "blob routes" `Quick test_blob_routes];
  "files", [Alcotest.test_case "stream and cleanup" `Quick test_stream_and_cleanup;
            Alcotest.test_case "HTTP ranges" `Quick test_file_server;
            Alcotest.test_case "blob row lifecycle" `Quick test_blob_row_lifecycle;
            Alcotest.test_case "concurrent uploads" `Quick test_concurrent_uploads;
            Alcotest.test_case "seed HTTP routes" `Quick test_http_routes]]

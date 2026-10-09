open Campfire
open Yojson.Basic.Util
module V = Storage_variation
module I = Storage_image

let vectors = lazy (Yojson.Basic.from_file "fixtures/storage.json")
let member value key = Yojson.Basic.Util.member key value
let text value = to_string value
let list value = to_list value
let check label expected actual = Alcotest.(check string) label expected actual
let check_int label expected actual = Alcotest.(check int) label expected actual

let rec typed = function
  | `Null -> V.Nil | `Bool b -> V.Bool b | `Int n -> V.Int (Int64.of_int n)
  | `String s -> V.Str s
  | `List xs -> V.Array (List.map typed xs)
  | `Assoc ["sym",`String s] -> V.Symbol s
  | `Assoc ["str",`String s] -> V.Str s
  | `Assoc ["hash",`List entries] -> V.Hash (List.map (function
      | `List [`String key;value] -> key,typed value
      | _ -> Alcotest.fail "bad typed hash") entries)
  | _ -> Alcotest.fail "bad typed value"

let variation item = match typed (member item "transformations_typed") with
  | V.Hash entries -> entries | _ -> Alcotest.fail "variation is not hash"

let hex input =
  String.to_seq input |> List.of_seq
  |> List.map (fun c -> Printf.sprintf "%02x" (Char.code c))
  |> String.concat ""

let file_bytes path =
  let input=open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr input)
    (fun () -> really_input_string input (in_channel_length input))

let variation_vectors () =
  let samples=member (Lazy.force vectors) "variations" |> list in
  check_int "pinned variations" 12 (List.length samples);
  List.iter (fun item ->
    let v=match typed (member item "typed") with
      | V.Hash entries -> entries | _ -> Alcotest.fail "bad variation" in
    check "Marshal" (member item "marshal_hex" |> text) (hex (V.marshal v));
    check "digest" (member item "digest" |> text) (V.digest v);
    let decoded=match typed (member item "decoded_typed") with
      | V.Hash entries -> entries | _ -> Alcotest.fail "bad decoded variation" in
    check "decoded Marshal" (member item "decoded_marshal_hex" |> text)
      (hex (V.marshal decoded));
    check "decoded digest" (member item "decoded_digest" |> text)
      (V.digest decoded)) samples;
  Alcotest.(check bool) "unsupported operation" true
    (try ignore (V.operations ["rotate",V.Int 90L]);false
     with Invalid_argument _ -> true);
  Alcotest.(check bool) "oversize operation" true
    (try ignore (V.operations (V.resize_to_limit max_int 100));false
     with Invalid_argument _ -> true)

let rec reference_root path remaining =
  if remaining=0 then failwith "reference fixtures not found" else
  let candidate=Filename.concat path "once-campfire-rust" in
  if Sys.file_exists (Filename.concat candidate "vectors/storage.json")
  then candidate else reference_root (Filename.dirname path) (remaining-1)

let root () = reference_root (Sys.getcwd ()) 9
let fixture name = Filename.concat (root ()) ("reference/test/fixtures/files/" ^ name)
let expected name = Filename.concat (root ()) ("vectors/storage/" ^ name)

let temp_path suffix = Filename.temp_file "campfire-image-" suffix
let with_temp suffix f =
  let path=temp_path suffix in
  Fun.protect ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () -> f path)

let image_vectors () =
  let actual_version=Storage_vips.version () in
  check "matching libvips" "8.16.1" actual_version;
  let entries=(member (Lazy.force vectors) "messages" |> list) @
    (member (Lazy.force vectors) "avatars" |> list) @
    (member (Lazy.force vectors) "logos" |> list) in
  let compared=ref 0 in
  List.iter (fun entry ->
    let variants=member entry "variants" in
    let variants=match variants with `List xs -> xs | _ -> [] in
    let source=fixture (member entry "fixture" |> text) in
    let original=member entry "blob" in
    let media=member original "content_type" |> text in
    if String.starts_with ~prefix:"image" media then begin
      let metadata=member original "metadata" |> text |> Yojson.Basic.from_string in
      let expected_dims=member metadata "width",member metadata "height" in
      let actual=Storage_vips.analyze source in
      (match expected_dims,actual with
       | (`Int w,`Int h),Some (aw,ah) ->
           check_int "source width" w aw;check_int "source height" h ah
       | (`Null,`Null),None -> ()
       | _ -> Alcotest.fail "source dimensions differ");
      List.iter (fun variant ->
        let variation=variation variant in
        check "variation digest" (member variant "variation_digest" |> text)
          (V.digest variation);
        let format=V.format variation in
        with_temp ("." ^ format) (fun target ->
          Storage_vips.transform ~source ~target ~operations:(V.operations variation);
          let golden=expected (member variant "file" |> text) in
          Alcotest.(check bool) "exact derivative bytes" true
            (file_bytes golden = file_bytes target);
          let blob=member variant "blob" in
          check "derivative checksum" (member blob "checksum" |> text)
            (Storage_disk.checksum_file target);
          let metadata=member blob "metadata" |> text |> Yojson.Basic.from_string in
          (match Storage_vips.analyze target with
           | Some (w,h) ->
               check_int "derivative width" (member metadata "width" |> to_int) w;
               check_int "derivative height" (member metadata "height" |> to_int) h
           | None -> Alcotest.fail "derivative unreadable");
          incr compared)) variants
    end) entries;
  check_int "all pinned image derivatives" 7 !compared

let malformed () =
  with_temp ".jpg" (fun path ->
    let output=open_out_bin path in
    output_string output "\255\216\255\224 not really a JPEG";
    close_out output;
    Alcotest.(check bool) "corrupt analyzer" true
      (Storage_vips.analyze path=None);
    with_temp ".webp" (fun target ->
      Alcotest.(check bool) "corrupt transform" true
        (try Storage_vips.transform ~source:path ~target
          ~operations:[Some 4,Some 4];false with Failure _ -> true)))

let with_runtime_and_service f =
  let seed=Filename.concat (root ()) "parity/.seed/default/db/production.sqlite3" in
  let source=Sqlite3.db_open ~mode:`READONLY seed in
  let db_file=temp_path ".sqlite3" in
  Sys.remove db_file;
  let quoted=String.concat "''" (String.split_on_char '\'' db_file) in
  let result=Sqlite3.exec source ("VACUUM INTO '" ^ quoted ^ "'") in
  ignore (Sqlite3.db_close source);
  if result<>Sqlite3.Rc.OK then Alcotest.fail "seed copy failed";
  let storage=Filename.temp_file "campfire-image-storage-" "" in
  Sys.remove storage;Unix.mkdir storage 0o700;
  let runtime=Db_runtime.open_db ~readers:4 ~prepare:false db_file in
  let service=Storage_disk.create ~root:storage ~name:"local" in
  let rec remove path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Array.iter (fun child -> remove (Filename.concat path child)) (Sys.readdir path);
        Unix.rmdir path
      end else Sys.remove path in
  Fun.protect ~finally:(fun () ->
    Db_runtime.close runtime;
    remove storage;
    List.iter remove [db_file;db_file^"-wal";db_file^"-shm"])
    (fun () -> f runtime service)

let count runtime table = Db_runtime.read runtime (fun db ->
  Db_runtime.query_one db ("SELECT COUNT(*) FROM " ^ table) []
    (fun row -> Sqlite3.column_int row 0) |> Option.get)

let rec file_count path =
  if Sys.is_directory path then
    Array.fold_left (fun total child ->
      total+file_count (Filename.concat path child)) 0 (Sys.readdir path)
  else 1

let lifecycle () = with_runtime_and_service (fun runtime service ->
  let now=Authentication.now_time "2026-09-26T12:00:00Z" in
  let original=Storage_blob.create_and_upload runtime service
    ~source:(fixture "moon.jpg") ~filename:"moon.jpg"
    ~content_type:(Some "image/jpeg") ~now in
  let analyzed=I.analyze runtime service original in
  check "analyzed metadata"
    "{\"identified\":true,\"width\":640,\"height\":640,\"analyzed\":true}"
    (Option.get analyzed.metadata);
  let variation=V.resize_to_limit ~format:"webp" 64 64 in
  let first=I.process_variant runtime service analyzed variation ~now in
  let second=I.process_variant runtime service analyzed variation ~now in
  Alcotest.(check int64) "cache reuses blob" first.id second.id;
  let concurrent_variation=V.resize_to_limit ~format:"png" 63 63 in
  let outputs : Db_remaining.Blob.t option array=Array.make 4 None in
  let threads=Array.init 4 (fun index -> Thread.create (fun () ->
    outputs.(index)<-Some (I.process_variant runtime service analyzed
      concurrent_variation ~now)) ()) in
  Array.iter Thread.join threads;
  let concurrent=Option.get outputs.(0) in
  Array.iter (function
    | Some blob -> Alcotest.(check int64) "concurrent winner" concurrent.id
        blob.Db_remaining.Blob.id
    | None -> Alcotest.fail "missing concurrent result") outputs;
  let record=Db_runtime.read runtime (fun db ->
    Db_remaining.Variant_record.find_for db ~blob_id:analyzed.id
      ~variation_digest:(V.digest (I.variation_for analyzed variation))) in
  (match record with
   | None -> Alcotest.fail "missing tracked variant record"
   | Some record ->
       let attachment=Db_runtime.read runtime (fun db ->
         Db_remaining.Attachment.find_for db
           ~record_type:"ActiveStorage::VariantRecord"
           ~record_id:record.id ~name:"image") in
       (match attachment with
        | Some attached -> Alcotest.(check int64) "attached generated image"
            first.id attached.blob_id
        | None -> Alcotest.fail "missing generated image attachment"));
  Alcotest.(check bool) "variant file present" true
    (Storage_disk.exists service first.key);
  Alcotest.(check bool) "concurrent file present" true
    (Storage_disk.exists service concurrent.key);
  let concurrent_records=Db_runtime.read runtime (fun db ->
    Db_runtime.query_one db
      "SELECT COUNT(*) FROM active_storage_variant_records WHERE blob_id=? AND variation_digest=?"
      [Sqlite3.Data.INT analyzed.id;
       Sqlite3.Data.TEXT (V.digest (I.variation_for analyzed concurrent_variation))]
      (fun row -> Sqlite3.column_int row 0) |> Option.get) in
  check_int "one concurrent record" 1 concurrent_records;
  check_int "no abandoned concurrent files" 3 (file_count service.root);
  let variant_count=count runtime "active_storage_variant_records" in
  Storage_blob.purge runtime service analyzed;
  Alcotest.(check bool) "source file purged" false
    (Storage_disk.exists service analyzed.key);
  Alcotest.(check bool) "variant file purged" false
    (Storage_disk.exists service first.key);
  Alcotest.(check bool) "concurrent file purged" false
    (Storage_disk.exists service concurrent.key);
  check_int "variant records removed" (variant_count-2)
    (count runtime "active_storage_variant_records");
  check_int "all generated files removed" 0 (file_count service.root))

let failed_processing () = with_runtime_and_service (fun runtime service ->
  let now=Authentication.now_time "2026-09-26T12:00:00Z" in
  let key=Storage_disk.generate_key () in
  let bytes="\255\216\255\224 not really a JPEG" in
  Storage_disk.upload_bytes service ~key ~bytes ();
  let row : Db_remaining.Blob.t = {
    id=0L;key;filename="bad.jpg";content_type=Some "image/jpeg";
    metadata=Some "{\"identified\":true}";service_name="local";
    byte_size=Int64.of_int (String.length bytes);
    checksum=Some (Storage_disk.checksum_bytes bytes);created_at="" } in
  let bad=Db_runtime.write runtime (fun tx ->
    Db_remaining.Blob.create tx ~now row) in
  let before=count runtime "active_storage_variant_records" in
  Alcotest.(check bool) "corrupt image rejected" true
    (try ignore (I.process_variant runtime service bad
      (V.resize_to_limit 64 64) ~now);false with Failure _ -> true);
  check_int "failed processing leaves no variant row" before
    (count runtime "active_storage_variant_records");
  check_int "failed processing leaves no staged image" 1
    (file_count service.root))

let tracked_vector () = with_runtime_and_service (fun runtime service ->
  let now=Authentication.now_time "2026-09-26T12:00:00Z" in
  let source=Storage_blob.create_and_upload runtime service
    ~source:(fixture "moon.jpg") ~filename:"moon.jpg"
    ~content_type:(Some "image/jpeg") ~now in
  let variation=V.resize_to_limit 1200 800 in
  let effective=I.variation_for source variation in
  check "defaulted variation digest" "IBhrLAIapu+NCId+2Kz6EqUWRKY="
    (V.digest effective);
  let blob=I.process_variant runtime service source variation ~now in
  check "tracked variant filename" "moon.jpg" blob.filename;
  check "tracked variant MIME" "image/jpeg"
    (Option.get blob.content_type);
  check "tracked variant metadata"
    "{\"identified\":true,\"width\":640,\"height\":640,\"analyzed\":true}"
    (Option.get blob.metadata);
  check "tracked variant checksum" "p7Xvr8seqToD36kDFhsGng=="
    (Option.get blob.checksum);
  Alcotest.(check bool) "tracked variant exact bytes" true
    (file_bytes (expected "moon-thumb.jpg") =
      file_bytes (Storage_disk.path_for service blob.key)))

let () =
  let image_cases =
    if Sys.getenv_opt "CAMPFIRE_REQUIRE_MEDIA_VECTORS"=Some "1" then
      ["exact media",`Quick,image_vectors;"malformed",`Quick,malformed;
       "tracked golden vector",`Quick,tracked_vector;
       "tracked lifecycle",`Quick,lifecycle;
       "failed cleanup",`Quick,failed_processing]
    else [] in
  Alcotest.run "M6-T2 image" [
    "variation",["Marshal and digest",`Quick,variation_vectors];
    "vips",image_cases]

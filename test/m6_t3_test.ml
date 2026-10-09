open Campfire
open Yojson.Basic.Util
module V = Storage_variation
module M = Storage_media
module B = Storage_blob

let vectors = lazy (Yojson.Basic.from_file "fixtures/storage.json")
let secret = lazy (Yojson.Basic.from_file "fixtures/rails_compat.json"
  |> member "secret_key_base" |> to_string)
let get value key = member key value
let str = to_string
let lst = to_list
let check = Alcotest.(check string)

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
let upstream_file path = Filename.concat upstream path

let rec typed = function
  | `Null -> V.Nil | `Bool b -> V.Bool b | `Int n -> V.Int (Int64.of_int n)
  | `String s -> V.Str s | `List xs -> V.Array (List.map typed xs)
  | `Assoc ["sym",`String s] -> V.Symbol s
  | `Assoc ["str",`String s] -> V.Str s
  | `Assoc ["hash",`List entries] -> V.Hash (List.map (function
      | `List [`String key;value] -> key,typed value
      | _ -> Alcotest.fail "invalid typed hash") entries)
  | _ -> Alcotest.fail "invalid typed value"
let variation key item = match typed (get item key) with
  | V.Hash entries -> entries | _ -> Alcotest.fail "not a variation"

let blob_of_vector item : Db_remaining.Blob.t = {
  id=Int64.of_int (get item "id" |> to_int);
  key=get item "key" |> str;filename=get item "filename" |> str;
  content_type=Some (get item "content_type" |> str);
  metadata=Some (get item "metadata" |> str);
  service_name=get item "service_name" |> str;
  byte_size=Int64.of_int (get item "byte_size" |> to_int);
  checksum=Some (get item "checksum" |> str);created_at="" }

let keys_and_paths () =
  let secret_key_base=Lazy.force secret in
  let now="2026-09-26T12:00:00Z" in
  let samples=get (Lazy.force vectors) "variations" |> lst in
  Alcotest.(check int) "variation count" 12 (List.length samples);
  List.iter (fun item ->
    let variation=variation "typed" item in
    let key=V.key ~secret_key_base variation in
    check "signed variation key" (get item "key" |> str) key;
    match V.from_key ~secret_key_base ~now key with
    | None -> Alcotest.fail "signed variation rejected"
    | Some decoded ->
        check "decoded variation digest" (get item "decoded_digest" |> str)
          (V.digest decoded);
        let tampered=key ^ "x" in
        Alcotest.(check bool) "tampered key rejected" true
          (V.from_key ~secret_key_base ~now tampered=None)) samples;
  let messages=get (Lazy.force vectors) "messages" |> lst in
  let checked=ref 0 in
  List.iter (fun item ->
    let blob=blob_of_vector (get item "blob") in
    let variants=get item "variants" in
    let path kind variation=B.representation_path kind ~secret_key_base blob variation in
    (match get item "thumb_path",variants with
    | `String expected,`List (variant::_) ->
        let variation=variation "transformations_typed" variant in
        check "thumb redirect" expected (path "redirect" variation);
        check "thumb proxy" (get item "thumb_proxy_path" |> str)
          (path "proxy" variation);incr checked
    | _ -> ());
    (match get item "poster_path",variants with
    | `String expected,`List variants ->
        let poster=List.find (fun v -> get v "label"=`String "alpha-centuri-poster") variants in
        let variation=variation "transformations_typed" poster in
        check "poster redirect" expected (path "redirect" variation);
        check "poster proxy" (get item "poster_proxy_path" |> str)
          (path "proxy" variation);incr checked
    | _ -> ())) messages;
  List.iter (fun item -> match get item "path" with
    | `String expected ->
        let blob=blob_of_vector (get item "blob") in
        let variant=get item "variants" |> lst |> List.hd in
        let variation=variation "transformations_typed" variant in
        check "avatar representation path" expected
          (B.representation_path "redirect" ~secret_key_base blob variation);
        incr checked
    | _ -> ()) (get (Lazy.force vectors) "avatars" |> lst);
  Alcotest.(check int) "representation paths" 5 !checked

let metadata () =
  let fixture=upstream_file "reference/test/fixtures/files/alpha-centuri.mov" in
  let reference=get (Lazy.force vectors) "messages" |> lst
    |> List.find (fun item -> get item "fixture"=`String "alpha-centuri.mov") in
  let expected=get (get reference "blob") "metadata" |> str
    |> Yojson.Basic.from_string in
  let actual=M.metadata_for_path ~content_type:"video/quicktime" fixture in
  let combined=match actual with
    | `Assoc fields -> `Assoc (("identified",`Bool true)::fields@ ["analyzed",`Bool true])
    | _ -> Alcotest.fail "video metadata shape" in
  check "video ffprobe metadata" (Rails_format.encode (Yojson.Safe.from_string
    (Yojson.Basic.to_string expected)))
    (Rails_format.encode (Yojson.Safe.from_string
      (Yojson.Basic.to_string combined)));
  let sample=`Assoc ["streams",`List [`Assoc [
    "codec_type",`String "audio";"duration",`String "3.125000";
    "bit_rate",`String "128000";"sample_rate",`String "44100";
    "tags",`Assoc ["artist",`String "Camper"]]]] in
  check "audio analyzer" "{\"duration\":3.125,\"bit_rate\":128000,\"sample_rate\":44100,\"tags\":{\"artist\":\"Camper\"}}"
    (Yojson.Basic.to_string (M.audio_metadata sample));
  let rotated=`Assoc ["streams",`List [
    `Assoc ["codec_type",`String "video";"width",`Int 1920;
      "height",`Int 1080;"side_data_list",`List [
        `Assoc ["side_data_type",`String "Display Matrix";"rotation",`Int (-90)]]];
    `Assoc ["codec_type",`String "audio"]];
    "format",`Assoc ["duration",`String "3.5"]] in
  check "rotated video" "{\"width\":1080.0,\"height\":1920.0,\"duration\":3.5,\"angle\":-90,\"audio\":true,\"video\":true}"
    (Yojson.Basic.to_string (M.video_metadata rotated));
  let wav=Filename.temp_file "campfire-audio-" ".wav" in
  Fun.protect ~finally:(fun () -> Sys.remove wav) (fun () ->
    let out=open_out_bin wav in
    let u16 n = output_byte out (n land 255);output_byte out ((n lsr 8) land 255) in
    let u32 n = u16 (n land 65535);u16 (n lsr 16) in
    output_string out "RIFF";u32 16036;output_string out "WAVEfmt ";
    u32 16;u16 1;u16 1;u32 8000;u32 16000;u16 2;u16 16;
    output_string out "data";u32 16000;
    output_string out (String.make 16000 '\000');close_out out;
    let actual=M.metadata_for_path ~content_type:"audio/wav" wav in
    check "actual WAV ffprobe metadata"
      "{\"duration\":1.0,\"bit_rate\":128000,\"sample_rate\":8000}"
      (Yojson.Basic.to_string actual))

let process_bounds () =
  let started=Unix.gettimeofday () in
  Alcotest.(check bool) "timeout kills process" true
    (try ignore (M.run ~timeout:0.2 "sh" ["-c";"exec sleep 10"]);false
     with M.Process_timeout _ -> true);
  Alcotest.(check bool) "returns promptly" true
    (Unix.gettimeofday () -. started < 2.);
  Alcotest.(check bool) "stdout cap" true
    (try ignore (M.run ~stdout_limit:10 ~timeout:2. "sh"
      ["-c";"printf '12345678901234567890'"]);false
     with M.Process_error _ -> true);
  Alcotest.(check bool) "timeout after pipes close" true
    (try ignore (M.run ~timeout:0.2 "sh"
      ["-c";"exec 1>&- 2>&-; exec sleep 10"]);false
     with M.Process_timeout _ -> true);
  let corrupt=Filename.temp_file "corrupt-video-" ".mov" in
  Fun.protect ~finally:(fun () -> Sys.remove corrupt) (fun () ->
    let out=open_out_bin corrupt in
    output_string out "not a movie";close_out out;
    Alcotest.(check bool) "malformed preview rejected" true
      (try ignore (M.video_preview corrupt);false
       with M.Process_error _ -> true))

let null_analyzer_and_interrupted_wait () =
  let missing="/this/path/does/not/exist" in
  check "text uses null analyzer" "{}"
    (Yojson.Basic.to_string (M.metadata_for_path
      ~program:missing ~content_type:"text/plain" missing));
  check "octet stream uses null analyzer" "{}"
    (Yojson.Basic.to_string (M.metadata_for_path
      ~program:missing ~content_type:"application/octet-stream" missing));
  let database=Filename.temp_file "campfire-null-analyzer-" ".sqlite3" in
  let runtime=Db_runtime.open_db ~readers:2 database in
  Fun.protect ~finally:(fun () ->
    Db_runtime.close runtime;
    List.iter (fun path -> if Sys.file_exists path then Sys.remove path)
      [database;database^"-wal";database^"-shm"]) (fun () ->
    let now=Option.get (Ptime.of_rfc3339 "2026-09-26T12:00:00Z" |> Result.to_option)
      |> fun (time,_,_) -> time in
    let service=Storage_disk.create ~root:missing ~name:"local" in
    let blob=B.create_direct runtime service ~filename:"reply.text"
      ~content_type:(Some "text/plain") ~metadata:"{\"identified\":true}"
      ~byte_size:5L ~checksum:"dummy" ~now in
    let analyzed=M.analyze ~program:missing runtime service blob in
    check "text metadata saved without opening file"
      "{\"identified\":true,\"analyzed\":true}"
      (Option.get analyzed.metadata);
    let saved=Db_runtime.read runtime (fun db ->
      Db_remaining.Blob.find db blob.id) in
    check "text metadata persisted"
      "{\"identified\":true,\"analyzed\":true}"
      (Option.get saved.metadata));
  let calls=ref 0 in
  let selected=M.select_until ~select:(fun _ _ _ _ ->
    incr calls;
    if !calls<=3 then raise (Unix.Unix_error (Unix.EINTR,"select",""));
    ([],[],[])) [] (Unix.gettimeofday ()+.5.) in
  Alcotest.(check bool) "interrupted select returns" true
    (selected=([],[],[]));
  Alcotest.(check int) "select retried" 4 !calls;
  let waits=ref 0 in
  let value=M.retry_eintr (fun () ->
    incr waits;
    if !waits<=3 then raise (Unix.Unix_error (Unix.EINTR,"waitpid",""));
    42) in
  Alcotest.(check int) "interrupted waitpid returns" 42 value;
  Alcotest.(check int) "waitpid retried" 4 !waits

let concurrent_entropy () =
  let count=16 and iterations=100 in
  let results=Array.make (16 * 100) "" in
  let errors=Array.make count None in
  let threads=Array.init count (fun worker -> Thread.create (fun () ->
    try for index=0 to iterations-1 do
      results.(worker*iterations+index)<-Secure_random.bytes 64
    done with exn -> errors.(worker)<-Some (Printexc.to_string exn)) ()) in
  Array.iter Thread.join threads;
  Array.iter (function None -> () | Some message -> Alcotest.fail message) errors;
  Array.iter (fun value -> Alcotest.(check int) "entropy length" 64
    (String.length value)) results;
  let unique=Hashtbl.create (Array.length results) in
  Array.iter (fun value -> Hashtbl.replace unique value ()) results;
  Alcotest.(check int) "independent entropy samples"
    (Array.length results) (Hashtbl.length unique)

let file_bytes path =
  let ic=open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let strict_preview () =
  let expected_version=get (get (Lazy.force vectors) "versions") "ffmpeg" |> str in
  let actual=M.run ~timeout:5. "ffmpeg" ["-version"]
    |> String.split_on_char '\n' |> List.hd |> String.trim in
  check "matching ffmpeg" expected_version actual;
  check "matching libvips" "8.16.1" (Storage_vips.version ());
  let video=get (Lazy.force vectors) "messages" |> lst
    |> List.find (fun item -> get item "fixture"=`String "alpha-centuri.mov") in
  let source=upstream_file "reference/test/fixtures/files/alpha-centuri.mov" in
  let expected_root=upstream_file "vectors/storage" in
  let bytes=M.video_preview source in
  let expected=get (get video "preview_image") "file" |> str
    |> Filename.concat expected_root |> file_bytes in
  check "exact ffmpeg preview bytes" expected bytes;
  let database=Filename.temp_file "campfire-media-" ".sqlite3" in
  let seed=upstream_file "parity/.seed/default/db/production.sqlite3" in
  let src=Sqlite3.db_open ~mode:`READONLY seed in
  Sys.remove database;
  let quoted=String.concat "''" (String.split_on_char '\'' database) in
  let rc=Sqlite3.exec src ("VACUUM INTO '" ^ quoted ^ "'") in
  ignore (Sqlite3.db_close src);
  if rc<>Sqlite3.Rc.OK then Alcotest.fail "seed clone";
  let root=Filename.temp_file "campfire-media-files-" "" in
  Sys.remove root;Unix.mkdir root 0o700;
  let rec remove path = if Sys.file_exists path then
    if Sys.is_directory path then (
      Array.iter (fun entry -> remove (Filename.concat path entry)) (Sys.readdir path);
      Unix.rmdir path) else Sys.remove path in
  let runtime=Db_runtime.open_db ~readers:4 ~prepare:false database in
  let service=Storage_disk.create ~root ~name:"local" in
  Fun.protect ~finally:(fun () ->
    Db_runtime.close runtime;remove root;remove database) (fun () ->
    let now=Option.get (Ptime.of_rfc3339 "2026-09-26T12:00:00Z" |> Result.to_option)
      |> fun (time,_,_) -> time in
    let blob=B.create_and_upload runtime service ~source
      ~filename:"alpha-centuri.mov" ~content_type:(Some "video/quicktime") ~now in
    let blob=M.analyze runtime service blob in
    check "analyzed video metadata" (get (get video "blob") "metadata" |> str)
      (Option.get blob.metadata);
    let repeats=Array.make 8 blob in
    let threads=Array.init 8 (fun index -> Thread.create (fun () ->
      repeats.(index)<-M.preview_image runtime service blob ~now) ()) in
    Array.iter Thread.join threads;
    let image=repeats.(0) in
    let expected_blob=get (get video "preview_image") "blob" in
    check "preview metadata" (get expected_blob "metadata" |> str)
      (Option.get image.metadata);
    check "preview checksum" (get expected_blob "checksum" |> str)
      (Option.get image.checksum);
    check "preview file" expected (file_bytes (Storage_disk.path_for service image.key));
    Array.iter (fun (winner:Db_remaining.Blob.t) -> Alcotest.(check int64) "one preview winner"
      image.id winner.id) repeats;
    let empty=M.process_representation runtime service blob [] ~now in
    Alcotest.(check bool) "empty variation returns preview" true
      (match empty with Some result -> result.id=image.id | None -> false);
    let derivatives=List.map (fun variant ->
      let name=get variant "file" |> str in
      let variation=variation "transformations_typed" variant in
      let result=Option.get (M.process_representation runtime service blob variation ~now) in
      let golden=Filename.concat expected_root name |> file_bytes in
      check "exact video derivative" golden
        (file_bytes (Storage_disk.path_for service result.key));
      check "video derivative checksum" (get (get variant "blob") "checksum" |> str)
        (Option.get result.checksum);
      result) (get video "variants" |> lst) in
    B.purge runtime service blob;
    Alcotest.(check bool) "purged video" false
      (Sys.file_exists (Storage_disk.path_for service blob.key));
    List.iter (fun (dependent:Db_remaining.Blob.t) ->
      Alcotest.(check bool) "purged derivative" false
        (Sys.file_exists (Storage_disk.path_for service dependent.key)))
      (image::derivatives))

let () =
  let cases=["signatures and paths",`Quick,keys_and_paths;
    "metadata",`Quick,metadata;"bounded process",`Quick,process_bounds;
    "null analyzer and EINTR",`Quick,null_analyzer_and_interrupted_wait;
    "concurrent entropy",`Quick,concurrent_entropy] in
  let cases=if Sys.getenv_opt "CAMPFIRE_REQUIRE_MEDIA_VECTORS"=Some "1"
    then cases@["strict preview",`Slow,strict_preview] else cases in
  Alcotest.run "M6-T3 audio/video and representation" ["media",cases]

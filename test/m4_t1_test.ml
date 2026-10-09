open Campfire

let fixture name =
  let local = Filename.concat "fixtures/assets" name in
  let path = if Sys.file_exists local then local else Filename.concat "test" local in
  Assets.read_file path
let json name = Yojson.Basic.from_string (fixture name)
let member key value = Yojson.Basic.Util.member key value
let string value = Yojson.Basic.Util.to_string value
let assoc value = Yojson.Basic.Util.to_assoc value
let list value = Yojson.Basic.Util.to_list value
let sha256 body = Mirage_crypto.Hash.SHA256.digest (Cstruct.of_string body) |> Cstruct.to_hex_string

let overrides = [
  "models/file_uploader.js";
  "controllers/copy_to_clipboard_controller.js";
  "controllers/rooms_list_controller.js";
  "lib/autocomplete/base_autocomplete_handler.js";
]

let ref_manifest = lazy (json "manifest.json")
let ref_digest logical = member logical (Lazy.force ref_manifest) |> member "digested_path" |> string

let replace_override_digests text =
  List.fold_left (fun text logical ->
    let ours = Option.get (Assets.digested_path logical) in
    let theirs = ref_digest logical in
    Str.global_replace (Str.regexp_string ours) theirs text) text overrides

let manifest_matches () =
  let ours = Assets.manifest_json () |> Yojson.Basic.from_string |> assoc in
  let reference = assoc (Lazy.force ref_manifest) in
  let ours = List.filter (fun (logical, _) -> logical <> "install-edge.svg") ours in
  Alcotest.(check int) "entry count" (List.length reference) (List.length ours);
  List.iter (fun (logical, _) ->
    let expected = ref_digest logical in
    let actual = Option.get (Assets.digested_path logical) in
    if not (List.mem logical overrides) then
      Alcotest.(check string) logical expected actual
    else Alcotest.(check bool) (logical ^ " overridden") true (expected <> actual)) reference;
  Alcotest.(check bool) "added Edge icon" true (Option.is_some (Assets.digested_path "install-edge.svg"))

let compiled_bytes () =
  let skipped = List.map ref_digest overrides in
  let expected = assoc (json "compiled_sha256.json") in
  List.iter (fun (path, hash) ->
    if not (List.mem path skipped) then
      match Assets.serve ~method_:"GET" ~path:("/assets/" ^ path) () with
      | None -> Alcotest.fail ("missing " ^ path)
      | Some response -> Alcotest.(check string) path (string hash) (sha256 response.body)) expected;
  Alcotest.(check int) "compiled count plus addition" (List.length expected + 1) (List.length (Lazy.force Assets.manifest))

let tags_match () =
  let html, link = Assets.stylesheet_tags () in
  Alcotest.(check string) "stylesheet tags" (fixture "stylesheet_link_tag_all.html") html;
  Alcotest.(check string) "Link header" (fixture "link_header.txt") link;
  Alcotest.(check string) "importmap tags" (fixture "javascript_importmap_tags.html")
    (replace_override_digests (Assets.javascript_importmap_tags ()))

let static_vectors () =
  List.iter (fun case ->
    let method_ = member "method" case |> string in
    let path = member "path" case |> string in
    let env = member "env" case in
    let get key = match member key env with `String value -> Some value | _ -> None in
    let override_of = List.find_opt (fun logical -> path = "/assets/" ^ ref_digest logical) overrides in
    let request_path = match override_of with
      | Some logical -> "/assets/" ^ Option.get (Assets.digested_path logical)
      | None -> path in
    let expected_status = member "status" case |> Yojson.Basic.Util.to_int in
    let expected_headers = member "headers" case |> assoc in
    let label = method_ ^ " " ^ path in
    let response = Assets.serve ~method_ ~path:request_path
      ?accept_encoding:(get "HTTP_ACCEPT_ENCODING") ?range:(get "HTTP_RANGE") () in
    if expected_status = 404 && List.mem_assoc "x-cascade" expected_headers then
      Alcotest.(check bool) (label ^ " fallthrough") true (Option.is_none response)
    else match response with
    | None -> Alcotest.fail (label ^ " missing response")
    | Some response ->
      Alcotest.(check int) (label ^ " status") expected_status response.status;
      let actual_headers = List.filter (fun (key, _) -> key <> "last-modified") response.headers in
      if request_path = "/assets/.manifest.json" || Option.is_some override_of then
        Alcotest.(check string) (label ^ " content-type")
          (member "content-type" (member "headers" case) |> string)
          (Option.get (Assets.header response "content-type"))
      else (
        let sort = List.sort compare in
        Alcotest.(check (list (pair string string))) (label ^ " headers")
          (sort (List.map (fun (key, value) -> key, string value) expected_headers))
          (sort actual_headers);
        if method_ = "GET" then
          Alcotest.(check string) (label ^ " body") (member "body_sha256" case |> string) (sha256 response.body))
  ) (list (json "static_responses.json"))

let helpers_and_edges () =
  Alcotest.(check string) "icon" "/assets/campfire-icon-3d9986c5.png" (Assets.asset_path "campfire-icon.png");
  Alcotest.(check string) "query tail" "/assets/bot-8a69692e.svg?v=1#x" (Assets.asset_path "bot.svg?v=1#x");
  Alcotest.(check string) "absolute passthrough" "/rooms/1" (Assets.asset_path "/rooms/1");
  Alcotest.(check string) "URL passthrough" "https://example.com/a.png" (Assets.asset_path "https://example.com/a.png");
  Alcotest.(check string) "style extension" (Assets.asset_path "base.css") (Assets.stylesheet_path "base");
  Alcotest.(check bool) "missing asset" true (Result.is_error (Assets.try_asset_path "nope.png"));
  let get path = Assets.serve ~method_:"GET" ~path () in
  Alcotest.(check bool) "NUL rejected" true (Option.is_none (get "/robots%00.txt"));
  Alcotest.(check bool) "traversal cannot leave index" true (Option.is_none (get "/assets/../../etc/passwd"));
  let robots = Option.get (get "/robots.txt") in
  let last_modified = Option.get (Assets.header robots "last-modified") in
  let conditional = Option.get (Assets.serve ~method_:"GET" ~path:"/robots.txt" ~if_modified_since:last_modified ()) in
  Alcotest.(check int) "304" 304 conditional.status;
  Alcotest.(check bool) "304 headers" true (conditional.headers = []);
  Alcotest.(check string) "304 body" "" conditional.body;
  let head = Option.get (Assets.serve ~method_:"HEAD" ~path:"/robots.txt" ()) in
  Alcotest.(check string) "HEAD body" "" head.body;
  Alcotest.(check string) "HEAD length" "99" (Option.get (Assets.header head "content-length"));
  let sound = Assets.audio_path "56k.mp3" in
  let multiple = Option.get (Assets.serve ~method_:"GET" ~path:sound ~range:"bytes=0-1, 4-5" ()) in
  Alcotest.(check int) "multipart status" 206 multiple.status;
  Alcotest.(check string) "multipart content type" "audio/mpeg" (Option.get (Assets.header multiple "content-type"));
  Alcotest.(check bool) "multipart prefix" true (String.starts_with ~prefix:"\r\n--AaB03x\r\ncontent-type: audio/mpeg\r\ncontent-range: bytes 0-1/" multiple.body);
  Alcotest.(check bool) "multipart suffix" true (String.ends_with ~suffix:"\r\n--AaB03x--\r\n" multiple.body)

let integrated_static_headers () =
  let db_path = Filename.temp_file "campfire-m4-assets-" ".sqlite3" in
  let runtime = Db_runtime.open_db db_path in
  Fun.protect ~finally:(fun () ->
    Db_runtime.close runtime;
    List.iter (fun path -> if Sys.file_exists path then Sys.remove path)
      [db_path; db_path ^ "-wal"; db_path ^ "-shm"]) (fun () ->
    let send ?range ?if_modified_since path =
      let headers = ["host", "campfire.test"] in
      let headers = match range with None -> headers | Some value -> ("range", value) :: headers in
      let headers = match if_modified_since with None -> headers
        | Some value -> ("if-modified-since", value) :: headers in
      let request = Cohttp.Request.make ~headers:(Cohttp.Header.of_list headers)
        (Uri.of_string path) in
      let response, body = Lwt_main.run (Http_app.handle ~runtime
        ~secret_key_base:"unused" ~dispatch:(fun _ -> None) request Cohttp_lwt.Body.empty) in
      response, Lwt_main.run (Cohttp_lwt.Body.to_string body) in
    let status response = Cohttp.Code.code_of_status (Cohttp.Response.status response) in
    let header response name = Cohttp.Header.get (Cohttp.Response.headers response) name in
    let plain, body = send "/robots.txt" in
    Alcotest.(check int) "integrated static GET" 200 (status plain);
    Alcotest.(check int) "integrated body length" 99 (String.length body);
    Alcotest.(check (option string)) "integrated Content-Length" (Some "99")
      (header plain "content-length");
    let last_modified = Option.get (header plain "last-modified") in
    let conditional, body = send ~if_modified_since:last_modified "/robots.txt" in
    Alcotest.(check int) "integrated static 304" 304 (status conditional);
    Alcotest.(check string) "integrated 304 body" "" body;
    Alcotest.(check (option string)) "static 304 has no Cache-Control" None
      (header conditional "cache-control");
    let unsatisfiable, body = send ~range:"bytes=999999999-" "/robots.txt" in
    Alcotest.(check int) "integrated static 416" 416 (status unsatisfiable);
    Alcotest.(check string) "integrated 416 body" "Byte range unsatisfiable\n" body;
    Alcotest.(check (option string)) "static 416 has no Cache-Control" None
      (header unsatisfiable "cache-control"))

let () = Alcotest.run "M4 asset pipeline" [
  "reference", [
    Alcotest.test_case "manifest" `Quick manifest_matches;
    Alcotest.test_case "compiled bytes" `Quick compiled_bytes;
    Alcotest.test_case "head tags" `Quick tags_match;
    Alcotest.test_case "static responses" `Quick static_vectors;
    Alcotest.test_case "helpers and edge paths" `Quick helpers_and_edges;
    Alcotest.test_case "integrated static headers" `Quick integrated_static_headers;
  ]
]

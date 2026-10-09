let lookup values name = List.assoc_opt name values

let test_config_defaults () =
  let config =
    Campfire.Config.from_lookup (lookup ["SECRET_KEY_BASE", "abc"])
    |> Result.get_ok
  in
  Alcotest.(check string) "database" "storage/db/production.sqlite3" config.storage.database;
  Alcotest.(check string) "files" "storage/files" config.storage.files;
  Alcotest.(check int) "readers" 5 config.db_readers;
  Alcotest.(check bool) "ssl" false config.disable_ssl

let test_config_overrides () =
  let values = ["SECRET_KEY_BASE", "abc"; "RAILS_ENV", "test";
                "CAMPFIRE_STORAGE_PATH", "/data"; "CAMPFIRE_DATABASE_PATH", "/elsewhere/app.db";
                "RAILS_MAX_THREADS", "0"; "DISABLE_SSL", "false"] in
  let config = Campfire.Config.from_lookup (lookup values) |> Result.get_ok in
  Alcotest.(check string) "database override" "/elsewhere/app.db" config.storage.database;
  Alcotest.(check string) "files" "/data/files" config.storage.files;
  Alcotest.(check int) "readers lower bound" 1 config.db_readers;
  Alcotest.(check bool) "disable SSL by presence" true config.disable_ssl

let test_missing_secret () =
  Alcotest.(check bool) "secret required" true
    (Result.is_error (Campfire.Config.from_lookup (fun _ -> None)))

let test_database_schema () =
  let path = Filename.temp_file "campfire-ocaml-" ".sqlite3" in
  Fun.protect
    ~finally:(fun () -> Sys.remove path)
    (fun () ->
      let db = Sqlite3.db_open path in
      Sqlite3.Rc.check (Sqlite3.exec db "CREATE TABLE accounts (id INTEGER PRIMARY KEY)");
      Sqlite3.Rc.check (Sqlite3.exec db "INSERT INTO accounts VALUES (1)");
      ignore (Sqlite3.db_close db);
      let report = Campfire.Database.inspect path |> Result.get_ok in
      Alcotest.(check int) "account count" 1 report.account_count;
      Alcotest.(check bool) "missing tables" true (List.mem "messages" report.missing_tables))

let test_upstream_database_schema () =
  let path = Filename.temp_file "campfire-ocaml-schema-" ".sqlite3" in
  Fun.protect
    ~finally:(fun () -> Sys.remove path)
    (fun () ->
      let schema =
        let input = open_in "fixtures/schema.sql" in
        Fun.protect ~finally:(fun () -> close_in input)
          (fun () -> really_input_string input (in_channel_length input)) in
      let db = Sqlite3.db_open path in
      Sqlite3.Rc.check (Sqlite3.exec db schema);
      ignore (Sqlite3.db_close db);
      let report = Campfire.Database.inspect path |> Result.get_ok in
      Alcotest.(check (list string)) "required tables" [] report.missing_tables)

let test_route_vectors () =
  let open Yojson.Basic.Util in
  let vectors = Yojson.Basic.from_file "fixtures/routes.json" |> member "recognitions" |> to_list in
  List.iter (fun vector ->
    let expected = vector |> member "endpoint" in
    if expected <> `Null then begin
      let method_ = vector |> member "verb" |> to_string in
      let path = vector |> member "path" |> to_string in
      let result = Campfire.Routes.recognize method_ path in
      let match_ = match result with
        | Some value -> value
        | None -> Alcotest.failf "No route for %s %s" method_ path
      in
      Alcotest.(check string) (method_ ^ " " ^ path) (to_string expected) match_.endpoint;
      let expected_params = vector |> member "params" |> to_assoc in
      List.iter (fun (key, expected) ->
        Alcotest.(check (option string)) (path ^ " " ^ key)
          (Some (to_string expected)) (List.assoc_opt key match_.params)) expected_params
    end) vectors

let test_unknown_routes () =
  List.iter (fun (method_, path) ->
    Alcotest.(check bool) (method_ ^ " " ^ path) true
      (Option.is_none (Campfire.Routes.recognize method_ path)))
    ["GET", "/nope"; "PATCH", "/rooms"; "GET", "/ROOMS/1"; "GET", "/cable"]

let rails_vectors () = Yojson.Basic.from_file "fixtures/rails_compat.json"

let test_derived_keys () =
  let open Yojson.Basic.Util in
  let vectors = rails_vectors () in
  let secret_key_base = vectors |> member "secret_key_base" |> to_string in
  vectors |> member "key_generator" |> to_list |> List.iter (fun item ->
    let salt = item |> member "salt" |> to_string in
    let length = item |> member "length" |> to_int in
    let key = Campfire.Key_generator.derive ~secret_key_base ~salt ~length in
    let actual = Cstruct.of_string key |> Cstruct.to_hex_string in
    Alcotest.(check string) salt (item |> member "key_hex" |> to_string) actual)

let test_signed_cookie_vectors () =
  let open Yojson.Basic.Util in
  let vectors = rails_vectors () in
  let secret_key_base = vectors |> member "secret_key_base" |> to_string in
  let signed = vectors |> member "signed_cookies" in
  signed |> member "generate" |> to_list |> List.iter (fun item ->
    let name = item |> member "name" |> to_string in
    let value = item |> member "value" |> to_string in
    let expires_at = item |> member "expires_at" in
    let expires_at = if expires_at = `Null then None else Some (to_string expires_at) in
    let actual = Campfire.Signed_cookie.generate ~secret_key_base ~name ~value ~expires_at in
    Alcotest.(check string) ("generate " ^ name ^ ": " ^ value)
      (item |> member "raw" |> to_string) actual);
  signed |> member "verify" |> to_list |> List.iter (fun item ->
    let name = item |> member "name" |> to_string in
    let raw = item |> member "raw" |> to_string in
    let now = item |> member "now" |> to_string in
    let expected = item |> member "expected" in
    let expected = if expected = `Null then None else Some expected in
    let actual = Campfire.Signed_cookie.verify_value ~secret_key_base ~name ~raw ~now in
    if actual <> expected then
      Alcotest.failf "verify %s: expected %s, got %s"
        (item |> member "case" |> to_string)
        (match expected with None -> "null" | Some value -> Yojson.Basic.to_string value)
        (match actual with None -> "null" | Some value -> Yojson.Basic.to_string value))

let test_encrypted_cookie_vectors () =
  let open Yojson.Basic.Util in
  let vectors = rails_vectors () in
  let secret_key_base = vectors |> member "secret_key_base" |> to_string in
  let encrypted = vectors |> member "encrypted_cookies" in
  encrypted |> member "generate" |> to_list |> List.iter (fun item ->
    let raw = item |> member "raw" |> to_string in
    let iv =
      let len = String.length raw in
      String.sub raw (len - 42) 16 |> Base64.decode_exn in
    let name = item |> member "name" |> to_string in
    let value = item |> member "value" in
    let expires_at = item |> member "expires_at" in
    let expires_at = if expires_at = `Null then None else Some (to_string expires_at) in
    let actual = Campfire.Encrypted_cookie.encrypt_with_iv
        ~secret_key_base ~name ~value ~expires_at ~iv in
    Alcotest.(check string) ("encrypt " ^ name) raw actual);
  encrypted |> member "verify" |> to_list |> List.iter (fun item ->
    let name = item |> member "name" |> to_string in
    let raw = item |> member "raw" |> to_string in
    let now = item |> member "now" |> to_string in
    let expected = item |> member "expected" in
    let expected = if expected = `Null then None else Some expected in
    let actual = Campfire.Encrypted_cookie.decrypt ~secret_key_base ~name ~raw ~now in
    if actual <> expected then
      Alcotest.failf "decrypt %s: expected %s, got %s"
        (item |> member "case" |> to_string)
        (match expected with None -> "null" | Some value -> Yojson.Basic.to_string value)
        (match actual with None -> "null" | Some value -> Yojson.Basic.to_string value))

let test_random_encrypted_cookie_round_trip () =
  let secret_key_base = "test-only-secret" in
  let name = "_campfire_session" in
  let value = `Assoc ["session_id", `String "abc"] in
  let expires_at = Some "2046-01-01T12:00:00.000Z" in
  let raw = Campfire.Encrypted_cookie.encrypt
      ~secret_key_base ~name ~value ~expires_at in
  Alcotest.(check bool) "two random IVs differ" true
    (raw <> Campfire.Encrypted_cookie.encrypt ~secret_key_base ~name ~value ~expires_at);
  let actual = Campfire.Encrypted_cookie.decrypt ~secret_key_base ~name ~raw
      ~now:"2026-01-01T12:00:00.000Z" in
  Alcotest.(check bool) "decrypt generated cookie" true (actual = Some value)

let () = Alcotest.run "campfire-core" [
  "config", [
    Alcotest.test_case "defaults" `Quick test_config_defaults;
    Alcotest.test_case "overrides" `Quick test_config_overrides;
    Alcotest.test_case "missing secret" `Quick test_missing_secret;
  ];
  "database", [
    Alcotest.test_case "missing tables" `Quick test_database_schema;
    Alcotest.test_case "upstream schema" `Quick test_upstream_database_schema;
  ];
  "routes", [
    Alcotest.test_case "upstream positive vectors" `Quick test_route_vectors;
    Alcotest.test_case "unknown routes" `Quick test_unknown_routes;
  ];
  "signed cookies", [
    Alcotest.test_case "PBKDF2 vectors" `Quick test_derived_keys;
    Alcotest.test_case "Rails generate and verify vectors" `Quick test_signed_cookie_vectors;
  ];
  "encrypted cookies", [
    Alcotest.test_case "Rails generate and verify vectors" `Quick test_encrypted_cookie_vectors;
    Alcotest.test_case "random IV round trip" `Quick test_random_encrypted_cookie_round_trip;
  ];
]

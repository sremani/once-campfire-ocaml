open Campfire
open Lwt.Infix

let rec reference_root path remaining =
  if remaining = 0 then failwith "pinned Rails seed not found" else
  let candidate = Filename.concat path "once-campfire-rust" in
  if Sys.file_exists (Filename.concat candidate
      "parity/.seed/default/db/production.sqlite3") then candidate
  else reference_root (Filename.dirname path) (remaining-1)

let with_seed f =
  let reference = reference_root (Sys.getcwd ()) 8 in
  let source = Sqlite3.db_open ~mode:`READONLY
    (Filename.concat reference "parity/.seed/default/db/production.sqlite3") in
  let directory = Filename.temp_file "campfire-post-writer-" "" in
  Sys.remove directory;
  Unix.mkdir directory 0o700;
  let database = Filename.concat directory "test.sqlite3" in
  let socket = Filename.concat directory "writer.sock" in
  let quoted = String.concat "''" (String.split_on_char '\'' database) in
  let result = Sqlite3.exec source ("VACUUM INTO '" ^ quoted ^ "'") in
  ignore (Sqlite3.db_close source);
  if result <> Sqlite3.Rc.OK then failwith "seed copy failed";
  let child = Unix.fork () in
  if child = 0 then (
    try
      Unix.putenv "CAMPFIRE_POST_BATCH_DELAY_US" "1000";
      let runtime = Db_runtime.open_db ~readers:1 ~prepare:false database in
      Post_writer.serve socket runtime
    with _ -> exit 1)
  else Fun.protect ~finally:(fun () ->
    (try Unix.kill child Sys.sigterm with _ -> ());
    ignore (Unix.waitpid [] child);
    List.iter (fun path -> if Sys.file_exists path then Sys.remove path)
      [socket; database; database ^ "-wal"; database ^ "-shm"];
    Unix.rmdir directory) (fun () ->
    let rec ready attempts =
      if Sys.file_exists socket then ()
      else if attempts = 0 then Alcotest.fail "writer did not start"
      else (Thread.delay 0.01; ready (attempts-1)) in
    ready 200;
    let runtime = Db_runtime.open_db ~readers:1 ~prepare:false database in
    Fun.protect ~finally:(fun () -> Db_runtime.close runtime)
      (fun () -> f runtime socket))

let test_creates_and_indexes () = with_seed (fun runtime socket ->
  let room_id,creator_id = Db_runtime.read runtime (fun db ->
    Db_runtime.query_one db
      "SELECT room_id,user_id FROM memberships LIMIT 1" []
      (fun row -> Sqlite3.column_int64 row 0,Sqlite3.column_int64 row 1)
    |> Option.get) in
  let request i =
    {Post_writer.room_id;creator_id;
     client_message_id=Some ("post-writer-test-" ^ string_of_int i);
     body="writer body " ^ string_of_int i;
     index_plain="writer body " ^ string_of_int i;
     now="2026-10-14T12:00:00Z"} in
  let created = Lwt_main.run (
    Lwt.all (List.init 4 (fun i ->
      Post_writer.create_message_async socket (request i)))) in
  Alcotest.(check int) "four distinct messages" 4
    (List.length (List.sort_uniq Int64.compare
      (List.map (fun message -> message.Db_messages.Message.id) created)));
  List.iteri (fun i message ->
    let body,index = Db_runtime.read runtime (fun db ->
      let body = Db_runtime.query_one db
        "SELECT body FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?"
        [Sqlite3.Data.INT message.Db_messages.Message.id]
        (fun row -> Sqlite3.column_text row 0) |> Option.get in
      let index = Db_runtime.query_one db
        "SELECT body FROM message_search_index WHERE rowid=?"
        [Sqlite3.Data.INT message.Db_messages.Message.id]
        (fun row -> Sqlite3.column_text row 0) |> Option.get in
      body,index) in
    Alcotest.(check string) "message body" ("writer body " ^ string_of_int i) body;
    Alcotest.(check string) "search index" ("writer body " ^ string_of_int i) index)
    created;
  let invalid = { (request 99) with Post_writer.room_id=(-1L) } in
  let valid = request 100 in
  let capture request = Lwt.catch
    (fun () -> Post_writer.create_message_async socket request >|= fun x -> Ok x)
    (fun exn -> Lwt.return (Error exn)) in
  let bad,good = Lwt_main.run (Lwt.both (capture invalid) (capture valid)) in
  Alcotest.(check bool) "bad request fails" true (Result.is_error bad);
  Alcotest.(check bool) "independent request succeeds" true (Result.is_ok good);
  let count = Db_runtime.read runtime (fun db ->
    Db_runtime.query_one db
      "SELECT COUNT(*) FROM messages WHERE client_message_id LIKE 'post-writer-test-%'"
      [] (fun row -> Sqlite3.column_int row 0) |> Option.get) in
  Alcotest.(check int) "only successful messages persisted" 5 count)

let () = Alcotest.run "post writer" [
  "integration", [Alcotest.test_case "create, index, and isolate failures" `Quick
    test_creates_and_indexes]
]

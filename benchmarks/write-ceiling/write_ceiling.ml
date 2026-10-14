open Campfire

let rec reference_root path remaining =
  if remaining = 0 then failwith "pinned reference seed missing" else
  let root = Filename.concat path "once-campfire-rust" in
  if Sys.file_exists
      (Filename.concat root "parity/.seed/default/db/production.sqlite3")
  then root else reference_root (Filename.dirname path) (remaining - 1)

let source = Filename.concat (reference_root (Sys.getcwd ()) 8)
  "parity/.seed/default/db/production.sqlite3"

let copy_seed destination =
  let db = Sqlite3.db_open ~mode:`READONLY source in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close db)) (fun () ->
    let escaped = String.concat "''" (String.split_on_char '\'' destination) in
    match Sqlite3.exec db ("VACUUM INTO '" ^ escaped ^ "'") with
    | Sqlite3.Rc.OK -> ()
    | rc -> failwith ("seed copy: " ^ Sqlite3.Rc.to_string rc))

let () =
  let count, shared = match Array.to_list Sys.argv with
    | [_; value; path; prefix] -> int_of_string value, Some (path,prefix)
    | [_; value] -> int_of_string value, None
    | [_] -> 5_000, None
    | _ -> invalid_arg "usage: write_ceiling [COUNT [SHARED_DATABASE PREFIX]]" in
  if count <= 0 then invalid_arg "positive write count required";
  let path, prefix, owns_path = match shared with
    | Some (path,prefix) -> path,prefix,false
    | None ->
        let path = Filename.temp_file "campfire-write-ceiling-" ".sqlite3" in
        Sys.remove path;
        path,"ceiling",true in
  Fun.protect ~finally:(fun () ->
    if owns_path then List.iter (fun name -> if Sys.file_exists name then Sys.remove name)
      [path;path ^ "-wal";path ^ "-shm"]) (fun () ->
    if owns_path then copy_seed path;
    let runtime = Db_runtime.open_db ~readers:1 ~prepare:false path in
    Fun.protect ~finally:(fun () -> Db_runtime.close runtime) (fun () ->
      let now = Authentication.now_time "2026-10-08T12:00:00Z" in
      let started = Unix.gettimeofday () in
      for i=1 to count do
        let plain = Printf.sprintf "bench write %08x" i in
        let attrs : Db_messages.Message.new_message = {
          room_id=654632876L;creator_id=127326141L;
          client_message_id=Some (Printf.sprintf "%s-%08x" prefix i);
          body=Some plain;attachment_blob_id=None} in
        ignore (Db_runtime.write runtime (fun tx ->
          Db_messages.Message.create ~index_plain:plain tx ~now attrs))
      done;
      let elapsed = Unix.gettimeofday () -. started in
      let indexed = Db_runtime.read runtime (fun db ->
        Db_runtime.query_one db
          "SELECT count(*) FROM message_search_index WHERE body MATCH 'bench write'"
          [] (fun stmt -> Sqlite3.column_int stmt 0) |> Option.get) in
      Printf.printf "writes=%d indexed=%d elapsed=%.3fs rate=%.1f/s\n%!"
        count indexed elapsed (float count /. elapsed)))

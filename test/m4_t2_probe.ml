(* Offline pinned-seed HTTP renderer for byte comparisons. It never prints
   fixture credentials; callers capture its response body from stdout. *)
open Campfire

let rec reference_root path remaining =
  if remaining = 0 then failwith "pinned Rust seed not found"
  else let candidate = Filename.concat path "once-campfire-rust" in
    if Sys.file_exists
      (Filename.concat candidate "parity/.seed/default/db/production.sqlite3")
    then candidate else reference_root (Filename.dirname path) (remaining - 1)

let member key json = Yojson.Safe.Util.member key json
let string key json = member key json |> Yojson.Safe.Util.to_string

let with_seed f =
  let root = reference_root (Sys.getcwd ()) 8 in
  let seed = Filename.concat root "parity/.seed/default" in
  let source = Sqlite3.db_open ~mode:`READONLY
    (Filename.concat seed "db/production.sqlite3") in
  let temporary = Filename.temp_file "campfire-m4-t2-probe-" ".sqlite3" in
  Sys.remove temporary;
  let quoted = String.concat "''" (String.split_on_char '\'' temporary) in
  let result = Sqlite3.exec source ("VACUUM INTO '" ^ quoted ^ "'") in
  ignore (Sqlite3.db_close source);
  if result <> Sqlite3.Rc.OK then failwith "could not copy pinned seed";
  let runtime = Db_runtime.open_db ~readers:1 ~prepare:false temporary in
  Fun.protect ~finally:(fun () ->
    Db_runtime.close runtime;
    List.iter (fun path -> if Sys.file_exists path then Sys.remove path)
      [temporary;temporary ^ "-wal";temporary ^ "-shm"])
    (fun () -> f root seed runtime)

let () =
  if Array.length Sys.argv <> 3 then
    failwith "usage: m4_t2_probe.exe ROW ROLE";
  let row = int_of_string Sys.argv.(1) in
  let role = Sys.argv.(2) in
  with_seed (fun root seed runtime ->
    let reference_env = Filename.concat root "parity/.env.reference" in
    let channel = open_in reference_env in
    Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
      try while true do
        let line = input_line channel in
        match String.index_opt line '=' with
        | Some at when at > 0 && line.[0] <> '#' ->
            let key = String.sub line 0 at in
            let value = String.sub line (at+1) (String.length line-at-1) in
            if List.mem key ["VAPID_PUBLIC_KEY";"APP_VERSION";"GIT_REVISION"]
            then Unix.putenv key value
        | _ -> ()
      done with End_of_file -> ());
    let labels = Yojson.Safe.from_file (Filename.concat seed "labels.json") in
    let path = match row with
      | 28 -> "/account/bots"
      | 49 -> "/join/" ^ string "join_codes.signal" labels
      | _ -> failwith "unsupported offline probe row" in
    let sessions = Yojson.Safe.from_file
      "test/fixtures/campfire_sessions.json" in
    let cookie = sessions |> member "sessions" |> Yojson.Safe.Util.to_list
      |> List.hd |> string "cookie_header" in
    let secrets = Yojson.Safe.from_file "test/fixtures/rails_compat.json" in
    let headers = [
      "host","campfire.test";
      "accept-encoding","identity";
      "origin","http://campfire.test";
      "sec-fetch-site","same-origin";
      "x-request-id","m8-t2-differential";
      "user-agent","Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/126.0.0.0 Safari/537.36"] in
    let headers = if role="signed" || role="denied" then
      ("cookie",cookie) :: headers else headers in
    let request = Cohttp.Request.make ~meth:`GET
      ~headers:(Cohttp.Header.of_list headers)
      (Uri.of_string ("http://campfire.test" ^ path)) in
    let _,body = Lwt_main.run (Http_app.handle ~runtime
      ~secret_key_base:(string "secret_key_base" secrets)
      ~now:(string "clock.now" labels) ~ssl:false ~force_ssl:false
      ~dispatch:App_dispatch.endpoint request (Cohttp_lwt.Body.of_string "")) in
    print_string (Lwt_main.run (Cohttp_lwt.Body.to_string body)))

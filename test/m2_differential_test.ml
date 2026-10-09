open Campfire
module A = Db_accounts.Account
module U = Db_accounts.User
module S = Db_accounts.Session
module R = Db_rooms.Room
module M = Db_rooms.Membership
module Msg = Db_messages.Message
module B = Db_messages.Boost
module Search = Db_messages.Search
module Hooks = Db_remaining.Hooks

let now = Authentication.now_time "2026-10-10T12:00:00.123456Z"
let now_text = "2026-10-10T12:00:00.123456Z"
let david = 127326141L and jason = 149087659L
let kevin = 712064548L and jz = 773523953L
let designers = 654632876L and hq = 201306877L
let watercooler = 486777696L and pets = 104393281L

let fixture name =
  let local = Filename.concat "fixtures" name in
  if Sys.file_exists local then local else Filename.concat "test/fixtures" name

let copy_database source destination =
  let ic = open_in_bin source in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    let oc = open_out_bin destination in
    Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
      let buffer = Bytes.create 65536 in
      let rec copy () =
        let got = input ic buffer 0 (Bytes.length buffer) in
        if got > 0 then (output oc buffer 0 got; copy ())
      in copy ()))

let with_fixture f =
  let path = Filename.temp_file "campfire-m2-differential-" ".sqlite3" in
  Sys.remove path;
  copy_database (fixture "model_fixtures.sqlite3") path;
  let runtime = Db_runtime.open_db ~prepare:false path in
  Fun.protect ~finally:(fun () ->
    Db_runtime.close runtime;
    List.iter (fun suffix -> let file = path ^ suffix in
      if Sys.file_exists file then Sys.remove file) [""; "-wal"; "-shm"])
    (fun () -> f runtime)

let message room creator body client_message_id =
  { Msg.room_id=room; creator_id=creator; body=Some body;
    client_message_id=Some client_message_id; attachment_blob_id=None }

let scenario rt =
  let write f = Db_runtime.write rt f in
  let m = write (fun tx -> Msg.create tx ~now (message designers david "Hello <b>there</b>" "s1")) in
  let b = write (fun tx -> B.create tx ~now ~message_id:m.id ~booster_id:jason ~content:"hi") in
  ignore (write (fun tx -> B.create tx ~now ~message_id:m.id ~booster_id:kevin ~content:"yo"));
  write (fun tx -> B.destroy tx ~now b);
  ignore (write (fun tx -> Msg.update_body tx ~now (Msg.find (Db_runtime.conn tx) m.id) "Edited hovercraft"));
  let m2 = write (fun tx -> Msg.create tx ~now (message hq jason "Doomed" "s2")) in
  ignore (write (fun tx -> B.create tx ~now ~message_id:m2.id ~booster_id:david ~content:"x"));
  write (fun tx -> Msg.destroy tx ~now (Msg.find (Db_runtime.conn tx) m2.id));
  write (fun tx -> M.destroy tx (M.find (Db_runtime.conn tx) 658335620L)
    ~on_disconnect:(fun ~user_id:_ ~reconnect:_ -> ()));
  ignore (write (fun tx -> U.create_tx tx ~now:now_text
    { name="User"; email_address=Some "u@example.com";
      password_digest=Some (Db_accounts.Password.digest_with_cost ~cost:4 "secret123456");
      role=U.Member; bio=None; bot_token=None }));
  ignore (write (fun tx -> R.create tx ~now:now_text Db_rooms.Open ~name:(Some "Open!") ~creator_id:david));
  ignore (write (fun tx -> R.create_for tx ~now:now_text Db_rooms.Closed ~name:(Some "Hello!")
    ~creator_id:david [kevin;david]));
  ignore (write (fun tx -> R.update tx ~now:now_text (R.find (Db_runtime.conn tx) watercooler)
    ~room_type:Db_rooms.Open ()));
  ignore (write (fun tx -> R.update tx ~now:now_text (R.find (Db_runtime.conn tx) pets)
    ~name:(Some "Pets2") ()));
  ignore (write (fun tx -> M.update_involvement tx ~now:now_text
    (M.find (Db_runtime.conn tx) 515358788L) (Some Db_rooms.Invisible)));
  write (fun tx -> let m = M.find (Db_runtime.conn tx) 211379269L in
    let m = M.connected tx ~now:now_text m in
    let m = M.connected tx ~now:now_text m in
    ignore (M.disconnected tx ~now:now_text m));
  ignore (write (fun tx -> R.find_or_create_direct_for tx ~now:now_text
    ~user_ids:[jz;kevin] ~creator_id:david));
  ignore (write (fun tx -> S.start (Db_runtime.conn tx) ~now:now_text ~user_id:kevin
    ~user_agent:(Some "x") ~ip_address:(Some "8.8.8.8")));
  let sink _ = () in
  let banned = write (fun tx -> Hooks.ban_user tx ~now:now_text ~sink
    (U.find (Db_runtime.conn tx) kevin)) in
  ignore (write (fun tx -> U.unban (Db_runtime.conn tx) ~now:now_text banned));
  write (fun tx -> Hooks.destroy_messages_by_creator tx ~now ~sink ~creator_id:jz);
  ignore (write (fun tx -> Hooks.deactivate_user tx ~now:now_text ~sink
    (U.find (Db_runtime.conn tx) jz)));
  for n=0 to 11 do
    let at = Ptime.add_span now (Ptime.Span.of_int_s (n+1)) |> Option.get in
    ignore (write (fun tx -> Search.record tx ~now:at ~user_id:david
      ~query:("q" ^ string_of_int n)))
  done;
  let bot = write (fun tx -> U.create_bot_tx tx ~now:now_text ~name:"Bot"
    ~webhook_url:"http://x" ()) in
  ignore (write (fun tx -> U.update_bot (Db_runtime.conn tx) ~now:now_text bot
    {U.no_changes with name=Some "Bot2"} ~webhook_url:(Some "http://y")));
  ignore (write (fun tx -> A.update (Db_runtime.conn tx) ~now:now_text
    (Option.get (A.first (Db_runtime.conn tx)))
    ~settings:["restrict_room_creation_to_administrators","true"] ()));
  ignore (write (fun tx -> Msg.create tx ~now (message hq kevin "Last one" "s3")))

let tables = ["accounts","id"; "action_text_rich_texts","id"; "bans","id";
  "boosts","id"; "memberships","room_id,user_id"; "messages","id";
  "push_subscriptions","id"; "rooms","id"; "searches","id";
  "sessions","id"; "users","id"; "webhooks","id";
  "message_search_index","rowid"]

let normalized_value name value =
  let render = function
    | Sqlite3.Data.NULL -> "NULL"
    | Sqlite3.Data.INT n -> "INT:" ^ Int64.to_string n
    | Sqlite3.Data.FLOAT x -> "FLOAT:" ^ string_of_float x
    | Sqlite3.Data.TEXT s -> "TEXT:" ^ String.escaped s
    | Sqlite3.Data.BLOB s -> "BLOB:" ^ String.escaped s
    | Sqlite3.Data.NONE -> "NONE" in
  match name,value with
  | "password_digest", Sqlite3.Data.TEXT s -> "bcrypt:" ^ String.sub s 0 4
  | ("bot_token" | "token" | "join_code"), Sqlite3.Data.TEXT s ->
      "random:" ^ string_of_int (String.length s)
  | "email_address", Sqlite3.Data.TEXT s when
      (try ignore (Str.search_forward (Str.regexp_string "-deactivated-") s 0); true
       with Not_found -> false) ->
      let marker = Str.search_forward (Str.regexp_string "-deactivated-") s 0 in
      let at = String.index_from s marker '@' in
      String.sub s 0 (marker + 13) ^ "<uuid>" ^ String.sub s at (String.length s - at)
  | name, Sqlite3.Data.TEXT s when String.ends_with ~suffix:"_at" name ->
      let fraction = match String.index_opt s '.' with
        | None -> 0 | Some dot -> String.length s - dot - 1 in
      "time:" ^ string_of_int fraction
  | _, value -> render value

let dump db table order =
  let columns = if table="message_search_index" then "rowid AS id, body" else "*" in
  Db_runtime.query_all db
    ("SELECT " ^ columns ^ " FROM \"" ^ table ^ "\" ORDER BY " ^ order) []
    (fun stmt ->
      List.init (Sqlite3.column_count stmt) (fun n ->
        let name = Sqlite3.column_name stmt n in
        name ^ "=" ^ normalized_value name (Sqlite3.column stmt n))
      |> List.sort String.compare)

let compare_with_rails rt =
  let path = Filename.temp_file "campfire-m2-rails-" ".sqlite3" in
  copy_database (fixture "model_scenario.sqlite3") path;
  let rails = Sqlite3.db_open ~mode:`READONLY path in
  Fun.protect ~finally:(fun () ->
    ignore (Sqlite3.db_close rails);
    List.iter (fun suffix ->
      let file = path ^ suffix in if Sys.file_exists file then Sys.remove file)
      [""; "-wal"; "-shm"]) (fun () ->
    Db_runtime.read rt (fun actual ->
      List.iter (fun (table,order) ->
        let expected = dump rails table order in
        let got = dump actual table order in
        if expected <> got then
          let only_expected = List.filter (fun x -> not (List.mem x got)) expected in
          let only_actual = List.filter (fun x -> not (List.mem x expected)) got in
          Alcotest.failf "%s differs: Rails only=%s OCaml only=%s"
            table (String.concat "\n" (List.map (String.concat " ") only_expected))
            (String.concat "\n" (List.map (String.concat " ") only_actual))) tables))

let test_scenario () = with_fixture (fun rt -> scenario rt; compare_with_rails rt)
let () = Alcotest.run "M2 Rails differential" [
  "state", [Alcotest.test_case "Rails mutation scenario row parity" `Quick test_scenario]
]

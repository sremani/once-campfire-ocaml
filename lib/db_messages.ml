(** Message, rich text, boost, search, and sound rows in the pinned Rails schema.
    All writes take the caller's [Db_runtime.tx]. The rich text adapter is
    deliberately supplied by the application so Action Text can be plugged in. *)

let text s = Sqlite3.Data.TEXT s
let integer n = Sqlite3.Data.INT n
let optional f = function None -> Sqlite3.Data.NULL | Some x -> f x
let column_option s i = match Sqlite3.column s i with
  | Sqlite3.Data.NULL -> None | _ -> Some (Sqlite3.column_text s i)
let q = Db_runtime.query_all
let one = Db_runtime.query_one
let run db sql params = ignore (Db_runtime.execute db sql params)
let required what = function Some x -> x | None -> failwith (what ^ " not found")
let now_string = Db_time.to_db
let count_sql db sql params = one db sql params (fun s -> Sqlite3.column_int s 0) |> Option.get

let replace_all source needle replacement =
  let n = String.length needle and len = String.length source in
  let out = Buffer.create len in
  let rec loop i =
    if i >= len then Buffer.contents out
    else if i+n <= len && String.sub source i n = needle then
      (Buffer.add_string out replacement; loop (i+n))
    else (Buffer.add_char out source.[i]; loop (i+1)) in
  loop 0

module Rich_text_record = struct
  type t = { id:int64; name:string; body:string option; record_type:string;
             record_id:int64; created_at:string; updated_at:string }
  let select = "SELECT id,name,body,record_type,record_id,created_at,updated_at FROM action_text_rich_texts"
  let decode s = { id=Sqlite3.column_int64 s 0; name=Sqlite3.column_text s 1;
    body=column_option s 2; record_type=Sqlite3.column_text s 3;
    record_id=Sqlite3.column_int64 s 4; created_at=Sqlite3.column_text s 5;
    updated_at=Sqlite3.column_text s 6 }
  let find_for db ~record_type ~record_id ~name =
    one db (select ^ " WHERE record_id=? AND record_type=? AND name=? LIMIT 1")
      [integer record_id; text record_type; text name] decode
  let find db id = one db (select ^ " WHERE id=? LIMIT 1") [integer id] decode |> required "RichTextRecord"
  let create tx ~now ~record_type ~record_id ~name ~body =
    let db = Db_runtime.conn tx and now = now_string now in
    run db "INSERT INTO action_text_rich_texts (body,created_at,name,record_id,record_type,updated_at) VALUES (?,?,?,?,?,?)"
      [text body; text now; text name; integer record_id; text record_type; text now];
    find db (Sqlite3.last_insert_rowid db)
  let update_body tx ~now row body =
    let db = Db_runtime.conn tx in
    run db "UPDATE action_text_rich_texts SET body=?,updated_at=? WHERE id=?"
      [text body; text (now_string now); integer row.id];
    find db row.id
  let delete tx row = run (Db_runtime.conn tx) "DELETE FROM action_text_rich_texts WHERE id=?" [integer row.id]
end

type rich_text = {
  to_plain_text : Sqlite3.db -> string -> string;
  mentioned_user_ids : Sqlite3.db -> string -> int64 list;
}

(** A small fixture adapter. Production callers should pass the Action Text
    adapter from M4, including mention attachment resolution and sanitization. *)
let basic_rich_text = {
  to_plain_text = (fun _ html ->
    let out = Buffer.create (String.length html) in
    let rec loop i =
      if i < String.length html then
        if html.[i] = '<' then
          (match String.index_from_opt html i '>' with
           | None -> ()
           | Some j ->
             let tag = String.sub html (i+1) (j-i-1) |> String.lowercase_ascii in
             let starts s = String.starts_with ~prefix:s tag in
             if Buffer.length out > 0 && List.exists starts ["br";"p";"div";"li";"h1";"blockquote";"pre"]
             then Buffer.add_char out '\n';
             loop (j+1))
        else (Buffer.add_char out html.[i]; loop (i+1)) in
    loop 0;
    let raw = Buffer.contents out |> String.trim in
    List.fold_left (fun s (entity, value) -> replace_all s entity value)
      raw ["&amp;","&"; "&lt;","<"; "&gt;",">"; "&quot;","\""; "&#39;","'"]);
  mentioned_user_ids = (fun _ _ -> []);
}

module Sound = struct
  type image = { file:string; width:int; height:int }
  type t = { name:string; text:string option; image:image option }
  let names = List.sort String.compare ["56k";"ballmer";"bell";"bezos";"bueller";"butts";"clowntown";"cottoneyejoe";
    "crickets";"curb";"dadgummit";"dangerzone";"danielsan";"deeper";"donotwant";
    "drama";"flawless";"glados";"gogogo";"greatjob";"greyjoy";"guarantee";
    "heygirl";"honk";"horn";"horror";"inconceivable";"letitgo";"live";
    "loggins";"makeitso";"noooo";"nyan";"ohmy";"ohyeah";"pushit";
    "rimshot";"rollout";"rumble";"sax";"secret";"sexyback";"story";
    "tada";"tmyk";"totes";"trololo";"trombone";"unix";"vuvuzela";
    "what";"whoomp";"wups";"yay";"yeah";"yodel"]
  let images = ["56k","56k.webp",79,33;"clowntown","clowntown.webp",210,150;
    "curb","curb.webp",150,101;"dangerzone","dangerzone.webp",157,32;
    "deeper","top.webp",188,80;"donotwant","donotwant.webp",150,150;
    "drama","drama.webp",300,16;"greatjob","greatjob.webp",79,16;
    "loggins","loggins.webp",200,151;"nyan","nyan.webp",36,15;
    "pushit","pushit.webp",104,15;"rumble","rumble.webp",220,150;
    "what","what.webp",100,131;"yay","yay.webp",103,50;"yeah","yeah.webp",104,15]
  let texts = ["bell","🔔";"bezos","😆💭";"bueller","anyone?";
    "butts","👐 🚬";"cottoneyejoe","🎶🙉🎶 ";"crickets","hears crickets chirping";
    "dadgummit","dad gummit!! 🎣";"danielsan","🎆 🏆 🎆";"ballmer","developers!";
    "flawless","#flawless";"glados","🤖💢";"gogogo","Go, go, go!";
    "greyjoy","😖🎺";"guarantee","guarantees it 👌";"heygirl","✨💁✨";
    "honk","HONK";"horn","🐶 ✂️ 🐱";"horror","💀 💀 💀 💀 💀 💀 💀";
    "inconceivable","doesn't think it means what you think it means…";
    "letitgo","❄️👩❄️⛄️❄️";"live","is DOING IT LIVE";"makeitso","make it so 👉";
    "noooo","👸💀😒";"ohmy","raises an eyebrow 😏";
    "ohyeah","isn't playing by the rules";"rimshot","plays a rimshot";
    "rollout","is rolling out 🚗";"sax","🌇🎷🎶";
    "secret","found a secret area 🔑";"sexyback","🔞";
    "story","and now you know…";"tada","plays a fanfare 🎏";
    "tmyk","✨ ⭐️ The More You Know ✨ ⭐️";"totes","😁👍";
    "trololo","трололо";"trombone","plays a sad trombone";
    "unix","knows this 💻";"vuvuzela","======<() ~ ♪ ~♫";
    "whoomp","👏‼️😎";"wups","wups!";"yodel","📣🗻🙉"]
  let find_by_name name = if not (List.mem name names) then None else
    let image = List.find_map (fun (n,file,width,height) ->
      if n=name then Some {file;width;height} else None) images in
    Some {name; image; text=List.assoc_opt name texts}
  let asset_path sound = sound.name ^ ".mp3"
  let image_asset_path image = "sounds/" ^ image.file
end

let sound_in plain =
  match String.starts_with ~prefix:"/play " plain with
  | false -> None
  | true ->
    let name = String.sub plain 6 (String.length plain - 6) in
    let valid = name <> "" && String.for_all (function
      | 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' -> true | _ -> false) name in
    if valid then Sound.find_by_name name else None

module Message = struct
  type t = { id:int64; room_id:int64; creator_id:int64; client_message_id:string;
             created_at:string; updated_at:string }
  type new_message = { room_id:int64; creator_id:int64; client_message_id:string option;
                       body:string option; attachment_blob_id:int64 option }
  type content_type = Attachment | Sound | Text
  let page_size = 40
  let select = "SELECT messages.id,messages.room_id,messages.creator_id,messages.client_message_id,messages.created_at,messages.updated_at FROM messages"
  let decode s = { id=Sqlite3.column_int64 s 0; room_id=Sqlite3.column_int64 s 1;
    creator_id=Sqlite3.column_int64 s 2; client_message_id=Sqlite3.column_text s 3;
    created_at=Sqlite3.column_text s 4; updated_at=Sqlite3.column_text s 5 }
  let find_by_id db id = one db (select ^ " WHERE messages.id=? LIMIT 1") [integer id] decode
  let find db id = find_by_id db id |> required "Message"
  let last db = one db (select ^ " ORDER BY messages.id DESC LIMIT 1") [] decode
  let count db = count_sql db "SELECT COUNT(*) FROM messages" []
  let by_creator db creator_id = q db (select ^ " WHERE messages.creator_id=?") [integer creator_id] decode
  let for_room db room_id = q db (select ^ " WHERE messages.room_id=?") [integer room_id] decode
  let find_in_room db room_id id = one db (select ^ " WHERE messages.room_id=? AND messages.id=? LIMIT 1")
    [integer room_id; integer id] decode |> required "Message"
  let count_in_room db room_id = count_sql db "SELECT COUNT(*) FROM messages WHERE room_id=?" [integer room_id]
  let find_reachable db user_id id = one db
    (select ^ " JOIN memberships ON messages.room_id=memberships.room_id WHERE memberships.user_id=? AND messages.id=? LIMIT 1")
    [integer user_id; integer id] decode |> required "Message"
  let last_page db room_id = q db (select ^ " WHERE messages.room_id=? ORDER BY messages.created_at DESC LIMIT 40")
    [integer room_id] decode |> List.rev
  let first_page db room_id = q db (select ^ " WHERE messages.room_id=? ORDER BY messages.created_at ASC LIMIT 40")
    [integer room_id] decode
  let page_before db room_id message = q db
    (select ^ " WHERE messages.room_id=? AND messages.created_at<? ORDER BY messages.created_at DESC LIMIT 40")
    [integer room_id; text message.created_at] decode |> List.rev
  let page_after db room_id message = q db
    (select ^ " WHERE messages.room_id=? AND messages.created_at>? ORDER BY messages.created_at ASC LIMIT 40")
    [integer room_id; text message.created_at] decode
  let page_around db room_id message = page_before db room_id message @ [message] @ page_after db room_id message
  let page_created_since db room_id time = q db
    (select ^ " WHERE messages.room_id=? AND messages.created_at>? ORDER BY messages.created_at ASC LIMIT 40")
    [integer room_id; text time] decode
  let page_updated_since db room_id time excluding =
    let without = if excluding=[] then "" else
      " AND messages.id NOT IN (" ^ Db_runtime.placeholders (List.length excluding) ^ ")" in
    q db (select ^ " WHERE messages.room_id=?" ^ without ^
          " AND messages.updated_at>? ORDER BY +messages.created_at DESC LIMIT 40")
      ([integer room_id] @ List.map integer excluding @ [text time]) decode |> List.rev
  let exists_before db room_id message = Option.is_some (one db
    "SELECT 1 FROM messages WHERE room_id=? AND created_at<? LIMIT 1"
    [integer room_id; text message.created_at] (fun _ -> ()))
  let exists_after db room_id message = Option.is_some (one db
    "SELECT 1 FROM messages WHERE room_id=? AND created_at>? LIMIT 1"
    [integer room_id; text message.created_at] (fun _ -> ()))
  let paged db room_id = Option.is_some (one db
    "SELECT 1 FROM messages WHERE room_id=? LIMIT 1 OFFSET 40" [integer room_id] (fun _ -> ()))
  let match_terms input =
    let white_space n =
      (n >= 0x0009 && n <= 0x000d) || n=0x0020 || n=0x0085 ||
      n=0x00a0 || n=0x1680 || (n >= 0x2000 && n <= 0x200a) ||
      n=0x2028 || n=0x2029 || n=0x202f || n=0x205f || n=0x3000 in
    let decoder = Uutf.decoder (`String input) in
    let words = ref [] and word = Buffer.create 16 in
    let flush () = if Buffer.length word > 0 then
      (words := Buffer.contents word :: !words; Buffer.clear word) in
    let rec read () = match Uutf.decode decoder with
      | `Uchar uchar ->
        let n = Uchar.to_int uchar in
        if n=0 || white_space n then flush () else Uutf.Buffer.add_utf_8 word uchar;
        read ()
      | `Malformed bytes -> Buffer.add_string word bytes; read ()
      | `End -> flush (); List.rev !words
      | `Await -> assert false in
    let terms = read () in
    terms |> List.filter ((<>) "") |> List.map (fun word ->
      "\"" ^ String.concat "\"\"" (String.split_on_char '"' word) ^ "\"")
    |> String.concat " "
  let search_in_room db room_id input = match match_terms input with
    | "" -> []
    | query -> q db (select ^ " JOIN message_search_index idx ON messages.id=idx.rowid WHERE messages.room_id=? AND idx.body MATCH ? ORDER BY messages.created_at ASC")
      [integer room_id; text query] decode
  let search_reachable_sql =
    "SELECT messages.id,messages.room_id,messages.creator_id,messages.client_message_id,messages.created_at,messages.updated_at,memberships.user_id IS NOT NULL FROM messages" ^
    " JOIN rooms ON messages.room_id=rooms.id LEFT JOIN memberships ON rooms.id=memberships.room_id AND memberships.user_id=? JOIN message_search_index idx ON messages.id=idx.rowid WHERE idx.body MATCH ? ORDER BY idx.rowid DESC LIMIT 1000"
  let search_reachable db user_id input = match match_terms input with
    | "" -> []
    | query ->
      let rows = q db search_reachable_sql
        [integer user_id; text query]
        (fun s -> decode s, Sqlite3.column_int s 6 <> 0) in
      let reachable = rows |> List.filter_map (fun (m, ok) -> if ok then Some m else None) in
      if List.length reachable >= 100 || List.length rows < 1000 then
        (reachable |> List.filteri (fun i _ -> i < 100) |> List.rev)
      else q db (select ^ " JOIN memberships ON messages.room_id=memberships.room_id JOIN message_search_index idx ON messages.id=idx.rowid WHERE memberships.user_id=? AND idx.body MATCH ? ORDER BY messages.id DESC LIMIT 100")
        [integer user_id; text query] decode |> List.rev
  let body db message = Rich_text_record.find_for db ~record_type:"Message" ~record_id:message.id ~name:"body"
  let body_html db message = Option.bind (body db message) (fun row -> row.body)
  let attachment_blob_id db message = one db
    "SELECT blob_id FROM active_storage_attachments WHERE record_type='Message' AND record_id=? AND name='attachment' LIMIT 1"
    [integer message.id] (fun s -> Sqlite3.column_int64 s 0)
  let attachment_filename db message = one db
    "SELECT b.filename FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id=a.blob_id WHERE a.record_type='Message' AND a.record_id=? AND a.name='attachment' LIMIT 1"
    [integer message.id] (fun s -> Sqlite3.column_text s 0)
  let plain_text_body ?(rich_text=basic_rich_text) db message =
    let body = body_html db message |> Option.map (rich_text.to_plain_text db) in
    match body with Some body when String.trim body <> "" -> body
    | _ -> Option.value ~default:"" (attachment_filename db message)
  let sound ?(rich_text=basic_rich_text) db message = sound_in (plain_text_body ~rich_text db message)
  let content_type ?(rich_text=basic_rich_text) db message =
    if Option.is_some (attachment_blob_id db message) then Attachment
    else if Option.is_some (sound ~rich_text db message) then Sound else Text
  let mentionees_in_room db room_id ids =
    if ids=[] then [] else
      let ids = List.sort_uniq Int64.compare ids in
      q db ("SELECT users.id,users.name,users.email_address,users.password_digest,users.role,users.status,users.bio,users.bot_token,users.created_at,users.updated_at FROM users JOIN memberships ON users.id=memberships.user_id WHERE memberships.room_id=? AND users.id IN (" ^ Db_runtime.placeholders (List.length ids) ^ ")")
        (integer room_id :: List.map integer ids) Db_accounts.User.decode
  let mentionees ?(rich_text=basic_rich_text) db message =
    let ids = match body_html db message with None -> [] | Some html -> rich_text.mentioned_user_ids db html in
    mentionees_in_room db message.room_id ids
  let room db message = Db_rooms.Room.find db message.room_id
  let creator db message = Db_accounts.User.find db message.creator_id
  let index_body ?(rich_text=basic_rich_text) db message = plain_text_body ~rich_text db message
  let insert_index ?(rich_text=basic_rich_text) db message =
    run db "INSERT INTO message_search_index(rowid,body) VALUES (?,?)"
      [integer message.id; text (index_body ~rich_text db message)]
  let update_index ?(rich_text=basic_rich_text) db message =
    run db "UPDATE message_search_index SET body=? WHERE rowid=?"
      [text (index_body ~rich_text db message); integer message.id]
  let touch ?(rich_text=basic_rich_text) tx ~now message =
    let db = Db_runtime.conn tx and stamp = now_string now in
    run db "UPDATE messages SET updated_at=? WHERE id=?" [text stamp; integer message.id];
    Db_rooms.Room.touch tx ~now message.room_id;
    Db_runtime.after_commit tx (fun tx -> update_index ~rich_text (Db_runtime.conn tx) (find (Db_runtime.conn tx) message.id));
    {message with updated_at=stamp}
  let create ?(rich_text=basic_rich_text) ?(on_push=(fun ~room_id:_ ~message_id:_ -> ())) tx ~now attrs =
    let db = Db_runtime.conn tx and stamp = now_string now in
    let client_message_id = Option.value ~default:(Db_accounts.uuid ()) attrs.client_message_id in
    Perf_probe.time "post_insert_message" (fun () ->
      run db "INSERT INTO messages (client_message_id,created_at,creator_id,room_id,updated_at) VALUES (?,?,?,?,?)"
        [text client_message_id; text stamp; integer attrs.creator_id; integer attrs.room_id; text stamp]);
    let id = Sqlite3.last_insert_rowid db in
    Perf_probe.time "post_insert_body" (fun () ->
      match attrs.body with None -> () | Some body ->
        ignore (Rich_text_record.create tx ~now ~record_type:"Message" ~record_id:id ~name:"body" ~body));
    (match attrs.attachment_blob_id with None -> () | Some blob_id ->
      run db "INSERT INTO active_storage_attachments (blob_id,created_at,name,record_id,record_type) VALUES (?,?,'attachment',?,'Message')"
        [integer blob_id; text stamp; integer id]);
    Perf_probe.time "post_touch_room" (fun () ->
      Db_rooms.Room.touch tx ~now attrs.room_id);
    let message = Perf_probe.time "post_find_message" (fun () -> find db id) in
    let index () = Perf_probe.time "post_insert_index" (fun () ->
      insert_index ~rich_text db message) in
    let receive () = Perf_probe.time "post_receive_room" (fun () ->
      Db_rooms.Room.receive tx ~now ~room_id:message.room_id ~message_id:message.id
        ~created_at:message.created_at ~creator_id:message.creator_id ~on_push) in
    Db_runtime.after_commit tx (fun _ -> index (); receive ());
    message
  let update_body ?(rich_text=basic_rich_text) tx ~now message html =
    let db = Db_runtime.conn tx in
    match body db message with
    | Some row when row.body=Some html -> message
    | existing ->
      (match existing with Some row -> ignore (Rich_text_record.update_body tx ~now row html)
       | None -> ignore (Rich_text_record.create tx ~now ~record_type:"Message" ~record_id:message.id ~name:"body" ~body:html));
      touch ~rich_text tx ~now message
  let replace_attachment ?(rich_text=basic_rich_text) ?(on_purge=(fun ~blob_id:_ -> ())) tx ~now message blob_id =
    let db = Db_runtime.conn tx in
    let changed = ref message in
    (match attachment_blob_id db message with None -> () | Some old_blob ->
      run db "DELETE FROM active_storage_attachments WHERE record_type='Message' AND record_id=? AND name='attachment'"
        [integer message.id];
      Db_runtime.emit_after_commit tx (fun () -> on_purge ~blob_id:old_blob);
      changed := touch ~rich_text tx ~now !changed);
    (match blob_id with None -> () | Some id ->
      run db "INSERT INTO active_storage_attachments (blob_id,created_at,name,record_id,record_type) VALUES (?,?,'attachment',?,'Message')"
        [integer id; text (now_string now); integer message.id];
      changed := touch ~rich_text tx ~now !changed);
    !changed
  let destroy ?(on_purge=(fun ~blob_id:_ -> ())) tx ~now message =
    let db = Db_runtime.conn tx in
    (match attachment_blob_id db message with None -> () | Some blob_id ->
      run db "DELETE FROM active_storage_attachments WHERE record_type='Message' AND record_id=? AND name='attachment'" [integer message.id];
      Db_runtime.emit_after_commit tx (fun () -> on_purge ~blob_id));
    run db "DELETE FROM boosts WHERE message_id=?" [integer message.id];
    run db "DELETE FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?" [integer message.id];
    run db "DELETE FROM messages WHERE id=?" [integer message.id];
    Db_rooms.Room.touch tx ~now message.room_id;
    Db_runtime.after_commit tx (fun tx ->
      run (Db_runtime.conn tx) "DELETE FROM message_search_index WHERE rowid=?" [integer message.id])
  let destroy_for_room ?on_purge tx ~now ~room_id =
    for_room (Db_runtime.conn tx) room_id |> List.iter (fun m -> destroy ?on_purge tx ~now m)
  let destroy_by_creator ?on_purge tx ~now ~creator_id =
    by_creator (Db_runtime.conn tx) creator_id |> List.iter (fun m -> destroy ?on_purge tx ~now m)
  let reload db message = find db message.id
end

module Boost = struct
  type t = { id:int64; message_id:int64; booster_id:int64; content:string;
             created_at:string; updated_at:string }
  let select = "SELECT id,message_id,booster_id,content,created_at,updated_at FROM boosts"
  let decode s = { id=Sqlite3.column_int64 s 0; message_id=Sqlite3.column_int64 s 1;
    booster_id=Sqlite3.column_int64 s 2; content=Sqlite3.column_text s 3;
    created_at=Sqlite3.column_text s 4; updated_at=Sqlite3.column_text s 5 }
  let find db id = one db (select ^ " WHERE id=? LIMIT 1") [integer id] decode |> required "Boost"
  let for_message db message_id = q db (select ^ " WHERE message_id=?") [integer message_id] decode
  let for_message_ordered db message_id = q db (select ^ " WHERE message_id=? ORDER BY created_at ASC") [integer message_id] decode
  let find_by_message_and_booster db message_id id booster_id = one db
    (select ^ " WHERE message_id=? AND id=? AND booster_id=? LIMIT 1")
    [integer message_id; integer id; integer booster_id] decode |> required "Boost"
  let create ?rich_text tx ~now ~message_id ~booster_id ~content =
    let db = Db_runtime.conn tx and stamp = now_string now in
    run db "INSERT INTO boosts (booster_id,content,created_at,message_id,updated_at) VALUES (?,?,?,?,?)"
      [integer booster_id; text content; text stamp; integer message_id; text stamp];
    let id = Sqlite3.last_insert_rowid db in
    ignore (Message.touch ?rich_text tx ~now (Message.find db message_id));
    find db id
  let destroy ?rich_text tx ~now boost =
    let db = Db_runtime.conn tx in
    run db "DELETE FROM boosts WHERE id=?" [integer boost.id];
    ignore (Message.touch ?rich_text tx ~now (Message.find db boost.message_id))
end

let boosts db message = Boost.for_message_ordered db message.Message.id

module Search = struct
  type t = { id:int64; user_id:int64; query:string; created_at:string; updated_at:string }
  let recent_searches = 10
  let select = "SELECT id,user_id,query,created_at,updated_at FROM searches"
  let decode s = { id=Sqlite3.column_int64 s 0; user_id=Sqlite3.column_int64 s 1;
    query=Sqlite3.column_text s 2; created_at=Sqlite3.column_text s 3;
    updated_at=Sqlite3.column_text s 4 }
  let ordered_for_user db user_id = q db (select ^ " WHERE user_id=? ORDER BY updated_at DESC") [integer user_id] decode
  let count db = count_sql db "SELECT COUNT(*) FROM searches" []
  let count_for_user db user_id = count_sql db "SELECT COUNT(*) FROM searches WHERE user_id=?" [integer user_id]
  let record tx ~now ~user_id ~query =
    let db = Db_runtime.conn tx and stamp = now_string now in
    let existing = one db (select ^ " WHERE user_id=? AND query=? LIMIT 1")
      [integer user_id; text query] decode in
    let id = match existing with
      | Some search -> search.id
      | None ->
        run db "INSERT INTO searches (created_at,query,updated_at,user_id) VALUES (?,?,?,?)"
          [text stamp; text query; text stamp; integer user_id];
        let id = Sqlite3.last_insert_rowid db in
        run db "DELETE FROM searches WHERE user_id=? AND id NOT IN (SELECT id FROM searches WHERE user_id=? ORDER BY updated_at DESC LIMIT 10)"
          [integer user_id; integer user_id]; id in
    run db "UPDATE searches SET updated_at=? WHERE id=?" [text stamp; integer id];
    one db (select ^ " WHERE id=?") [integer id] decode |> required "Search"
  let destroy_all_for_user tx user_id =
    run (Db_runtime.conn tx) "DELETE FROM searches WHERE user_id=?" [integer user_id]
end

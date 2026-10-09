(** The less frequently accessed Rails models. All mutations are made through
    [Db_runtime.tx], and event delivery is delegated to the application. *)

let i n = Sqlite3.Data.INT n
let s value = Sqlite3.Data.TEXT value
let opt f = function None -> Sqlite3.Data.NULL | Some value -> f value
let col_opt row n = match Sqlite3.column row n with
  | Sqlite3.Data.NULL -> None | _ -> Some (Sqlite3.column_text row n)
let one = Db_runtime.query_one
let all = Db_runtime.query_all
let run db sql params = ignore (Db_runtime.execute db sql params)
let required name = function Some value -> value | None -> failwith (name ^ " not found")
let db = Db_runtime.conn
let stamp = Db_time.to_db

module Event = struct
  type t =
    | PushMessage of { room_id : int64; message_id : int64 }
    | DisconnectUser of { user_id : int64; reconnect : bool }
    | RemoveBannedContent of { user_id : int64 }
    | DeliverWebhook of { bot_id : int64; message_id : int64 }
    | PurgeBlob of { blob_id : int64 }
  type sink = t -> unit
  let after_commit tx sink event = Db_runtime.emit_after_commit tx (fun () -> sink event)
  let on_push sink ~room_id ~message_id = sink (PushMessage {room_id;message_id})
  let on_disconnect sink ~user_id ~reconnect = sink (DisconnectUser {user_id;reconnect})
  let on_remove_content sink ~user_id = sink (RemoveBannedContent {user_id})
  let on_delivery sink ~bot_id ~message_id = sink (DeliverWebhook {bot_id;message_id})
  let on_purge sink ~blob_id = sink (PurgeBlob {blob_id})
end

module Blob = struct
  type t = { id:int64; key:string; filename:string; content_type:string option;
             metadata:string option; service_name:string; byte_size:int64;
             checksum:string option; created_at:string }
  let select = "SELECT id,key,filename,content_type,metadata,service_name,byte_size,checksum,created_at FROM active_storage_blobs"
  let decode row = { id=Sqlite3.column_int64 row 0; key=Sqlite3.column_text row 1;
    filename=Sqlite3.column_text row 2; content_type=col_opt row 3;
    metadata=col_opt row 4; service_name=Sqlite3.column_text row 5;
    byte_size=Sqlite3.column_int64 row 6; checksum=col_opt row 7;
    created_at=Sqlite3.column_text row 8 }
  let find db id = one db (select ^ " WHERE id=? LIMIT 1") [i id] decode |> required "ActiveStorage::Blob"
  let create tx ~now blob =
    let conn = db tx in
    run conn "INSERT INTO active_storage_blobs (byte_size,checksum,content_type,created_at,filename,key,metadata,service_name) VALUES (?,?,?,?,?,?,?,?)"
      [i blob.byte_size;opt s blob.checksum;opt s blob.content_type;s (stamp now);
       s blob.filename;s blob.key;opt s blob.metadata;s blob.service_name];
    find conn (Sqlite3.last_insert_rowid conn)
  let attachments db blob = all db
    "SELECT id FROM active_storage_attachments WHERE blob_id=?" [i blob.id]
    (fun row -> Sqlite3.column_int64 row 0)
  let variant_records db blob = all db
    "SELECT id FROM active_storage_variant_records WHERE blob_id=?" [i blob.id]
    (fun row -> Sqlite3.column_int64 row 0)
  (* Database half of purge. M6 deletes the disk object after commit. *)
  let destroy tx blob =
    let conn = db tx in
    if attachments conn blob <> [] then invalid_arg "blob is attached";
    run conn "DELETE FROM active_storage_variant_records WHERE blob_id=?" [i blob.id];
    run conn "DELETE FROM active_storage_blobs WHERE id=?" [i blob.id]
end

module Attachment = struct
  type t = { id:int64; name:string; record_type:string; record_id:int64;
             blob_id:int64; created_at:string }
  let select = "SELECT id,name,record_type,record_id,blob_id,created_at FROM active_storage_attachments"
  let decode row = { id=Sqlite3.column_int64 row 0; name=Sqlite3.column_text row 1;
    record_type=Sqlite3.column_text row 2; record_id=Sqlite3.column_int64 row 3;
    blob_id=Sqlite3.column_int64 row 4; created_at=Sqlite3.column_text row 5 }
  let find_for db ~record_type ~record_id ~name = one db
    (select ^ " WHERE record_id=? AND record_type=? AND name=? LIMIT 1")
    [i record_id;s record_type;s name] decode
  let create tx ~now ~record_type ~record_id ~name ~blob_id =
    let conn = db tx in
    run conn "INSERT INTO active_storage_attachments (blob_id,created_at,name,record_id,record_type) VALUES (?,?,?,?,?)"
      [i blob_id;s (stamp now);s name;i record_id;s record_type];
    one conn (select ^ " WHERE id=?") [i (Sqlite3.last_insert_rowid conn)] decode |> required "ActiveStorage::Attachment"
  let delete tx attachment = run (db tx) "DELETE FROM active_storage_attachments WHERE id=?" [i attachment.id]
  let blob db attachment = Blob.find db attachment.blob_id
end

module Variant_record = struct
  type t = { id:int64; blob_id:int64; variation_digest:string }
  let select = "SELECT id,blob_id,variation_digest FROM active_storage_variant_records"
  let decode row = {id=Sqlite3.column_int64 row 0;blob_id=Sqlite3.column_int64 row 1;
    variation_digest=Sqlite3.column_text row 2}
  let find db id = one db (select ^ " WHERE id=? LIMIT 1") [i id] decode |> required "ActiveStorage::VariantRecord"
  let find_for db ~blob_id ~variation_digest = one db
    (select ^ " WHERE blob_id=? AND variation_digest=? LIMIT 1")
    [i blob_id;s variation_digest] decode
  let create tx ~blob_id ~variation_digest =
    let conn=db tx in
    run conn "INSERT INTO active_storage_variant_records (blob_id,variation_digest) VALUES (?,?)"
      [i blob_id;s variation_digest];
    find conn (Sqlite3.last_insert_rowid conn)
  let delete tx row = run (db tx) "DELETE FROM active_storage_variant_records WHERE id=?" [i row.id]
end

module Ban = struct
  type t = { id:int64; user_id:int64; ip_address:string; created_at:string; updated_at:string }
  let decode row = {id=Sqlite3.column_int64 row 0;user_id=Sqlite3.column_int64 row 1;
    ip_address=Sqlite3.column_text row 2;created_at=Sqlite3.column_text row 3;
    updated_at=Sqlite3.column_text row 4}
  let select = "SELECT id,user_id,ip_address,created_at,updated_at FROM bans"
  let banned db ip_address = Option.is_some (one db
    "SELECT 1 FROM bans WHERE ip_address=? LIMIT 1" [s ip_address] (fun _ -> ()))
  let for_user db user_id = all db (select ^ " WHERE user_id=?") [i user_id] decode
  let octet text n = Char.code text.[n]
  let valid_ip input =
    let address,prefix = match String.split_on_char '/' input with
      | [address] -> address,None
      | [address;prefix] -> address,Some prefix
      | _ -> "",Some "invalid" in
    let address = if String.starts_with ~prefix:"[" address && String.ends_with ~suffix:"]" address
      then String.sub address 1 (String.length address-2) else address in
    match Ipaddr.of_string address with
    | Error _ -> None
    | Ok ip ->
      let maxbits = match ip with Ipaddr.V4 _ -> 32 | Ipaddr.V6 _ -> 128 in
      let bits = match prefix with
        | None -> Some maxbits
        | Some value when value<>"" && String.for_all (function '0'..'9' -> true | _ -> false) value ->
          int_of_string_opt value
        | Some _ -> None in
      match bits with
      | None -> None
      | Some bits when bits < 0 || bits > maxbits -> None
      | Some bits ->
        let octets=Ipaddr.to_octets ip |> Bytes.of_string in
        for n=0 to Bytes.length octets-1 do
          let remain=bits-(n*8) in
          let mask=if remain>=8 then 255 else if remain<=0 then 0 else (255 lsl (8-remain)) land 255 in
          Bytes.set octets n (Char.chr ((Char.code (Bytes.get octets n)) land mask))
        done;
        Some (ip,Bytes.to_string octets)
  let internal input = match valid_ip input with
    | None -> None
    | Some (ip,octets) ->
      let mapped = match ip with
        | Ipaddr.V4 _ -> false
        | Ipaddr.V6 _ -> octet octets 10=255 && octet octets 11=255 in
      let offset = if mapped then 12 else 0 in
      let v4 = match ip with Ipaddr.V4 _ -> true | Ipaddr.V6 _ -> mapped in
      let a=octet octets offset and b=octet octets (offset+1) in
      let private_v4 = a=10 || (a=172 && b>=16 && b<=31) || (a=192 && b=168) in
      let loopback_v4 = a=127 and link_local_v4 = a=169 && b=254 in
      let ipv6_internal = match ip with
        | Ipaddr.V4 _ -> false
        | Ipaddr.V6 _ ->
          (octet octets 0 land 254 = 252) ||
          (octet octets 0=254 && octet octets 1 land 192=128) ||
          (octets=String.make 15 '\000' ^ "\001") in
      Some ((v4 && (private_v4 || loopback_v4 || link_local_v4)) || ipv6_internal)
  let validate input = match internal input with
    | None -> ["ip_address","is not a valid IP address"]
    | Some true -> ["ip_address","cannot be a private or internal IP address"]
    | Some false -> []
  let create tx ~now ~user_id ~ip_address =
    (match validate ip_address with [] -> () | (_,message)::_ -> invalid_arg ("ip_address " ^ message));
    let conn=db tx and now=stamp now in
    run conn "INSERT INTO bans (created_at,ip_address,updated_at,user_id) VALUES (?,?,?,?)"
      [s now;s ip_address;s now;i user_id];
    one conn (select ^ " WHERE id=?") [i (Sqlite3.last_insert_rowid conn)] decode |> required "Ban"
  let create_ban_callback ~now tx user_id ip_address =
    ignore (create tx ~now ~user_id ~ip_address)
end

module Push_subscription = struct
  type t = { id:int64; user_id:int64; endpoint:string option; p256dh_key:string option;
             auth_key:string option; user_agent:string option; created_at:string; updated_at:string }
  type payload = { title:string; body:string; path:string }
  let permitted_endpoint_hosts = ["jmt17.google.com";"fcm.googleapis.com";
    "updates.push.services.mozilla.com";"web.push.apple.com";"notify.windows.com"]
  let max_payload_title_bytes = 256
  let max_payload_body_bytes = 3072
  let select = "SELECT id,user_id,endpoint,p256dh_key,auth_key,user_agent,created_at,updated_at FROM push_subscriptions"
  let decode row = {id=Sqlite3.column_int64 row 0;user_id=Sqlite3.column_int64 row 1;
    endpoint=col_opt row 2;p256dh_key=col_opt row 3;auth_key=col_opt row 4;
    user_agent=col_opt row 5;created_at=Sqlite3.column_text row 6;
    updated_at=Sqlite3.column_text row 7}
  let new_ ~user_id ~endpoint ~p256dh_key ~auth_key ~user_agent =
    {id=0L;user_id;endpoint;p256dh_key;auth_key;user_agent;created_at="";updated_at=""}
  let find db id = one db (select ^ " WHERE id=? LIMIT 1") [i id] decode |> required "Push::Subscription"
  let count db = one db "SELECT COUNT(*) FROM push_subscriptions" []
    (fun row -> Sqlite3.column_int64 row 0) |> Option.get
  let for_user db user_id = all db (select ^ " WHERE user_id=?") [i user_id] decode
  let find_for_user_by_keys db ~user_id ~endpoint ~p256dh_key ~auth_key = one db
    (select ^ " WHERE user_id=? AND endpoint=? AND p256dh_key=? AND auth_key=? LIMIT 1")
    [i user_id;s endpoint;s p256dh_key;s auth_key] decode
  let permitted_host host =
    let host=String.lowercase_ascii host in
    List.exists (fun allowed -> host=allowed || String.ends_with ~suffix:("."^allowed) host)
      permitted_endpoint_hosts
  let parsed_endpoint endpoint =
    if endpoint="" || String.exists (function ' '| '\t'|'\r'|'\n' -> true | _ -> false) endpoint
    then None else
    try
      let uri=Uri.of_string endpoint in
      match Uri.scheme uri,Uri.host uri with
      | Some scheme,Some host when host<>"" && String.contains endpoint ':' ->
        let authority =
          let marker="://" in
          let start=match String.index_opt endpoint ':' with
            | Some n when String.length endpoint>=n+3 &&
              String.sub endpoint n 3=marker -> n+3
            | _ -> raise Exit in
          let stop=ref start in
          while !stop<String.length endpoint &&
            not (List.mem endpoint.[!stop] ['/';'?';'#']) do incr stop done;
          String.sub endpoint start (!stop-start) in
        let authority=match String.rindex_opt authority '@' with
          | None -> authority
          | Some n -> String.sub authority (n+1) (String.length authority-n-1) in
        let port=if String.ends_with ~suffix:"]" authority then None else
          match String.rindex_opt authority ':' with
          | None -> None
          | Some n ->
            let value=String.sub authority (n+1) (String.length authority-n-1) in
            if value="" || not (String.for_all (function '0'..'9' -> true | _ -> false) value)
            then raise Exit;
            let parsed=int_of_string value in
            if parsed>65535 then raise Exit else Some parsed in
        let port=match port with
          | Some _ -> port
          | None when String.lowercase_ascii scheme="https" -> Some 443
          | None when String.lowercase_ascii scheme="http" -> Some 80
          | None -> None in
        Some (String.lowercase_ascii scheme,host,port)
      | _ -> None
    with _ -> None
  let resolved_endpoint_ip subscription resolve =
    match Option.bind subscription.endpoint parsed_endpoint with
    | Some ("https",host,(None|Some 443)) when permitted_host host -> resolve host
    | _ -> None
  let validate subscription resolve =
    let endpoint=Option.value ~default:"" subscription.endpoint in
    let blank=String.trim endpoint="" in
    let errors=if blank then ["endpoint","can't be blank"] else [] in
    let error=match parsed_endpoint endpoint with
      | None -> Some "is not a valid URL"
      | Some (scheme,_,_) when scheme<>"https" -> Some "must use HTTPS"
      | Some (_,_,Some port) when port<>443 -> Some "must use the default HTTPS port"
      | Some (_,host,_) when not (permitted_host host) -> Some "is not a permitted push service"
      | Some _ when resolved_endpoint_ip subscription resolve=None ->
        Some "resolves to a private or invalid IP address"
      | Some _ -> None in
    match error with None -> errors | Some message -> errors @ ["endpoint",message]
  let create tx ~now ~resolve subscription =
    (match validate subscription resolve with [] -> () | (_,message)::_ -> invalid_arg ("endpoint " ^ message));
    let conn=db tx and at=stamp now in
    run conn "INSERT INTO push_subscriptions (auth_key,created_at,endpoint,p256dh_key,updated_at,user_agent,user_id) VALUES (?,?,?,?,?,?,?)"
      [opt s subscription.auth_key;s at;opt s subscription.endpoint;
       opt s subscription.p256dh_key;s at;opt s subscription.user_agent;i subscription.user_id];
    find conn (Sqlite3.last_insert_rowid conn)
  let destroy tx subscription = run (db tx) "DELETE FROM push_subscriptions WHERE id=?" [i subscription.id]
  let destroy_by_endpoint tx ~user_id ~endpoint = run (db tx)
    "DELETE FROM push_subscriptions WHERE endpoint=? AND user_id=?" [s endpoint;i user_id]
  let badge subscription db = Db_rooms.Membership.unread_count db subscription.user_id
  let json_len uchar = match Uchar.to_int uchar with
    | 34|92|10|13|9|8|12 -> 2
    | n when n<32 -> 6
    | n when n<128 -> 1
    | n when n<2048 -> 2
    | n when n<65536 -> 3
    | _ -> 4
  let truncate_json_string value max_bytes =
    let decoder=Uutf.decoder (`String value) in
    let chars=ref [] and total=ref 0 in
    let rec collect () = match Uutf.decode decoder with
      | `Uchar uchar -> chars := uchar :: !chars; total := !total + json_len uchar; collect ()
      | `Malformed _ -> chars := Uchar.rep :: !chars; total := !total+3; collect ()
      | `End -> List.rev !chars
      | `Await -> assert false in
    let chars=collect () in
    if !total<=max_bytes then value else
      let out=Buffer.create max_bytes in
      let rec take used = function
        | uchar::rest when used+json_len uchar+3<=max_bytes ->
          Uutf.Buffer.add_utf_8 out uchar; take (used+json_len uchar) rest
        | _ -> Buffer.add_string out "…" in
      take 0 chars;
      Buffer.contents out
  let payload_for ?(rich_text=Db_messages.basic_rich_text) db
      (room:Db_rooms.Room.t) (message:Db_messages.Message.t) =
    let creator=Db_accounts.User.find db message.creator_id in
    let body=Db_messages.Message.plain_text_body ~rich_text db message in
    let title,body=if Db_rooms.Room.direct room then creator.name,body else
      Option.value ~default:"" room.name,creator.name ^ ": " ^ body in
    {title=truncate_json_string title max_payload_title_bytes;
     body=truncate_json_string body max_payload_body_bytes;
     path="/rooms/" ^ Int64.to_string room.id}
  let recipient_query involvement mentionee_ids =
    let suffix=if mentionee_ids=[] then "" else
      " AND push_subscriptions.user_id IN (" ^ Db_runtime.placeholders (List.length mentionee_ids) ^ ")" in
    "SELECT push_subscriptions.id,push_subscriptions.user_id,push_subscriptions.endpoint," ^
    "push_subscriptions.p256dh_key,push_subscriptions.auth_key," ^
    "push_subscriptions.user_agent,push_subscriptions.created_at," ^
    "push_subscriptions.updated_at FROM push_subscriptions" ^
    " INNER JOIN users ON users.id=push_subscriptions.user_id" ^
    " INNER JOIN memberships ON memberships.user_id=users.id" ^
    " WHERE (memberships.connected_at IS NULL OR memberships.connected_at<?)" ^
    " AND memberships.room_id=? AND memberships.user_id!=?" ^
    " AND memberships.involvement='" ^ involvement ^ "'" ^ suffix
  let for_users_involved_in_everything db ~room_id ~creator_id ~now =
    all db (recipient_query "everything" [])
      [s (Db_rooms.Membership.cutoff now);i room_id;i creator_id] decode
  let for_mentioned_users db ~room_id ~creator_id ~mentionee_ids ~now =
    if mentionee_ids=[] then [] else
    all db (recipient_query "mentions" mentionee_ids)
      ([s (Db_rooms.Membership.cutoff now);i room_id;i creator_id] @ List.map i mentionee_ids) decode
  let pushes_for ?(rich_text=Db_messages.basic_rich_text) db
      (message:Db_messages.Message.t) ~now =
    let room=Db_rooms.Room.find db message.Db_messages.Message.room_id in
    let payload=payload_for ~rich_text db room message in
    let everything=for_users_involved_in_everything db ~room_id:room.id
      ~creator_id:message.creator_id ~now in
    let mentionee_ids=Db_messages.Message.mentionees ~rich_text db message
      |> List.map (fun user -> user.Db_accounts.User.id) in
    let mentions=for_mentioned_users db ~room_id:room.id ~creator_id:message.creator_id
      ~mentionee_ids ~now in
    payload,everything,mentions
end

module Webhook = struct
  type t = { id:int64; user_id:int64; url:string option; created_at:string; updated_at:string }
  type payload = { user_id:int64; user_name:string; room_id:int64;
    room_name:string option; room_path:string; message_id:int64;
    body_html:string option; body_plain:string; message_path:string }
  let endpoint_timeout_seconds = 7
  let select = "SELECT id,user_id,url,created_at,updated_at FROM webhooks"
  let decode row = {id=Sqlite3.column_int64 row 0;user_id=Sqlite3.column_int64 row 1;
    url=col_opt row 2;created_at=Sqlite3.column_text row 3;
    updated_at=Sqlite3.column_text row 4}
  let find_by_user db user_id = one db (select ^ " WHERE user_id=? LIMIT 1") [i user_id] decode
  let create tx ~now ~user_id ~url =
    let conn=db tx and at=stamp now in
    run conn "INSERT INTO webhooks (created_at,updated_at,url,user_id) VALUES (?,?,?,?)"
      [s at;s at;opt s url;i user_id];
    one conn (select ^ " WHERE id=?") [i (Sqlite3.last_insert_rowid conn)] decode |> required "Webhook"
  let update_url tx ~now webhook url =
    if webhook.url=Some url then webhook else (
      let conn=db tx and at=stamp now in
      run conn "UPDATE webhooks SET updated_at=?,url=? WHERE id=?" [s at;s url;i webhook.id];
      {webhook with url=Some url;updated_at=at})
  let destroy tx webhook = run (db tx) "DELETE FROM webhooks WHERE id=?" [i webhook.id]
  let whitespace uchar =
    let n=Uchar.to_int uchar in
    (n>=9 && n<=13) || List.mem n [32;133;160;5760;8232;8233;8239;8287;12288] ||
    (n>=8192 && n<=8202)
  let unicode_trim value =
    let decoder=Uutf.decoder (`String value) in
    let rec decode acc = match Uutf.decode decoder with
      | `Uchar uchar -> decode (uchar::acc)
      | `Malformed _ -> decode (Uchar.rep::acc)
      | `End -> List.rev acc
      | `Await -> assert false in
    let rec drop = function uchar::rest when whitespace uchar -> drop rest | xs -> xs in
    let chars=decode [] |> drop |> List.rev |> drop |> List.rev in
    let out=Buffer.create (String.length value) in
    List.iter (Uutf.Buffer.add_utf_8 out) chars;
    Buffer.contents out
  let payload ?(rich_text=Db_messages.basic_rich_text) (webhook:t) db
      (message:Db_messages.Message.t)
      ~room_bot_messages_path ~message_path =
    let creator=Db_accounts.User.find db message.creator_id in
    let room=Db_rooms.Room.find db message.Db_messages.Message.room_id in
    let recipient=Db_accounts.User.find db webhook.user_id in
    let plain=Db_messages.Message.plain_text_body ~rich_text db message in
    let mention=Db_accounts.User.attachable_plain_text_representation recipient in
    let plain=Db_messages.replace_all plain mention "" |> unicode_trim in
    {user_id=creator.id;user_name=creator.name;room_id=room.id;room_name=room.name;
     room_path=room_bot_messages_path;message_id=message.id;
     body_html=Db_messages.Message.body_html db message;
     body_plain=plain;message_path}
  let payload_json payload =
    Rails_format.generate (`Assoc [
      "user",`Assoc ["id",`Intlit (Int64.to_string payload.user_id);"name",`String payload.user_name];
      "room",`Assoc ["id",`Intlit (Int64.to_string payload.room_id);
        "name",(match payload.room_name with None -> `Null | Some name -> `String name);
        "path",`String payload.room_path];
      "message",`Assoc ["id",`Intlit (Int64.to_string payload.message_id);
        "body",`Assoc ["html",(match payload.body_html with None -> `Null | Some html -> `String html);
          "plain",`String payload.body_plain];"path",`String payload.message_path]])
end

(** Typed entry points for the callback arguments in the hot M2 models. The
    models arrange commit timing; these functions only translate event shapes. *)
module Hooks = struct
  let message_attachment db (message:Db_messages.Message.t) =
    match Attachment.find_for db ~record_type:"Message" ~record_id:message.id
      ~name:"attachment" with
    | None -> None
    | Some attachment -> Some (attachment, Attachment.blob db attachment)
  let create_message ?rich_text tx ~now ~sink attrs =
    Db_messages.Message.create ?rich_text ~on_push:(Event.on_push sink) tx ~now attrs
  let replace_message_attachment ?rich_text tx ~now ~sink message blob_id =
    Db_messages.Message.replace_attachment ?rich_text ~on_purge:(Event.on_purge sink)
      tx ~now message blob_id
  let destroy_message tx ~now ~sink message =
    Db_messages.Message.destroy ~on_purge:(Event.on_purge sink) tx ~now message
  let destroy_messages_for_room tx ~now ~sink ~room_id =
    Db_messages.Message.destroy_for_room ~on_purge:(Event.on_purge sink)
      tx ~now ~room_id
  let destroy_messages_by_creator tx ~now ~sink ~creator_id =
    Db_messages.Message.destroy_by_creator ~on_purge:(Event.on_purge sink)
      tx ~now ~creator_id
  let remove_banned_content tx ~now ~sink (user:Db_accounts.User.t) =
    let messages = Db_messages.Message.by_creator (Db_runtime.conn tx) user.id in
    List.iter (Db_messages.Message.destroy ~on_purge:(Event.on_purge sink) tx ~now)
      messages;
    messages
  let ban_user tx ~now ~sink user =
    Db_accounts.User.ban_tx tx ~now
      ~create_ban:(Ban.create_ban_callback ~now:(Db_accounts.now_time now))
      ~on_disconnect:(Event.on_disconnect sink)
      ~on_remove_content:(Event.on_remove_content sink) user
  let deactivate_user tx ~now ~sink user =
    Db_accounts.User.deactivate_tx tx ~now
      ~on_disconnect:(Event.on_disconnect sink) user
  let reset_remote_connections tx ~sink user =
    Db_accounts.User.reset_remote_connections tx
      ~on_disconnect:(Event.on_disconnect sink) user
  let deliver_webhook_later tx ~message_id ~sink bot =
    Db_accounts.User.deliver_webhook_later tx ~message_id
      ~on_delivery:(Event.on_delivery sink) bot
  let revoke_from tx room user_ids ~sink =
    Db_rooms.revoke_from tx room user_ids
      ~on_disconnect:(Event.on_disconnect sink)
  let revise tx room ~granted ~revoked ~sink =
    Db_rooms.revise tx room ~granted ~revoked
      ~on_disconnect:(Event.on_disconnect sink)
end

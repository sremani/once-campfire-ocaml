(** Application handlers for the bounded job runner. Network deliveries run on
    job or push workers; SQLite mutations use the database writer. *)

type t = {
  jobs : Jobs.t;
  push_pool : Web_push.pool option;
  cable : Cable_channels.t;
}

let current : t option ref = ref None

let now () = Http_app.now_utc ()
let now_time () = Db_accounts.now_time (now ())
let i64 = Int64.to_string

let avatar_path ~secret_key_base (user:Db_accounts.User.t) =
  let signed=Signed_id.generate ~secret_key_base ~model:"User"
    ~id:(Int64.to_int user.id) ~purpose:(Some "avatar") ~expires_at:None in
  let version=View_presenter.timestamp_number user.updated_at in
  "/users/"^signed^"/avatar?v="^version

let mention_resolver ~secret_key_base db raw =
  match Global_id.locate_signed ~secret_key_base ~raw ~purpose:"attachable"
    ~now:(now ()) () with
  | Some gid when gid.Global_id.model_name="User" ->
    (match Int64.of_string_opt gid.id with
     | None -> None
     | Some id -> Option.map (fun (user:Db_accounts.User.t) ->
         {Rich_text.id=user.id;name=user.name;title=user.name;
          attachable_sgid=raw;user_path="/users/"^i64 user.id;
          avatar_path=avatar_path ~secret_key_base user})
         (Db_accounts.User.find_by_id db id))
  | _ -> None

let rich_text ~secret_key_base = Rich_text.db_adapter ~resolve_sgid:(fun db ->
  mention_resolver ~secret_key_base db)

let detached_user ~secret_key_base (user:Db_accounts.User.t) : Views.user =
  let role=match user.role with
    | Db_accounts.User.Member -> "member"
    | Administrator -> "administrator" | Bot -> "bot" in
  {id=user.id;name=user.name;title=Db_accounts.User.title user;
   avatar_url=avatar_path ~secret_key_base user;role}

let detached_message ~secret_key_base db room (message:Db_messages.Message.t) : Views.message =
  let creator=Db_accounts.User.find db message.creator_id
    |> detached_user ~secret_key_base in
  let boosts=Db_messages.Boost.for_message_ordered db message.id
    |> List.map (fun (boost:Db_messages.Boost.t) ->
      let booster=Db_accounts.User.find db boost.booster_id
        |> detached_user ~secret_key_base in
      {Views.id=boost.id;message_id=boost.message_id;
       content=boost.content;
       all_emoji=View_presenter.all_emoji boost.content;booster}) in
  let raw_body=Option.value ~default:"" (Db_messages.Message.body_html db message) in
  let editable_body=match Rich_text.editable_value
      ~resolve_sgid:(mention_resolver ~secret_key_base db) raw_body with
    | Ok (Some body) -> body | _ -> raw_body in
  let content=match Db_messages.Message.attachment_blob_id db message with
    | Some blob_id ->
      let blob=Db_remaining.Blob.find db blob_id in
      let path=Storage_blob.blob_path "redirect" ~secret_key_base blob () in
      let download_path=Storage_blob.blob_path "redirect" ~secret_key_base
        blob ~disposition:"attachment" () in
      let content_type=Option.value ~default:"" blob.content_type in
      let is_video=String.starts_with ~prefix:"video" content_type in
      let variation=if is_video then Some [
        "format",Storage_variation.Symbol "webp";
        "resize_to_limit",Storage_variation.Array [
          Storage_variation.Int 1200L;Storage_variation.Int 800L]]
        else if Storage_image.is_variable blob then
          Some (Storage_image.variation_for blob
            (Storage_variation.resize_to_limit 1200 800))
        else None in
      let preview_url=Option.map (Storage_blob.representation_path "redirect"
        ~secret_key_base blob) variation in
      let attachment : Views.attachment={filename=blob.filename;
        blob_path=path;download_path;preview_url} in
      (match preview_url with
       | None -> Views.Attachment attachment
       | Some preview_url ->
           let width,height=View_presenter.media_dimensions blob in
           Views.Media_attachment (attachment,
             {preview_url;is_video;width;height}))
    | None -> (match Db_messages.Message.sound db message with
    | Some sound -> Views.Rich_sound {
        url=Assets.asset_path (Db_messages.Sound.asset_path sound);
        image=Option.map (fun (image:Db_messages.Sound.image) ->
          Assets.asset_path ("sounds/" ^ image.file),
          image.width,image.height) sound.image;
        text=sound.text}
    | None ->
      let html=Option.value ~default:"" (Db_messages.Message.body_html db message) in
      let presented=Rich_text.present_message
        ~resolve_sgid:(mention_resolver ~secret_key_base db) html in
      Views.Text (Views.trusted_html_of_sanitized
        presented)) in
  {Views.id=message.id;client_message_id=message.client_message_id;
   room_id=message.room_id;room_name=Option.value room.Db_rooms.Room.name ~default:"";
   creator;created_at_iso=View_presenter.iso_time message.created_at;
   created_at_ms=View_presenter.milliseconds message.created_at;
   updated_at_ms=View_presenter.milliseconds message.updated_at;
   all_emoji=false;content;editable_body;boosts}

let broadcast_create ~secret_key_base cable runtime room message =
  let view,member_ids=Db_runtime.read runtime (fun db ->
    detached_message ~secret_key_base db room message,
    Db_rooms.Room.user_ids db room) in
  Cable_broadcasts.message_create cable ~room ~message ~member_ids
    ~html:(Views.message_item view |> Views.render)

let webhook_delivery url payload =
  Lwt_preemptive.run_in_main (fun () -> Webhook.deliver url payload)

let save_attachment runtime storage (attachment:Webhook.attachment) =
  let path,channel=Filename.open_temp_file "campfire-webhook" ".attachment" in
  Fun.protect ~finally:(fun () ->
    close_out_noerr channel;
    if Sys.file_exists path then Sys.remove path) (fun () ->
    output_string channel attachment.data;
    close_out channel;
    Storage_blob.create_and_upload runtime storage ~source:path
      ~filename:attachment.filename ~content_type:(Some attachment.content_type)
      ~now:(now_time ()))

let start ?(resolve=(fun host -> match Network_guard.resolve host with
    | Ok ip -> Some (Ipaddr.to_string ip) | Error _ -> None))
    ?(outbound=Outbound_http.web_push_outbound)
    ?(deliver_webhook=webhook_delivery)
    ~config ~runtime ~storage ~cable () =
  let push_pool=match Web_push_vapid.from_options
    ~subject:config.Config.vapid_subject
    ~public_key:config.vapid_public_key ~private_key:config.vapid_private_key with
    | Error _ -> None
    | Ok vapid -> Some (Web_push.create_pool ~resolve ~outbound ~vapid
        ~invalidate:(fun id ->
          Db_runtime.write runtime (fun tx ->
            let db=Db_runtime.conn tx in
            match Db_runtime.query_one db
              (Db_remaining.Push_subscription.select^" WHERE id=? LIMIT 1")
              [Sqlite3.Data.INT id] Db_remaining.Push_subscription.decode with
            | None -> ()
            | Some subscription -> Db_remaining.Push_subscription.destroy tx subscription)) ()) in
  let sink=ref (fun (_:Db_remaining.Event.t) -> ()) in
  let rich_text=rich_text ~secret_key_base:config.secret_key_base in
  let on_push ~room_id:_ ~message_id = match push_pool with
    | None -> ()
    | Some pool -> Db_runtime.read runtime (fun db ->
        let message=Db_messages.Message.find db message_id in
        ignore (Web_push.push_message ~rich_text pool db message ~now:(now ()))) in
  let on_remove_banned ~user_id =
    let messages=Db_runtime.read runtime (fun db ->
      Db_messages.Message.by_creator db user_id) in
    List.iter (fun message ->
      Db_runtime.write runtime (fun tx ->
        Db_remaining.Hooks.destroy_message tx ~now:(now_time ()) ~sink:!sink message);
      let room=Db_runtime.read runtime (fun db ->
        Db_rooms.Room.find db message.Db_messages.Message.room_id) in
      Cable_broadcasts.message_remove cable ~room ~message) messages in
  let on_purge ~blob_id =
    match Db_runtime.read runtime (fun db ->
      Db_runtime.query_one db
        (Db_remaining.Blob.select^" WHERE id=? LIMIT 1")
        [Sqlite3.Data.INT blob_id] Db_remaining.Blob.decode) with
    | None -> ()
    | Some blob -> Storage_blob.purge runtime storage blob in
  let on_webhook ~bot_id ~message_id =
    let bot,room,url,payload=Db_runtime.read runtime (fun db ->
      let bot=Db_accounts.User.find db bot_id in
      let message=Db_messages.Message.find db message_id in
      let room=Db_rooms.Room.find db message.room_id in
      let webhook=match Db_remaining.Webhook.find_by_user db bot_id with
        | Some webhook -> webhook | None -> failwith "bot has no webhook" in
      let payload=Db_remaining.Webhook.payload ~rich_text webhook db message
        ~room_bot_messages_path:(Route_helpers.room_bot_messages
          (i64 room.id) (Db_accounts.User.bot_key bot))
        ~message_path:(Route_helpers.room_at_message (i64 room.id) (i64 message.id))
        |> Db_remaining.Webhook.payload_json in
      bot,room,Option.value ~default:"" webhook.url,payload) in
    let delivery=match deliver_webhook url payload with
      | Ok delivery -> delivery
      | Error _ -> failwith "webhook delivery failed" in
    let attachment_blob_id,body=match delivery.Webhook.reply with
      | Webhook.None_reply -> None,None
      | Text text ->
        let body=match Rich_text.sanitize text with
          | Ok body -> body
          | Error reason -> failwith ("webhook reply canonicalization failed: "^reason) in
        None,Some body
      | Attachment attachment ->
        let blob=save_attachment runtime storage attachment in
        Some blob.Db_remaining.Blob.id,None in
    if delivery.reply<>Webhook.None_reply then (
      let message=Db_runtime.write runtime (fun tx ->
        Db_remaining.Hooks.create_message tx ~sink:!sink ~now:(now_time ())
          {Db_messages.Message.room_id=room.id;creator_id=bot.id;
           client_message_id=None;body;attachment_blob_id}) in
      let message=match attachment_blob_id with
        | None -> message
        | Some blob_id ->
          let blob=Db_runtime.read runtime (fun db -> Db_remaining.Blob.find db blob_id) in
          let analyzed=Storage_media.analyze runtime storage blob in
          let content_type=Option.value ~default:"" analyzed.content_type in
          if String.starts_with ~prefix:"video/" content_type then
            ignore (Storage_media.process_representation runtime storage analyzed
              (Storage_variation.format_only "webp") ~now:(now_time ()))
          else if String.starts_with ~prefix:"image/" content_type then
            ignore (Storage_media.process_representation runtime storage analyzed
              (Storage_variation.resize_to_limit 1200 800) ~now:(now_time ()));
          Db_runtime.write runtime (fun tx ->
            Db_messages.Message.touch tx ~now:(now_time ()) message) in
      broadcast_create ~secret_key_base:config.secret_key_base cable runtime room message) in
  let jobs=Jobs.create ~workers:config.job_concurrency
    ~on_push ~on_webhook ~on_remove_banned ~on_purge () in
  let app={jobs;push_pool;cable} in
  sink:=Jobs.compose_sinks cable jobs;
  current:=Some app;
  app

let event_sink app = Jobs.compose_sinks app.cable app.jobs

let deliver_test_notification app ~subscription ~badge ~path =
  match app.push_pool with
  | None -> Error (Web_push.Argument "Web Push is off")
  | Some pool ->
    let notification={Web_push.title="Campfire Test";
      body=Db_accounts.uuid ();path;badge;subscription} in
    pool.Web_push.deliver_one notification |> Result.map (fun _ -> ())

let shutdown app ~deadline =
  (match !current with Some running when running == app -> current:=None | _ -> ());
  let jobs_drained=Jobs.shutdown app.jobs ~deadline in
  let push_drained=match app.push_pool with
    | None -> true | Some pool -> Web_push.shutdown pool ~deadline in
  jobs_drained && push_drained

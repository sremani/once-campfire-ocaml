(** Room, message, search and autocomplete actions. Page fragments are temporary
    render seams for M4; mutations, access checks, redirects and API responses
    live here. M5 supplies broadcasts and webhook delivery; M6 supplies uploads. *)

open Lwt.Infix
module H = Http_app
module R = Db_rooms
module M = Db_messages
module U = Db_accounts.User

let response value = Lwt.return value
let empty status = H.respond ~status ~content_type:"text/html; charset=utf-8" ""
let error status = response (H.error ~status)
let head status = response (empty status)
let action_head _c status =
  let headers = if List.mem status [204;205;304] then [] else
    ["content-type","text/html"] in
  response (Cohttp.Response.make ~status:(Cohttp.Code.status_of_code status)
    ~headers:(Cohttp.Header.of_list headers) (), Cohttp_lwt.Body.empty)
let public_error c status =
  let content_type,body = match c.H.format with
    | Http_format.Json :: _ ->
        let reason = if status=404 then "Not Found" else "Bad Request" in
        "application/json; charset=UTF-8",
        Printf.sprintf "{\"status\":%d,\"error\":\"%s\"}" status reason
    | _ when status=404 ->
        "text/html; charset=UTF-8",
        Option.value (Assets.file "/404.html") ~default:""
    | _ -> "text/html; charset=UTF-8","" in
  let body = if c.H.method_="HEAD" then "" else body in
  response (H.respond ~status ~content_type
    ~headers:["x-campfire-public-exception","1";
      "content-length",string_of_int (String.length body)] body)
let absolute c path = H.base_url c ^ path
let redirect c path = response (H.redirect (absolute c path))
let read c f = Db_runtime.read_async c.H.runtime f
let write c f = Db_runtime.write_async c.H.runtime f
let rich_text c = View_presenter.rich_text c
let with_cable c f = Option.iter f c.H.cable
let storage_service : Storage_disk.t option ref = ref None
let register_storage service = storage_service := Some service
let number c key = Option.bind (H.param_string c key) Ruby_compat.integer_cast
let user c = c.H.current_user
let user_id c = Option.map (fun u -> u.U.id) (user c)
let object_param c key = match H.param c key with
  | Some (Http_params.Object fields) -> Some fields | _ -> None
let field fields key = Http_params.find_string key fields
let html ?(status=200) title = response (H.html ~status
  ("<!DOCTYPE html><html><head><title>" ^ title ^
   "</title></head><body><main><h1>" ^ title ^ "</h1></main></body></html>"))
let accepts c kind = Http_format.negotiate c.H.format [kind] = Some kind
let html_only c title = if accepts c Http_format.Html then html title else error 406
let turbo_only c body = if accepts c Http_format.Turbo_stream then
  response (H.respond ~status:200 ~content_type:"text/vnd.turbo-stream.html; charset=utf-8" body)
  else error 406
let remember_room c id =
  let value = Int64.to_string id in
  if Cookie_http.get c.H.cookies "last_room" <> Some value then
    Cookie_http.set c.H.cookies "last_room"
      { (Cookie_http.cookie value) with permanent=true }

let room_path id = "/rooms/" ^ Int64.to_string id
let room_message_path room_id id = room_path room_id ^ "/messages/" ^ Int64.to_string id
let recorded_html ?context (page : Views.recorded_page) =
  let reply,_ = H.html ~status:200 page.body in
  match Http_cache.Page_parts.splice ~text:page.text page.fragments with
  | None -> reply, Cohttp_lwt.Body.of_string page.body,
      Http_cache.hex (Http_cache.sha256 page.body)
  | Some parts ->
      Option.iter (fun c -> c.H.page_parts <- Some parts) context;
      let validator=Http_cache.Page_parts.etag parts in
      let headers=Cohttp.Header.replace (Cohttp.Response.headers reply)
        "etag" ("W/\"" ^ validator ^ "\"") in
      {reply with headers}, Http_cache.Page_parts.body parts, validator
let room_sidebar_html (room : R.Room.t) =
  let name = Option.value room.name ~default:"" |> Ruby_compat.html_escape in
  let id = Cable_broadcasts.room_dom_id room "list" in
  Printf.sprintf "<li id=\"%s\"><a href=\"/rooms/%Ld\">%s</a></li>"
    id room.id name
let room_id c = match number c "room_id" with Some id -> Some id | None -> number c "id"
let room_for_user c ?(kind=`Any) () = match user_id c, room_id c with
  | Some uid, Some id -> read c (fun db ->
      match R.Room.find_for_user db uid id with
      | None -> None
      | Some room -> if (match kind with
          | `Any -> true | `No_direct -> not (R.Room.direct room)
          | `Direct -> R.Room.direct room) then Some room else None)
  | _ -> Lwt.return_none
let scoped_room c = match user_id c, number c "room_id" with
  | Some uid, Some rid -> read c (fun db ->
      match R.Membership.find_by_room_and_user db rid uid with
      | None -> None
      | Some membership -> Option.map (fun room -> membership,room)
          (R.Room.find_by_id db rid))
  | _ -> Lwt.return_none
let room_or_root c ?(kind=`Any) f =
  room_for_user c ~kind () >>= function
  | None ->
      H.session_set c "flash" (`Assoc ["discard",`List [];
        "flashes",`Assoc ["alert",`String "Room not found or inaccessible"]]);
      redirect c "/"
  | Some room -> f room
let scope_or_404 c f = scoped_room c >>= function
  | None -> public_error c 404 | Some (membership,room) -> f membership room
let can_admin c creator = match user c with
  | None -> false
  | Some u -> U.can_administer u ~record_creator_id:(Some creator) ~record_is_new:false
let check_creation c =
  read c (fun db -> match Db_accounts.Account.first db with
    | Some account when Db_accounts.Account.restrict_room_creation_to_administrators account ->
        (match user c with Some u -> U.is_administrator u | None -> false)
    | _ -> true)
let room_name c = match object_param c "room" with
  | None -> Error ()
  | Some fields -> Ok (if List.mem_assoc "name" fields then Some (field fields "name") else None)
let ids_from_param c =
  let raw = match H.param c "user_ids" with
    | Some (Http_params.Array xs) -> xs
    | Some value -> [value]
    | None -> [] in
  raw |> List.filter_map (function Http_params.Text value -> Ruby_compat.integer_cast value | _ -> None)
let existing_ids db ids = U.where_ids db ids |> List.map (fun u -> u.U.id)

let rooms_index c = match user_id c with
  | None -> error 500
  | Some uid -> read c (fun db -> R.Room.last_for_user db uid) >>= function
      | None -> error 500
      | Some room -> redirect c (room_path room.R.Room.id)
let context_for_account c db account =
  View_presenter.context ~has_custom_logo:(View_presenter.has_custom_logo db account)
    c account
let room_show c = room_or_root c (fun room ->
  remember_room c room.R.Room.id;
  if not (accepts c Http_format.Html) then error 406 else
  match H.private_lookup c with
  | Some cached -> response cached
  | None ->
  read c (fun db ->
    let account = Db_accounts.Account.first db in
    let messages = M.Message.last_page db room.R.Room.id
      |> List.map (View_presenter.message c db room) in
    let direct_names = if room.R.Room.room_type=R.Direct then
      R.Room.users db room |> List.filter_map (fun (user:U.t) ->
        if Some user.U.id=user_id c then None else Some user.U.name)
      else [] in
    let invitation = match R.Room.original db with
      | Some original when original.R.Room.id=room.R.Room.id ->
          not (M.Message.paged db room.R.Room.id)
      | _ -> false in
    account, context_for_account c db account, messages, direct_names, invitation)
  >>= fun (account, context, messages, direct_names, invitation) ->
  let room_view = View_presenter.room room in
  let room_view = if room.R.Room.room_type=R.Direct then
    {room_view with Views.name=(match direct_names with
      | [] -> (match context.Views.current_user with
          | Some user -> user.Views.name | None -> "")
      | [name] -> name
      | names -> String.concat ", " names)}
    else room_view in
  let messages_stream_name = Turbo_stream.signed_stream_name
    ~secret_key_base:c.H.secret_key_base
    [Cable_channels.room_param room; "messages"] in
  let page=Views.room_show_recorded ~context ~room:room_view ~messages ~messages_stream_name
      ?invitation_join_code:(if invitation then
        Option.map (fun (row : Db_accounts.Account.t) -> row.join_code) account
        else None)
      () in
  let reply,body,_=recorded_html ~context:c page in
  response (reply,body))
let room_destroy c = room_or_root c (fun room ->
  if not (can_admin c room.R.Room.creator_id) then head 403 else
  write c (fun tx ->
    let ids = R.Room.user_ids (Db_runtime.conn tx) room in
    Db_remaining.Hooks.revoke_from tx room ids ~sink:c.H.event_sink;
    R.Room.destroy_tx tx room ~destroy_messages:(fun tx ~room_id ->
      Db_remaining.Hooks.destroy_messages_for_room tx
        ~sink:c.H.event_sink ~now:(Db_accounts.now_time c.H.now) ~room_id))
  >>= fun () ->
  with_cable c (fun cable -> Cable_broadcasts.room_remove cable ~room);
  redirect c "/")
let room_nil_action _ = error 500
let room_type_show c = room_or_root c ~kind:`No_direct (fun room ->
  remember_room c room.R.Room.id; redirect c (room_path room.R.Room.id))
let last_room_for_user c db uid =
  let remembered=Option.bind (Cookie_http.get c.H.cookies "last_room")
    Ruby_compat.integer_cast in
  let remembered=Option.bind remembered (R.Room.find_for_user db uid) in
  let room=match remembered with
    | Some room -> Some room | None -> R.Room.original_for_user db uid in
  Option.map (fun (room:R.Room.t) -> room.id) room
let render_room_form c ?room kind =
  if not (accepts c Http_format.Html) then error 406 else
  read c (fun db ->
    let account=Db_accounts.Account.first db in
    let users=U.active_ordered db in
    let selected_ids=match room with
      | None -> [] | Some room -> R.Room.user_ids db room in
    let selected,unselected=List.partition
      (fun (user:U.t) -> List.mem user.id selected_ids) users in
    let last_room_id=Option.bind (user_id c) (last_room_for_user c db) in
    context_for_account c db account,users,selected,unselected,last_room_id)
  >>= fun (context,users,selected,unselected,last_room_id) ->
  let kind = match kind with
    | R.Open -> Views.Open | R.Closed -> Views.Closed | R.Direct -> Views.Direct in
  let form : Views.room_form_data = {
    form_room_id=Option.map (fun (room:R.Room.t) -> room.id) room;
    form_room_name=(match room with
      | None -> Some "New room" | Some room -> room.name);
    form_kind=kind;
    can_administer=(match room with
      | None -> true | Some room -> can_admin c room.R.Room.creator_id);
    form_current_user_id=user_id c;
    form_users=List.map (View_presenter.user c) users;
    selected_users=List.map (View_presenter.user c) selected;
    unselected_users=List.map (View_presenter.user c) unselected;
  } in
  response (H.html ~status:200
    (Views.room_form_page ~context ?last_room_id form))
let room_type_form kind c =
  check_creation c >>= fun allowed ->
  if not allowed then action_head c 403 else render_room_form c kind
let room_type_edit kind c = room_or_root c ~kind:`No_direct (fun room ->
  render_room_form c ~room kind)
let room_type_create kind c =
  check_creation c >>= fun allowed ->
  if not allowed then action_head c 403 else match room_name c,user_id c with
  | Error (),_ -> public_error c 400 | _,None -> error 500
  | Ok name,Some uid ->
      let ids = ids_from_param c in
      write c (fun tx ->
        let db = Db_runtime.conn tx in
        let users = if kind=R.Open then [uid] else existing_ids db ids in
        R.Room.create_for tx ~now:c.H.now kind
          ~name:(Option.join name) ~creator_id:uid users)
      >>= fun room ->
      read c (fun db -> R.Room.user_ids db room) >>= fun user_ids ->
      with_cable c (fun cable ->
        let html = room_sidebar_html room in
        match kind with
        | R.Open -> Cable_broadcasts.open_room_create cable ~room ~html
        | R.Closed -> Cable_broadcasts.closed_room_create cable ~room ~user_ids ~html
        | R.Direct -> ());
      redirect c (room_path room.R.Room.id)
let room_type_update kind c = room_or_root c ~kind:`No_direct (fun room ->
  if not (can_admin c room.R.Room.creator_id) then head 403 else
  match room_name c with
  | Error () -> public_error c 400
  | Ok name ->
      let ids = ids_from_param c in
      write c (fun tx ->
        let db = Db_runtime.conn tx in
        let room = R.Room.update tx ~now:c.H.now room
          ?name ~room_type:kind () in
        if kind=R.Closed then (
          let granted = existing_ids db ids in
          let revoked = List.filter (fun id -> not (List.mem id ids)) (R.Room.user_ids db room) in
          Db_remaining.Hooks.revise tx room ~granted ~revoked
            ~sink:c.H.event_sink);
        room) >>= fun room ->
      read c (fun db -> R.Room.user_ids db room) >>= fun user_ids ->
      with_cable c (fun cable ->
        let html = room_sidebar_html room in
        match kind with
        | R.Open -> Cable_broadcasts.open_room_update cable ~room ~html
        | R.Closed -> Cable_broadcasts.closed_room_update cable ~room ~user_ids ~html
        | R.Direct -> ());
      redirect c (room_path room.R.Room.id))
let direct_create c = match user_id c with
  | None -> error 500
  | Some uid ->
      let ids = uid :: ids_from_param c in
      write c (fun tx ->
        let ids = existing_ids (Db_runtime.conn tx) ids in
        R.Room.find_or_create_direct_for tx ~now:c.H.now
          ~user_ids:ids ~creator_id:uid) >>= fun room ->
      read c (fun db -> R.Membership.for_room db room.R.Room.id)
      >>= fun memberships ->
      with_cable c (fun cable -> Cable_broadcasts.direct_room_create cable
        ~room ~memberships ~render:(fun _ -> room_sidebar_html room));
      redirect c (room_path room.R.Room.id)
let direct_edit c = room_or_root c ~kind:`Direct (fun room ->
  render_room_form c ~room R.Direct)
let direct_show c = match number c "id" with
  | None -> head 404 | Some id -> redirect c (room_path id)
let direct_destroy c = room_or_root c ~kind:`Direct (fun room ->
  write c (fun tx ->
    let ids = R.Room.user_ids (Db_runtime.conn tx) room in
    Db_remaining.Hooks.revoke_from tx room ids ~sink:c.H.event_sink;
    R.Room.destroy_tx tx room ~destroy_messages:(fun tx ~room_id ->
      Db_remaining.Hooks.destroy_messages_for_room tx
        ~sink:c.H.event_sink ~now:(Db_accounts.now_time c.H.now) ~room_id))
  >>= fun () ->
  with_cable c (fun cable -> Cable_broadcasts.room_remove cable ~room);
  redirect c "/")
let involvement_show c = scope_or_404 c (fun membership room ->
  if not (accepts c Http_format.Html) then error 406 else
  View_presenter.load_context c >>= fun context ->
  let involvement=Option.value
    (Option.map R.involvement_name membership.R.Membership.involvement) ~default:"" in
  let body=Views.room_involvement_frame ~context
    ~room:(View_presenter.room room) ~involvement in
  response (H.html ~status:200 (Views.page ~context body)))
let involvement_update c = scope_or_404 c (fun membership room ->
  let involvement = match H.param_string c "involvement" with
    | None | Some "" -> Some None
    | Some value -> (try Some (Some (R.involvement_of_name value)) with _ -> None) in
  match involvement with
  | None -> error 500
  | Some involvement ->
      write c (fun tx -> ignore (R.Membership.update_involvement tx
        ~now:c.H.now membership involvement)) >>= fun () ->
      redirect c (room_path room.R.Room.id ^ "/involvement"))
let refresh_show c = scope_or_404 c (fun _ room ->
  let since = match H.param_string c "since" with
    | None -> 0L | Some s -> Ruby_compat.to_i s in
  let since = Int64.to_float since /. 1000. in
  let time = Option.value (Ptime.of_float_s since) ~default:Ptime.epoch in
  read c (fun db ->
    let stamp = Db_time.to_db time in
    let created = M.Message.page_created_since db room.R.Room.id stamp in
    let ids = List.map (fun m -> m.M.Message.id) created in
    let updated = M.Message.page_updated_since db room.R.Room.id stamp ids in
    (List.map (View_presenter.message c db room) created,
     List.map (View_presenter.message c db room) updated))
  >>= fun (created,updated) ->
  turbo_only c (Views.room_refresh_stream ~room:(View_presenter.room room)
    ~created ~updated))

let message_in_room c room key = match number c key with
  | None -> Lwt.return_none
  | Some id -> read c (fun db -> match M.Message.find_by_id db id with
      | Some message when message.M.Message.room_id=room.R.Room.id -> Some message
      | _ -> None)
let message_or_404 c room key f = message_in_room c room key >>= function
  | None -> public_error c 404 | Some message -> f message
exception Invalid_message_page
let paginate c db room =
  let find key = match number c key with
    | None when (match H.param c key with
        | Some value -> not (Http_params.blank value) | None -> false) ->
        raise Invalid_message_page
    | None -> None
    | Some id -> (match M.Message.find_by_id db id with
      | Some message when message.M.Message.room_id=room.R.Room.id -> Some message
      | _ -> raise Invalid_message_page) in
  match find "before" with
  | Some message -> M.Message.page_before db room.R.Room.id message
  | None -> (match find "after" with
    | Some message -> M.Message.page_after db room.R.Room.id message
    | None -> M.Message.last_page db room.R.Room.id)
let read_paged c f = Lwt.catch
  (fun () -> read c f >|= fun value -> Ok value)
  (function Invalid_message_page -> Lwt.return (Error ())
    | error -> Lwt.fail error)
let message_index c = scope_or_404 c (fun _ room ->
  read_paged c (fun db -> paginate c db room) >>= function
  | Error () -> public_error c 404
  | Ok messages ->
  if messages=[] then head 204 else
  if not (accepts c Http_format.Html) then error 406 else
  match H.private_lookup c with
  | Some cached -> response cached
  | None ->
  read c (fun db -> List.map (View_presenter.message c db room) messages)
  >>= fun messages ->
  let page=Views.message_index_recorded messages in
  let reply,body,validator=recorded_html ~context:c page in
  let frame=match H.header c "turbo-frame" with
    | Some id -> String.trim id <> "" | None -> false in
  let flash=Http_cache.flash_etaggers (H.flash c) in
  let headers,_,fresh=Http_cache.fresh_when ~frame ~flash ~template:"messages/index"
    ~validator c.H.request (Cohttp.Response.headers reply) in
  let headers=Cohttp.Header.remove headers "last-modified" in
  if fresh then
    let headers=Cohttp.Header.remove headers "content-type"
      |> fun headers -> Cohttp.Header.remove headers "content-length" in
    response (Cohttp.Response.make ~status:`Not_modified ~headers (),
      Cohttp_lwt.Body.empty)
  else response ({reply with headers},body))
type attachment_change = Keep_attachment | Remove_attachment
  | Upload_attachment of Http_params.upload | Invalid_attachment

let attachment_change fields = match Http_params.get "attachment" fields with
  | None -> Keep_attachment
  | Some (Http_params.Nil | Http_params.Text "") -> Remove_attachment
  | Some (Http_params.File file) -> Upload_attachment file
  | Some _ -> Invalid_attachment

let with_uploaded_blob c file f = match !storage_service with
  | None -> Lwt.fail_with "local storage service is not registered"
  | Some service ->
      H.track_upload_worker c (Lwt_preemptive.detach (fun () ->
        Storage_blob.stage_file service ~source:file.Http_params.path
          ~filename:file.filename ~content_type:file.content_type
          (fun prepared staged ->
            let result = Db_runtime.write c.H.runtime (fun tx ->
              let blob = Storage_blob.insert tx
                ~now:(Db_accounts.now_time c.H.now) prepared in
              f tx blob.id) in
            Storage_disk.keep staged;
            result)) ())

let message_params c = match object_param c "message" with
  | None -> Error 400
  | Some fields ->
      let attachment=attachment_change fields in
      if attachment=Invalid_attachment then Error 500
      else Ok (field fields "body",field fields "client_message_id",attachment)
let deliver_webhooks_to_bots c room message =
  let rich_text=App_jobs.rich_text ~secret_key_base:c.H.secret_key_base in
  read c (fun db ->
    let candidates=if R.Room.direct room then R.Room.active_bots db room
      else M.Message.mentionees ~rich_text db message in
    List.filter (fun (bot:U.t) -> U.is_bot bot && U.is_active bot &&
      bot.id<>message.M.Message.creator_id) candidates) >>= fun bots ->
  if bots=[] then Lwt.return_unit else
  write c (fun tx -> List.iter
    (Db_remaining.Hooks.deliver_webhook_later tx
      ~message_id:message.M.Message.id ~sink:c.H.event_sink) bots)
let message_create c = scoped_room c >>= function
  | None ->
      if not (accepts c Http_format.Html) then error 406 else
      View_presenter.load_context c >>= fun context ->
      response (H.html ~status:200
        (Views.page ~context Views.message_room_not_found))
  | Some (_,room) ->
      (match message_params c,user_id c with
       | Error 400,_ -> public_error c 400
       | Error code,_ -> error code | _,None -> error 500
       | Ok (body,client_message_id,attachment),Some creator_id ->
           let create tx attachment_blob_id =
             Db_remaining.Hooks.create_message ~rich_text:(rich_text c) tx
               ~sink:c.H.event_sink ~now:(Db_accounts.now_time c.H.now)
               {room_id=room.R.Room.id;creator_id;client_message_id;body;
                attachment_blob_id} in
           (match attachment with
            | Upload_attachment file -> with_uploaded_blob c file
                (fun tx blob_id -> create tx (Some blob_id))
            | _ -> write c (fun tx -> create tx None)) >>= fun message ->
           read c (fun db ->
             View_presenter.message c db room message,
             R.Room.user_ids db room) >>= fun (view,member_ids) ->
           with_cable c (fun cable -> Cable_broadcasts.message_create cable
             ~room ~message ~member_ids
             ~html:(Views.message_item view |> Views.render));
           deliver_webhooks_to_bots c room message >>= fun () ->
           turbo_only c (Views.message_create_stream
             ~room:(View_presenter.room room) view))
let message_show c = scope_or_404 c (fun _ room ->
  message_or_404 c room "id" (fun message ->
    if not (accepts c Http_format.Html) then error 406 else
    read c (fun db -> View_presenter.message c db room message,
      Db_accounts.Account.first db) >>= fun (message,account) ->
    let context = View_presenter.context c account in
    response (H.html ~status:200 (Views.message_show ~context message))))
let message_edit c = scope_or_404 c (fun _ room ->
  message_or_404 c room "id" (fun message ->
    if not (can_admin c message.M.Message.creator_id) then head 403
    else if not (accepts c Http_format.Html) then error 406 else
    read c (fun db -> View_presenter.message c db room message,
      context_for_account c db (Db_accounts.Account.first db))
    >>= fun (message,context) ->
    response (H.html ~status:200 (Views.message_edit ~context message))))
let message_update c = scope_or_404 c (fun _ room ->
  message_or_404 c room "id" (fun message ->
    if not (can_admin c message.M.Message.creator_id) then head 403 else
    match message_params c with
    | Error 400 -> public_error c 400
    | Error code -> error code
    | Ok (body,_,attachment) ->
        let update tx attachment_blob_id =
          let now=Db_accounts.now_time c.H.now in
          let message=match body with None -> message | Some body ->
            M.Message.update_body ~rich_text:(rich_text c) tx ~now message body in
          match attachment_blob_id with
          | None -> message
          | Some blob_id -> Db_remaining.Hooks.replace_message_attachment
              ~rich_text:(rich_text c)
              tx ~now ~sink:c.H.event_sink message blob_id in
        (match attachment with
         | Upload_attachment file -> with_uploaded_blob c file
             (fun tx blob_id -> update tx (Some (Some blob_id)))
         | Keep_attachment ->
             (match body with None -> Lwt.return message
              | Some _ -> write c (fun tx -> update tx None))
         | Remove_attachment -> write c (fun tx -> update tx (Some None))
         | Invalid_attachment -> assert false) >>= fun message ->
        read c (fun db -> View_presenter.message c db room message)
        >>= fun view ->
        with_cable c (fun cable -> Cable_broadcasts.message_replace cable
          ~room ~message
          ~html:(Views.message_presentation view |> Views.render));
        if accepts c Http_format.Json then error 500
        else redirect c (room_message_path room.R.Room.id message.M.Message.id)))
let message_destroy c = scope_or_404 c (fun _ room ->
  message_or_404 c room "id" (fun message ->
    if not (can_admin c message.M.Message.creator_id) then head 403 else
    write c (fun tx -> Db_remaining.Hooks.destroy_message tx
      ~sink:c.H.event_sink ~now:(Db_accounts.now_time c.H.now) message)
    >>= fun () ->
    with_cable c (fun cable -> Cable_broadcasts.message_remove cable
      ~room ~message);
    read c (fun db -> View_presenter.message c db room message)
    >>= fun message ->
    turbo_only c (Views.message_destroy_stream message)))
let reachable_message c = match user_id c,number c "message_id" with
  | Some uid,Some mid -> read c (fun db ->
      match M.Message.find_by_id db mid with
      | None -> None
      | Some m -> (match R.Room.find_for_user db uid m.M.Message.room_id with
        | None -> None | Some _ -> Some m))
  | _ -> Lwt.return_none
let broadcast_boost_create c (message : M.Message.t) (boost : M.Boost.t) =
  match c.H.cable with
  | None -> Lwt.return_unit
  | Some cable -> read c (fun db ->
      R.Room.find db message.room_id,
      View_presenter.boost c db boost) >|= fun (room, view) ->
      Cable_broadcasts.boost_create cable ~room ~message ~boost
        ~html:(Views.boost_item view |> Views.render)
let broadcast_boost_remove c (message : M.Message.t) (boost : M.Boost.t) =
  match c.H.cable with
  | None -> Lwt.return_unit
  | Some cable -> read c (fun db -> R.Room.find db message.room_id)
      >|= fun room -> Cable_broadcasts.boost_remove cable ~room ~boost
let boost_index c = reachable_message c >>= function
  | None -> public_error c 404
  | Some message ->
      if not (accepts c Http_format.Html) then error 406 else
      read c (fun db ->
        let room=R.Room.find db message.M.Message.room_id in
        View_presenter.message c db room message) >>= fun view ->
      View_presenter.load_context c >>= fun context ->
      response (H.html ~status:200
        (Views.page ~context (Views.message_boosts view)))
let boost_new c = reachable_message c >>= function
  | None -> public_error c 404
  | Some message ->
      if not (accepts c Http_format.Html) then error 406 else
      read c (fun db ->
        let room=R.Room.find db message.M.Message.room_id in
        View_presenter.message c db room message) >>= fun view ->
      View_presenter.load_context c >>= fun context ->
      (match context.Views.current_user with
       | None -> error 500
       | Some user -> response (H.html ~status:200
           (Views.page ~context (Views.message_new_boost ~context ~message:view ~user))))
let boost_create c = reachable_message c >>= function
  | None -> public_error c 404
  | Some message -> (match object_param c "boost",user_id c with
      | None,_ -> public_error c 400 | _,None -> error 500
      | Some fields,Some booster_id -> (match field fields "content" with
          | None -> error 500
          | Some content -> write c (fun tx -> M.Boost.create tx
              ~now:(Db_accounts.now_time c.H.now)
              ~message_id:message.M.Message.id ~booster_id ~content) >>= fun boost ->
              broadcast_boost_create c message boost >>= fun () ->
              redirect c ("/messages/" ^ Int64.to_string message.M.Message.id ^ "/boosts")))
let boost_destroy c = reachable_message c >>= function
  | None -> public_error c 404
  | Some message -> (match number c "id",user_id c with
      | Some bid,Some uid ->
          read c (fun db -> M.Boost.for_message db message.M.Message.id
            |> List.find_opt (fun b -> b.M.Boost.id=bid && b.M.Boost.booster_id=uid))
          >>= (function
            | None -> public_error c 404
            | Some boost -> write c (fun tx -> M.Boost.destroy tx
                ~now:(Db_accounts.now_time c.H.now) boost) >>= fun () ->
                broadcast_boost_remove c message boost >>= fun () -> action_head c 204)
      | _ -> public_error c 404)

let json_time stamp =
  let date = if String.length stamp >= 19 then String.sub stamp 0 19 else stamp in
  let date = String.map (function ' ' -> 'T' | ch -> ch) date in
  let frac = if String.length stamp > 20 && stamp.[19]='.' then
    String.sub stamp 20 (min 3 (String.length stamp-20)) else "" in
  let frac = frac ^ String.make (3-String.length frac) '0' in
  date ^ "." ^ frac ^ "Z"
let avatar_url c (user:U.t) =
  let token = Signed_id.generate ~secret_key_base:c.H.secret_key_base
    ~model:"User" ~id:(Int64.to_int user.U.id) ~purpose:(Some "avatar") ~expires_at:None in
  let version = String.to_seq user.U.updated_at |> List.of_seq
    |> List.filter (function '0'..'9' -> true | _ -> false)
    |> List.to_seq |> String.of_seq in
  let version = if String.length version >= 14 then String.sub version 0 14 else version in
  absolute c ("/users/" ^ token ^ "/avatar?v=" ^ version)
let user_json c (user:U.t) =
  let role = match user.U.role with U.Member -> "member"
    | U.Administrator -> "administrator" | U.Bot -> "bot" in
  `Assoc ["id",`Int (Int64.to_int user.U.id);"name",`String user.U.name;
    "role",`String role;"avatar_url",`String (avatar_url c user)]
let message_json c db (message:M.Message.t) =
  let plain = M.Message.plain_text_body ~rich_text:(rich_text c) db message in
  let room = R.Room.find db message.M.Message.room_id in
  let view = View_presenter.message c db room message in
  Views.message_json ~base_url:(H.base_url c) ~plain_text_body:plain view
let boost_json c db (message:M.Message.t) (boost:M.Boost.t) =
  Views.boost_json ~base_url:(H.base_url c)
    ~room_id:message.M.Message.room_id
    ~created_at:(json_time boost.M.Boost.created_at)
    (View_presenter.boost c db boost)
let bot_room c f = room_for_user c () >>= function
  | None -> action_head c 404 | Some room -> f room
let bot_message c room key f = message_or_404 c room key f
let bot_boost_message c f = bot_room c (fun room ->
  message_in_room c room "message_id" >>= function
  | None -> action_head c 404 | Some message -> f message)
let bot_attachment c = match H.param c "attachment" with
  | None -> Keep_attachment
  | Some (Http_params.Nil | Http_params.Text "") -> Remove_attachment
  | Some (Http_params.File file) -> Upload_attachment file
  | Some _ -> Invalid_attachment
let bot_index c = bot_room c (fun room ->
  read_paged c (fun db ->
    let messages = paginate c db room in
    let count = M.Message.count_in_room db room.R.Room.id in
    let next = match messages with
      | [] -> None
      | first::_ ->
        let last = List.hd (List.rev messages) in
        if Option.is_some (H.param c "after") then
          if M.Message.exists_after db room.R.Room.id last then Some ("after",last.M.Message.id) else None
        else if M.Message.exists_before db room.R.Room.id first then Some ("before",first.M.Message.id) else None in
    (List.map (message_json c db) messages,count,next)) >>= function
  | Error () -> public_error c 404
  | Ok (messages,count,next) ->
  H.set_header c "x-total-count" (string_of_int count);
  (match next with None -> () | Some (key,id) ->
    let token = Option.value (H.param_string c "bot_key") ~default:"" in
    H.set_header c "link" (Printf.sprintf "<%s/rooms/%Ld/%s/messages?%s=%Ld>; rel=\"next\""
      (H.base_url c) room.R.Room.id token key id));
  if accepts c Http_format.Json then response (H.respond ~status:200
    ~content_type:"application/json; charset=utf-8"
    ("[" ^ String.concat "," messages ^ "]")) else error 406)
let bot_create c = bot_room c (fun room ->
  let body = c.H.raw_post in
  let attachment=bot_attachment c in
  if attachment=Invalid_attachment then error 500 else
  if String.trim body="" && (match attachment with Upload_attachment _ -> false | _ -> true)
  then action_head c 422 else match user_id c with
  | None -> error 500
  | Some creator_id ->
      let create tx attachment_blob_id = Db_remaining.Hooks.create_message
        ~rich_text:(rich_text c) tx
        ~sink:c.H.event_sink ~now:(Db_accounts.now_time c.H.now)
        {room_id=room.R.Room.id;creator_id;client_message_id=None;
         body=(if String.trim body="" then None else Some body);attachment_blob_id} in
      (match attachment with
       | Upload_attachment file -> with_uploaded_blob c file
           (fun tx blob_id -> create tx (Some blob_id))
       | _ -> write c (fun tx -> create tx None)) >>= fun message ->
      read c (fun db -> View_presenter.message c db room message,
        R.Room.user_ids db room) >>= fun (view,member_ids) ->
      with_cable c (fun cable -> Cable_broadcasts.message_create cable
        ~room ~message ~member_ids
        ~html:(Views.message_item view |> Views.render));
      deliver_webhooks_to_bots c room message >>= fun () ->
      let location = absolute c ("/messages/" ^ Int64.to_string message.M.Message.id) in
      response (H.respond ~headers:["location",location] ~status:201
        ~content_type:"application/json" ""))
let bot_update c = bot_room c (fun room ->
  bot_message c room "id" (fun message ->
    if not (can_admin c message.M.Message.creator_id) then head 403 else
    let attachment=bot_attachment c in
    if attachment=Invalid_attachment then error 500 else
    let update tx attachment_blob_id =
      let now=Db_accounts.now_time c.H.now in
      let message=match attachment with
        | Keep_attachment -> M.Message.update_body ~rich_text:(rich_text c)
            tx ~now message c.H.raw_post
        | _ -> message in
      match attachment_blob_id with
      | None -> message
      | Some blob_id -> Db_remaining.Hooks.replace_message_attachment
          ~rich_text:(rich_text c)
          tx ~now ~sink:c.H.event_sink message blob_id in
    (match attachment with
     | Upload_attachment file -> with_uploaded_blob c file
         (fun tx blob_id -> update tx (Some (Some blob_id)))
     | Remove_attachment -> write c (fun tx -> update tx (Some None))
     | Keep_attachment -> write c (fun tx -> update tx None)
     | Invalid_attachment -> assert false) >>= fun message ->
    read c (fun db -> View_presenter.message c db room message)
    >>= fun view ->
    with_cable c (fun cable -> Cable_broadcasts.message_replace cable
      ~room ~message ~html:(Views.message_presentation view |> Views.render));
    if not (accepts c Http_format.Json) then redirect c (room_message_path room.R.Room.id message.M.Message.id)
    else read c (fun db -> message_json c db message) >>= fun value ->
      response (H.respond ~status:200 ~content_type:"application/json; charset=utf-8" value)))
let bot_destroy c = bot_room c (fun room ->
  bot_message c room "id" (fun message ->
    if not (can_admin c message.M.Message.creator_id) then head 403 else
    write c (fun tx -> Db_remaining.Hooks.destroy_message tx
      ~sink:c.H.event_sink ~now:(Db_accounts.now_time c.H.now) message)
    >>= fun () ->
    with_cable c (fun cable -> Cable_broadcasts.message_remove cable
      ~room ~message);
    action_head c 204))
let bot_boost_create c = bot_boost_message c (fun message ->
  let content = c.H.raw_post in
  if String.trim content="" then action_head c 422 else match user_id c with
  | None -> error 500
  | Some booster_id ->
      write c (fun tx -> M.Boost.create tx ~now:(Db_accounts.now_time c.H.now)
        ~message_id:message.M.Message.id ~booster_id ~content) >>= fun boost ->
      broadcast_boost_create c message boost >>= fun () ->
      if not (accepts c Http_format.Json) then error 406 else
      read c (fun db -> boost_json c db message boost) >>= fun value ->
      response (H.respond ~status:201 ~content_type:"application/json; charset=utf-8" value))
let bot_boost_destroy c = bot_boost_message c (fun message ->
  match number c "id",user_id c with
  | Some bid,Some uid ->
      read c (fun db -> M.Boost.for_message db message.M.Message.id
        |> List.find_opt (fun b -> b.M.Boost.id=bid && b.M.Boost.booster_id=uid))
      >>= (function
        | None -> action_head c 404
        | Some boost -> write c (fun tx -> M.Boost.destroy tx
            ~now:(Db_accounts.now_time c.H.now) boost) >>= fun () ->
            broadcast_boost_remove c message boost >>= fun () -> action_head c 204)
  | _ -> action_head c 404)

let search_query c = match H.param c "q" with
  | None | Some Http_params.Nil -> Ok None
  | Some (Http_params.Text value) -> Ok (Some (Search_words.sanitize value))
  | _ -> Error ()
let searched_messages c q = match user_id c,q with
  | Some uid,Some q when String.trim q<>"" ->
      read c (fun db -> M.Message.search_reachable db uid q)
  | _ -> Lwt.return []
let search_index c = match search_query c,user_id c with
  | Error (),_ -> error 500 | _,None -> error 500
  | Ok q,Some uid ->
      searched_messages c q >>= fun messages ->
      if not (accepts c Http_format.Html) then error 406 else
      match H.private_lookup c with
      | Some cached -> response cached
      | None ->
      read c (fun db ->
        let account = Db_accounts.Account.first db in
        let rendered = messages |> List.filter_map (fun (message : M.Message.t) ->
          match R.Room.find_by_id db message.M.Message.room_id with
          | None -> None
          | Some room -> Some (View_presenter.message c db room message)) in
        let recent_searches=M.Search.ordered_for_user db uid
          |> List.map (fun (search:M.Search.t) -> search.query) in
        let return_to_room_id=last_room_for_user c db uid in
        context_for_account c db account,rendered,recent_searches,return_to_room_id)
      >>= fun (context,rendered,recent_searches,return_to_room_id) ->
      response (H.html ~status:200
        (Views.search_index_with ~context ~query:(Option.value q ~default:"")
          ?q:(H.param_string c "q") ~recent_searches ?return_to_room_id
          ~results:rendered ()))
let search_create c = match search_query c,user_id c with
  | Error (),_ -> error 500 | _,None -> error 500
  | Ok None,_ -> error 500
  | Ok (Some q),Some uid ->
      searched_messages c (Some q) >>= fun _ ->
      write c (fun tx -> ignore (M.Search.record tx
        ~now:(Db_accounts.now_time c.H.now) ~user_id:uid ~query:q)) >>= fun () ->
      redirect c ("/searches?q=" ^ Ruby_compat.cgi_escape q)
let search_clear c = match search_query c,user_id c with
  | Error (),_ -> error 500 | _,None -> error 500
  | Ok q,Some uid ->
      searched_messages c q >>= fun _ ->
      write c (fun tx -> M.Search.destroy_all_for_user tx uid) >>= fun () ->
      redirect c "/searches"

let autocomplete c = match user_id c with
  | None -> error 500
  | Some uid ->
      let requested_room = H.param_string c "room_id" in
      let room_id = Option.bind requested_room Ruby_compat.integer_cast in
      (match requested_room with
       | Some value when String.trim value<>"" && room_id=None -> Lwt.return_none
       | Some value when String.trim value<>"" ->
           read c (fun db -> Option.bind room_id (R.Room.find_for_user db uid))
       | _ -> Lwt.return (Some {R.Room.id=0L;name=None;room_type=R.Open;
           creator_id=uid;created_at="";updated_at=""})) >>= function
      | None -> head 404
      | Some room ->
          let query = match H.param_string c "filter",H.param_string c "query" with
            | Some value,_ when String.trim value<>"" -> Some value
            | _,Some value when String.trim value<>"" -> Some value
            | _ -> None in
          read c (fun db ->
            if room.R.Room.id=0L then match query with
              | None -> U.active_ordered db
              | Some query -> U.active_filtered_by_ordered db query
            else
              let condition,params = match query with
                | None -> "",[]
                | Some value -> " AND users.name LIKE ?",[Sqlite3.Data.TEXT ("%"^value^"%")] in
              Db_runtime.query_all db
                ("SELECT users.id,users.name,users.email_address,users.password_digest,users.role,users.status,users.bio,users.bot_token,users.created_at,users.updated_at FROM users" ^
                  " INNER JOIN memberships ON users.id=memberships.user_id" ^
                  " WHERE memberships.room_id=? AND users.status=0" ^ condition ^
                  " ORDER BY LOWER(users.name)")
                (Sqlite3.Data.INT room.R.Room.id :: params) U.decode) >>= fun users ->
          let count = List.length users in
          let page = match Option.bind (H.param_string c "page") int_of_string_opt with
            | Some n when n>0 -> min n 1_000_000_000 | _ -> 1 in
          let offset = min count ((page-1)*20) in
          let users = users |> List.filteri (fun i _ -> i>=offset && i<offset+20) in
          if accepts c Http_format.Json then (
            H.set_header c "x-total-count" (string_of_int count);
            if page*20 < count then (
              let uri = Uri.with_query' (Cohttp.Request.uri c.H.request)
                ([("page",string_of_int (page+1))] @
                 (Uri.query (Cohttp.Request.uri c.H.request) |>
                  List.filter (fun (k,_) -> k<>"page") |>
                  List.concat_map (fun (k,values) -> List.map (fun value -> k,value) values))) in
              H.set_header c "link" ("<" ^ H.base_url c ^ Uri.to_string uri ^ ">; rel=\"next\""));
            let values = List.map (fun (u:U.t) ->
              let gid = Global_id.make ~model_name:"User" ~id:(Int64.to_string u.U.id) in
              `Assoc ["name",`String (Ruby_compat.html_escape u.U.name);
                "value",`Int (Int64.to_int u.U.id);
                "avatar_url",`String (avatar_url c u);
                "sgid",`String (Global_id.attachable_sgid
                  ~secret_key_base:c.H.secret_key_base ~gid)]) users in
            response (H.json ~status:200 (`List values)))
          else if accepts c Http_format.Html then
            let mentions=List.map (fun (row:U.t) ->
              let mention=View_presenter.mention_of_user c row in
              {Views.user=View_presenter.user c row;
                sgid=mention.Rich_text.attachable_sgid}) users in
            response (H.html ~status:200
              (Views.autocomplete_users mentions |> Views.render))
          else error 406

let endpoint name : H.endpoint option =
  let regular action = Some {H.action;before_action=H.default_before_action} in
  let bot action = Some {H.action;before_action=H.before ~access:H.Bot_allowed ()} in
  let missing = Some {H.action=(fun _ -> head 404);
    before_action=(fun _ -> Lwt.return (Ok ()))} in
  match name with
  | "autocompletable/users#index" -> regular autocomplete
  | "rooms#index" | "rooms/opens#index" | "rooms/closeds#index" | "rooms/directs#index" -> regular rooms_index
  | "rooms#show" -> regular room_show
  | "rooms#destroy" -> regular room_destroy
  | "rooms/opens#show" | "rooms/closeds#show" -> regular room_type_show
  | "rooms/opens#new" -> regular (room_type_form R.Open)
  | "rooms/closeds#new" -> regular (room_type_form R.Closed)
  | "rooms/opens#create" -> regular (room_type_create R.Open)
  | "rooms/closeds#create" -> regular (room_type_create R.Closed)
  | "rooms/opens#edit" -> regular (room_type_edit R.Open)
  | "rooms/closeds#edit" -> regular (room_type_edit R.Closed)
  | "rooms/opens#update" -> regular (room_type_update R.Open)
  | "rooms/closeds#update" -> regular (room_type_update R.Closed)
  | "rooms/opens#destroy" | "rooms/closeds#destroy" -> regular room_nil_action
  | "rooms/directs#new" -> regular (fun c ->
      View_presenter.load_context c >|= fun context ->
      H.html ~status:200 (Views.direct_new ~context))
  | "rooms/directs#create" -> regular direct_create
  | "rooms/directs#edit" -> regular direct_edit
  | "rooms/directs#show" -> regular direct_show
  | "rooms/directs#destroy" -> regular direct_destroy
  | "rooms/involvements#show" -> regular involvement_show
  | "rooms/involvements#update" -> regular involvement_update
  | "rooms/refreshes#show" -> regular refresh_show
  | "messages#index" -> regular message_index
  | "messages#create" -> regular message_create
  | "messages#show" -> regular message_show
  | "messages#edit" -> regular message_edit
  | "messages#update" -> regular message_update
  | "messages#destroy" -> regular message_destroy
  | "messages/boosts#index" -> regular boost_index
  | "messages/boosts#new" -> regular boost_new
  | "messages/boosts#create" -> regular boost_create
  | "messages/boosts#destroy" -> regular boost_destroy
  | "messages/by_bots#index" -> bot bot_index
  | "messages/by_bots#create" -> bot bot_create
  | "messages/by_bots#update" -> bot bot_update
  | "messages/by_bots#destroy" -> bot bot_destroy
  | "messages/boosts/by_bots#create" -> bot bot_boost_create
  | "messages/boosts/by_bots#destroy" -> bot bot_boost_destroy
  | "searches#index" -> regular search_index
  | "searches#create" -> regular search_create
  | "searches#clear" -> regular search_clear
  | "rooms/settings#show" -> Some {H.action=(fun _ -> error 500);
      before_action=(fun _ -> Lwt.return (Ok ()))}
  | name when List.exists (fun prefix -> String.starts_with ~prefix name)
      ["rooms#";"rooms/directs#";"messages#";"messages/boosts#"] -> missing
  | _ -> None

(** Account, onboarding, session, and user actions from the pinned Rust port.
    HTML rendering is intentionally a small seam for the M4 view port.  All
    database work in actions goes through the asynchronous runtime API. *)

open Lwt.Infix

module H = Http_app
module A = Db_accounts
module U = A.User
module R = Db_rooms.Room
module P = Db_remaining.Push_subscription

let storage_service : Storage_disk.t option ref = ref None
let register_storage service = storage_service := Some service

let response value = Lwt.return value
let empty status = H.respond ~status ~content_type:"text/html; charset=utf-8" ""
let not_found () = response (empty 404)
let record_not_found () = response (H.error ~status:404)
let bad_request c =
  let format=match c.H.format with
    | [] | Http_format.All :: _ -> Http_format.Html
    | format :: _ -> format in
  response (H.respond ~status:400 ~content_type:(Http_format.mime format) "")
let parameter_missing c =
  (* params.require raises before rendering. PublicExceptions bypasses app
     headers and cookies; Http_cache.finish removes this internal marker. *)
  let content_type,body=match c.H.format with
    | Http_format.Json :: _ ->
        "application/json; charset=UTF-8","{\"status\":400,\"error\":\"Bad Request\"}"
    | Http_format.Xml :: _ ->
        "application/xml; charset=UTF-8",
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<hash>\n  <status type=\"integer\">400</status>\n  <error>Bad Request</error>\n</hash>\n"
    | _ -> "text/html; charset=UTF-8","" in
  let body=if c.H.method_="HEAD" then "" else body in
  response (H.respond ~status:400 ~content_type
    ~headers:["x-campfire-public-exception","1";
              "content-length",string_of_int (String.length body)] body)
let forbidden () = response (empty 403)
let accepts c kind = Http_format.negotiate c.H.format [kind] = Some kind
let html c title =
  if not (accepts c Http_format.Html) then response (H.error ~status:406)
  else response (H.html ~status:200 ("<!DOCTYPE html><html><head><title>" ^ title ^
    "</title></head><body><main><h1>" ^ title ^ "</h1></main></body></html>"))
let view c render =
  if not (accepts c Http_format.Html) then response (H.error ~status:406)
  else View_presenter.load_context c >|= fun context ->
    H.html ~status:200 (render context)
let absolute c path = H.base_url c ^ path
let redirect c path = response (H.redirect (absolute c path))
let redirect_raw path = response (H.redirect path)
let redirect_with_notice c path notice =
  H.session_set c "flash" (`Assoc [
    "flashes", `Assoc ["notice", `String notice];
    "discard", `List []]);
  redirect c path
let read c f = Db_runtime.read_async c.H.runtime f
let write c f = Db_runtime.write_async c.H.runtime f
let number c key = Option.bind (H.param_string c key) Int64.of_string_opt
let object_param c key = match H.param c key with
  | Some (Http_params.Object fields) -> Some fields | _ -> None
let field fields key = Http_params.find_string key fields
let field_present fields key = List.mem_assoc key fields
let current_id c = match c.H.auth with
  | Some (Authentication.Authenticated a) -> Some a.user.id | _ -> None
let current_user c = match current_id c with
  | None -> Lwt.return_none
  | Some id -> read c (fun db -> U.find_by_id db id)
let admin_before c =
  H.default_before_action c >>= function
  | Error _ as result -> Lwt.return result
  | Ok () -> current_user c >|= function
      | Some user when U.is_administrator user -> Ok ()
      | _ -> Error (empty 403)

let start_session c user =
  write c (fun tx -> A.Session.start (Db_runtime.conn tx) ~now:c.H.now
    ~user_id:user.U.id ~user_agent:(H.header c "user-agent")
    ~ip_address:(Some c.H.remote_ip)) >|= fun session ->
  let cookie = { (Cookie_http.cookie session.A.Session.token) with
    permanent=true; httponly=true } in
  ignore (Cookie_http.set_signed c.H.cookies ~secret_key_base:c.H.secret_key_base
    "session_token" cookie)

let post_auth_path c =
  let path = match H.session_get c "return_to_after_authenticating" with
    | Some (`String path) -> path
    | Some value when value <> `Null -> Yojson.Basic.to_string value
    | _ -> absolute c "/" in
  H.session_remove c "return_to_after_authenticating"; path

let welcome c =
  match current_id c with
  | None -> redirect c "/session/new"
  | Some user_id ->
      read c (fun db ->
        let rooms = Db_rooms.Room.for_user db user_id in
        if rooms = [] then None else
        let last = Option.bind (Cookie_http.get c.H.cookies "last_room") Int64.of_string_opt in
        let selected = match last with
          | Some id -> List.find_opt (fun (room : Db_rooms.Room.t) -> room.id=id) rooms
          | None -> None in
        Some (Option.value selected ~default:(Option.get (Db_rooms.Room.original_for_user db user_id))))
      >>= function
      | None -> view c (fun context -> Views.welcome ~context ())
      | Some room -> redirect c (Route_helpers.room (Int64.to_string room.Db_rooms.Room.id))

let first_run_prevent c = read c A.Account.first >|= Option.is_some
let first_run_show c = first_run_prevent c >>= function
  | true -> redirect c "/"
  | false -> view c (fun context -> Views.first_run ~context ())
let first_run_create c =
  first_run_prevent c >>= function
  | true -> redirect c "/"
  | false -> match object_param c "user" with
    | None -> parameter_missing c
    | Some fields -> match field fields "name" with
      | None -> response (H.error ~status:500)
      | Some name ->
          let email_address = Option.value (field fields "email_address") ~default:"" in
          let password = Option.value (field fields "password") ~default:"" in
          Lwt_preemptive.detach A.Password.digest password >>= fun password_digest ->
          Lwt.catch
            (fun () -> write c (fun tx -> A.First_run.create_tx tx ~now:c.H.now ~name
              ~email_address ~password_digest) >>= fun user ->
              start_session c user >>= fun () -> redirect c "/")
            (function
              | Sqlite3.SqliteError error when String.starts_with
                  ~prefix:"UNIQUE constraint failed" error -> redirect c "/"
              | _ -> response (H.error ~status:500))

let render_session_new c ~status ?alert owner =
  if not (accepts c Http_format.Html) then response (H.error ~status:406)
  else View_presenter.load_context c >|= fun context ->
    let context = { context with Views.flash_alert=alert } in
    H.html ~status (Views.session_new ~context
      ?email_address:(H.param_string c "email_address")
      ?help_contact:(Option.bind owner (fun (user : U.t) ->
        Option.map (fun email -> user.name, email) user.email_address)) ())

let session_new c =
  read c (fun db -> U.count db,
    List.find_opt U.is_administrator (U.active_ordered_without_bots db))
  >>= fun (count, owner) ->
  if count = 0 then redirect c "/first_run"
  else render_session_new c ~status:200 owner

let rate_limits : (string, int * float) Hashtbl.t = Hashtbl.create 64
let rate_mutex = Mutex.create ()
let session_rate_limit c =
  let now = Authentication.now_time c.H.now |> Ptime.to_float_s in
  Mutex.lock rate_mutex;
  let count, expires = match Hashtbl.find_opt rate_limits c.H.remote_ip with
    | Some (count, expires) when expires > now -> count + 1, expires
    | _ -> 1, now +. 180. in
  Hashtbl.replace rate_limits c.H.remote_ip (count, expires);
  Mutex.unlock rate_mutex;
  count > 10
let session_reject c status =
  read c (fun db -> List.find_opt U.is_administrator
    (U.active_ordered_without_bots db)) >>= fun owner ->
  render_session_new c ~status ~alert:"Too many requests or unauthorized." owner
let session_create c =
  if session_rate_limit c then session_reject c 429
  else match H.param_string c "email_address", H.param_string c "password" with
    | Some email_address, Some password ->
        read c (fun db -> U.authenticate_by_email_address db ~email_address ~password)
        >>= (function
          | None -> session_reject c 401
          | Some user -> start_session c user >>= fun () -> redirect_raw (post_auth_path c))
    | _ -> session_reject c 401
let session_destroy c =
  let delete_push tx = match H.param_string c "push_subscription_endpoint", current_id c with
    | Some endpoint, Some user_id ->
        P.destroy_by_endpoint tx ~user_id ~endpoint
    | _ -> () in
  write c (fun tx ->
    delete_push tx;
    (match c.H.auth with
     | Some (Authentication.Authenticated identity) ->
         let session = A.Session.find (Db_runtime.conn tx) identity.session.id in
         A.Session.destroy (Db_runtime.conn tx) session;
         Db_remaining.Hooks.reset_remote_connections tx
           ~sink:c.H.event_sink (U.find (Db_runtime.conn tx) identity.user.id)
     | _ -> ())) >>= fun () ->
  H.reset_session c; Cookie_http.delete c.H.cookies "session_token";
  redirect c "/"

let session_transfer_show c = match H.param_string c "id" with
  | None -> bad_request c
  | Some transfer_id -> View_presenter.load_context c >|= fun context ->
      H.html ~status:200 (Views.session_transfer ~context ~transfer_id)
let session_transfer_update c =
  let user_id = Option.bind (H.param_string c "id") (fun raw ->
    Signed_id.verify ~secret_key_base:c.H.secret_key_base ~model:"User" ~raw
      ~purpose:(Some "transfer") ~now:c.H.now ()) in
  match user_id with
  | None -> bad_request c
  | Some id -> read c (fun db ->
      match U.find_by_id db (Int64.of_int id) with
      | Some user when U.is_active user -> Some user | _ -> None) >>= function
      | None -> bad_request c
      | Some user -> start_session c user >>= fun () -> redirect_raw (post_auth_path c)

let join_code c = read c A.Account.first >|= function
  | None -> `Missing_account
  | Some account when H.param_string c "join_code" = Some account.A.Account.join_code -> `Valid
  | Some _ -> `Invalid
let join_new c = join_code c >>= function
  | `Missing_account -> response (H.error ~status:500)
  | `Invalid -> not_found ()
  | `Valid ->
      read c (fun db -> Db_runtime.query_one db
        "SELECT name,email_address FROM users WHERE role=1 ORDER BY id ASC LIMIT 1" []
        (fun row -> Sqlite3.column_text row 0,
          match Sqlite3.column row 1 with
          | Sqlite3.Data.NULL -> "" | _ -> Sqlite3.column_text row 1))
      >>= fun help_contact ->
      view c (fun context -> Views.join_new_with ~context
        ~join_code:(Option.value (H.param_string c "join_code") ~default:"")
        ?help_contact ())
let join_create c = join_code c >>= function
  | `Missing_account -> response (H.error ~status:500)
  | `Invalid -> not_found ()
  | `Valid -> match object_param c "user" with
    | None -> parameter_missing c
    | Some fields -> match field fields "name" with
      | None -> response (H.error ~status:500)
      | Some name ->
          let email_address = field fields "email_address" in
          let password_digest = match field fields "password" with
            | Some password when password <> "" ->
                Lwt_preemptive.detach A.Password.digest password >|= Option.some
            | _ -> Lwt.return_none in
          password_digest >>= fun password_digest ->
          let attributes = {U.name; email_address; password_digest;
            role=U.Member; bio=None; bot_token=None} in
          Lwt.catch
            (fun () -> write c (fun tx -> U.create_tx tx ~now:c.H.now attributes)
              >>= fun user -> start_session c user >>= fun () -> redirect c "/")
            (function
              | Sqlite3.SqliteError error when String.starts_with
                  ~prefix:"UNIQUE constraint failed" error ->
                  let path = "/session/new" ^ match email_address with
                    | None -> "" | Some email -> "?email_address=" ^ Uri.pct_encode email in
                  redirect c path
              | _ -> response (H.error ~status:500))

let account_edit c =
  if not (accepts c Http_format.Html) then response (H.error ~status:406)
  else read c (fun db ->
    let account=A.Account.first db in
    let can_admin=match c.H.current_user with
      | Some user -> U.is_administrator user | None -> false in
    let users=Db_runtime.query_all db
      (U.select ^ (if can_admin then
        " WHERE status IN (0,2) AND role<>2 ORDER BY LOWER(name)"
        else " WHERE status=0 AND role<>2 ORDER BY LOWER(name)")) [] U.decode in
    let has_custom_logo=match account with None -> false | Some account ->
      Option.is_some (Db_remaining.Attachment.find_for db
        ~record_type:"Account" ~record_id:account.id ~name:"logo") in
    let last_room=match current_id c with
      | None -> None
      | Some user_id ->
        let selected=Option.bind
          (Option.bind (Cookie_http.get c.H.cookies "last_room") Int64.of_string_opt)
          (R.find_for_user db user_id) in
        (match selected with Some _ -> selected | None -> R.original_for_user db user_id) in
    account,users,has_custom_logo,Option.map (fun (room:R.t) -> room.id) last_room)
  >>= function
  | None, _, _, _ -> response (H.error ~status:500)
  | Some account, users, has_custom_logo, last_room_id ->
      let context = View_presenter.context ~has_custom_logo c (Some account) in
      let users=List.map (fun (user:U.t) ->
        {Views.user=View_presenter.user c user;
         status=(match user.status with
           | U.Active -> "active" | U.Deactivated -> "deactivated" | U.Banned -> "banned")}) users in
      let administrators,members=List.partition (fun (item:Views.account_member) ->
        item.user.role="administrator") users in
      let page=Option.value (H.param_string c "page") ~default:"0"
        |> Ruby_compat.to_i |> Int64.to_int |> max 1 |> min 1_000_000_000 in
      let page_count=max 1 ((List.length users + 499) / 500) in
      let next_page=if page=page_count then None else Some (string_of_int (page+1)) in
      response (H.html ~status:200 (Views.account_edit_page ~context
        ?last_room_id ~account_id:account.id
        ~join_code:account.join_code
        ~restrict_room_creation:(A.Account.restrict_room_creation_to_administrators account)
        ~administrators ~members ?next_page ()))
let account_update c = match object_param c "account" with
  | None -> parameter_missing c
  | Some fields ->
      let name = field fields "name" in
      let settings = match Http_params.find "settings" fields with
        | Some (Http_params.Object values) ->
            Some (List.filter_map (fun (key, value) -> match value with
              | Http_params.Text value -> Some (key, value) | _ -> None) values)
        | _ -> None in
      write c (fun tx ->
        let db = Db_runtime.conn tx in
        let account = Option.get (A.Account.first db) in
        ignore (A.Account.update db ~now:c.H.now account ?name ?settings ()))
      >>= fun () -> redirect_with_notice c "/account/edit" "✓"
let account_join_code c =
  write c (fun tx -> let db=Db_runtime.conn tx in
    let account=Option.get (A.Account.first db) in
    ignore (A.Account.reset_join_code db ~now:c.H.now account))
  >>= fun () -> redirect c "/account/edit"
let account_styles_edit c = read c A.Account.first >>= function
  | None -> not_found ()
  | Some account -> view c (fun context -> Views.custom_styles_edit ~context
      ~styles:(Option.value account.A.Account.custom_styles ~default:""))
let account_styles_update c = match object_param c "account" with
  | None -> parameter_missing c
  | Some fields ->
      let custom_styles = if field_present fields "custom_styles" then
        Some (field fields "custom_styles") else None in
      write c (fun tx -> let db=Db_runtime.conn tx in
        let account=Option.get (A.Account.first db) in
        ignore (A.Account.update db ~now:c.H.now account ?custom_styles ()))
      >>= fun () -> redirect_with_notice c "/account/custom_styles/edit" "✓"

let find_user c key = match number c key with
  | None -> Lwt.return_none
  | Some id -> read c (fun db -> U.find_by_id db id)
let account_users_index c =
  if not (accepts c Http_format.Turbo_stream) then response (H.error ~status:406)
  else read c U.active_ordered_without_bots >>= fun users ->
    let page = Option.value (H.param_string c "page") ~default:"0"
      |> Ruby_compat.to_i |> Int64.to_int in
    let page = max 1 (min 1_000_000_000 page) in
    let start = (page - 1) * 500 in
    let users = List.mapi (fun index user -> index,user) users in
    let has_next = List.exists (fun (index,_) -> index >= start + 500) users in
    let users = users |> List.filter_map (fun (index,user) ->
      if index >= start && index < start + 500 then
        Some {Views.user=View_presenter.user c user; status="active"} else None) in
    let next_page = if has_next then Some (string_of_int (page + 1)) else None in
    View_presenter.load_context c >>= fun context ->
    response (H.respond ~status:200
      ~content_type:"text/vnd.turbo-stream.html; charset=utf-8"
      (Views.account_users_page_stream ~context ~users ?next_page ()))
let account_user_update c = match object_param c "user" with
  | None -> parameter_missing c
  | Some fields -> find_user c "id" >>= function
      | None -> record_not_found ()
      | Some user when not (U.is_active user) -> record_not_found ()
      | Some user ->
          let role = match field fields "role" with
            | Some "administrator" -> U.Administrator | _ -> U.Member in
          write c (fun tx -> ignore (U.update (Db_runtime.conn tx) ~now:c.H.now user
            { U.no_changes with role=Some role })) >>= fun () ->
          redirect c "/account/edit"
let account_user_destroy c = find_user c "id" >>= function
  | None -> record_not_found ()
  | Some user when not (U.is_active user) -> record_not_found ()
  | Some user -> write c (fun tx -> ignore (Db_remaining.Hooks.deactivate_user
      tx ~now:c.H.now ~sink:c.H.event_sink user))
      >>= fun () -> redirect c "/account/edit"

let bots_index c =
  read c (fun db -> U.active_bots_ordered db |> List.map (fun bot ->
    let rooms = R.for_user_without_directs db bot.U.id in
    let rooms = List.sort (fun (left:R.t) right ->
      String.compare
        (String.lowercase_ascii (Option.value left.name ~default:""))
        (String.lowercase_ascii (Option.value right.name ~default:""))) rooms in
    bot, List.map (fun (room:R.t) ->
      Option.value room.name ~default:"", "/rooms/" ^ Int64.to_string room.id ^ "/" ^
        U.bot_key bot ^ "/messages") rooms)) >>= fun bots ->
  view c (fun context -> Views.bots_index ~context
    ~bots:(List.map (fun (bot,rooms) -> View_presenter.user c bot,rooms) bots))
let bots_new c = view c (fun context -> Views.bot_form ~context ())
let bot_find c key = match number c key with
  | None -> Lwt.return_none
  | Some id -> read c (fun db ->
      match U.find_by_id db id with
      | Some user when U.is_active user && U.is_bot user -> Some user
      | _ -> None)
let bots_edit c = bot_find c "id" >>= function
  | None -> record_not_found ()
  | Some bot ->
      read c (fun db ->
        let webhook_url=U.webhook_url db bot in
        let avatar=Option.map (Db_remaining.Attachment.blob db)
          (Db_remaining.Attachment.find_for db ~record_type:"User"
            ~record_id:bot.U.id ~name:"avatar") in
        webhook_url,avatar) >>= fun (webhook_url,avatar) ->
      let avatar_attachment_url=Option.map (fun blob -> absolute c
        (Storage_blob.blob_path "redirect"
          ~secret_key_base:c.H.secret_key_base blob ())) avatar in
      view c (fun context -> Views.bot_form_page ~context
        ~bot_id:bot.U.id ~name:bot.U.name ?webhook_url
        ?avatar_attachment_url ())
let bots_create c = match object_param c "user" with
  | None -> parameter_missing c
  | Some fields -> match field fields "name" with
    | None -> response (H.error ~status:500)
    | Some name ->
        let webhook_url = field fields "webhook_url" in
        write c (fun tx -> ignore (U.create_bot_tx tx ~now:c.H.now ~name ?webhook_url ()))
        >>= fun () -> redirect c "/account/bots"
let bots_update c = match object_param c "user" with
  | None -> parameter_missing c
  | Some fields -> bot_find c "id" >>= function
    | None -> record_not_found ()
    | Some bot ->
        let changes = {U.no_changes with name=field fields "name"} in
        let webhook_url = field fields "webhook_url" in
        write c (fun tx -> ignore (U.update_bot (Db_runtime.conn tx) ~now:c.H.now bot
          changes ~webhook_url)) >>= fun () -> redirect c "/account/bots"
let bots_destroy c = bot_find c "id" >>= function
  | None -> record_not_found ()
  | Some bot -> write c (fun tx -> ignore (Db_remaining.Hooks.deactivate_user
      tx ~now:c.H.now ~sink:c.H.event_sink bot))
      >>= fun () -> redirect c "/account/bots"
let bot_key_update c = bot_find c "bot_id" >>= function
  | None -> record_not_found ()
  | Some bot -> write c (fun tx -> ignore (U.reset_bot_key (Db_runtime.conn tx) ~now:c.H.now bot))
      >>= fun () -> redirect c "/account/bots"

let transfer_id c (user:U.t) =
  let now=Authentication.now_time c.H.now in
  let expires_at=Ptime.add_span now (Ptime.Span.of_int_s (4 * 60 * 60))
    |> Option.map (Authentication.utc_rfc3339 ~frac_s:3) in
  Signed_id.generate ~secret_key_base:c.H.secret_key_base ~model:"User"
    ~id:(Int64.to_int user.id) ~purpose:(Some "transfer") ~expires_at

let back_url c =
  let request_url=Uri.to_string (Cohttp.Request.uri c.H.request) in
  match H.header c "referer" with
  | Some referer when referer<>request_url -> referer
  | _ -> "/"

let user_status (user:U.t) = match user.status with
  | U.Active -> "active" | U.Deactivated -> "deactivated" | U.Banned -> "banned"

let user_show c = find_user c "id" >>= function
  | None -> record_not_found ()
  | Some user -> view c (fun context -> Views.user_show_page ~context
      ~back_url:(back_url c) ~user:(View_presenter.user c user)
      ~email_address:(Option.value user.U.email_address ~default:"")
      ~bio:user.U.bio ~status:(user_status user)
      ~transfer_id:(transfer_id c user) ())

let profile_memberships db (user:U.t) =
  let sentence = function
    | [] -> user.name
    | [name] -> name
    | [left;right] -> left ^ " and " ^ right
    | names ->
        let rev=List.rev names in
        String.concat ", " (List.rev (List.tl rev)) ^ ", and " ^ List.hd rev in
  let convert ((membership:Db_rooms.Membership.t),(room:R.t)) : Views.profile_membership =
    let direct=R.direct room in
    let room_display_name=if direct then
      R.users db room |> List.filter_map (fun (member:U.t) ->
        if member.id=user.id then None else Some member.name) |> sentence
      else Option.value room.name ~default:"" in
    {room_id=room.id;
     room_param_key=(match room.room_type with
       | Db_rooms.Open -> "rooms_open"
       | Db_rooms.Closed -> "rooms_closed"
       | Db_rooms.Direct -> "rooms_direct");
     room_display_name;
     involvement=Option.fold ~none:"" ~some:Db_rooms.involvement_name
       membership.involvement;
     direct} in
  let all=Db_rooms.Membership.with_ordered_room db user.id |> List.map convert in
  List.partition (fun (item:Views.profile_membership) -> item.direct) all

let profile_show c = current_user c >>= function
  | None -> forbidden ()
  | Some user ->
      read c (fun db ->
        let avatar_attached=Option.is_some (Db_remaining.Attachment.find_for db
          ~record_type:"User" ~record_id:user.U.id ~name:"avatar") in
        let direct_memberships,shared_memberships=profile_memberships db user in
        avatar_attached,direct_memberships,shared_memberships)
      >>= fun (avatar_attached,direct_memberships,shared_memberships) ->
      view c (fun context -> Views.profile_show_page ~context
        ~back_url:(back_url c) ~user:(View_presenter.user c user)
        ~email_address:(Option.value user.U.email_address ~default:"")
        ~bio:user.U.bio ~avatar_attached ~transfer_id:(transfer_id c user)
        ~shared_memberships ~direct_memberships ())
let profile_update c = match object_param c "user" with
  | None -> parameter_missing c
  | Some fields -> current_user c >>= function
    | None -> forbidden ()
    | Some user ->
        let password_digest = match field fields "password" with
          | Some password when password <> "" ->
              Lwt_preemptive.detach A.Password.digest password >|= Option.some
          | _ -> Lwt.return_none in
        password_digest >>= fun password_digest ->
        let changes = {U.no_changes with name=field fields "name";
          email_address=Option.map (fun value -> Some value) (field fields "email_address");
          password_digest;
          bio=Option.map (fun value -> Some value) (field fields "bio")} in
        write c (fun tx -> ignore (U.update (Db_runtime.conn tx) ~now:c.H.now user changes))
        >>= fun () -> redirect_with_notice c "/users/me/profile"
          (if field_present fields "avatar" then
             "It may take up to 30 minutes to change everywhere." else "✓")
let user_ban c = find_user c "user_id" >>= function
  | None -> record_not_found ()
  | Some user ->
      let path = Route_helpers.user (Int64.to_string user.U.id) in
      write c (fun tx ->
        ignore (Db_remaining.Hooks.ban_user tx ~now:c.H.now
          ~sink:c.H.event_sink user))
      >>= fun () -> redirect c path
let user_unban c = find_user c "user_id" >>= function
  | None -> record_not_found ()
  | Some user ->
      let path = Route_helpers.user (Int64.to_string user.U.id) in
      write c (fun tx -> ignore (U.unban (Db_runtime.conn tx) ~now:c.H.now user))
      >>= fun () -> redirect c path
let sidebar_show c = match current_id c with
  | None -> forbidden ()
  | Some user_id ->
      if not (accepts c Http_format.Html) then response (H.error ~status:406)
      else match H.private_lookup c with
      | Some cached -> response cached
      | None -> read c (fun db ->
        let account = Db_accounts.Account.first db in
        let memberships = Db_rooms.Membership.visible_with_ordered_room db user_id in
        let directs,shared = List.partition (fun (_,room) ->
          room.R.room_type=Db_rooms.Direct) memberships in
        let directs = List.sort (fun (_,a) (_,b) ->
          String.compare b.R.updated_at a.R.updated_at) directs in
        let entries = List.map (fun (membership,room) ->
          let members = if room.R.room_type=Db_rooms.Direct then
            let others = R.users db room |> List.filter (fun (member:U.t) ->
              member.id<>user_id) in
            (if others=[] then [U.find db user_id] else others)
            |> List.map (View_presenter.user c)
          else [] in
          {Views.room=View_presenter.room room;
           unread=Db_rooms.Membership.unread membership;members})
          (directs @ shared) in
        let all_directs = R.for_user_of_type db user_id Db_rooms.Direct in
        let excluded = user_id :: List.concat_map (R.user_ids db) all_directs in
        let placeholder_limit = max 0 (20 - List.length (List.sort_uniq Int64.compare excluded) - 1) in
        let placeholders = U.active db
          |> List.filter (fun (member:U.t) -> not (List.mem member.id excluded))
          |> List.sort (fun (a:U.t) (b:U.t) ->
               String.compare a.created_at b.created_at)
          |> List.filteri (fun i _ -> i<placeholder_limit)
          |> List.map (View_presenter.user c) in
        let can_create_rooms = match c.H.current_user,account with
          | Some user,Some account -> U.is_administrator user ||
              not (Db_accounts.Account.restrict_room_creation_to_administrators account)
          | _ -> false in
        View_presenter.context
          ~has_custom_logo:(View_presenter.has_custom_logo db account)
          c account,entries,placeholders,can_create_rooms)
      >|= fun (context,entries,placeholders,can_create_rooms) ->
      let secret_key_base = c.H.secret_key_base in
      let rooms_stream_name = Turbo_stream.signed_stream_name
        ~secret_key_base ["rooms"] in
      let user_rooms_stream_name = Turbo_stream.signed_stream_name
        ~secret_key_base [Global_id.to_param (Cable_channels.user_gid user_id);"rooms"] in
      let rooms=List.map (fun (entry:Views.sidebar_entry) -> entry.room) entries in
      let frame_request=match H.header c "turbo-frame" with
        | Some id -> String.trim id<>"" | None -> false in
      let body=if frame_request then
        Views.sidebar_frame ~context ~rooms ~entries ~placeholders
          ~can_create_rooms ~rooms_stream_name ~user_rooms_stream_name ()
        |> Views.frame_page
      else Views.sidebar_page ~context ~rooms ~entries ~placeholders
          ~can_create_rooms ~rooms_stream_name ~user_rooms_stream_name () in
      H.html ~status:200 body

let push_index c = match current_id c with
  | None -> forbidden ()
  | Some user_id ->
      if not (accepts c Http_format.Html) then
        response (H.error ~status:406)
      else
        let last_cookie=Option.bind (Cookie_http.get c.H.cookies "last_room")
          Int64.of_string_opt in
        read c (fun db ->
          let subscriptions=P.for_user db user_id in
          let last_room=Option.bind last_cookie (R.find_for_user db user_id) in
          let last_room=match last_room with
            | Some room -> Some room | None -> R.original_for_user db user_id in
          subscriptions,Option.map (fun (room:R.t) -> room.id) last_room)
        >>= fun (subscriptions,last_room_id) ->
        let push_subscriptions=List.map (fun (row:P.t) ->
          let agent=User_agent.parse
            (Option.value row.user_agent ~default:"") in
          { Views.id=row.id;
            endpoint=Option.value row.endpoint ~default:"";
            browser=User_agent.browser agent;
            version=User_agent.version agent;
            platform=Option.value (User_agent.platform agent) ~default:"" })
          subscriptions in
        view c (fun context -> Views.push_subscriptions_index ~context
          ?last_room_id ~push_subscriptions ())
let push_value = function
  | Http_params.Nil -> Some ""
  | Http_params.Text value -> Some value
  | Http_params.Json_scalar (`Bool value) -> Some (string_of_bool value)
  | Http_params.Json_scalar (`Int value) -> Some (string_of_int value)
  | Http_params.Json_scalar (`Float value) -> Some (string_of_float value)
  | _ -> None

let matching_push_subscription db ~user_id fields =
  let query=Buffer.create 256 and bindings=ref [Sqlite3.Data.INT user_id] in
  Buffer.add_string query (P.select ^ " WHERE user_id=?");
  List.iter (fun key -> match Http_params.get key fields with
    | None -> ()
    | Some param ->
        (match push_value param with
         | None -> Buffer.add_string query (" AND " ^ key ^ " IS NULL")
         | Some value ->
             Buffer.add_string query (" AND " ^ key ^ "=?");
             bindings := Sqlite3.Data.TEXT value :: !bindings))
    ["endpoint";"p256dh_key";"auth_key"];
  Buffer.add_string query " LIMIT 1";
  Db_runtime.query_one db (Buffer.contents query)
    (List.rev !bindings) P.decode

let push_create c =
  let fields = match object_param c "push_subscription" with
    | Some fields -> Some fields
    | None -> if Routes.media_type (H.header c "content-type") = Some "application/json" then
        Some c.H.request_params else None in
  match current_id c, fields with
  | _, None -> parameter_missing c
  | None, _ -> forbidden ()
  | Some user_id, Some fields ->
      let resolve host =
        try Unix.getaddrinfo host "443" [Unix.AI_SOCKTYPE Unix.SOCK_STREAM]
            |> List.find_map (fun address -> match address.Unix.ai_addr with
              | Unix.ADDR_INET (ip, _) -> Some (Unix.string_of_inet_addr ip)
              | _ -> None)
        with _ -> None in
      let validate subscription =
        let endpoint=subscription.P.endpoint in
        Lwt_preemptive.detach (fun () ->
          let host = Option.bind endpoint (fun url -> Uri.host (Uri.of_string url)) in
          match host with
          | Some host when P.permitted_host host -> resolve host
          | _ -> None) () >|= fun resolved ->
        let lookup host = match Option.bind endpoint (fun url -> Uri.host (Uri.of_string url)) with
          | Some expected when host = expected -> resolved | _ -> None in
        P.validate subscription lookup,lookup in
      read c (fun db -> matching_push_subscription db ~user_id fields)
      >>= function
        | Some existing -> validate existing >>= fun (errors,_) ->
            if errors <> [] then response (empty 422) else
            write c (fun tx ->
              ignore (Db_runtime.execute (Db_runtime.conn tx)
                "UPDATE push_subscriptions SET updated_at=? WHERE id=?"
                [Sqlite3.Data.TEXT (Db_time.of_rfc3339 c.H.now);
                 Sqlite3.Data.INT existing.P.id]))
            >>= fun () -> response (empty 200)
        | None ->
            let value key=Option.bind (Http_params.get key fields) push_value in
            let candidate = P.new_ ~user_id
              ~endpoint:(value "endpoint") ~p256dh_key:(value "p256dh_key")
              ~auth_key:(value "auth_key")
              ~user_agent:(H.header c "user-agent") in
            validate candidate >>= fun (errors,lookup) ->
            if errors <> [] then response (empty 422) else
            Lwt.catch (fun () ->
              write c (fun tx -> ignore (P.create tx
                ~now:(Authentication.now_time c.H.now) ~resolve:lookup candidate))
              >>= fun () -> response (empty 200))
              (function Invalid_argument _ -> response (empty 422)
                | _ -> response (H.error ~status:500))
let push_destroy c = match current_id c, number c "id" with
  | Some user_id, Some id ->
      write c (fun tx ->
        match Db_runtime.query_one (Db_runtime.conn tx)
          (P.select ^ " WHERE id=? LIMIT 1") [Sqlite3.Data.INT id] P.decode with
        | Some subscription when subscription.P.user_id = user_id -> P.destroy tx subscription
        | _ -> ()) >>= fun () -> redirect c "/users/me/push_subscriptions"
  | _ -> redirect c "/users/me/push_subscriptions"

let push_test_notification c =
  match current_id c,
    Option.bind (H.param_string c "push_subscription_id") Ruby_compat.integer_cast with
  | Some user_id,Some id ->
    read c (fun db ->
      let subscription=Db_runtime.query_one db
        (P.select^" WHERE id=? LIMIT 1") [Sqlite3.Data.INT id] P.decode in
      match subscription with
      | Some subscription when subscription.P.user_id=user_id ->
        Some (subscription,Db_rooms.Membership.unread_count db user_id)
      | _ -> None) >>= (function
      | None -> not_found ()
      | Some (subscription,badge) ->
        let path=absolute c "/users/me/push_subscriptions" in
        (match !(App_jobs.current) with
         | None -> response (H.error ~status:500)
         | Some jobs ->
           Lwt.catch (fun () ->
             Lwt_preemptive.detach (fun () ->
               App_jobs.deliver_test_notification jobs ~subscription ~badge ~path) ()
             >>= function
             | Ok () -> redirect c "/users/me/push_subscriptions"
             | Error _ -> response (H.error ~status:500))
             (fun _ -> response (H.error ~status:500))))
  | _ -> not_found ()

let cache_key table id updated_at =
  let digits = String.to_seq updated_at |> Seq.filter (function
    | '0'..'9' -> true | _ -> false) |> String.of_seq in
  (* Active Record's cache_timestamp_format is %Y%m%d%H%M%S%6N. SQLite omits
     its zero fractional part, but Rails restores all six microsecond digits. *)
  let padded = digits ^ String.make (max 0 (20 - String.length digits)) '0' in
  let version = String.sub padded 0 (min 20 (String.length padded)) in
  table ^ "/" ^ Int64.to_string id ^ "-" ^ version

let media_headers c ~seconds ?validator ?template () =
  let etag_headers = match validator,template with
    | None,None -> []
    | _ -> ["etag",Http_cache.combined_etag ?template validator] in
  let headers = etag_headers @ ["cache-control",Printf.sprintf
    "max-age=%d, public, stale-while-revalidate=604800" seconds] in
  let fresh = Http_cache.is_fresh c.H.request (Cohttp.Header.of_list headers) in
  (* Rails expires_in sets Date from the application clock only for a fresh
     representation. The front cache retains that Date on a conditional hit. *)
  let headers = if fresh then headers else
    ("date",Http_cache.httpdate (Authentication.now_time c.H.now))::headers in
  headers,fresh

let media_response ~status ~content_type ~headers body =
  H.respond ~status ~content_type ~headers body

let not_modified headers =
  Cohttp.Response.make ~status:`Not_modified
    ~headers:(Cohttp.Header.of_list headers) (),Cohttp_lwt.Body.empty

let stock_file ~logical ~filename ~content_type ~headers =
  let path=Assets.asset_path logical in
  match Assets.serve ~method_:"GET" ~path () with
  | None -> response (empty 404)
  | Some asset ->
      let disposition=Storage_disk.disposition "inline" filename in
      let headers=Cohttp.Header.of_list
        (("content-type",content_type)::
          ("content-transfer-encoding","binary")::
          ("content-disposition",disposition)::
          ("content-length",string_of_int (String.length asset.body))::headers) in
      Lwt.return (Cohttp.Response.make ~status:`OK ~headers (),
        Cohttp_lwt.Body.of_stream (Lwt_stream.of_list [asset.body]))

let variant_file c service blob ~content_type ~headers =
  let path=Storage_disk.path_for service blob.Db_remaining.Blob.key in
  if not (Sys.file_exists path) then response (empty 404)
  else let disposition=Storage_disk.disposition "inline"
      (Filename.basename path) in
    let served=Storage_file_server.serve ~method_:c.H.original_method
      ?range:(H.header c "range")
      ~path ~content_type ~disposition () in
    (* Rails' send_file response does not expose the file mtime. Freshness is
       governed by the model ETag produced by stale? above. *)
    let served_headers=List.filter (fun (name,_) ->
      String.lowercase_ascii name <> "last-modified") served.headers in
    let response=Cohttp.Response.make
      ~status:(Cohttp.Code.status_of_code served.status)
      ~headers:(Cohttp.Header.of_list
        (("content-transfer-encoding","binary")::headers @ served_headers)) () in
    Lwt.return (response,Storage_file_server.stream served.body)

let attachment_blob c ~record_type ~record_id ~name =
  read c (fun db -> match Db_remaining.Attachment.find_for db
    ~record_type ~record_id ~name with
    | None -> None
    | Some attachment -> Some (Db_remaining.Attachment.blob db attachment))

let processed_image c service blob variation =
  if not (Storage_image.is_variable blob) then Lwt.return_none
  else Lwt_preemptive.detach (fun () -> Some
    (Storage_image.process_variant c.H.runtime service blob variation
      ~now:(A.now_time c.H.now))) ()

let account_logo_show c =
  read c A.Account.first >>= fun account ->
  let validator=Option.map (fun (row:A.Account.t) ->
    cache_key "accounts" row.id row.updated_at) account in
  let headers,fresh=media_headers c ~seconds:300 ?validator () in
  if fresh then response (not_modified headers) else
  let small=H.param_string c "size"=Some "small" in
  let size=if small then 192 else 512 in
  let stock () = stock_file
    ~logical:(if small then "logos/app-icon-192.png" else "logos/app-icon.png")
    ~filename:(if small then "app-icon-192.png" else "app-icon.png")
    ~content_type:"image/png" ~headers in
  match account,!storage_service with
  | Some account,Some service ->
      attachment_blob c ~record_type:"Account" ~record_id:account.id
        ~name:"logo" >>= (function
        | None -> stock ()
        | Some blob ->
            processed_image c service blob
              (Storage_variation.resize_to_limit ~format:"png" size size)
            >>= (function
            | None -> stock ()
            | Some output -> variant_file c service output
                ~content_type:"image/png" ~headers))
  | _ -> stock ()
let account_logo_destroy c =
  read c A.Account.first >>= function
  | None -> response (H.error ~status:500)
  | Some account ->
      write c (fun tx ->
        let db=Db_runtime.conn tx in
        match Db_remaining.Attachment.find_for db
          ~record_type:"Account" ~record_id:account.id ~name:"logo" with
        | None -> None
        | Some attachment ->
            Db_remaining.Attachment.delete tx attachment;
            ignore (Db_runtime.execute db
              "UPDATE accounts SET updated_at=? WHERE id=?"
              [Sqlite3.Data.TEXT (Db_time.of_rfc3339 c.H.now);
               Sqlite3.Data.INT account.id]);
            Some attachment.blob_id)
      >>= (function
        | None -> Lwt.return_unit
        | Some blob_id -> match !storage_service with
          | None ->
              c.H.event_sink (Db_remaining.Event.PurgeBlob {blob_id});
              Lwt.return_unit
          | Some service -> Lwt_preemptive.detach (fun () ->
              match Db_runtime.read c.H.runtime (fun db ->
                Db_runtime.query_one db
                  (Db_remaining.Blob.select ^ " WHERE id=? LIMIT 1")
                  [Sqlite3.Data.INT blob_id] Db_remaining.Blob.decode) with
              | None -> ()
              | Some blob -> Storage_blob.purge c.H.runtime service blob) ())
      >>= fun () -> redirect c "/account/edit"
let avatar_show c =
  let id=Option.bind (H.param_string c "user_id") (fun raw ->
    Signed_id.verify ~secret_key_base:c.H.secret_key_base ~model:"User"
      ~raw ~purpose:(Some "avatar") ~now:c.H.now ())
    |> Option.map Int64.of_int in
  match id with
  | None -> response (empty 404)
  | Some id -> read c (fun db -> U.find_by_id db id) >>= function
    | None -> response (empty 404)
    | Some user ->
      let headers,fresh=media_headers c ~seconds:1800
        ~validator:(cache_key "users" user.id user.updated_at) () in
      if fresh then response (not_modified headers)
      else let fallback () =
        if U.is_bot user then stock_file
          ~logical:"default-bot-avatar.svg" ~filename:"default-bot-avatar.svg"
          ~content_type:"image/svg+xml" ~headers
        else response (media_response ~status:200
          ~content_type:"image/svg+xml; charset=utf-8" ~headers
          (Views.avatar_svg ~user_id:user.id ~initials:(U.initials user))) in
      match !storage_service with
      | None -> fallback ()
      | Some service ->
          attachment_blob c ~record_type:"User" ~record_id:user.id
            ~name:"avatar" >>= (function
          | None -> fallback ()
          | Some blob ->
              processed_image c service blob
                (Storage_variation.resize_to_limit ~format:"webp" 512 512)
              >>= (function
              | None -> fallback ()
              | Some output -> variant_file c service output
                  ~content_type:"image/webp" ~headers))
let avatar_destroy c = match current_id c with
  | None -> forbidden ()
  | Some id ->
      write c (fun tx ->
        let db=Db_runtime.conn tx in
        match Db_remaining.Attachment.find_for db
          ~record_type:"User" ~record_id:id ~name:"avatar" with
        | None -> None
        | Some attachment ->
            Db_remaining.Attachment.delete tx attachment;
            ignore (Db_runtime.execute db
              "UPDATE users SET updated_at=? WHERE id=?"
              [Sqlite3.Data.TEXT (Db_time.of_rfc3339 c.H.now);
               Sqlite3.Data.INT id]);
            Some attachment.blob_id)
      >>= (function
        | None -> Lwt.return_unit
        | Some blob_id -> match !storage_service with
          | None ->
              c.H.event_sink (Db_remaining.Event.PurgeBlob {blob_id});
              Lwt.return_unit
          | Some service -> Lwt_preemptive.detach (fun () ->
              match Db_runtime.read c.H.runtime (fun db ->
                Db_runtime.query_one db
                  (Db_remaining.Blob.select ^ " WHERE id=? LIMIT 1")
                  [Sqlite3.Data.INT blob_id] Db_remaining.Blob.decode) with
              | None -> ()
              | Some blob -> Storage_blob.purge c.H.runtime service blob) ())
      >>= fun () -> redirect c "/users/me/profile"

let endpoint name : H.endpoint option =
  let public action = Some {H.action; before_action=H.before ~access:H.Public ()} in
  let guest action = Some {H.action; before_action=H.before ~access:H.Guest_only ()} in
  let user action = Some {H.action; before_action=H.default_before_action} in
  let admin action = Some {H.action; before_action=admin_before} in
  let missing = Some {H.action=(fun _ -> not_found ());
    before_action=(fun _ -> Lwt.return (Ok ()))} in
  match name with
  | "welcome#show" -> user welcome
  | "first_runs#show" -> public first_run_show
  | "first_runs#create" -> public first_run_create
  | "sessions#new" -> public session_new
  | "sessions#create" -> public session_create
  | "sessions#destroy" -> user session_destroy
  | "sessions/transfers#show" -> public session_transfer_show
  | "sessions/transfers#update" -> public session_transfer_update
  | "users#new" -> guest join_new
  | "users#create" -> guest join_create
  | "users#show" -> user user_show
  | "users/profiles#show" -> user profile_show
  | "users/profiles#update" -> user profile_update
  | "users/sidebars#show" -> user sidebar_show
  | "users/bans#create" -> admin user_ban
  | "users/bans#destroy" -> admin user_unban
  | "users/push_subscriptions#index" -> user push_index
  | "users/push_subscriptions#create" -> user push_create
  | "users/push_subscriptions#destroy" -> user push_destroy
  | "accounts#edit" -> user account_edit
  | "accounts#update" -> admin account_update
  | "accounts/join_codes#create" -> admin account_join_code
  | "accounts/custom_styles#edit" -> admin account_styles_edit
  | "accounts/custom_styles#update" -> admin account_styles_update
  | "accounts/users#index" -> user account_users_index
  | "accounts/users#update" -> admin account_user_update
  | "accounts/users#destroy" -> admin account_user_destroy
  | "accounts/bots#index" -> admin bots_index
  | "accounts/bots#new" -> admin bots_new
  | "accounts/bots#create" -> admin bots_create
  | "accounts/bots#edit" -> admin bots_edit
  | "accounts/bots#update" -> admin bots_update
  | "accounts/bots#destroy" -> admin bots_destroy
  | "accounts/bots/keys#update" -> admin bot_key_update
  | "accounts/logos#show" -> public account_logo_show
  | "accounts/logos#destroy" -> admin account_logo_destroy
  | "users/avatars#show" -> user avatar_show
  | "users/avatars#destroy" -> user avatar_destroy
  | "users/push_subscriptions/test_notifications#create" -> user push_test_notification
  | name when List.exists (fun prefix -> String.starts_with ~prefix name)
      ["first_runs#";"sessions#";"accounts#";"accounts/users#";
       "accounts/bots#";"users/profiles#";"users/push_subscriptions#"] -> missing
  | _ -> None

(** Request and database rows supplied to the standalone [Views] renderers.
    Rich-text and attachment presentation are completed with M4-T3 and M6. *)

module A = Db_accounts
module R = Db_rooms
module M = Db_messages
module U = A.User
module V = Views

let milliseconds stamp =
  match Authentication.parse_time stamp with
  | None -> 0L
  | Some time -> Int64.of_float (Ptime.to_float_s time *. 1000.)

let iso_time stamp =
  match Authentication.parse_time stamp with
  | None -> stamp
  | Some time -> Authentication.utc_rfc3339 ~frac_s:3 time

let avatar_path (ctx : Http_app.context) (user : U.t) =
  let token = Signed_id.generate ~secret_key_base:ctx.secret_key_base
    ~model:"User" ~id:(Int64.to_int user.id) ~purpose:(Some "avatar")
    ~expires_at:None in
  let digits = String.to_seq user.updated_at |> List.of_seq
    |> List.filter (function '0'..'9' -> true | _ -> false)
    |> List.to_seq |> String.of_seq in
  let version = if String.length digits >= 14 then String.sub digits 0 14 else digits in
  "/users/" ^ token ^ "/avatar?v=" ^ version

let timestamp_number stamp =
  let digits = String.to_seq stamp |> List.of_seq
    |> List.filter (function '0'..'9' -> true | _ -> false)
    |> List.to_seq |> String.of_seq in
  if String.length digits >= 14 then String.sub digits 0 14 else digits

let user (ctx : Http_app.context) (row : U.t) : V.user =
  let role = match row.role with U.Member -> "member"
    | U.Administrator -> "administrator" | U.Bot -> "bot" in
  { id=row.id; name=row.name; title=U.title row; avatar_url=avatar_path ctx row; role }

let mention_of_user (ctx : Http_app.context) (row : U.t) =
  let gid=Global_id.make ~model_name:"User" ~id:(Int64.to_string row.id) in
  { Rich_text.id=row.id; name=row.name; title=U.title row;
    attachable_sgid=Global_id.attachable_sgid
      ~secret_key_base:ctx.secret_key_base ~gid;
    user_path="/users/" ^ Int64.to_string row.id;
    avatar_path=avatar_path ctx row }

let mention_resolver (ctx : Http_app.context) db raw =
  match Global_id.locate_signed ~secret_key_base:ctx.secret_key_base
    ~raw ~purpose:"attachable" ~now:ctx.now () with
  | Some gid when gid.Global_id.model_name="User" ->
      (match Int64.of_string_opt gid.id with
       | None -> None
       | Some id -> Option.map (mention_of_user ctx) (U.find_by_id db id))
  | _ -> None

let gid_resolver (ctx : Http_app.context) db raw =
  match Global_id.parse raw with
  | Some gid when gid.model_name="User" ->
      (match Int64.of_string_opt gid.id with
       | None -> None
       | Some id -> Option.map (mention_of_user ctx) (U.find_by_id db id))
  | _ -> None

let request_host (ctx : Http_app.context) =
  Option.bind (Http_app.header ctx "host") (fun raw ->
    try Uri.host (Uri.of_string ("http://" ^ raw)) with _ -> None)

let rich_text (ctx : Http_app.context) =
  Rich_text.db_adapter_with_gid ~resolve_sgid:(mention_resolver ctx)
    ~resolve_gid:(gid_resolver ctx)

let missing_user : V.user =
  { id=0L; name="Unknown user"; title="Unknown user";
    avatar_url="/assets/campfire-icon.png"; role="member" }

let asset_paths = lazy (
  List.map (fun (logical, digested) -> logical, "/assets/" ^ digested)
    (Lazy.force Assets.manifest))

let stylesheet_tags = lazy (fst (Assets.stylesheet_tags ())
  |> V.trusted_html_of_sanitized)
let importmap_tags = lazy (Assets.javascript_importmap_tags ()
  |> V.trusted_html_of_sanitized)

let context ?(has_custom_logo=false) (ctx : Http_app.context)
    (account : A.Account.t option) : V.context =
  let account_name = match account with None -> "" | Some row -> row.name in
  let custom_styles = Option.bind account (fun row -> row.custom_styles) in
  let logo_url = Route_helpers.fresh_account_logo
    ?v:(Option.map (fun (row : A.Account.t) -> timestamp_number row.updated_at) account)
    () in
  { V.default_context with
    base_url=Http_app.base_url ctx;
    account_name;
    logo_url;
    has_custom_logo;
    current_user=Option.map (user ctx) ctx.current_user;
    platform=User_agent.to_view (User_agent.application_platform
      (Http_app.header ctx "user-agent"));
    assets=Lazy.force asset_paths;
    stylesheet_tags=Some (Lazy.force stylesheet_tags);
    importmap_tags=Some (Lazy.force importmap_tags);
    custom_styles;
    vapid_public_key=Sys.getenv_opt "VAPID_PUBLIC_KEY";
    app_version=(match Sys.getenv_opt "APP_VERSION", Sys.getenv_opt "GIT_REVISION" with
      | Some version, _ when version <> "" -> version
      | _, Some revision when revision <> "" -> revision
      | _ -> "0") }

let load_context ctx =
  Db_runtime.read_async ctx.Http_app.runtime (fun db ->
    let account=A.Account.first db in
    let has_custom_logo=match account with None -> false | Some account ->
      Db_remaining.Attachment.find_for db ~record_type:"Account"
        ~record_id:account.id ~name:"logo" <> None in
    account,has_custom_logo)
  |> Lwt.map (fun (account,has_custom_logo) ->
    context ~has_custom_logo ctx account)

let room (row : R.Room.t) : V.room =
  let kind = match row.room_type with
    | R.Open -> V.Open | R.Closed -> V.Closed | R.Direct -> V.Direct in
  { id=row.id; kind; name=Option.value row.name ~default:"";
    updated_at_ms=milliseconds row.updated_at }

let emoji_codepoint n =
  (n >= 0x1F000 && n <= 0x1FAFF) ||
  (n >= 0x2600 && n <= 0x27BF) ||
  List.mem n [0xA9;0xAE;0x203C;0x2049;0x2122;0x2139;0x3030;0x303D;
    0x3297;0x3299;0xFE0F]

let all_emoji value =
  let seen = ref false in
  let valid = Uutf.String.fold_utf_8 (fun ok _ -> function
    | `Uchar uchar -> seen := true; ok && emoji_codepoint (Uchar.to_int uchar)
    | `Malformed _ -> false) true value in
  valid && !seen

let media_dimensions (blob : Db_remaining.Blob.t) =
  let entries=match blob.metadata with
    | None -> []
    | Some raw -> (try match Yojson.Basic.from_string raw with
      | `Assoc entries -> entries | _ -> [] with _ -> []) in
  let dimension key = match List.assoc_opt key entries with
    | Some (`Int value) -> Some (V.Dimension_int value)
    | Some (`Float value) -> Some (V.Dimension_float value)
    | _ -> None in
  dimension "width",dimension "height"

let boost (ctx : Http_app.context) db (row : M.Boost.t) : V.boost =
  let booster = match U.find_by_id db row.booster_id with
    | None -> missing_user | Some row -> user ctx row in
  { id=row.id; message_id=row.message_id; content=row.content;
    all_emoji=all_emoji row.content; booster }

let message_room_name db (room_row : R.Room.t) =
  let direct = room_row.room_type = R.Direct in
  let other_names = if direct then
    R.Room.users db room_row |> List.map (fun (member : U.t) -> member.name)
    else [] in
  V.room_display_name ~name:room_row.name ~direct ~other_names ()

let message (ctx : Http_app.context) db (room_row : R.Room.t)
    (row : M.Message.t) : V.message =
  let creator = match U.find_by_id db row.creator_id with
    | None -> missing_user | Some row -> user ctx row in
  let boosts = M.Boost.for_message_ordered db row.id |> List.map (boost ctx db) in
  let raw_body = Option.value ~default:"" (M.Message.body_html db row) in
  let editable_body = match Rich_text.editable_value
      ~resolve_sgid:(mention_resolver ctx db)
      ~resolve_gid:(gid_resolver ctx db)
      ?request_host:(request_host ctx) raw_body with
    | Ok (Some body) -> body
    | _ -> raw_body in
  let content =
    match M.Message.attachment_blob_id db row with
    | Some blob_id ->
        let blob=Db_remaining.Blob.find db blob_id in
        let path=Storage_blob.blob_path "redirect"
          ~secret_key_base:ctx.secret_key_base blob () in
        let download_path=Storage_blob.blob_path "redirect"
          ~secret_key_base:ctx.secret_key_base blob ~disposition:"attachment" () in
        let content_type=Option.value ~default:"" blob.content_type in
        let is_video=String.starts_with ~prefix:"video" content_type in
        let variation = if is_video then Some [
          "format",Storage_variation.Symbol "webp";
          "resize_to_limit",Storage_variation.Array [
            Storage_variation.Int 1200L;Storage_variation.Int 800L]]
          else if Storage_image.is_variable blob then
            Some (Storage_image.variation_for blob
              (Storage_variation.resize_to_limit 1200 800))
          else None in
        let preview_url=Option.map (Storage_blob.representation_path "redirect"
          ~secret_key_base:ctx.secret_key_base blob) variation in
        let attachment : V.attachment = { filename=blob.filename;
          blob_path=path;download_path;preview_url } in
        (match preview_url with
        | None -> V.Attachment attachment
        | Some preview_url ->
            let width,height=media_dimensions blob in
            V.Media_attachment (attachment,
              {preview_url;is_video;width;height}))
    | None ->
        (match M.Message.sound ~rich_text:(rich_text ctx) db row with
         | Some sound -> V.Rich_sound {
             url=Assets.asset_path (M.Sound.asset_path sound);
             image=Option.map (fun (image:M.Sound.image) ->
               Assets.asset_path ("sounds/" ^ image.file),
               image.width,image.height) sound.image;
             text=sound.text}
         | None ->
             let html=Option.value ~default:"" (M.Message.body_html db row) in
             let presented=Rich_text.present_message
               ~resolve_sgid:(mention_resolver ctx db)
               ~resolve_gid:(gid_resolver ctx db)
               ?request_host:(request_host ctx) html in
             V.Text (V.trusted_html_of_sanitized presented)) in
  { V.id=row.id; client_message_id=row.client_message_id;
    room_id=row.room_id; room_name=message_room_name db room_row;
    creator; created_at_iso=iso_time row.created_at;
    created_at_ms=milliseconds row.created_at;
    updated_at_ms=milliseconds row.updated_at;
    all_emoji=all_emoji (M.Message.plain_text_body ~rich_text:(rich_text ctx) db row);
    content; editable_body; boosts }

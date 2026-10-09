open Campfire

let read path =
  let path = if Sys.file_exists path then path else "test/" ^ path in
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
    really_input_string channel (in_channel_length channel))
let contains haystack needle =
  let n = String.length needle in
  let rec loop i =
    i + n <= String.length haystack &&
    (String.sub haystack i n = needle || loop (i+1)) in
  loop 0
let check_contains title haystack needle =
  Alcotest.(check bool) title true (contains haystack needle)
let check_absent title haystack needle =
  Alcotest.(check bool) title false (contains haystack needle)
let fixture_json path =
  Yojson.Safe.from_file (if Sys.file_exists path then path else "test/" ^ path)

let sample_user : Views.user = {
  id=127326141L;name="David";title="David";role="administrator";
  avatar_url="/users/avatar";
}
let sample_context : Views.context = {
  Views.default_context with
  base_url="http://campfire.test";account_name="37signals";
  current_user=Some sample_user;
}

let rec reference_root path remaining =
  if remaining = 0 then failwith "pinned Rust reference checkout not found"
  else let candidate = Filename.concat path "once-campfire-rust" in
    if Sys.file_exists
      (Filename.concat candidate "parity/.seed/default/db/production.sqlite3")
    then candidate else reference_root (Filename.dirname path) (remaining - 1)

let test_message_room_names () =
  let database = Filename.concat (reference_root (Sys.getcwd ()) 8)
    "parity/.seed/default/db/production.sqlite3" in
  let db = Sqlite3.db_open ~mode:`READONLY database in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close db)) (fun () ->
    let direct = Db_rooms.Room.find db 186869642L in
    Alcotest.(check string) "direct message permalink room"
      "David and Jason" (View_presenter.message_room_name db direct);
    let group = Db_rooms.Room.find db 699448329L in
    Alcotest.(check string) "group direct message permalink room"
      "David, Jason, Kevin, and JZ"
      (View_presenter.message_room_name db group);
    let named = Db_rooms.Room.of_type db Db_rooms.Open |> List.hd in
    Alcotest.(check string) "named message permalink room"
      (Option.value named.name ~default:"")
      (View_presenter.message_room_name db named))

let test_application_layout_bytes () =
  let pinned = Filename.concat (reference_root (Sys.getcwd ()) 8)
    "crates/views/tests/golden/a/sessions_transfer.html" |> read in
  let context = {sample_context with
    stylesheet_tags=Some (Views.trusted_html_of_sanitized
      "<link rel=\"stylesheet\" href=\"/test.css\">");
    importmap_tags=Some (Views.trusted_html_of_sanitized
      "<script></script>")} in
  let actual = Views.page ~context (Views.text "sample") in
  let whitespace_before source anchor =
    let anchor_length=String.length anchor in
    let rec find at =
      if at+anchor_length>String.length source then
        failwith ("layout anchor missing: " ^ anchor)
      else if String.sub source at anchor_length=anchor then at
      else find (at+1) in
    let rec first at =
      if at=0 then 0 else match source.[at-1] with
      | ' ' | '\n' | '\r' | '\t' -> first (at-1)
      | _ -> at in
    let at=find 0 in
    String.sub source (first at) (at-first at) in
  List.iter (fun anchor ->
    Alcotest.(check string) ("Askama application layout before " ^ anchor)
      (whitespace_before pinned anchor)
      (whitespace_before actual anchor)) [
    "<html>";"<head>";"<body ";"<nav id=\"nav\">";
    "<main id=\"main-content\">";"</main>";
    "<aside id=\"sidebar\"";"<dialog class=\"lightbox\"";
    "</body>";"</html>"]

let test_svg_golden () =
  let cases = ["david",127326141L,"D";
    "three_initials",773523956L,"ABC"] in
  List.iter (fun (name,user_id,initials) ->
    let expected = read ("fixtures/views_avatar_"^name^".svg") in
    Alcotest.(check string) name expected (Views.avatar_svg ~user_id ~initials)) cases;
  let escaped = Views.avatar_svg ~user_id:1L ~initials:"<script>" in
  check_absent "svg initials escaped" escaped "<script>"

let user_json_from_golden () =
  let expected = read "fixtures/views_user_json.json" |> String.trim in
  let json = Yojson.Safe.from_string expected in
  let open Yojson.Safe.Util in
  let id = json |> member "id" |> to_int |> Int64.of_int in
  let name = json |> member "name" |> to_string in
  let role = json |> member "role" |> to_string in
  let avatar_url = json |> member "avatar_url" |> to_string in
  let base_url = "http://campfire.test" in
  let path = String.sub avatar_url (String.length base_url)
    (String.length avatar_url - String.length base_url) in
  let user : Views.user = {id;name;role;avatar_url=path;title=name} in
  Views.user_json ~base_url ~user
let test_json_golden () =
  Alcotest.(check string) "reference user JSON"
    (read "fixtures/views_user_json.json" |> String.trim)
    (user_json_from_golden ())

let test_manifest_json_escaping () =
  let name="Back\\slash \"quoted\" <b>&amp;</b>" in
  let context={sample_context with account_name=name;
    logo_url="/account/logo?v=1"} in
  let json=Views.pwa_manifest_json ~context
    ~logo_url_small:"/account/logo?size=small&v=1"
    |> Yojson.Safe.from_string in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "manifest account name" name
    (json |> member "name" |> to_string);
  Alcotest.(check string) "small logo URL"
    "/account/logo?size=small&v=1"
    (json |> member "icons" |> to_list |> List.hd
      |> member "src" |> to_string)

let message_json_from_golden () =
  let golden = fixture_json "fixtures/views_messages_by_bots_show.json" in
  let open Yojson.Safe.Util in
  let source = golden |> member "input" in
  let field value key = value |> member key in
  let string value key = field value key |> to_string in
  let number value key = field value key |> to_int |> Int64.of_int in
  let creator = field source "creator" in
  let room = field source "room" in
  let body = field source "body" in
  let user : Views.user = {
    id=number creator "id";name=string creator "name";
    title=string creator "name";role=string creator "role";
    avatar_url=string creator "avatar_url"} in
  let message : Views.message = {
    id=number source "id";client_message_id="api";
    room_id=number room "id";room_name="";creator=user;
    created_at_iso=string source "created_at";
    created_at_ms=0L;updated_at_ms=0L;all_emoji=false;
    content=Views.Text (Views.trusted_html_of_sanitized (string body "html"));
    editable_body="";boosts=[]} in
  Views.message_json ~base_url:"http://campfire.test"
    ~plain_text_body:(string body "plain_text") message
let message_json_from_data source =
  let open Yojson.Safe.Util in
  let field value key = value |> member key in
  let string value key = field value key |> to_string in
  let number value key = field value key |> to_int |> Int64.of_int in
  let creator = field source "creator" in
  let room = field source "room" in
  let body = field source "body" in
  let user : Views.user = {
    id=number creator "id";name=string creator "name";
    title=string creator "name";role=string creator "role";
    avatar_url=string creator "avatar_url"} in
  let message : Views.message = {
    id=number source "id";client_message_id="api";
    room_id=number room "id";room_name="";creator=user;
    created_at_iso=string source "created_at";
    created_at_ms=0L;updated_at_ms=0L;all_emoji=false;
    content=Views.Text (Views.trusted_html_of_sanitized (string body "html"));
    editable_body="";boosts=[]} in
  Views.message_json ~base_url:"http://campfire.test"
    ~plain_text_body:(string body "plain_text") message
let messages_by_bots_index_from_golden () =
  let open Yojson.Safe.Util in
  let messages=fixture_json "fixtures/views_messages_by_bots_index.json"
    |> member "input" |> to_list in
  "[" ^ String.concat "," (List.map message_json_from_data messages) ^ "]"
let boost_json_from_golden () =
  let open Yojson.Safe.Util in
  let input=fixture_json "fixtures/views_messages_boosts_by_bots_show.json"
    |> member "input" in
  let get obj key=obj |> member key in
  let str obj key=get obj key |> to_string in
  let id obj key=get obj key |> to_int |> Int64.of_int in
  let booster=get input "booster" in
  let user : Views.user={
    id=id booster "id";name=str booster "name";title=str booster "name";
    role=str booster "role";avatar_url=str booster "avatar_url"} in
  let message=get input "message" in
  let boost : Views.boost={
    id=id input "id";message_id=id message "id";content=str input "content";
    all_emoji=false;booster=user} in
  let url=str message "url" in
  let room_id=Scanf.sscanf url "http://campfire.test/rooms/%Ld/messages/%Ld"
    (fun room_id _ -> room_id) in
  Views.boost_json ~base_url:"http://campfire.test" ~room_id
    ~created_at:(str input "created_at") boost
let test_message_json_golden () =
  let golden = fixture_json "fixtures/views_messages_by_bots_show.json" in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "Rails Jbuilder message bytes"
    (golden |> member "raw" |> to_string) (message_json_from_golden ())

let test_pages_escape_and_structure () =
  let context = {sample_context with account_name="<Campfire & Co>"} in
  let session = Views.session_new ~context ~email_address:"evil\" onfocus=\"run" () in
  check_contains "full document" session "<!DOCTYPE html>";
  check_contains "layout navigation" session "id=\"nav\"";
  check_contains "layout main" session "id=\"main-content\"";
  check_contains "sign in form" session "name=\"password\"";
  check_contains "account logo figure" session
    "class=\"account-logo avatar center margin-block-end txt-xx-large\"";
  check_contains "sign-in reload" session
    "name=\"turbo-visit-control\" content=\"reload\"";
  check_contains "sign-in translation menu" session
    "class=\"language-list-menu shadow\"";
  check_contains "translated email" session "Introduce tu correo electrónico";
  check_absent "unneeded Lexxy listener on sign-in" session "lexxy:initialize";
  let public_context = {context with vapid_public_key=Some "test-public-key";
    app_version="parity"} in
  let owned = Views.session_new ~context:public_context
    ~help_contact:("Owner", "owner@example.test") () in
  check_contains "VAPID meta" owned "name=\"vapid-public-key\"";
  check_contains "owner contact" owned "owner@example.test";
  check_contains "version badge" owned "class=\"version-badge\"";
  check_absent "escaped account name" session "<Campfire & Co>";
  check_absent "escaped input attribute" session "onfocus=\"run\"";
  let setup = Views.first_run ~context () in
  check_contains "first run form" setup "name=\"user[name]\"";
  check_contains "closed image dialog" setup "<dialog class=\"lightbox\"";
  check_contains "lightbox controller target" setup "data-lightbox-target=\"dialog\"";
  check_absent "no blocking lightbox placeholder" setup "<div id=\"lightbox\"";
  let welcome = Views.welcome ~context () in
  check_contains "welcome golden title" welcome "No rooms yet";
  let account = Views.account_edit ~context ~join_code:"JOIN<ME>"
    ~restrict_room_creation:true ~users:[sample_user] in
  check_contains "account users" account "id=\"user_127326141\"";
  check_contains "account PATCH override" account
    "name=\"_method\" type=\"hidden\" value=\"patch\"";
  check_absent "join code escaped" account "JOIN<ME>";
  let profile = Views.profile_edit ~context ~user:sample_user
    ~email_address:"david@example.test" ~bio:(Some "<script>alert(1)</script>")
    ~transfer_url:"http://campfire.test/session/transfers/test-token" in
  check_contains "profile bio field" profile "name=\"user[bio]\"";
  check_contains "profile method" profile "name=\"_method\" type=\"hidden\" value=\"patch\"";
  check_contains "profile transfer link" profile
    "id=\"session_transfer_url\"";
  check_contains "profile QR link" profile "Show auto-login QR code";
  check_absent "profile bio escaped" profile "<script>alert(1)</script>";
  let transfer = Views.session_transfer ~context ~transfer_id:"test-token" in
  check_contains "transfer auto-submit" transfer
    "data-controller=\"auto-submit\"";
  check_contains "transfer PUT override" transfer
    "type=\"hidden\" name=\"_method\" value=\"put\" />";
  check_contains "transfer Rust content-block bytes" transfer
    ("<main id=\"main-content\">\n\n" ^
     "<form data-controller=\"auto-submit\" action=\"/session/transfers/test-token\" " ^
     "accept-charset=\"UTF-8\" method=\"post\">" ^
     "<input type=\"hidden\" name=\"_method\" value=\"put\" /></form>\n\n" ^
     "      <footer id=\"footer\">");
  let join = Views.join_new ~context ~join_code:"invite-code" in
  check_contains "join signup form" join "name=\"user[email_address]\"";
  check_contains "join signup action" join "action=\"/join/invite-code\"";
  let search = Views.search_index ~context ~query:"test" ~results:[] in
  check_contains "search results controller" search
    "data-controller=\"search-results\"";
  check_contains "search results visible class" search
    "class=\"messages searches__results\"";
  let direct = Views.direct_new ~context in
  check_contains "Ping Turbo frame" direct "id=\"direct_rooms_control\"";
  check_contains "Ping picker URL" direct
    "data-autocomplete-url-value=\"/autocompletable/users\"";
  check_contains "Ping selection template" direct
    "data-template-id=\"autocompletable-user\""

let message_from_golden () =
  let root = fixture_json "fixtures/views_messages_create.json" in
  let open Yojson.Safe.Util in
  let input = root |> member "input" in
  let data = input |> member "message" in
  let creator = data |> member "creator" in
  let string x key = x |> member key |> to_string in
  let int64 x key = x |> member key |> to_int |> Int64.of_int in
  let user : Views.user = {
    id=int64 creator "id";name=string creator "name";
    title=string creator "title";avatar_url=string creator "avatar_url";
    role="administrator"} in
  let rich = data |> member "content" |> fun x -> string x "html" in
  let message : Views.message = {
    id=int64 data "id";client_message_id=string data "client_message_id";
    room_id=int64 data "room_id";room_name=string data "room_name";
    creator=user;created_at_iso=string data "created_at";
    created_at_ms=1790427846407L;updated_at_ms=1790427846410L;
    all_emoji=false;content=Views.Text (Views.trusted_html_of_sanitized rich);
    editable_body="<p>Fresh message</p>";boosts=[]} in
  message, root

let test_message_stream_goldens () =
  let message, root = message_from_golden () in
  let open Yojson.Safe.Util in
  let expected = root |> member "expected" |> to_list in
  let first = List.hd expected |> to_string in
  let room : Views.room = {
    id=message.room_id;kind=Closed;name="Designers";updated_at_ms=0L} in
  let create = Views.message_create_stream ~room message in
  check_contains "reference turbo target" create first;
  check_contains "reference message DOM id" create "id=\"message_fresh-1\"";
  check_contains "rich text kept" create "Fresh <em>message</em>";
  check_contains "relative permalink" create
    "href=\"/rooms/654632876/@933434495\"";
  check_contains "search result room separator" create
    "class=\"message__room\">\n                <a";
  check_absent "cache safe host" create "campfire.test";
  let destroy = Views.message_destroy_stream message in
  let expected_destroy = fixture_json "fixtures/views_messages_destroy.json"
    |> member "expected" |> to_list |> List.map to_string
    |> List.filter (fun token -> String.starts_with ~prefix:"<" token)
    |> String.concat "" in
  Alcotest.(check string) "reference destroy stream" expected_destroy destroy;
  let refreshed = Views.room_refresh_stream ~room ~created:[message]
    ~updated:[message] in
  check_contains "refresh append" refreshed "action=\"append\"";
  check_contains "refresh replace" refreshed "action=\"replace\"";
  let room_page = Views.room_show ~context:sample_context ~room
    ~messages:[message] ~messages_stream_name:"signed" () in
  check_contains "room page fragment" room_page "id=\"message_fresh-1\"";
  check_contains "room stream" room_page "signed-stream-name=\"signed\"";
  check_contains "current user for Stimulus" room_page
    "name=\"current-user-id\" content=\"127326141\"";
  check_contains "Lexxy composer" room_page "<lexxy-editor";
  check_contains "Lexxy composer id" room_page "id=\"message_body\"";
  check_contains "message template target" room_page
    "data-messages-target=\"template\"";
  check_contains "typing author target" room_page
    "data-typing-notifications-target=\"author\"";
  let edit = Views.message_edit ~context:sample_context message in
  check_contains "Turbo edit frame" edit "id=\"edit_message_fresh-1\"";
  check_contains "Lexxy edit field" edit "aria-label=\"Edit message\"";
  check_contains "Lexxy edit waits for mount" edit "data-wait-for-mount=\"\"";
  let sidebar = Views.sidebar_frame ~context:sample_context ~rooms:[room]
    ~rooms_stream_name:"rooms-signature"
    ~user_rooms_stream_name:"user-rooms-signature" () |> Views.render in
  check_contains "sidebar frame" sidebar "id=\"user_sidebar\"";
  check_contains "shared room target" sidebar "id=\"shared_rooms\"";
  check_contains "sidebar cable stream" sidebar
    "signed-stream-name=\"rooms-signature\"";
  check_contains "sidebar shell controller" room_page
    "data-controller=\"rooms-list read-rooms turbo-frame\""

let test_recorded_message_parts () =
  let message,_=message_from_golden () in
  let long={message with Views.content=Views.Text
    (Views.trusted_html_of_sanitized ("<p>" ^ String.make 2048 'x' ^ "</p>"))} in
  let short={message with Views.content=Views.Unrenderable;
    client_message_id="short"} in
  let reconstruct (recorded:Views.recorded_page) =
    let output=Buffer.create (String.length recorded.body) in
    let position=ref 0 in
    List.iter (fun (offset,fragment) ->
      Alcotest.(check bool) "recorded offset in range" true
        (offset >= !position && offset <= String.length recorded.text);
      Buffer.add_substring output recorded.text !position (offset- !position);
      Buffer.add_string output fragment;
      position:=offset) recorded.fragments;
    Buffer.add_substring output recorded.text !position
      (String.length recorded.text- !position);
    Alcotest.(check string) "recorded body reconstruction"
      recorded.body (Buffer.contents output) in
  let indexed=Views.message_index_recorded [long;short;long] in
  reconstruct indexed;
  Alcotest.(check string) "index keeps string API"
    (Views.message_index [long;short;long] |> Views.render) indexed.body;
  Alcotest.(check int) "two identical large fragments" 2
    (List.length indexed.fragments);
  Alcotest.(check bool) "page parts digest available" true
    (Option.is_some (Http_cache.Page_parts.of_offsets
      ~text:indexed.text indexed.fragments));
  let room : Views.room={id=message.room_id;kind=Views.Closed;
    name="Designers 世界";updated_at_ms=0L} in
  let page=Views.room_show_recorded ~context:sample_context ~room
    ~messages:[long;short;long] ~messages_stream_name:"signed" () in
  reconstruct page;
  Alcotest.(check string) "room keeps string API"
    (Views.room_show ~context:sample_context ~room
      ~messages:[long;short;long] ~messages_stream_name:"signed" ())
    page.body;
  Alcotest.(check int) "room large fragment count" 2
    (List.length page.fragments);
  let empty=Views.message_index_recorded [short] in
  reconstruct empty;
  Alcotest.(check int) "short fragment stays in text" 0
    (List.length empty.fragments)

let message_from_b_json data : Views.message =
  let open Yojson.Safe.Util in
  let get obj key=obj |> member key in
  let str obj key=get obj key |> to_string in
  let id obj key=get obj key |> to_int |> Int64.of_int in
  let maybe_str obj key=match get obj key with `String s -> Some s | _ -> None in
  let millis stamp=match Ptime.of_rfc3339 stamp with
    | Ok (time,_,_) -> Int64.of_float (Ptime.to_float_s time *. 1000.)
    | Error _ -> 0L in
  let user obj : Views.user={
    id=id obj "id";name=str obj "name";title=str obj "title";
    avatar_url=str obj "avatar_url";role="member"} in
  let attachment content : Views.attachment={
    filename=str content "filename";blob_path=str content "blob_path";
    download_path=str content "download_path";
    preview_url=None} in
  let dimension = function
    | `Int n -> Some (Views.Dimension_int n)
    | `Float n -> Some (Views.Dimension_float n)
    | _ -> None in
  let content=get data "content" in
  let presentation=match str content "type" with
    | "text" -> Views.Text (Views.trusted_html_of_sanitized (str content "html"))
    | "attachment" ->
        let file=attachment content in
        let preview=get content "preview" in
        (match maybe_str preview "type" with
         | Some ("image" | "video" as media_type) ->
             let preview_url=if media_type="image" then str preview "thumb_url"
               else str preview "poster_url" in
             Views.Media_attachment (file, {
               Views.preview_url;is_video=media_type="video";
               width=dimension (get content "width");
               height=dimension (get content "height")})
         | _ -> Views.Attachment file)
    | "sound" ->
        let image=match get content "image" with
          | `Assoc _ as item -> Some (str item "src",
              get item "width" |> to_int,get item "height" |> to_int)
          | _ -> None in
        Views.Rich_sound {url=str content "url";
          image;text=maybe_str content "text"}
    | _ -> Views.Unrenderable in
  let boosts=get data "boosts" |> to_list |> List.map (fun item ->
    ({Views.id=id item "id";message_id=id item "message_id";
      content=str item "content";
      all_emoji=(get item "all_emoji" |> to_bool);
      booster=user (get item "booster")} : Views.boost)) in
  let created_at_iso=str data "created_at" in
  let updated_at_iso=str data "updated_at" in
  {Views.id=id data "id";client_message_id=str data "client_message_id";
    room_id=id data "room_id";room_name=str data "room_name";
    creator=user (get data "creator");created_at_iso;
    created_at_ms=millis created_at_iso;
    updated_at_ms=millis updated_at_iso;
    all_emoji=(get data "all_emoji" |> to_bool);
    content=presentation;editable_body="";boosts}


let room_from_golden name =
  let open Yojson.Safe.Util in
  let golden = fixture_json ("fixtures/views_" ^ name ^ ".json") in
  let context_json = golden |> member "context" in
  let input = golden |> member "input" in
  let string obj key = obj |> member key |> to_string in
  let id obj key = obj |> member key |> to_int |> Int64.of_int in
  let millis value = match Ptime.of_rfc3339 value with
    | Ok (time,_,_) -> Int64.of_float (Ptime.to_float_s time *. 1000.)
    | Error _ -> 0L in
  let current_json = context_json |> member "current_user" in
  let current_user : Views.user = {
    id=id current_json "id";name=string current_json "name";
    title=string (input |> member "user") "title";
    avatar_url=string current_json "avatar_url";
    role=(if current_json |> member "administrator" |> to_bool
      then "administrator" else "member")} in
  let account = context_json |> member "account" in
  let assets = context_json |> member "assets" |> to_assoc
    |> List.map (fun (name,path) -> name,to_string path) in
  let common=fixture_json "fixtures/views_a_onboarding.json" in
  let str_common key=common |> member key |> to_string in
  let context : Views.context = {Views.default_context with
    base_url=string context_json "base_url";
    account_name=string account "name";
    logo_url=string account "logo_url";
    current_user=Some current_user;assets;
    stylesheet_tags=Some (Views.trusted_html_of_sanitized
      (str_common "stylesheet_tags"));
    importmap_tags=Some (Views.trusted_html_of_sanitized
      (str_common "importmap_tags"));
    vapid_public_key=Some (str_common "vapid_public_key");
    platform={Views.default_context.platform with
      chrome=true;mac=true;desktop=true;browser="Chrome";
      operating_system="macOS"}} in
  let room_json = input |> member "room" in
  let room : Views.room = {
    id=id room_json "id";name=string room_json "display_name";
    kind=(match string room_json "kind" with
      | "closed" -> Views.Closed | "direct" -> Views.Direct | _ -> Views.Open);
    updated_at_ms=millis (string input "updated_at")} in
  let messages = input |> member "messages" |> to_list
    |> List.map message_from_b_json in
  Views.room_show ~context ~room ~messages
    ~messages_stream_name:(string input "messages_stream_name")
    ?invitation_join_code:(if input |> member "invitation" |> to_bool
      then Some (string input "join_code") else None) ()

let search_from_golden name =
  let open Yojson.Safe.Util in
  let golden=fixture_json ("fixtures/views_" ^ name ^ ".json") in
  let get obj key=obj |> member key in
  let str obj key=get obj key |> to_string in
  let id obj key=get obj key |> to_int |> Int64.of_int in
  let source=get golden "context" in
  let account=get source "account" in
  let current=get source "current_user" in
  let user : Views.user={
    id=id current "id";name=str current "name";title=str current "name";
    avatar_url=str current "avatar_url";
    role=(if get current "administrator" |> to_bool
      then "administrator" else "member")} in
  let common=fixture_json "fixtures/views_a_onboarding.json" in
  let assets=get source "assets" |> to_assoc
    |> List.map (fun (name,path) -> name,to_string path) in
  let context : Views.context={Views.default_context with
    base_url=str source "base_url";account_name=str account "name";
    logo_url=str account "logo_url";current_user=Some user;assets;
    stylesheet_tags=Some (Views.trusted_html_of_sanitized
      (str common "stylesheet_tags"));
    importmap_tags=Some (Views.trusted_html_of_sanitized
      (str common "importmap_tags"));
    vapid_public_key=Some (str common "vapid_public_key")} in
  let input=get golden "input" in
  let option_string key=match get input key with
    | `String value -> Some value | _ -> None in
  let query=Option.value (option_string "query") ~default:"" in
  let results=get input "messages" |> to_list |> List.map message_from_b_json in
  let recents=get input "recent_searches" |> to_list |> List.map to_string in
  Views.search_index_with ~context ~query ?q:(option_string "q")
    ~recent_searches:recents ~return_to_room_id:(id input "return_to_room_id")
    ~results ()

let direct_new_from_golden () =
  let open Yojson.Safe.Util in
  let golden=fixture_json "fixtures/views_rooms_directs_new.json" in
  let source=golden |> member "context" in
  let get obj key=obj |> member key in
  let str obj key=get obj key |> to_string in
  let account=get source "account" in
  let current=get source "current_user" in
  let user : Views.user={
    id=(get current "id" |> to_int |> Int64.of_int);
    name=str current "name";title=str current "name";
    avatar_url=str current "avatar_url";
    role=(if get current "administrator" |> to_bool
      then "administrator" else "member")} in
  let common=fixture_json "fixtures/views_a_onboarding.json" in
  let assets=get source "assets" |> to_assoc
    |> List.map (fun (name,path) -> name,to_string path) in
  let context : Views.context={Views.default_context with
    base_url=str source "base_url";account_name=str account "name";
    logo_url=str account "logo_url";current_user=Some user;assets;
    stylesheet_tags=Some (Views.trusted_html_of_sanitized
      (str common "stylesheet_tags"));
    importmap_tags=Some (Views.trusted_html_of_sanitized
      (str common "importmap_tags"));
    vapid_public_key=Some (str common "vapid_public_key")} in
  Views.direct_new ~context

let room_form_from_golden name =
  let open Yojson.Safe.Util in
  let golden=fixture_json ("fixtures/views_" ^ name ^ ".json") in
  let get obj key=obj |> member key in
  let str obj key=get obj key |> to_string in
  let id obj key=get obj key |> to_int |> Int64.of_int in
  let source=get golden "context" in
  let account=get source "account" in
  let current=get source "current_user" in
  let current_user : Views.user={
    id=id current "id";name=str current "name";title=str current "name";
    avatar_url=str current "avatar_url";
    role=(if get current "administrator" |> to_bool
      then "administrator" else "member")} in
  let common=fixture_json "fixtures/views_a_onboarding.json" in
  let assets=get source "assets" |> to_assoc
    |> List.map (fun (name,path) -> name,to_string path) in
  let context : Views.context={Views.default_context with
    base_url=str source "base_url";account_name=str account "name";
    logo_url=str account "logo_url";current_user=Some current_user;assets;
    stylesheet_tags=Some (Views.trusted_html_of_sanitized
      (str common "stylesheet_tags"));
    importmap_tags=Some (Views.trusted_html_of_sanitized
      (str common "importmap_tags"));
    vapid_public_key=Some (str common "vapid_public_key")} in
  let input=get golden "input" in
  let room=get input "room" in
  let maybe_id obj key=match get obj key with
    | `Int value -> Some (Int64.of_int value) | _ -> None in
  let maybe_string obj key=match get obj key with
    | `String value -> Some value | _ -> None in
  let user item : Views.user={
    id=id item "id";name=str item "name";title=str item "title";
    avatar_url=str item "avatar_url";role="member"} in
  let users key=match get input key with
    | `List items -> List.map user items | _ -> [] in
  let data : Views.room_form_data={
    form_room_id=maybe_id room "id";
    form_room_name=maybe_string room "name";
    form_kind=(if String.starts_with ~prefix:"rooms_closeds" name
      then Views.Closed else Views.Open);
    can_administer=(get input "can_administer" |> to_bool);
    form_current_user_id=maybe_id input "current_user_id";
    form_users=users "users";selected_users=users "selected_users";
    unselected_users=users "unselected_users"} in
  Views.room_form_page ~context ?last_room_id:(maybe_id source "last_room_visited_id")
    data

let direct_edit_from_golden () =
  let open Yojson.Safe.Util in
  let golden=fixture_json "fixtures/views_rooms_directs_edit.json" in
  let get obj key=obj |> member key in
  let str obj key=get obj key |> to_string in
  let id obj key=get obj key |> to_int |> Int64.of_int in
  let source=get golden "context" in
  let account=get source "account" in
  let current=get source "current_user" in
  let current_user : Views.user={
    id=id current "id";name=str current "name";title=str current "name";
    avatar_url=str current "avatar_url";
    role=(if get current "administrator" |> to_bool
      then "administrator" else "member")} in
  let common=fixture_json "fixtures/views_a_onboarding.json" in
  let assets=get source "assets" |> to_assoc
    |> List.map (fun (name,path) -> name,to_string path) in
  let context : Views.context={Views.default_context with
    base_url=str source "base_url";account_name=str account "name";
    logo_url=str account "logo_url";current_user=Some current_user;assets;
    stylesheet_tags=Some (Views.trusted_html_of_sanitized
      (str common "stylesheet_tags"));
    importmap_tags=Some (Views.trusted_html_of_sanitized
      (str common "importmap_tags"));
    vapid_public_key=Some (str common "vapid_public_key")} in
  let input=get golden "input" in
  let user item : Views.user={
    id=id item "id";name=str item "name";title=str item "title";
    avatar_url=str item "avatar_url";role="member"} in
  Views.direct_edit_page ~context
    ~last_room_id:(id source "last_room_visited_id")
    ~room_id:(id input "room_id")
    ~display_name:(str input "display_name")
    ~users:(get input "users" |> to_list |> List.map user) ()

let involvement_from_golden name =
  let open Yojson.Safe.Util in
  let golden=fixture_json ("fixtures/views_" ^ name ^ ".json") in
  let get obj key=obj |> member key in
  let input=get golden "input" in
  let source=get golden "context" in
  let assets=get source "assets" |> to_assoc
    |> List.map (fun (name,path) -> name,to_string path) in
  let context={Views.default_context with assets} in
  let kind=match get input "kind" |> to_string with
    | "closed" -> Views.Closed | "direct" -> Views.Direct
    | _ -> Views.Open in
  let room : Views.room={
    id=(get input "room_id" |> to_int |> Int64.of_int);
    kind;name="";updated_at_ms=0L} in
  Views.room_involvement_frame ~context ~room
    ~involvement:(get input "involvement" |> to_string)
    |> Views.render

let join_from_golden () =
  let open Yojson.Safe.Util in
  let fixture=fixture_json "fixtures/views_a_users_new.json" in
  let get obj key=obj |> member key in
  let str obj key=get obj key |> to_string in
  let case=get fixture "case" in
  let account=get case "account" in
  let assets=get fixture "assets" |> to_assoc
    |> List.map (fun (name,path) -> name,to_string path) in
  let context : Views.context={Views.default_context with
    base_url=str fixture "base_url";account_name=str account "name";
    logo_url=str account "logo_path";assets;
    stylesheet_tags=Some (Views.trusted_html_of_sanitized
      (str fixture "stylesheet_tags"));
    importmap_tags=Some (Views.trusted_html_of_sanitized
      (str fixture "importmap_tags"));
    vapid_public_key=Some (str fixture "vapid_public_key");
    app_version=str fixture "app_version"} in
  let david=get (get case "users") "David" in
  Views.join_new_with ~context ~join_code:(str account "join_code")
    ~help_contact:(str david "name",str david "email_address") ()

let bot_form_from_golden name =
  let open Yojson.Safe.Util in
  let fixture=fixture_json "fixtures/views_a_bot_forms.json" in
  let get obj key=obj |> member key in
  let str obj key=get obj key |> to_string in
  let case=get (get fixture "cases") name in
  let account=get case "account" in
  let assets=get fixture "assets" |> to_assoc
    |> List.map (fun (name,path) -> name,to_string path) in
  let david=get (get case "users") "David" in
  let current_user : Views.user={
    id=(get david "id" |> to_int |> Int64.of_int);
    name=str david "name";title=str david "name";
    avatar_url=str david "avatar_path";role=str david "role"} in
  let context : Views.context={Views.default_context with
    base_url=str fixture "base_url";account_name=str account "name";
    logo_url=str account "logo_path";assets;current_user=Some current_user;
    has_custom_logo=(get account "has_logo" |> to_bool);
    custom_styles=(match get account "custom_styles" with
      | `String css -> Some css | _ -> None);
    stylesheet_tags=Some (Views.trusted_html_of_sanitized
      (str fixture "stylesheet_tags"));
    importmap_tags=Some (Views.trusted_html_of_sanitized
      (str fixture "importmap_tags"));
    vapid_public_key=Some (str fixture "vapid_public_key");
    app_version=str fixture "app_version"} in
  if name="bots_new" then Views.bot_form_page ~context ()
  else
    let bot=get (get case "users") "Bender Bot" in
    Views.bot_form_page ~context
      ~bot_id:(get bot "id" |> to_int |> Int64.of_int)
      ~name:(str bot "name") ~webhook_url:(str bot "webhook_url")
      ?avatar_attachment_url:(match get case "avatar_url" with
        | `String value -> Some value | _ -> None) ()

let bots_index_from_golden () =
  let open Yojson.Safe.Util in
  let fixture=fixture_json "fixtures/views_a_bots_index.json" in
  let get obj key=obj |> member key in
  let str obj key=get obj key |> to_string in
  let case=get fixture "case" in
  let account=get case "account" in
  let assets=get fixture "assets" |> to_assoc
    |> List.map (fun (name,path) -> name,to_string path) in
  let current_user : Views.user={
    id=127326141L;name="David";title="David";role="administrator";
    avatar_url=""} in
  let context : Views.context={Views.default_context with
    base_url=str fixture "base_url";account_name=str account "name";
    logo_url=str account "logo_path";assets;current_user=Some current_user;
    stylesheet_tags=Some (Views.trusted_html_of_sanitized
      (str fixture "stylesheet_tags"));
    importmap_tags=Some (Views.trusted_html_of_sanitized
      (str fixture "importmap_tags"));
    vapid_public_key=Some (str fixture "vapid_public_key")} in
  let bots=get case "users" |> to_list |> List.map (fun item ->
    let user=get item "user" in
    let bot : Views.user={
      id=(get user "id" |> to_int |> Int64.of_int);
      name=str user "name";title=str user "name";
      avatar_url=str user "avatar_path";role="bot"} in
    let rooms=get item "rooms" |> to_list |> List.map (fun room ->
      str room "name",str room "path") in
    bot,rooms) in
  Views.bots_index ~context ~bots

let account_from_golden name =
  let open Yojson.Safe.Util in
  let fixture=fixture_json "fixtures/views_a_account_pages.json" in
  let common=fixture_json "fixtures/views_a_onboarding.json" in
  let get obj key=obj |> member key in
  let str obj key=get obj key |> to_string in
  let id obj key=get obj key |> to_int |> Int64.of_int in
  let case=get fixture name in
  let account=get case "account" in
  let users=get case "users" |> to_list in
  let current_json=List.find (fun item ->
    get item "email_address" = `String (str case "as")) users in
  let user_item item : Views.account_member =
    let user : Views.user={
      id=id item "id";name=str item "name";
      title=(str item "name" ^ (match get item "bio" with
        | `String bio when String.trim bio<>"" -> " – " ^ bio | _ -> ""));
      avatar_url=str item "avatar_path";role=str item "role"} in
    {user;status=str item "status"} in
  let current=(user_item current_json).user in
  let assets=get common "assets" |> to_assoc
    |> List.map (fun (key,value) -> key,to_string value) in
  let context : Views.context={Views.default_context with
    base_url=str common "base_url";account_name=str account "name";
    logo_url=str account "logo_path";
    has_custom_logo=(get account "has_logo" |> to_bool);
    current_user=Some current;assets;
    custom_styles=(match get account "custom_styles" with
      | `String value -> Some value | _ -> None);
    app_version=str common "app_version";
    flash_notice=(if name="account_edit_notice" then Some "✓" else None);
    stylesheet_tags=Some (Views.trusted_html_of_sanitized
      (str common "stylesheet_tags"));
    importmap_tags=Some (Views.trusted_html_of_sanitized
      (str common "importmap_tags"));
    vapid_public_key=Some (str common "vapid_public_key")} in
  if name="account_users_page_2" then
    let page_users=get case "page_users" |> to_list |> List.map to_string in
    let by_name user=List.mem (str user "name") page_users in
    let selected=List.filter by_name users |> List.map user_item in
    Views.account_users_page_stream ~context ~users:selected ()
  else
    let visible=users |> List.sort (fun a b ->
      String.compare (String.lowercase_ascii (str a "name"))
        (String.lowercase_ascii (str b "name")))
      |> List.map user_item |> List.filter (fun (member:Views.account_member) ->
      member.user.role<>"bot" &&
      (member.status="active" ||
        (current.role="administrator" && member.status="banned"))) in
    let admins,members=List.partition (fun (member:Views.account_member) ->
      member.user.role="administrator") visible in
    let last_room_id=id current_json "original_room_id" in
    Views.account_edit_page ~context ~last_room_id
      ~account_id:(id account "id") ~join_code:(str account "join_code")
      ~restrict_room_creation:(get account
        "restrict_room_creation_to_administrators" |> to_bool)
      ~administrators:admins ~members
      ?next_page:(if name="account_edit_paginated" then Some "2" else None) ()

let user_show_from_golden name =
  let open Yojson.Safe.Util in
  let fixture=fixture_json "fixtures/views_a_account_pages.json" in
  let common=fixture_json "fixtures/views_a_onboarding.json" in
  let get obj key=obj |> member key in
  let str obj key=get obj key |> to_string in
  let id obj key=get obj key |> to_int |> Int64.of_int in
  let case=get fixture name in
  let users=get case "users" |> to_list in
  let current_json=List.find (fun item ->
    get item "email_address" = `String (str case "as")) users in
  let shown_name=match name with
    | "users_show_self" -> "David"
    | "users_show_member_as_admin" | "users_show_member_as_member" -> "JZ"
    | "users_show_bot" -> "Bender Bot"
    | "users_show_deactivated" -> "Ex Employee"
    | "users_show_banned" -> "Spam Ham"
    | _ -> failwith "unknown user show golden" in
  let shown_json=List.find (fun item -> str item "name"=shown_name) users in
  let user item : Views.user={id=id item "id";name=str item "name";
    title=str item "name";avatar_url=str item "avatar_path";
    role=str item "role"} in
  let account=get case "account" in
  let assets=get common "assets" |> to_assoc
    |> List.map (fun (key,value) -> key,to_string value) in
  let context : Views.context={Views.default_context with
    base_url=str common "base_url";account_name=str account "name";
    logo_url=str account "logo_path";
    has_custom_logo=(get account "has_logo" |> to_bool);
    current_user=Some (user current_json);assets;
    custom_styles=(match get account "custom_styles" with
      | `String value -> Some value | _ -> None);
    app_version=str common "app_version";
    stylesheet_tags=Some (Views.trusted_html_of_sanitized
      (str common "stylesheet_tags"));
    importmap_tags=Some (Views.trusted_html_of_sanitized
      (str common "importmap_tags"));
    vapid_public_key=Some (str common "vapid_public_key")} in
  let optional_string key=match get shown_json key with
    | `String value -> Some value | _ -> None in
  let back_url=match get case "referrer" with
    | `String value -> value | _ -> "/" in
  Views.user_show_page ~context ~back_url ~user:(user shown_json)
    ~email_address:(Option.value (optional_string "email_address") ~default:"")
    ~bio:(optional_string "bio") ~status:(str shown_json "status")
    ~transfer_id:(str shown_json "transfer_id") ()

let profile_from_golden name =
  let open Yojson.Safe.Util in
  let fixture=fixture_json "fixtures/views_a_account_pages.json" in
  let common=fixture_json "fixtures/views_a_onboarding.json" in
  let get obj key=obj |> member key in
  let str obj key=get obj key |> to_string in
  let id obj key=get obj key |> to_int |> Int64.of_int in
  let case=get fixture name in
  let current_json=get case "users" |> to_list |> List.find (fun item ->
    get item "email_address" = `String (str case "as")) in
  let account=get case "account" in
  let assets=get common "assets" |> to_assoc
    |> List.map (fun (key,value) -> key,to_string value) in
  let platform=get (get common "platforms") (str case "ua") in
  let flag key=get platform key |> to_bool in
  let user : Views.user={id=id current_json "id";name=str current_json "name";
    title=str current_json "name";avatar_url=str current_json "avatar_path";
    role=str current_json "role"} in
  let context : Views.context={Views.default_context with
    base_url=str common "base_url";account_name=str account "name";
    logo_url=str account "logo_path";
    has_custom_logo=(get account "has_logo" |> to_bool);
    current_user=Some user;assets;
    custom_styles=(match get account "custom_styles" with
      | `String value -> Some value | _ -> None);
    app_version=str common "app_version";
    stylesheet_tags=Some (Views.trusted_html_of_sanitized
      (str common "stylesheet_tags"));
    importmap_tags=Some (Views.trusted_html_of_sanitized
      (str common "importmap_tags"));
    vapid_public_key=Some (str common "vapid_public_key");
    platform={ios=flag "ios";android=flag "android";mac=flag "mac";
      chrome=flag "chrome";firefox=flag "firefox";
      safari=flag "safari";edge=flag "edge";
      apple_messages=flag "apple_messages";mobile=flag "mobile";
      desktop=flag "desktop";windows=flag "windows";
      browser=str platform "browser";
      operating_system=str platform "operating_system"}} in
  let membership item : Views.profile_membership={
    room_id=id item "room_id";
    room_param_key=str item "param_key";
    room_display_name=str item "display_name";
    involvement=str item "involvement";
    direct=get item "direct" |> to_bool} in
  let profile=get case "profile" in
  let back_url=match get case "referrer" with
    | `String value -> value | _ -> "/" in
  Views.profile_show_page ~context ~back_url ~user
    ~email_address:(str current_json "email_address")
    ~bio:(match get current_json "bio" with
      | `String value -> Some value | _ -> None)
    ~avatar_attached:(get current_json "avatar_attached" |> to_bool)
    ~transfer_id:(str current_json "transfer_id")
    ~shared_memberships:(get profile "shared" |> to_list |> List.map membership)
    ~direct_memberships:(get profile "direct" |> to_list |> List.map membership) ()

let aux_from_golden name =
  let open Yojson.Safe.Util in
  match name with
  | "mention" ->
      let users=fixture_json "fixtures/views_a_autocomplete.json"
        |> member "users" |> to_list in
      let item=List.find (fun obj -> obj |> member "name" |> to_string="JZ")
        users in
      let str key=item |> member key |> to_string in
      let user : Views.user={
        id=(item |> member "id" |> to_int |> Int64.of_int);
        name=str "name";title=str "name" ^ " – " ^ str "bio";
        avatar_url=str "avatar_path";role=str "role"} in
      Views.mention_fragment {Views.user;sgid=str "attachable_sgid"}
      |> Views.render
  | "action_text_content" ->
      Views.action_text_content (Views.trusted_html_of_sanitized
        "\n  <p>Hi <strong>there</strong></p>\n") |> Views.render
  | "mailer_layout" ->
      Views.mailer_layout (Views.raw
        (Views.trusted_html_of_sanitized "<p>Mail</p>"))
  | "service_worker" -> Controller_aux.service_worker_js
  | "manifest" ->
      let common=fixture_json "fixtures/views_a_onboarding.json" in
      let account=fixture_json "fixtures/views_a_account_pages.json"
        |> member "manifest" in
      let str obj key=obj |> member key |> to_string in
      let assets=common |> member "assets" |> to_assoc
        |> List.map (fun (name,path) -> name,to_string path) in
      let context={Views.default_context with
        base_url=str common "base_url";
        account_name=str account "name";logo_url=str account "logo_path";
        assets} in
      Views.pwa_manifest_json ~context
        ~logo_url_small:(str account "logo_path_small")
  | "og_embed" | "og_embed_twitter" | "og_embed_long_no_href" ->
      let item=fixture_json "fixtures/views_a_og_embeds.json"
        |> member name in
      let option key=match item |> member key with
        | `String value -> Some value | _ -> None in
      let embed : Views.og_embed={
        href=option "href";image_url=option "url";
        filename=(item |> member "filename" |> to_string);
        description=option "description";
        twitter_avatar=(name="og_embed_twitter")} in
      Views.og_embed embed |> Views.render
  | _ -> failwith "unknown auxiliary view golden"

let refresh_from_golden () =
  let open Yojson.Safe.Util in
  let data=fixture_json "fixtures/views_rooms_refreshes_show.json"
    |> member "input" in
  let get obj key=obj |> member key in
  let id obj key=get obj key |> to_int |> Int64.of_int in
  let room : Views.room={
    id=id data "room_id";name="";updated_at_ms=0L;
    kind=(match get data "room_kind" |> to_string with
      | "closed" -> Views.Closed | "direct" -> Views.Direct | _ -> Views.Open)} in
  let messages key=get data key |> to_list |> List.map message_from_b_json in
  Views.room_refresh_stream ~room ~created:(messages "new_messages")
    ~updated:(messages "updated_messages")

let sidebar_from_golden ?(full=false) name =
  let open Yojson.Safe.Util in
  let golden=fixture_json ("fixtures/views_" ^ name ^ ".json") in
  let get obj key=obj |> member key in
  let str obj key=get obj key |> to_string in
  let id obj key=get obj key |> to_int |> Int64.of_int in
  let users=get golden "users" in
  let user name : Views.user =
    let obj=get users name in
    let bio=match get obj "bio" with `String bio when String.trim bio<>"" ->
      " – " ^ bio | _ -> "" in
    {id=id obj "id";name=str obj "name";
     title=str obj "name" ^ bio;avatar_url=str obj "avatar_path";
     role=str obj "role"} in
  let current_user=user (str golden "current_name") in
  let account=get golden "account" in
  let assets=get golden "assets" |> to_assoc
    |> List.map (fun (name,path) -> name,to_string path) in
  let common=fixture_json "fixtures/views_a_onboarding.json" in
  let context : Views.context = {Views.default_context with
    base_url=str golden "base_url";account_name=str account "name";
    logo_url=str account "logo_path";current_user=Some current_user;
    assets;
    stylesheet_tags=Some (Views.trusted_html_of_sanitized
      (str common "stylesheet_tags"));
    importmap_tags=Some (Views.trusted_html_of_sanitized
      (str common "importmap_tags"));
    vapid_public_key=Some (str common "vapid_public_key")} in
  let sidebar=get golden "sidebar" in
  let direct=get sidebar "direct" |> to_list |> List.map (fun obj ->
    let room : Views.room={id=id obj "room_id";kind=Views.Direct;
      name="";updated_at_ms=Int64.of_string (str obj "updated_at_epoch")} in
    ({Views.room;unread=get obj "unread" |> to_bool;
      members=get obj "member_names" |> to_list
        |> List.map (fun name -> user (to_string name))} : Views.sidebar_entry)) in
  let shared=get sidebar "shared" |> to_list |> List.map (fun obj ->
    let room : Views.room={id=id obj "room_id";
      kind=(if str obj "param_key"="rooms_closed" then Views.Closed else Views.Open);
      name=str obj "name";updated_at_ms=0L} in
    ({Views.room;unread=get obj "unread" |> to_bool;
      members=[]} : Views.sidebar_entry)) in
  let entries=direct @ shared in
  let placeholders=get sidebar "placeholders" |> to_list
    |> List.map (fun name -> user (to_string name)) in
  let streams=get golden "streams" in
  let rooms=List.map (fun (entry:Views.sidebar_entry) -> entry.room) entries in
  let can_create_rooms=get sidebar "can_create_rooms" |> to_bool in
  let rooms_stream_name=str streams "rooms" in
  let user_rooms_stream_name=str streams "user_rooms" in
  if full then Views.sidebar_page ~context ~rooms ~entries ~placeholders
    ~can_create_rooms ~rooms_stream_name ~user_rooms_stream_name ()
  else Views.sidebar_frame ~context ~rooms ~entries ~placeholders
    ~can_create_rooms ~rooms_stream_name ~user_rooms_stream_name ()
    |> Views.render

let shared_room_from_golden name =
  let open Yojson.Safe.Util in
  let golden=fixture_json "fixtures/views_sidebar_frame.json" in
  let rooms=golden |> member "sidebar" |> member "shared" |> to_list in
  let room_name,unread=if name="shared_room_unread" then "HQ",true
    else "All Talk",false in
  let data=List.find (fun x -> x |> member "name" |> to_string=room_name) rooms in
  let kind=if data |> member "param_key" |> to_string="rooms_closed"
    then Views.Closed else Views.Open in
  let room : Views.room={id=(data |> member "room_id" |> to_int |> Int64.of_int);
    kind;name=room_name;updated_at_ms=0L} in
  let entry : Views.sidebar_entry={room;unread;members=[]} in
  Views.sidebar_shared_room entry |> Views.render

let autocomplete_from_golden ~json =
  let open Yojson.Safe.Util in
  let data=fixture_json "fixtures/views_a_autocomplete.json" in
  let get obj key=obj |> member key in
  let str obj key=get obj key |> to_string in
  let users=get data "users" |> to_list |> List.map (fun item ->
    let user : Views.user={
      id=(get item "id" |> to_int |> Int64.of_int);
      name=str item "name";title=(match get item "bio" with
        | `String bio when String.trim bio<>"" -> str item "name" ^ " – " ^ bio
        | _ -> str item "name");
      role=str item "role";avatar_url=str item "avatar_path"} in
    ({Views.user;sgid=str item "attachable_sgid"} : Views.mention_user)) in
  if json then Views.autocomplete_users_json ~base_url:(str data "base_url") users
  else Views.autocomplete_users users |> Views.render
let autocomplete_template_from_golden () =
  let open Yojson.Safe.Util in
  let data=fixture_json "fixtures/views_a_onboarding.json" in
  let assets=data |> member "assets" |> to_assoc
    |> List.map (fun (name,path) -> name,to_string path) in
  let context={Views.default_context with assets} in
  Views.autocomplete_picker_template context |> Views.render


let b_messages_from_golden name =
  let open Yojson.Safe.Util in
  let golden=fixture_json ("fixtures/views_" ^ name ^ ".json") in
  let data=golden |> member "input" in
  if name="messages_room_not_found" then
    Views.message_room_not_found |> Views.render
  else if name="messages_boosts_index" then
    data |> message_from_b_json |> Views.message_boosts |> Views.render
  else if name="messages_boosts_new" then
    let context_json=golden |> member "context" in
    let assets=context_json |> member "assets" |> to_assoc
      |> List.map (fun (name,path) -> name,to_string path) in
    let context={Views.default_context with assets} in
    let json_user=data |> member "user" in
    let user : Views.user={
      id=(json_user |> member "id" |> to_int |> Int64.of_int);
      name=(json_user |> member "name" |> to_string);
      title=(json_user |> member "title" |> to_string);
      avatar_url=(json_user |> member "avatar_url" |> to_string);
      role="member"} in
    let message=data |> member "message" |> message_from_b_json in
    Views.message_new_boost ~context ~message ~user |> Views.render
  else if name="messages_index" then
    data |> member "messages" |> to_list
    |> List.map message_from_b_json |> Views.message_index |> Views.render
  else if name="messages_edit_text" || name="messages_edit_attachment" then
    let context_json=golden |> member "context" in
    let account=context_json |> member "account" in
    let assets=context_json |> member "assets" |> to_assoc
      |> List.map (fun (name,path) -> name,to_string path) in
    let context : Views.context={Views.default_context with
      base_url=(context_json |> member "base_url" |> to_string);
      account_name=(account |> member "name" |> to_string);
      logo_url=(account |> member "logo_url" |> to_string);
      assets} in
    let message={(message_from_b_json (data |> member "message")) with
      Views.editable_body=(data |> member "editable_body_html" |> to_string)} in
    Views.message_edit ~context message
  else message_from_b_json data |> Views.message_item |> Views.render

let onboarding_from_golden name =
  let open Yojson.Safe.Util in
  let golden=fixture_json "fixtures/views_a_onboarding.json" in
  let get obj key=obj |> member key in
  let str obj key=get obj key |> to_string in
  let case=get (get golden "cases") name in
  let account=get case "account" in
  let platform=get (get golden "platforms") (str case "ua") in
  let bool key=get platform key |> to_bool in
  let assets=get golden "assets" |> to_assoc
    |> List.map (fun (name,path) -> name,to_string path) in
  let context : Views.context={Views.default_context with
    base_url=str golden "base_url";
    account_name=(match account with `Null -> "" | _ -> str account "name");
    logo_url=(match account with `Null -> "/account/logo" | _ -> str account "logo_path");
    has_custom_logo=(match account with `Null -> false | _ ->
      get account "has_logo" |> to_bool);
    custom_styles=(match account with `Null -> None | _ ->
      (match get account "custom_styles" with `String css -> Some css | _ -> None));
    assets;
    stylesheet_tags=Some (Views.trusted_html_of_sanitized (str golden "stylesheet_tags"));
    importmap_tags=Some (Views.trusted_html_of_sanitized (str golden "importmap_tags"));
    vapid_public_key=Some (str golden "vapid_public_key");
    app_version=str golden "app_version";
    flash_alert=(if name="sessions_new_rejected" then
      Some "Too many requests or unauthorized." else None);
    platform={
      ios=bool "ios";android=bool "android";mac=bool "mac";
      chrome=bool "chrome";firefox=bool "firefox";safari=bool "safari";
      edge=bool "edge";windows=bool "windows";
      mobile=bool "mobile";desktop=bool "desktop";
      apple_messages=bool "apple_messages";
      browser=str platform "browser";
      operating_system=str platform "operating_system"}} in
  if String.starts_with ~prefix:"browser_settings_" name then
    Views.pwa_browser_settings context |> Views.render
  else if String.starts_with ~prefix:"system_settings_" name then
    Views.pwa_system_settings context |> Views.render
  else if String.starts_with ~prefix:"install_instructions_" name then
    Views.pwa_install_instructions context |> Views.render
  else if name="ban_button_banned" then
    let item=get (get case "users") "Spam Ham" in
    let user : Views.user={
      id=(get item "id" |> to_int |> Int64.of_int);
      name=str item "name";title=str item "name";
      avatar_url=str item "avatar_path";role=str item "role"} in
    Views.ban_button ~context ~user ~banned:true |> Views.render
  else if name="incompatible_browser" || name="incompatible_browser_apple_messages" then
    let body=Views_browser.content (Views.asset context)
      |> Views_browser.html |> Views.trusted_html_of_sanitized
      |> Views.raw in
    Views.page ~context
      ~title:(if name="incompatible_browser_apple_messages"
        then "Campfire" else "Unsupported browser") body
  else if name="sessions_transfer" then
    let path=str case "path" in
    let transfer_id=String.sub path (String.length "/session/transfers/")
      (String.length path - String.length "/session/transfers/") in
    Views.session_transfer ~context ~transfer_id
  else if name="custom_styles_edit" || name="custom_styles_layout" then
    let david=get (get case "users") "David" in
    let current_user : Views.user={
      id=(get david "id" |> to_int |> Int64.of_int);
      name=str david "name";title="David";
      avatar_url=str david "avatar_path";role=str david "role"} in
    let context={context with current_user=Some current_user} in
    Views.custom_styles_edit ~context
      ~styles:(Option.value context.custom_styles ~default:"")
  else if name="push_subscriptions" then
    let david=get (get case "users") "David" in
    let current_user : Views.user={
      id=(get david "id" |> to_int |> Int64.of_int);
      name=str david "name";title="David";
      avatar_url=str david "avatar_path";role=str david "role"} in
    let context={context with current_user=Some current_user} in
    let push_subscriptions=get (get case "data") "push_subscriptions"
      |> to_list |> List.map (fun ps -> ({
        Views.id=(get ps "id" |> to_int |> Int64.of_int);
        endpoint=str ps "endpoint";browser=str ps "browser";
        version=str ps "version";platform=str ps "platform"
      } : Views.push_subscription)) in
    Views.push_subscriptions_index ~context
      ~last_room_id:(get david "original_room_id" |> to_int |> Int64.of_int)
      ~push_subscriptions ()
  else if name="first_run" then Views.first_run ~context ()
  else let david=get case "david" in
    let contact=str david "name",str david "email_address" in
    let email=if name="sessions_new_email" then Some "x@y.com"
      else if name="sessions_new_rejected" then Some "david@37signals.com"
      else None in
    Views.session_new ~context ?email_address:email
      ~help_contact:contact ()

let () = if Array.length Sys.argv > 1 && Sys.argv.(1)="--dump-welcome" then
  let new_user = {sample_user with name="New Bie"} in
  let context = {sample_context with current_user=Some new_user} in
  print_string (Views.welcome ~context ())
else if Array.length Sys.argv > 1 && Sys.argv.(1)="--dump-message" then
  let message, _ = message_from_golden () in
  let room : Views.room = {id=message.room_id;kind=Closed;name="Designers";
    updated_at_ms=0L} in
  print_string (Views.message_create_stream ~room message)
else if Array.length Sys.argv > 1 && Sys.argv.(1)="--dump-room" then
  print_string (room_from_golden "rooms_show_member")
else if Array.length Sys.argv > 2 && Sys.argv.(1)="--dump-room-case" then
  print_string (room_from_golden Sys.argv.(2))
else if Array.length Sys.argv > 2 && Sys.argv.(1)="--dump-search-case" then
  print_string (search_from_golden Sys.argv.(2))
else if Array.length Sys.argv > 1 && Sys.argv.(1)="--dump-direct-new" then
  print_string (direct_new_from_golden ())
else if Array.length Sys.argv > 2 && Sys.argv.(1)="--dump-room-form" then
  print_string (room_form_from_golden Sys.argv.(2))
else if Array.length Sys.argv > 1 && Sys.argv.(1)="--dump-direct-edit" then
  print_string (direct_edit_from_golden ())
else if Array.length Sys.argv > 2 && Sys.argv.(1)="--dump-involvement" then
  print_string (involvement_from_golden Sys.argv.(2))
else if Array.length Sys.argv > 1 && Sys.argv.(1)="--dump-join" then
  print_string (join_from_golden ())
else if Array.length Sys.argv > 2 && Sys.argv.(1)="--dump-bot-form" then
  print_string (bot_form_from_golden Sys.argv.(2))
else if Array.length Sys.argv > 1 && Sys.argv.(1)="--dump-bots-index" then
  print_string (bots_index_from_golden ())
else if Array.length Sys.argv > 2 && Sys.argv.(1)="--dump-account" then
  print_string (account_from_golden Sys.argv.(2))
else if Array.length Sys.argv > 2 && Sys.argv.(1)="--dump-user-show" then
  print_string (user_show_from_golden Sys.argv.(2))
else if Array.length Sys.argv > 2 && Sys.argv.(1)="--dump-profile" then
  print_string (profile_from_golden Sys.argv.(2))
else if Array.length Sys.argv > 2 && Sys.argv.(1)="--dump-aux" then
  print_string (aux_from_golden Sys.argv.(2))
else if Array.length Sys.argv > 1 && Sys.argv.(1)="--dump-refresh" then
  print_string (refresh_from_golden ())
else if Array.length Sys.argv > 1 && Sys.argv.(1)="--dump-sidebar" then
  print_string (sidebar_from_golden "sidebar_frame")
else if Array.length Sys.argv > 2 && Sys.argv.(1)="--dump-sidebar-full" then
  print_string (sidebar_from_golden ~full:true Sys.argv.(2))
else if Array.length Sys.argv > 2 && Sys.argv.(1)="--dump-shared-room" then
  print_string (shared_room_from_golden Sys.argv.(2))
else if Array.length Sys.argv > 1 && Sys.argv.(1)="--dump-autocomplete" then
  print_string (autocomplete_from_golden ~json:false)
else if Array.length Sys.argv > 1 && Sys.argv.(1)="--dump-autocomplete-json" then
  print_string (autocomplete_from_golden ~json:true)
else if Array.length Sys.argv > 1 && Sys.argv.(1)="--dump-autocomplete-template" then
  print_string (autocomplete_template_from_golden ())
else if Array.length Sys.argv > 2 && Sys.argv.(1)="--dump-b-messages" then
  print_string (b_messages_from_golden Sys.argv.(2))
else if Array.length Sys.argv > 2 && Sys.argv.(1)="--dump-a" then
  print_string (onboarding_from_golden Sys.argv.(2))
else if Array.length Sys.argv > 2 && Sys.argv.(1)="--dump-svg" then
  (match Sys.argv.(2) with
   | "avatar_david" -> print_string (Views.avatar_svg ~user_id:127326141L ~initials:"D")
   | "avatar_three_initials" -> print_string (Views.avatar_svg ~user_id:773523956L ~initials:"ABC")
   | _ -> failwith "unknown SVG golden")
else if Array.length Sys.argv > 1 && Sys.argv.(1)="--dump-user-json" then
  print_string (user_json_from_golden ())
else if Array.length Sys.argv > 1 && Sys.argv.(1)="--dump-message-json" then
  print_string (message_json_from_golden ())
else if Array.length Sys.argv > 1 && Sys.argv.(1)="--dump-messages-json" then
  print_string (messages_by_bots_index_from_golden ())
else if Array.length Sys.argv > 1 && Sys.argv.(1)="--dump-boost-json" then
  print_string (boost_json_from_golden ())
else if Array.length Sys.argv > 1 && Sys.argv.(1)="--dump-destroy" then
  let message,_=message_from_golden () in
  print_string (Views.message_destroy_stream message)
else Alcotest.run "M4 views" [
  "reference SVG and JSON", [
    Alcotest.test_case "avatar SVG" `Quick test_svg_golden;
    Alcotest.test_case "user JSON" `Quick test_json_golden;
    Alcotest.test_case "manifest JSON escaping" `Quick test_manifest_json_escaping;
    Alcotest.test_case "message Jbuilder JSON" `Quick test_message_json_golden];
  "pages", [Alcotest.test_case "layout, forms, escaping" `Quick
    test_pages_escape_and_structure;
    Alcotest.test_case "Askama application shell whitespace" `Quick
      test_application_layout_bytes];
  "messages", [Alcotest.test_case "golden stream anchors and cache safety"
    `Quick test_message_stream_goldens;
    Alcotest.test_case "message permalink room names from pinned memberships"
      `Quick test_message_room_names;
    Alcotest.test_case "renderer recorded message offsets" `Quick
      test_recorded_message_parts]]

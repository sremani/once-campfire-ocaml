(** Server-rendered Campfire views. Ordinary strings are escaped with Tyxml. [trusted_html]
    is an explicit boundary for HTML already sanitized by the rich-text pipeline. *)

type fragment
type trusted_html

val text : string -> fragment
val concat : fragment list -> fragment
val render : fragment -> string
val trusted_html_of_sanitized : string -> trusted_html
val raw : trusted_html -> fragment

type user = {
  id : int64;
  name : string;
  title : string;
  avatar_url : string;
  role : string;
}

type context = {
  base_url : string;
  account_name : string;
  logo_url : string;
  has_custom_logo : bool;
  current_user : user option;
  platform : User_agent.view;
  assets : (string * string) list;
  stylesheet_tags : trusted_html option;
  importmap_tags : trusted_html option;
  custom_styles : string option;
  vapid_public_key : string option;
  app_version : string;
  flash_notice : string option;
  flash_alert : string option;
}

val default_context : context
val asset : context -> string -> string
val page : ?title:string -> ?body_class:string -> ?head:fragment ->
  ?nav:fragment -> ?sidebar:fragment -> ?footer:fragment ->
  context:context -> fragment -> string
val frame_page : ?head:fragment -> fragment -> string

val session_new : context:context -> ?email_address:string -> ?help_contact:(string * string) -> unit -> string
val session_transfer : context:context -> transfer_id:string -> string
val first_run : context:context -> unit -> string
type push_subscription = {
  id:int64; endpoint:string; browser:string; version:string; platform:string
}
val push_subscriptions_index : context:context -> ?last_room_id:int64 ->
  push_subscriptions:push_subscription list -> unit -> string
val pwa_browser_settings : context -> fragment
val pwa_system_settings : context -> fragment
val pwa_install_instructions : context -> fragment
val join_new : context:context -> join_code:string -> string
val join_new_with : context:context -> join_code:string ->
  ?help_contact:(string * string) -> unit -> string
val welcome : context:context -> unit -> string
val account_edit : context:context -> join_code:string -> restrict_room_creation:bool -> users:user list -> string
type account_member = { user:user; status:string }
val account_user_item : context:context -> account_member -> fragment
val account_users_page_stream : context:context -> users:account_member list ->
  ?next_page:string -> unit -> string
val account_edit_page : context:context -> ?last_room_id:int64 ->
  account_id:int64 -> join_code:string -> restrict_room_creation:bool ->
  administrators:account_member list -> members:account_member list ->
  ?next_page:string -> unit -> string
val bots_index : context:context -> bots:(user * (string * string) list) list -> string
val bot_form : context:context -> ?bot:user -> ?webhook_url:string -> unit -> string
val bot_form_page : context:context -> ?bot_id:int64 -> ?name:string ->
  ?webhook_url:string -> ?avatar_attachment_url:string -> unit -> string
val custom_styles_edit : context:context -> styles:string -> string
val user_show : context:context -> user:user -> bio:string option -> string
val user_show_page : context:context -> ?back_url:string -> user:user ->
  email_address:string -> bio:string option -> status:string ->
  transfer_id:string -> unit -> string
val profile_edit : context:context -> user:user -> email_address:string ->
  bio:string option -> transfer_url:string -> string
type profile_membership = {
  room_id:int64; room_param_key:string; room_display_name:string;
  involvement:string; direct:bool
}
val profile_show_page : context:context -> ?back_url:string -> user:user ->
  email_address:string -> bio:string option -> avatar_attached:bool ->
  transfer_id:string -> shared_memberships:profile_membership list ->
  direct_memberships:profile_membership list -> unit -> string
val user_json : base_url:string -> user:user -> string
type mention_user = { user:user; sgid:string }
val mention_fragment : mention_user -> fragment
val action_text_content : trusted_html -> fragment
val mailer_layout : fragment -> string
val pwa_manifest_json : context:context -> logo_url_small:string -> string
type og_embed = {
  href:string option; image_url:string option;
  filename:string; description:string option; twitter_avatar:bool
}
val og_embed : og_embed -> fragment
val autocomplete_users : mention_user list -> fragment
val autocomplete_users_json : base_url:string -> mention_user list -> string
val autocomplete_picker_template : context -> fragment
val ban_button : context:context -> user:user -> banned:bool -> fragment
val avatar_svg : user_id:int64 -> initials:string -> string

type room_kind = Open | Closed | Direct
type room = { id:int64; kind:room_kind; name:string; updated_at_ms:int64 }
type sidebar_entry = { room:room; unread:bool; members:user list }
val sidebar_shared_room : sidebar_entry -> fragment
val sidebar_direct_room : context:context -> sidebar_entry -> fragment
val sidebar_frame : context:context -> rooms:room list ->
  ?entries:sidebar_entry list -> ?placeholders:user list ->
  ?can_create_rooms:bool ->
  rooms_stream_name:string -> user_rooms_stream_name:string -> unit -> fragment
val sidebar_page : context:context -> rooms:room list ->
  ?entries:sidebar_entry list -> ?placeholders:user list ->
  ?can_create_rooms:bool ->
  rooms_stream_name:string -> user_rooms_stream_name:string -> unit -> string
val room_display_name : ?self_name:string -> name:string option -> direct:bool -> other_names:string list -> unit -> string
val room_involvement_frame : context:context -> room:room ->
  involvement:string -> fragment
val room_form : context:context -> ?room:room -> kind:room_kind -> users:user list -> unit -> string
type room_form_data = {
  form_room_id:int64 option; form_room_name:string option;
  form_kind:room_kind; can_administer:bool;
  form_current_user_id:int64 option;
  form_users:user list; selected_users:user list; unselected_users:user list;
}
val room_form_page : context:context -> ?last_room_id:int64 ->
  room_form_data -> string
val direct_new_content : context:context -> fragment
val direct_new : context:context -> string
val direct_edit_page : context:context -> ?last_room_id:int64 ->
  room_id:int64 -> display_name:string -> users:user list -> unit -> string

type attachment = { filename:string; blob_path:string; download_path:string; preview_url:string option }
type media_dimension = Dimension_int of int | Dimension_float of float
type media_attachment = {
  preview_url:string; is_video:bool;
  width:media_dimension option; height:media_dimension option;
}
type sound_view = { url:string; image:(string * int * int) option; text:string option }
type content = Text of trusted_html | Sound of string * string option |
  Rich_sound of sound_view | Attachment of attachment |
  Media_attachment of attachment * media_attachment | Unrenderable
type boost = { id:int64; message_id:int64; content:string; all_emoji:bool; booster:user }
type message = {
  id:int64; client_message_id:string; room_id:int64; room_name:string;
  creator:user; created_at_iso:string; created_at_ms:int64;
  updated_at_ms:int64; all_emoji:bool; content:content;
  editable_body:string; boosts:boost list;
}
val message_item : message -> fragment
val message_presentation : message -> fragment
val boost_item : boost -> fragment
val message_boosts : message -> fragment
val message_new_boost : context:context -> message:message -> user:user -> fragment
val message_room_not_found : fragment
val message_index : message list -> fragment
type recorded_page = {
  body:string;
  text:string;
  fragments:(int * string) list;
}
val message_index_recorded : message list -> recorded_page
val message_show : context:context -> message -> string
val message_edit : context:context -> message -> string
val message_json : ?base_url:string -> ?plain_text_body:string -> message -> string
val boost_json : base_url:string -> room_id:int64 -> created_at:string -> boost -> string
val room_show : context:context -> room:room -> messages:message list ->
  messages_stream_name:string -> ?invitation_join_code:string -> unit -> string
val room_show_recorded : context:context -> room:room -> messages:message list ->
  messages_stream_name:string -> ?invitation_join_code:string -> unit -> recorded_page
val search_index : context:context -> query:string ->
  results:message list -> string
val search_index_with : context:context -> query:string -> ?q:string ->
  ?recent_searches:string list -> ?return_to_room_id:int64 ->
  results:message list -> unit -> string
val turbo_stream : action:string -> target:string -> fragment -> string
val message_create_stream : room:room -> message -> string
val message_destroy_stream : message -> string
val room_refresh_stream : room:room -> created:message list -> updated:message list -> string
val account_users_stream : users:user list -> next_page:string option -> string

(** URL path helpers corresponding to [campfire_routes] in the pinned Rust port.
    Arguments are already formatted path components, as in Rust Display; the helpers
    preserve them literally. Callers handle encoding where a route requires it. *)

let root () = "/"
let first_run () = "/first_run"
let session () = "/session"
let new_session () = "/session/new"
let session_transfer id = Printf.sprintf "/session/transfers/%s" id
let account () = "/account"
let edit_account () = "/account/edit"
let account_users () = "/account/users"
let account_user id = Printf.sprintf "/account/users/%s" id
let edit_account_user id = Printf.sprintf "/account/users/%s/edit" id
let account_bots () = "/account/bots"
let new_account_bot () = "/account/bots/new"
let account_bot id = Printf.sprintf "/account/bots/%s" id
let edit_account_bot id = Printf.sprintf "/account/bots/%s/edit" id
let account_bot_key bot_id = Printf.sprintf "/account/bots/%s/key" bot_id
let account_join_code () = "/account/join_code"
let account_logo () = "/account/logo"
let account_custom_styles () = "/account/custom_styles"
let edit_account_custom_styles () = "/account/custom_styles/edit"
let join join_code = Printf.sprintf "/join/%s" join_code
let qr_code id = Printf.sprintf "/qr_code/%s" id
let user id = Printf.sprintf "/users/%s" id
let user_avatar user_id = Printf.sprintf "/users/%s/avatar" user_id
let user_ban user_id = Printf.sprintf "/users/%s/ban" user_id
let user_sidebar () = "/users/me/sidebar"
let user_profile () = "/users/me/profile"
let edit_user_profile () = "/users/me/profile/edit"
let user_push_subscriptions () = "/users/me/push_subscriptions"
let user_push_subscription id = Printf.sprintf "/users/me/push_subscriptions/%s" id
let user_push_subscription_test_notifications push_subscription_id = Printf.sprintf "/users/me/push_subscriptions/%s/test_notifications" push_subscription_id
let autocompletable_users () = "/autocompletable/users"
let rooms () = "/rooms"
let new_room () = "/rooms/new"
let room id = Printf.sprintf "/rooms/%s" id
let edit_room id = Printf.sprintf "/rooms/%s/edit" id
let room_messages room_id = Printf.sprintf "/rooms/%s/messages" room_id
let new_room_message room_id = Printf.sprintf "/rooms/%s/messages/new" room_id
let room_message room_id id = Printf.sprintf "/rooms/%s/messages/%s" room_id id
let edit_room_message room_id id = Printf.sprintf "/rooms/%s/messages/%s/edit" room_id id
let room_bot_messages room_id bot_key = Printf.sprintf "/rooms/%s/%s/messages" room_id bot_key
let room_bot_message room_id bot_key id = Printf.sprintf "/rooms/%s/%s/messages/%s" room_id bot_key id
let room_bot_message_boosts room_id bot_key message_id = Printf.sprintf "/rooms/%s/%s/messages/%s/boosts" room_id bot_key message_id
let room_bot_message_boost room_id bot_key message_id id = Printf.sprintf "/rooms/%s/%s/messages/%s/boosts/%s" room_id bot_key message_id id
let room_refresh room_id = Printf.sprintf "/rooms/%s/refresh" room_id
let room_settings room_id = Printf.sprintf "/rooms/%s/settings" room_id
let room_involvement room_id = Printf.sprintf "/rooms/%s/involvement" room_id
let room_at_message room_id message_id = Printf.sprintf "/rooms/%s/@%s" room_id message_id
let rooms_opens () = "/rooms/opens"
let new_rooms_open () = "/rooms/opens/new"
let rooms_open id = Printf.sprintf "/rooms/opens/%s" id
let edit_rooms_open id = Printf.sprintf "/rooms/opens/%s/edit" id
let rooms_closeds () = "/rooms/closeds"
let new_rooms_closed () = "/rooms/closeds/new"
let rooms_closed id = Printf.sprintf "/rooms/closeds/%s" id
let edit_rooms_closed id = Printf.sprintf "/rooms/closeds/%s/edit" id
let rooms_directs () = "/rooms/directs"
let new_rooms_direct () = "/rooms/directs/new"
let rooms_direct id = Printf.sprintf "/rooms/directs/%s" id
let edit_rooms_direct id = Printf.sprintf "/rooms/directs/%s/edit" id
let messages () = "/messages"
let message id = Printf.sprintf "/messages/%s" id
let edit_message id = Printf.sprintf "/messages/%s/edit" id
let message_boosts message_id = Printf.sprintf "/messages/%s/boosts" message_id
let new_message_boost message_id = Printf.sprintf "/messages/%s/boosts/new" message_id
let message_boost message_id id = Printf.sprintf "/messages/%s/boosts/%s" message_id id
let searches () = "/searches"
let clear_searches () = "/searches/clear"
let unfurl_link () = "/unfurl_link"
let webmanifest () = "/webmanifest"
let service_worker () = "/service-worker"
let rails_health_check () = "/up"

let fresh_user_avatar avatar_token updated_at_number =
  Printf.sprintf "/users/%s/avatar?v=%s" avatar_token updated_at_number

let fresh_account_logo ?v ?size () =
  let query =
    (match size with None -> [] | Some value -> ["size=" ^ value]) @
    (match v with None -> [] | Some value -> ["v=" ^ value])
  in
  if query = [] then account_logo ()
  else account_logo () ^ "?" ^ String.concat "&" query

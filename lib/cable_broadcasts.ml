(** Typed Turbo and sidebar broadcasts. Rendered partial HTML is supplied by
    the view layer so the stream wrapper stays independent of request context. *)

module C = Cable_channels
module R = Db_rooms.Room
module M = Db_messages.Message
module B = Db_messages.Boost
module Membership = Db_rooms.Membership

let i64 = Int64.to_string
let room_key (room:R.t) =
  Db_rooms.room_type_name room.room_type
  |> String.lowercase_ascii
  |> String.split_on_char ':'
  |> List.filter (fun part -> part <> "")
  |> String.concat "_"
let room_dom_id room prefix = prefix ^ "_" ^ room_key room ^ "_" ^ i64 room.R.id
let message_dom_id (message:M.t) prefix =
  (if prefix = "" then "message" else prefix ^ "_message") ^
  "_" ^ message.client_message_id
let message_stream room = C.room_param room ^ ":messages"
let user_rooms user_id = Global_id.to_param (C.user_gid user_id) ^ ":rooms"

let action_tag ?(attributes=[]) ~action ~target ?html () =
  let out = Buffer.create 128 in
  Buffer.add_string out "<turbo-stream";
  let add name value =
    Buffer.add_char out ' ';
    Buffer.add_string out name;
    Buffer.add_string out "=\"";
    Buffer.add_string out (Ruby_compat.html_escape value);
    Buffer.add_char out '"' in
  List.iter (fun (name,value) -> Option.iter (add name) value) attributes;
  add "action" action;
  add "target" target;
  Buffer.add_char out '>';
  if action <> "remove" && action <> "refresh" then (
    Buffer.add_string out "<template>";
    Option.iter (Buffer.add_string out) html;
    Buffer.add_string out "</template>");
  Buffer.add_string out "</turbo-stream>";
  Buffer.contents out

let broadcast t ~stream tag =
  C.broadcast_json t ~stream (`String tag)
let room_message t room tag = broadcast t ~stream:(message_stream room) tag
let to_user_rooms t user_id tag = broadcast t ~stream:(user_rooms user_id) tag
let maintain_scroll = ["maintain_scroll", Some "true"]

let message_create t ~(room:R.t) ~(message:M.t) ~member_ids ~html =
  let _ = message in
  let append = message_stream room, `String (action_tag ~action:"append"
    ~target:(room_dom_id room "messages") ~html ()) in
  let unreads = List.map (fun user_id ->
    "user_" ^ i64 user_id ^ "_unreads",
    `Assoc ["roomId", `Int (Int64.to_int room.id)]) member_ids in
  ignore (C.broadcast_batch_json t (append :: unreads))

let unread_room t ~(room:R.t) ~member_ids =
  List.iter (fun user_id ->
    ignore (C.unread_room t ~user_id ~room_id:room.id)) member_ids

let message_remove t ~(room:R.t) ~(message:M.t) =
  ignore (room_message t room (action_tag ~action:"remove"
    ~target:(message_dom_id message "") ()))

let message_replace t ~(room:R.t) ~(message:M.t) ~html =
  let target = message_dom_id message "presentation" in
  let html = "<div id=\"" ^ Ruby_compat.html_escape target ^
    "\" dir=\"auto\" data-reply-target=\"body\" data-messages-target=\"body\">" ^
    html ^ "</div>" in
  ignore (room_message t room (action_tag ~attributes:maintain_scroll
    ~action:"replace" ~target ~html ()))

let boost_create t ~(room:R.t) ~(message:M.t) ~(boost:B.t) ~html =
  let _ = boost in
  ignore (room_message t room (action_tag ~attributes:maintain_scroll
    ~action:"append" ~target:("boosts_message_" ^ message.client_message_id)
    ~html ()))

let boost_remove t ~(room:R.t) ~(boost:B.t) =
  ignore (room_message t room (action_tag ~action:"remove"
    ~target:("boost_" ^ i64 boost.id) ()))

let room_remove t ~(room:R.t) =
  ignore (broadcast t ~stream:"rooms" (action_tag ~action:"remove"
    ~target:(room_dom_id room "list") ()))

let open_room_create t ~(room:R.t) ~html =
  let _ = room in
  ignore (broadcast t ~stream:"rooms" (action_tag ~action:"prepend"
    ~target:"shared_rooms" ~html ()))

let open_room_update t ~(room:R.t) ~html =
  ignore (broadcast t ~stream:"rooms" (action_tag ~action:"replace"
    ~target:(room_dom_id room "list") ~html ()))

let closed_room_create t ~(room:R.t) ~user_ids ~html =
  let _ = room in
  let tag = action_tag ~action:"prepend" ~target:"shared_rooms" ~html () in
  List.iter (fun user_id -> ignore (to_user_rooms t user_id tag)) user_ids

let closed_room_update t ~(room:R.t) ~user_ids ~html =
  let tag = action_tag ~action:"replace"
    ~target:(room_dom_id room "list") ~html () in
  List.iter (fun user_id -> ignore (to_user_rooms t user_id tag)) user_ids

let direct_room_create t ~(room:R.t) ~memberships ~render =
  let _ = room in
  List.iter (fun (membership:Membership.t) ->
    let tag = action_tag ~action:"prepend" ~target:"direct_rooms"
      ~html:(render membership) () in
    ignore (to_user_rooms t membership.user_id tag)) memberships

let involvement_change t ~(room:R.t) ~(membership:Membership.t)
    ~previous ~html =
  if room.room_type = Db_rooms.Direct then () else
  let tag =
    if membership.involvement = Some Db_rooms.Invisible then
      Some (action_tag ~action:"remove" ~target:(room_dom_id room "list") ())
    else if previous = Some Db_rooms.Invisible then
      Some (action_tag ~action:"prepend" ~target:"shared_rooms" ~html ())
    else None in
  Option.iter (fun tag -> ignore (to_user_rooms t membership.user_id tag)) tag

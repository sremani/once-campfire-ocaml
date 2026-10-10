(** Application Cable channels and a bounded, thread-safe in-process broadcast hub. *)

open Lwt.Infix

type user = { id : int64; name : string }
type subscription = {
  identifier : string;
  channel : string;
  mutable streams : string list;
  mutable cursors : Cable_ring.subscriber list;
  base_streams : string list;
  room_id : int64 option;
}
type connection = {
  user : user;
  wake : unit Lwt_condition.t;
  mutable subscriptions : subscription list;
  mutable remote : [ `Remote of bool | `Server_restart ] option;
  mutable alive : bool;
}
type t = {
  db : Db_runtime.t;
  secret_key_base : string;
  now : unit -> string;
  mutex : Mutex.t;
  connections : connection list ref;
  hub : Cable_ring.t;
  notify : unit -> unit;
  started : float;
  mutable stopping : bool;
}

let quote = Rails_format.json_quote
let encode = Rails_format.encode
let as_int n = `Int (Int64.to_int n)
let identifier_frame identifier kind =
  "{\"identifier\":" ^ quote identifier ^ ",\"type\":" ^ quote kind ^ "}"
let delivery identifier payload =
  "{\"identifier\":" ^ quote identifier ^ ",\"message\":" ^ payload ^ "}"
let disconnect reason reconnect =
  "{\"type\":\"disconnect\",\"reason\":" ^ reason ^
  ",\"reconnect\":" ^ encode reconnect ^ "}"

let create ~db ~secret_key_base ~now () =
  let connections = ref [] in
  let mutex = Mutex.create () in
  let notification = Lwt_unix.make_notification (fun () ->
    Mutex.lock mutex;
    let live = !connections in
    Mutex.unlock mutex;
    List.iter (fun c -> Lwt_condition.broadcast c.wake ()) live) in
  {db; secret_key_base; now; mutex; connections;
   notify=(fun () -> Lwt_unix.send_notification notification);
   hub=Cable_ring.create (); started = Unix.gettimeofday (); stopping=false}

let with_lock t f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

let wake t = t.notify ()

let broadcast t ~stream ~payload =
  let count = Cable_ring.broadcast t.hub ~stream ~payload in
  if count > 0 then wake t;
  count

let broadcast_json t ~stream value = broadcast t ~stream ~payload:(encode value)
let read_room t ~user_id ~room_id =
  broadcast_json t ~stream:("user_" ^ Int64.to_string user_id ^ "_reads")
    (`Assoc ["room_id", as_int room_id])
let unread_room t ~user_id ~room_id =
  broadcast_json t ~stream:("user_" ^ Int64.to_string user_id ^ "_unreads")
    (`Assoc ["roomId", as_int room_id])
let disconnect_user t ~user_id ~reconnect =
  let count, wake_needed = with_lock t (fun () ->
    let wake_needed = ref false in
    let count = List.fold_left (fun n c ->
      if c.alive && c.user.id = user_id then (
        if c.remote = None then wake_needed := true;
        c.remote <- Some (`Remote reconnect); n+1)
      else n) 0 !(t.connections) in
    count, !wake_needed) in
  if wake_needed then wake t;
  count

let restart t =
  let count = with_lock t (fun () ->
    t.stopping <- true;
    List.fold_left (fun n c ->
      if c.alive then (c.remote <- Some `Server_restart; n + 1) else n)
      0 !(t.connections)) in
  if count > 0 then wake t;
  count
let event_sink t = function
  | Db_remaining.Event.DisconnectUser {user_id; reconnect} ->
      ignore (disconnect_user t ~user_id ~reconnect)
  | _ -> ()

let user_gid user_id = Global_id.make ~model_name:"User" ~id:(Int64.to_string user_id)
let room_gid room = Global_id.make
  ~model_name:(Db_rooms.room_type_name room.Db_rooms.Room.room_type)
  ~id:(Int64.to_string room.id)
let room_param room = Global_id.to_param (room_gid room)
let room_stream room channel = channel ^ ":" ^ room_param room

let field name = function `Assoc fields -> List.assoc_opt name fields | _ -> None
let string_field name value = match field name value with Some (`String s) -> Some s | _ -> None

let cast_id = function
  | `Int n -> Some (Int64.of_int n)
  | `String s -> Ruby_compat.integer_cast s
  | `Bool true -> Some 1L
  | `Bool false -> Some 0L
  | `Float f when Float.is_finite f && abs_float f < 9.2e18 -> Some (Int64.of_float f)
  | _ -> None

let verified_stream t params =
  match string_field "signed_stream_name" params with
  | None -> None
  | Some raw -> Turbo_stream.verified_stream_name
      ~secret_key_base:t.secret_key_base raw

let guarded_stream name =
  match String.split_on_char ':' name with
  | [_; "messages"] -> true
  | _ -> false

let room_from_stream db name =
  match String.split_on_char ':' name with
  | [param; "messages"] ->
      let gid = match Global_id.parse param with
        | Some gid -> Some gid | None -> Global_id.from_param param in
      Option.bind gid (fun gid ->
        if gid.app <> Global_id.app then None else
        match Int64.of_string_opt gid.id with
        | None -> None
        | Some id ->
            Option.bind (Db_rooms.Room.find_by_id db id) (fun room ->
              if gid.model_name = "Room" ||
                 gid.model_name = Db_rooms.room_type_name room.room_type
              then Some room else None))
  | _ -> None

let normalize_channel value =
  let value = if String.starts_with ~prefix:"::" value
    then String.sub value 2 (String.length value - 2) else value in
  match value with
  | "ApplicationCable::Channel" | "HeartbeatChannel" | "PresenceChannel"
  | "ReadRoomsChannel" | "RoomChannel" | "RoomMessagesChannel"
  | "TypingNotificationsChannel" | "UnreadRoomsChannel"
  | "Turbo::StreamsChannel" -> Some value
  | _ -> None

let add_subscription t c identifier params =
  if String.length identifier > 4096 || List.length c.subscriptions >= 64 ||
     List.exists (fun sub -> sub.identifier = identifier) c.subscriptions
  then Lwt.return_none else
  match Option.bind (string_field "channel" params) normalize_channel with
  | None -> Lwt.return_none
  | Some channel ->
      let room_id = Option.bind (field "room_id" params) cast_id in
      let find_room () = match room_id with
        | None -> Lwt.return_none
        | Some id -> Db_runtime.read_async t.db (fun db -> Db_rooms.Room.find_for_user db c.user.id id) in
      let room_stream_name room =
        let prefix = match channel with
          | "TypingNotificationsChannel" -> "typing_notifications"
          | "PresenceChannel" -> "presence"
          | _ -> "room" in
        room_stream room prefix in
      let resolve () = match channel with
        | "RoomChannel" | "PresenceChannel" | "TypingNotificationsChannel" ->
            find_room () >|= Option.map (fun room -> ([room_stream_name room], Some room.id))
        | "ReadRoomsChannel" ->
            Lwt.return_some (["user_" ^ Int64.to_string c.user.id ^ "_reads"], None)
        | "UnreadRoomsChannel" ->
            Lwt.return_some (["user_" ^ Int64.to_string c.user.id ^ "_unreads"], None)
        | "RoomMessagesChannel" | "Turbo::StreamsChannel" ->
            (match verified_stream t params with
             | None -> Lwt.return_none
             | Some stream when String.trim stream = "" -> Lwt.return_none
             | Some stream when channel = "Turbo::StreamsChannel" && guarded_stream stream ->
                 Lwt.return_none
             | Some stream when channel = "RoomMessagesChannel" ->
                 Db_runtime.read_async t.db (fun db ->
                   Option.bind (room_from_stream db stream) (fun room ->
                     Option.map (fun _ -> ([stream], Some room.id))
                       (Db_rooms.Room.find_for_user db c.user.id room.id)))
             | Some stream -> Lwt.return_some ([stream], None))
        | _ -> Lwt.return_some ([], None) in
      Lwt.catch resolve (fun _ -> Lwt.return_none) >>= fun result ->
      (match result with
       | None -> Lwt.return_some (identifier_frame identifier "reject_subscription")
       | Some (streams, room_id) ->
           let cursors = List.map (fun stream ->
             Cable_ring.subscribe t.hub ~stream ~identifier) streams in
           let sub = {identifier; channel; streams; cursors; base_streams=streams; room_id} in
           with_lock t (fun () -> c.subscriptions <- c.subscriptions @ [sub]);
           (match channel, room_id with
            | "PresenceChannel", Some room_id ->
                let now = t.now () in
                Db_runtime.write_async t.db (fun tx ->
                  match Db_rooms.Membership.find_by_room_and_user
                    (Db_runtime.conn tx) room_id c.user.id with
                  | None -> ()
                  | Some membership ->
                      ignore (Db_rooms.Membership.present tx ~now membership))
                >>= fun () ->
                ignore (read_room t ~user_id:c.user.id ~room_id);
                Lwt.return_some (identifier_frame identifier "confirm_subscription")
            | _ -> Lwt.return_some (identifier_frame identifier "confirm_subscription")))

let presence_change t c sub action =
  match sub.room_id with
  | None -> Lwt.return_unit
  | Some room_id ->
      let now = t.now () in
      Lwt.catch (fun () ->
        Db_runtime.write_async t.db (fun tx ->
          match Db_rooms.Membership.find_by_room_and_user
            (Db_runtime.conn tx) room_id c.user.id with
          | None -> ()
          | Some membership ->
              match action with
              | "absent" -> ignore (Db_rooms.Membership.disconnected tx ~now membership)
              | "refresh" -> ignore (Db_rooms.Membership.refresh_connection tx ~now membership)
              | "present" -> ignore (Db_rooms.Membership.present tx ~now membership)
              | _ -> ()))
        (fun _ -> Lwt.return_unit)

let remove_subscription t c identifier =
  let removed = with_lock t (fun () ->
    let found = List.find_opt (fun sub -> sub.identifier = identifier) c.subscriptions in
    c.subscriptions <- List.filter (fun sub -> sub.identifier <> identifier) c.subscriptions;
    found) in
  Option.iter (fun sub -> List.iter (Cable_ring.unsubscribe t.hub) sub.cursors) removed;
  match removed with
  | Some sub when sub.channel = "PresenceChannel" -> presence_change t c sub "absent"
  | _ -> Lwt.return_unit

let perform t c identifier data =
  let sub = with_lock t (fun () ->
    List.find_opt (fun sub -> sub.identifier = identifier) c.subscriptions) in
  match sub, data with
  | None, _ -> Lwt.return_unit
  | _, None -> Lwt.return_unit
  | Some sub, Some payload ->
      let action = match field "action" payload with
        | None | Some `Null -> "receive"
        | Some (`String value) when String.trim value = "" -> "receive"
        | Some (`String value) -> value
        | _ -> "" in
      match sub.channel, action with
      | "TypingNotificationsChannel", ("start" | "stop") ->
          let payload = `Assoc ["action",`String action;
            "user",`Assoc ["id",as_int c.user.id;"name",`String c.user.name]] in
          List.iter (fun stream -> ignore (broadcast_json t ~stream payload)) sub.streams;
          Lwt.return_unit
      | "PresenceChannel", ("present" | "absent" | "refresh") ->
          presence_change t c sub action >>= fun () ->
          if action = "present" then
            (match sub.room_id with Some room_id ->
              ignore (read_room t ~user_id:c.user.id ~room_id)
             | None -> ());
          Lwt.return_unit
      | "PresenceChannel", "subscribed" ->
          let cursors = List.map (fun stream ->
            Cable_ring.subscribe t.hub ~stream ~identifier:sub.identifier) sub.base_streams in
          with_lock t (fun () ->
            sub.streams <- sub.streams @ sub.base_streams;
            sub.cursors <- sub.cursors @ cursors);
          Lwt.return_unit
      | ("RoomChannel" | "TypingNotificationsChannel" | "ReadRoomsChannel"
        | "UnreadRoomsChannel" | "RoomMessagesChannel" | "Turbo::StreamsChannel"),
        "subscribed" ->
          let cursors = List.map (fun stream ->
            Cable_ring.subscribe t.hub ~stream ~identifier:sub.identifier) sub.base_streams in
          with_lock t (fun () ->
            sub.streams <- sub.streams @ sub.base_streams;
            sub.cursors <- sub.cursors @ cursors);
          Lwt.return_unit
      | _ -> Lwt.return_unit

let dispatch t c text =
  let data = try Some (Yojson.Basic.from_string text) with _ -> None in
  match data with
  | Some (`Assoc _ as data) ->
      (match string_field "command" data, string_field "identifier" data with
       | Some "subscribe", Some identifier ->
           let params = try Some (Yojson.Basic.from_string identifier) with _ -> None in
           (match params with
            | Some (`Assoc _ as params) -> add_subscription t c identifier params
            | _ -> Lwt.return_none)
       | Some "unsubscribe", Some identifier ->
           remove_subscription t c identifier >|= fun () -> None
       | Some "message", Some identifier ->
           let payload = match string_field "data" data with
             | None -> None
             | Some raw ->
                 (match Yojson.Basic.from_string raw with
                  | `Assoc _ as data -> Some data | _ -> None
                  | exception _ -> None) in
           perform t c identifier payload >|= fun () -> None
       | _ -> Lwt.return_none)
  | _ -> Lwt.return_none

let cookie_token t request =
  let headers = Cohttp.Header.get_multi (Cohttp.Request.headers request) "cookie" in
  Option.bind (Cookie_http.find "session_token" (Cookie_http.parse_headers headers))
    (fun raw -> Signed_cookie.verify ~secret_key_base:t.secret_key_base
      ~name:"session_token" ~raw ~now:(t.now ()))

let authenticate t request =
  match cookie_token t request with
  | None -> Lwt.return_none
  | Some token ->
      Db_runtime.read_async t.db (fun db ->
        Option.bind (Db_accounts.Session.find_by_token db token) (fun session ->
          Option.map (fun (user:Db_accounts.User.t) -> {id=user.id;name=user.name})
            (Db_accounts.User.find_by_id db session.user_id)))

let next_beat t =
  let elapsed = Unix.gettimeofday () -. t.started in
  let next = Float.floor (elapsed /. 3.) *. 3. +. 3. in
  max 0.01 (t.started +. next -. Unix.gettimeofday ())

let poll t c =
  let waiting = Lwt_condition.wait c.wake in
  let item = match with_lock t (fun () -> c.remote) with
    | Some (`Remote reconnect) -> `Remote reconnect
    | Some `Server_restart -> `Server_restart
    | None ->
        let cursors = with_lock t (fun () ->
          List.concat_map (fun sub -> sub.cursors) c.subscriptions) in
        (match Cable_ring.take_many t.hub cursors ~limit:Cable_ring.max_write_batch with
         | `Lagged frames -> `Lagged (List.map (fun (id,payload) -> delivery id payload) frames)
         | `Frames [] -> `Wait
         | `Frames frames -> `Frames (List.map (fun (id,payload) -> delivery id payload) frames)) in
  match item with
  | `Wait -> waiting >|= fun () -> `Wake
  | _ -> Lwt.cancel waiting; Lwt.return item

let cleanup t c =
  let subs = with_lock t (fun () ->
    c.alive <- false;
    t.connections := List.filter (fun other -> other != c) !(t.connections);
    let subs = c.subscriptions in c.subscriptions <- []; subs) in
  List.iter (fun sub -> List.iter (Cable_ring.unsubscribe t.hub) sub.cursors) subs;
  Lwt_list.iter_s (fun sub ->
    if sub.channel = "PresenceChannel" then presence_change t c sub "absent"
    else Lwt.return_unit) subs

let run t request socket =
  Lwt.catch (fun () -> authenticate t request) (fun _ -> Lwt.return_none) >>= function
  | None ->
      Cable_transport.send_text socket
        (disconnect "\"unauthorized\"" (`Bool false)) >>= fun () ->
      Cable_transport.send_close socket
  | Some _ when t.stopping ->
      Cable_transport.send_text socket
        (disconnect "\"server_restart\"" (`Bool true)) >>= fun () ->
      Cable_transport.send_close socket
  | Some user ->
      let c = {user; wake=Lwt_condition.create ();
        subscriptions=[];remote=None;alive=true} in
      with_lock t (fun () -> t.connections := c :: !(t.connections));
      (* Match the Rust second lookup after subscribing to remote disconnects. *)
      authenticate t request >>= fun still_valid ->
      if still_valid = None then (
        cleanup t c >>= fun () ->
        Cable_transport.send_text socket
          (disconnect "\"unauthorized\"" (`Bool false)) >>= fun () ->
        Cable_transport.send_close socket)
      else
      Lwt.finalize (fun () ->
        Cable_transport.send_text socket "{\"type\":\"welcome\"}" >>= fun () ->
        let incoming = Lwt_mvar.create_empty () in
        let reader = Lwt.catch (fun () ->
          let rec loop () =
            Cable_transport.read socket >>= fun message ->
            Lwt_mvar.put incoming message >>= fun () ->
            if message = Cable_transport.Closed then Lwt.return_unit else loop () in
          loop ()) (fun _ -> Lwt_mvar.put incoming Cable_transport.Closed) in
        Lwt.async (fun () -> reader);
        let rec loop () =
          Lwt.pick [
            (Lwt_mvar.take incoming >|= fun input -> `Input input);
            (poll t c >|= fun event -> `Event event);
            (Lwt_unix.sleep (next_beat t) >|= fun () -> `Beat)] >>= function
          | `Input Cable_transport.Closed -> Lwt.return_unit
          | `Input Cable_transport.Binary -> loop ()
          | `Input (Cable_transport.Text text) ->
              dispatch t c text >>= fun reply ->
              (match reply with None -> Lwt.return_unit
               | Some frame -> Cable_transport.send_text socket frame) >>= loop
          | `Event (`Frames frames) -> Cable_transport.send_texts socket frames >>= loop
          | `Event (`Remote reconnect) ->
              Cable_transport.send_text socket
                (disconnect "\"remote\"" (`Bool reconnect)) >>= fun () ->
              Cable_transport.send_close socket
          | `Event `Server_restart ->
              Cable_transport.send_text socket
                (disconnect "\"server_restart\"" (`Bool true)) >>= fun () ->
              Cable_transport.send_close socket
          | `Event (`Lagged frames) ->
              Cable_transport.send_texts socket frames >>= fun () ->
              Cable_transport.send_text socket (disconnect "null" (`Bool true)) >>= fun () ->
              Cable_transport.send_close socket
          | `Event (`Wait | `Wake) -> loop ()
          | `Beat ->
              let seconds = Int64.of_float (Unix.gettimeofday ()) in
              Cable_transport.send_text socket
                ("{\"type\":\"ping\",\"message\":" ^ Int64.to_string seconds ^ "}") >>= loop in
        Lwt.finalize loop (fun () -> Lwt.cancel reader; Lwt.return_unit))
        (fun () -> cleanup t c)

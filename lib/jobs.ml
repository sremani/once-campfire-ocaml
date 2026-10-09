(** In-process bounded queues for Rails perform_later events. Each kind has its
    own workers so a slow integration cannot block the others. *)

open Db_remaining.Event

type kind = Push_message | Deliver_webhook | Remove_banned_content | Purge_blob | Ad_hoc
type work = Event of Db_remaining.Event.t | Ad_hoc of (unit -> unit)
type queue = {
  kind : kind;
  pending : work Queue.t;
  condition : Condition.t;
  mutable active : int;
  mutable dropped : int;
  mutable completed : int;
  mutable failures : int;
}
type t = {
  mutex : Mutex.t;
  queues : queue list;
  capacity : int;
  mutable stopping : bool;
  mutable workers : Thread.t list;
  on_disconnect : user_id:int64 -> reconnect:bool -> unit;
}

let kinds = [Push_message; Deliver_webhook; Remove_banned_content; Purge_blob; Ad_hoc]
let kind_of_event = function
  | Db_remaining.Event.PushMessage _ -> Push_message
  | DeliverWebhook _ -> Deliver_webhook
  | RemoveBannedContent _ -> Remove_banned_content
  | PurgeBlob _ -> Purge_blob
  | DisconnectUser _ -> invalid_arg "DisconnectUser is synchronous"

let with_lock t f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

let queue t kind = List.find (fun q -> q.kind=kind) t.queues

let enqueue t kind work = with_lock t (fun () ->
  let q = queue t kind in
  if t.stopping || Queue.length q.pending >= t.capacity then (
    q.dropped <- q.dropped+1; false)
  else (Queue.add work q.pending; Condition.signal q.condition; true))

let event_sink t : Db_remaining.Event.sink = function
  | DisconnectUser {user_id;reconnect} -> t.on_disconnect ~user_id ~reconnect
  | event -> ignore (enqueue t (kind_of_event event) (Event event))

let perform_later t callback = enqueue t Ad_hoc (Ad_hoc callback)

let stats t kind = with_lock t (fun () ->
  let q = queue t kind in
  Queue.length q.pending,q.active,q.completed,q.failures,q.dropped)

let worker t q handler =
  let rec loop () =
    let next = with_lock t (fun () ->
      while Queue.is_empty q.pending && not t.stopping do
        Condition.wait q.condition t.mutex
      done;
      if Queue.is_empty q.pending then None else (
        q.active <- q.active+1; Some (Queue.take q.pending))) in
    match next with
    | None -> ()
    | Some work ->
      let failed = try
        (match work with Event event -> handler event | Ad_hoc callback -> callback ()); false
      with error ->
        Logs.err (fun m -> m "Campfire job failed: %s"
          (Printexc.to_string error)); true in
      with_lock t (fun () ->
        q.active <- q.active-1;
        if failed then q.failures <- q.failures+1 else q.completed <- q.completed+1);
      loop () in
  loop ()

let create ?(capacity=1024) ?(workers=1) ~on_push ~on_webhook
    ~on_remove_banned ~on_purge ?(on_disconnect=(fun ~user_id:_ ~reconnect:_ -> ())) () =
  let make kind = {kind;pending=Queue.create ();condition=Condition.create ();
    active=0;dropped=0;completed=0;failures=0} in
  let t = {mutex=Mutex.create ();queues=List.map make kinds;
    capacity=max 1 capacity;stopping=false;workers=[];
    on_disconnect} in
  let handle = function
    | Db_remaining.Event.PushMessage {room_id;message_id} -> on_push ~room_id ~message_id
    | DeliverWebhook {bot_id;message_id} -> on_webhook ~bot_id ~message_id
    | RemoveBannedContent {user_id} -> on_remove_banned ~user_id
    | PurgeBlob {blob_id} -> on_purge ~blob_id
    | DisconnectUser _ -> () in
  List.iter (fun q -> for _=1 to max 1 workers do
    let thread = Thread.create (fun () ->
      let rec supervise () =
        if not (with_lock t (fun () -> t.stopping)) then
          (try worker t q handle with exn ->
            Logs.err (fun m -> m "Campfire %s worker stopped: %s"
              (match q.kind with Push_message -> "push" | Deliver_webhook -> "webhook"
                | Remove_banned_content -> "banned content" | Purge_blob -> "purge"
                | Ad_hoc -> "ad hoc") (Printexc.to_string exn));
            Thread.delay 0.05;
            supervise ()) in
      supervise ()) () in
    t.workers <- thread :: t.workers
  done) t.queues;
  t

let compose_sinks cable jobs event =
  match event with
  | Db_remaining.Event.DisconnectUser _ -> Cable_channels.event_sink cable event
  | _ -> event_sink jobs event

(** Keep workers accepting follow-on jobs emitted by running jobs until every
    queue is empty and every worker is idle in one locked observation. *)
let shutdown t ~deadline =
  let rec await () =
    let drained = with_lock t (fun () ->
      let done_ = List.for_all
        (fun q -> Queue.is_empty q.pending && q.active=0) t.queues in
      if done_ then (
        t.stopping <- true;
        List.iter (fun q -> Condition.broadcast q.condition) t.queues);
      done_) in
    if drained then true else if Unix.gettimeofday () >= deadline then false
    else (Thread.delay 0.005; await ()) in
  await ()

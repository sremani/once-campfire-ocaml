(** Web Push notifications and a bounded delivery pool. Network I/O is an
    injected transport; the request carries a pinned, publicly resolved IP. *)

type notification = {
  title : string; body : string; path : string; badge : int64;
  subscription : Db_remaining.Push_subscription.t;
}
type request = {
  endpoint : string; pinned_ip : string; headers : (string * string) list;
  body : string; open_timeout : float; read_timeout : float;
  deadline : float;
}
type response = { status : int; reason : string }
type error = Invalid_subscription_key | Argument of string | Response of int * string
  | Gone of int | Network of string
type outbound = request -> (response, string) result
type resolver = string -> string option

let notification ~conn subscription (payload:Db_remaining.Push_subscription.payload) =
  {title=payload.title;body=payload.body;path=payload.path;
   badge=Db_remaining.Push_subscription.badge subscription conn;subscription}

let encoded_message n = Yojson.Safe.to_string (`Assoc [
  "title",`String n.title;
  "options",`Assoc [
    "body",`String n.body;
    "icon",`String "/account/logo";
    "data",`Assoc ["path",`String n.path;"badge",`Intlit (Int64.to_string n.badge)]]])

let public_ip value =
  match Ipaddr.of_string value with
  | Error _ -> false
  | Ok ip -> not (Network_guard.blocked_address ip)

let verify_response response =
  match response.status with
  | 404 | 410 -> Error (Gone response.status)
  | status when status>=200 && status<300 -> Ok status
  | status -> Error (Response (status,response.reason))

let invalidates_subscription = function
  | Gone _ | Invalid_subscription_key -> true
  | Argument _ | Response _ | Network _ -> false

let deliver ~resolve ~outbound ~vapid ~now n =
  let subscription = n.subscription in
  match subscription.endpoint with
  | None -> Ok None
  | Some endpoint ->
    (match Db_remaining.Push_subscription.parsed_endpoint endpoint with
     | Some ("https",host,(None|Some 443))
       when Db_remaining.Push_subscription.permitted_host host ->
       (match resolve host with
        | None -> Ok None
        | Some pinned_ip when not (public_ip pinned_ip) -> Ok None
        | Some pinned_ip ->
          let p256dh=Option.value ~default:"" subscription.p256dh_key in
          let auth=Option.value ~default:"" subscription.auth_key in
          (match Web_push_crypto.encrypt ~message:(encoded_message n) ~p256dh ~auth with
           | Error (Web_push_crypto.Invalid_key _) -> Error Invalid_subscription_key
           | Error (Web_push_crypto.Argument message) -> Error (Argument message)
           | Ok body ->
             let authorization=Web_push_vapid.authorization vapid
               ~audience:("https://"^host) ~now in
             let headers=[
               "Content-Type","application/octet-stream";
               "Ttl","2419200";"Urgency","high";
               "Content-Encoding","aes128gcm";
               "Content-Length",string_of_int (String.length body);
               "Authorization",authorization] in
             let request={endpoint;pinned_ip;headers;body;open_timeout=10.;
               read_timeout=10.;deadline=Unix.gettimeofday ()+.30.} in
             match outbound request with
             | Error message -> Error (Network message)
             | Ok response -> Result.map Option.some (verify_response response)))
     | _ -> Ok None)

type pool = {
  mutex : Mutex.t; condition : Condition.t;
  pending : notification Queue.t;
  invalidations : int64 Queue.t;
  mutable active : int; mutable invalidating : bool;
  mutable dropped : int; mutable stopping : bool;
  deliver_one : notification -> (int option,error) result;
  invalidate : int64 -> unit;
  max_active : int; max_queue : int;
}

let with_lock pool f =
  Mutex.lock pool.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock pool.mutex) f

let pending pool = with_lock pool (fun () -> Queue.length pool.pending + pool.active)
let dropped pool = with_lock pool (fun () -> pool.dropped)

let enqueue pool n = with_lock pool (fun () ->
  if pool.stopping || Queue.length pool.pending + pool.active >= pool.max_active+pool.max_queue
  then (pool.dropped <- pool.dropped+1; false)
  else (Queue.add n pool.pending; Condition.broadcast pool.condition; true))

let rec delivery_worker pool () =
  let next = with_lock pool (fun () ->
    while Queue.is_empty pool.pending && not pool.stopping do
      Condition.wait pool.condition pool.mutex
    done;
    if Queue.is_empty pool.pending then None else (
      pool.active <- pool.active+1; Some (Queue.take pool.pending))) in
  match next with
  | None -> ()
  | Some n ->
    let invalid = try
      match pool.deliver_one n with
      | Error error -> invalidates_subscription error
      | Ok _ -> false
    with error ->
      prerr_endline ("Web Push delivery failed: "^Printexc.to_string error);
      false in
    with_lock pool (fun () ->
      if invalid then Queue.add n.subscription.id pool.invalidations;
      pool.active <- pool.active-1;
      Condition.broadcast pool.condition);
    delivery_worker pool ()

let rec invalidation_worker pool () =
  let next = with_lock pool (fun () ->
    while Queue.is_empty pool.invalidations &&
      (not pool.stopping || pool.active>0 || not (Queue.is_empty pool.pending)) do
      Condition.wait pool.condition pool.mutex
    done;
    if Queue.is_empty pool.invalidations then None else (
      pool.invalidating <- true; Some (Queue.take pool.invalidations))) in
  match next with
  | None -> ()
  | Some id ->
    (try pool.invalidate id with _ -> ());
    with_lock pool (fun () -> pool.invalidating <- false);
    invalidation_worker pool ()

let create_pool ?(max_active=50) ?(max_queue=10000) ~resolve ~outbound
    ~vapid ~invalidate () =
  let pool={mutex=Mutex.create ();condition=Condition.create ();
    pending=Queue.create ();invalidations=Queue.create ();
    active=0;invalidating=false;dropped=0;stopping=false;
    deliver_one=(fun n -> deliver ~resolve ~outbound ~vapid
      ~now:(int_of_float (Unix.gettimeofday ())) n);
    invalidate;max_active=max 1 max_active;max_queue=max 0 max_queue} in
  for _=1 to pool.max_active do
    ignore (Thread.create (delivery_worker pool) ())
  done;
  ignore (Thread.create (invalidation_worker pool) ());
  pool

let queue pool conn payload subscriptions =
  List.sort (fun a b -> Int64.compare a.Db_remaining.Push_subscription.id b.id) subscriptions
  |> List.iter (fun subscription -> ignore (enqueue pool (notification ~conn subscription payload)))

let push_message ?(rich_text=Db_messages.basic_rich_text) pool conn message ~now =
  let payload,everything,mentions =
    Db_remaining.Push_subscription.pushes_for ~rich_text conn message ~now in
  queue pool conn payload everything;
  queue pool conn payload mentions;
  payload

let shutdown pool ~deadline =
  with_lock pool (fun () ->
    pool.stopping <- true; Condition.broadcast pool.condition);
  let rec await () =
    let drained = with_lock pool (fun () ->
      Queue.is_empty pool.pending && pool.active=0 &&
      Queue.is_empty pool.invalidations && not pool.invalidating) in
    if drained then true else if Unix.gettimeofday ()>=deadline then false
    else (Thread.delay 0.005; await ()) in
  await ()

(** Local, framed Unix-socket fanout for separate HTTP workers. The broker
    forwards events without interpreting their contents. A failed connection
    is fatal to a worker so a broken bus cannot silently lose Cable events. *)

type event =
  | Broadcast of string * string
  | Batch of (string * string) list
  | Disconnect of int64 * bool
  | Track of int
  | Subscribe of string * int
  | Unsubscribe of string
  | Ack of int

(* A 16 MiB accepted HTML request can expand substantially when escaped into a
   Turbo stream. Keep a bounded frame large enough for that supported path. *)
let max_frame = 128 * 1024 * 1024

let rec read_exact fd buffer offset remaining =
  if remaining > 0 then
    let count = try Unix.read fd buffer offset remaining
      with Unix.Unix_error (Unix.EINTR, _, _) -> -1 in
    if count < 0 then read_exact fd buffer offset remaining
    else
    if count = 0 then raise End_of_file
    else read_exact fd buffer (offset + count) (remaining - count)

let rec write_exact fd buffer offset remaining =
  if remaining > 0 then
    let count = try Unix.write fd buffer offset remaining
      with Unix.Unix_error (Unix.EINTR, _, _) -> 0 in
    if count = 0 then write_exact fd buffer offset remaining
    else write_exact fd buffer (offset + count) (remaining - count)

let read_frame fd =
  let header = Bytes.create 4 in
  read_exact fd header 0 4;
  let length =
    (Char.code (Bytes.get header 0) lsl 24) lor
    (Char.code (Bytes.get header 1) lsl 16) lor
    (Char.code (Bytes.get header 2) lsl 8) lor
    Char.code (Bytes.get header 3) in
  if length <= 0 || length > max_frame then failwith "invalid Cable bus frame";
  let body = Bytes.create length in
  read_exact fd body 0 length;
  let event : event = Marshal.from_bytes body 0 in
  event

let write_frame fd mutex event =
  let body = Marshal.to_bytes event [Marshal.No_sharing] in
  let length = Bytes.length body in
  if length > max_frame then failwith "Cable bus frame too large";
  let frame = Bytes.create (length + 4) in
  Bytes.set frame 0 (Char.chr ((length lsr 24) land 255));
  Bytes.set frame 1 (Char.chr ((length lsr 16) land 255));
  Bytes.set frame 2 (Char.chr ((length lsr 8) land 255));
  Bytes.set frame 3 (Char.chr (length land 255));
  Bytes.blit body 0 frame 4 length;
  Mutex.lock mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock mutex) (fun () ->
    write_exact fd frame 0 (Bytes.length frame))

type peer = {
  fd : Unix.file_descr;
  write_mutex : Mutex.t;
  interests : (string, int) Hashtbl.t;
  mutable tracking : bool;
}

let serve path =
  if Sys.file_exists path then Unix.unlink path;
  let listener = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect ~finally:(fun () -> Unix.close listener) (fun () ->
    Unix.bind listener (Unix.ADDR_UNIX path);
    Unix.chmod path 0o600;
    Unix.listen listener 16;
    let peers = ref [] in
    let peers_mutex = Mutex.create () in
    let detach peer =
      Mutex.lock peers_mutex;
      let attached = List.memq peer !peers in
      if attached then peers := List.filter (fun other -> other != peer) !peers;
      Mutex.unlock peers_mutex;
      if attached then (
        (try Unix.shutdown peer.fd Unix.SHUTDOWN_ALL with _ -> ());
        (try Unix.close peer.fd with _ -> ())) in
    let rec client_loop peer =
      let event = read_frame peer.fd in
      let acknowledge token = write_frame peer.fd peer.write_mutex (Ack token) in
      (match event with
       | Track token ->
           Mutex.lock peers_mutex;
           peer.tracking <- true;
           Mutex.unlock peers_mutex;
           acknowledge token
       | Subscribe (stream,token) ->
           Mutex.lock peers_mutex;
           let count = Option.value (Hashtbl.find_opt peer.interests stream) ~default:0 in
           Hashtbl.replace peer.interests stream (count + 1);
           Mutex.unlock peers_mutex;
           acknowledge token
       | Unsubscribe stream ->
           Mutex.lock peers_mutex;
           let count = Option.value (Hashtbl.find_opt peer.interests stream) ~default:0 in
           if count <= 1 then Hashtbl.remove peer.interests stream
           else Hashtbl.replace peer.interests stream (count - 1);
           Mutex.unlock peers_mutex
       | Ack _ -> failwith "unexpected Cable bus acknowledgement"
       | (Broadcast _ | Batch _ | Disconnect _) as event ->
           let interested other =
             if not other.tracking then true else
             match event with
             | Broadcast (stream,_) -> Hashtbl.mem other.interests stream
             | Batch events -> List.exists (fun (stream,_) ->
                 Hashtbl.mem other.interests stream) events
             | Disconnect _ -> true
             | _ -> false in
           Mutex.lock peers_mutex;
           let recipients = List.filter (fun other ->
             other != peer && interested other) !peers in
           Mutex.unlock peers_mutex;
           List.iter (fun other ->
             try write_frame other.fd other.write_mutex event
             with _ -> detach other) recipients);
      client_loop peer in
    while true do
      let fd,_ = Unix.accept listener in
      let peer = {fd;write_mutex=Mutex.create ();
        interests=Hashtbl.create 16;tracking=false} in
      Mutex.lock peers_mutex;
      peers := peer :: !peers;
      Mutex.unlock peers_mutex;
      ignore (Thread.create (fun () ->
        (try client_loop peer with _ -> ());
        detach peer) ())
    done)

type client = {
  fd : Unix.file_descr;
  write_mutex : Mutex.t;
  stopped : bool Atomic.t;
  reader : Thread.t;
  control_mutex : Mutex.t;
  ack_mutex : Mutex.t;
  ack_condition : Condition.t;
  mutable next_token : int;
  last_ack : int ref;
}

let connect path ~receive =
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  let rec wait remaining =
    try Unix.connect fd (Unix.ADDR_UNIX path)
    with Unix.Unix_error ((Unix.ENOENT | Unix.ECONNREFUSED), _, _)
      when remaining > 0 ->
        Thread.delay 0.01;
        wait (remaining - 1) in
  (try wait 500 with exn -> Unix.close fd; raise exn);
  let stopped = Atomic.make false in
  let ack_mutex = Mutex.create () in
  let ack_condition = Condition.create () in
  let last_ack = ref 0 in
  let reader = Thread.create (fun () ->
    try while not (Atomic.get stopped) do
      match read_frame fd with
      | Ack token ->
          Mutex.lock ack_mutex;
          last_ack := token;
          Condition.broadcast ack_condition;
          Mutex.unlock ack_mutex
      | event -> receive event
    done
    with exn ->
      if not (Atomic.get stopped) then (
        prerr_endline ("Cable bus disconnected: " ^ Printexc.to_string exn);
        exit 1)) () in
  {fd;write_mutex=Mutex.create ();stopped;reader;
    control_mutex=Mutex.create ();ack_mutex;ack_condition;
    next_token=0;last_ack}

let publish client event =
  if Atomic.get client.stopped then invalid_arg "Cable bus stopped";
  try write_frame client.fd client.write_mutex event
  with exn ->
    prerr_endline ("Cable bus send failed: " ^ Printexc.to_string exn);
    exit 1

let sync_control client make =
  Mutex.lock client.control_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock client.control_mutex) (fun () ->
    client.next_token <- client.next_token + 1;
    let token = client.next_token in
    publish client (make token);
    Mutex.lock client.ack_mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock client.ack_mutex) (fun () ->
      while !(client.last_ack) < token do
        Condition.wait client.ack_condition client.ack_mutex
      done))

let track client = sync_control client (fun token -> Track token)
let subscribe client stream =
  sync_control client (fun token -> Subscribe (stream,token))
let unsubscribe client stream = publish client (Unsubscribe stream)

let close client =
  Atomic.set client.stopped true;
  (try Unix.shutdown client.fd Unix.SHUTDOWN_ALL with _ -> ());
  Thread.join client.reader;
  Unix.close client.fd

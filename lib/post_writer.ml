(** Opt-in Unix-socket writer for ordinary message creates. The HTTP workers
    keep independent reader pools and perform all presentation and delivery;
    this process owns the one SQLite writer connection for these messages. *)

open Lwt.Infix

type request = {
  room_id : int64;
  creator_id : int64;
  client_message_id : string option;
  body : string;
  index_plain : string;
  now : string;
}

type reply = Created of Db_messages.Message.t | Failed of string

let max_frame = 64 * 1024

let rec read_exact fd bytes offset remaining =
  if remaining > 0 then
    let count = try Unix.read fd bytes offset remaining
      with Unix.Unix_error (Unix.EINTR,_,_) -> -1 in
    if count < 0 then read_exact fd bytes offset remaining
    else if count = 0 then raise End_of_file
    else read_exact fd bytes (offset+count) (remaining-count)

let rec write_exact fd bytes offset remaining =
  if remaining > 0 then
    let count = try Unix.write fd bytes offset remaining
      with Unix.Unix_error (Unix.EINTR,_,_) -> 0 in
    if count = 0 then write_exact fd bytes offset remaining
    else write_exact fd bytes (offset+count) (remaining-count)

let send fd value =
  let body = Marshal.to_bytes value [Marshal.No_sharing] in
  let size = Bytes.length body in
  if size > max_frame then invalid_arg "post writer frame too large";
  let header = Bytes.create 4 in
  for i = 0 to 3 do
    Bytes.set header i (Char.chr ((size lsr (24-8*i)) land 255))
  done;
  write_exact fd header 0 4;
  write_exact fd body 0 size

let receive fd =
  let header = Bytes.create 4 in
  read_exact fd header 0 4;
  let size = ref 0 in
  for i = 0 to 3 do
    size := (!size lsl 8) lor Char.code (Bytes.get header i)
  done;
  if !size < 1 || !size > max_frame then failwith "invalid post writer frame";
  let body = Bytes.create !size in
  read_exact fd body 0 !size;
  Marshal.from_bytes body 0

let rec read_exact_async fd bytes offset remaining =
  if remaining = 0 then Lwt.return_unit else
  Lwt_unix.read fd bytes offset remaining >>= fun count ->
  if count = 0 then Lwt.fail End_of_file
  else read_exact_async fd bytes (offset+count) (remaining-count)

let rec write_exact_async fd bytes offset remaining =
  if remaining = 0 then Lwt.return_unit else
  Lwt_unix.write fd bytes offset remaining >>= fun count ->
  if count = 0 then Lwt.fail End_of_file
  else write_exact_async fd bytes (offset+count) (remaining-count)

let send_async fd value =
  let body = Marshal.to_bytes value [Marshal.No_sharing] in
  let size = Bytes.length body in
  if size > max_frame then invalid_arg "post writer frame too large";
  let header = Bytes.create 4 in
  for i = 0 to 3 do
    Bytes.set header i (Char.chr ((size lsr (24-8*i)) land 255))
  done;
  write_exact_async fd header 0 4 >>= fun () ->
  write_exact_async fd body 0 size

let receive_async fd =
  let header = Bytes.create 4 in
  read_exact_async fd header 0 4 >>= fun () ->
  let size = ref 0 in
  for i = 0 to 3 do
    size := (!size lsl 8) lor Char.code (Bytes.get header i)
  done;
  if !size < 1 || !size > max_frame then failwith "invalid post writer frame";
  let body = Bytes.create !size in
  read_exact_async fd body 0 !size >|= fun () ->
  Marshal.from_bytes body 0

let async_pools : (string, Lwt_unix.file_descr Lwt_pool.t) Hashtbl.t =
  Hashtbl.create 2

let pool_for path = match Hashtbl.find_opt async_pools path with
  | Some pool -> pool
  | None ->
      let pool = Lwt_pool.create 4
        ~check:(fun _ valid -> valid false)
        ~dispose:Lwt_unix.close
        (fun () ->
          let fd = Lwt_unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
          Lwt.catch
            (fun () -> Lwt_unix.connect fd (Unix.ADDR_UNIX path) >|= fun () -> fd)
            (fun exn -> Lwt_unix.close fd >>= fun () -> Lwt.fail exn)) in
      Hashtbl.add async_pools path pool;
      pool

let create_message_async path request =
  Perf_probe.time_lwt "post_writer_rpc" (fun () ->
    Lwt_pool.use (pool_for path) (fun fd ->
      Perf_probe.time_lwt "post_writer_client_io" (fun () ->
        send_async fd request >>= fun () ->
        receive_async fd >>= function
        | Created message -> Lwt.return message
        | Failed error -> Lwt.fail_with ("post writer: " ^ error))))

type pending = {
  request : request;
  mutex : Mutex.t;
  ready : Condition.t;
  mutable result : reply option;
}

let make_pending request =
  {request;mutex=Mutex.create ();ready=Condition.create ();result=None}

let complete pending result =
  Mutex.lock pending.mutex;
  pending.result <- Some result;
  Condition.signal pending.ready;
  Mutex.unlock pending.mutex

let await pending =
  Mutex.lock pending.mutex;
  while pending.result = None do Condition.wait pending.ready pending.mutex done;
  let result = Option.get pending.result in
  Mutex.unlock pending.mutex;
  result

let create runtime request =
  let now = Db_accounts.now_time request.now in
  Db_runtime.write runtime (fun tx ->
    Db_messages.Message.create ~index_plain:request.index_plain
      ~on_push:(fun ~room_id:_ ~message_id:_ -> ()) tx ~now
      {room_id=request.room_id;creator_id=request.creator_id;
       client_message_id=request.client_message_id;
       body=Some request.body;attachment_blob_id=None})

let serve path runtime =
  if Sys.file_exists path then Unix.unlink path;
  let listener = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect ~finally:(fun () -> Unix.close listener) (fun () ->
    Unix.bind listener (Unix.ADDR_UNIX path);
    Unix.chmod path 0o600;
    Unix.listen listener 16;
    let queue_mutex = Mutex.create () and queue_ready = Condition.create () in
    let queue = Queue.create () in
    let batch_delay = match Sys.getenv_opt "CAMPFIRE_POST_BATCH_DELAY_US" with
      | Some value ->
          (try float_of_int (min 1000 (max 0 (int_of_string value))) /. 1_000_000.
           with Failure _ -> 0.)
      | None -> 0. in
    let enqueue pending =
      Mutex.lock queue_mutex;
      Queue.add pending queue;
      Condition.signal queue_ready;
      Mutex.unlock queue_mutex in
    let writer () =
      while true do
        Mutex.lock queue_mutex;
        while Queue.is_empty queue do Condition.wait queue_ready queue_mutex done;
        if batch_delay > 0. && Queue.length queue < 16 then (
          Mutex.unlock queue_mutex;
          Thread.delay batch_delay;
          Mutex.lock queue_mutex);
        let batch = ref [] in
        while not (Queue.is_empty queue) && List.length !batch < 16 do
          batch := Queue.take queue :: !batch
        done;
        Mutex.unlock queue_mutex;
        let batch = List.rev !batch in
        let committed = ref false in
        let results = try
          let messages = Perf_probe.time "post_writer_batch_db" (fun () ->
            Db_runtime.write runtime (fun tx ->
              Db_runtime.after_commit tx (fun _ -> committed := true);
              List.map (fun pending ->
                let request = pending.request in
                let now = Db_accounts.now_time request.now in
                Db_messages.Message.create ~index_plain:request.index_plain
                  ~on_push:(fun ~room_id:_ ~message_id:_ -> ()) tx ~now
                  {room_id=request.room_id;creator_id=request.creator_id;
                   client_message_id=request.client_message_id;
                   body=Some request.body;attachment_blob_id=None}) batch)) in
          List.map (fun message -> Created message) messages
        with exn ->
          if !committed then
            List.map (fun _ -> Failed (Printexc.to_string exn)) batch
          else
            List.map (fun pending ->
              try Created (create runtime pending.request)
              with exn -> Failed (Printexc.to_string exn)) batch in
        List.iter2 complete batch results
      done in
    ignore (Thread.create writer ());
    let handle fd =
      Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
        try while true do
          let (request : request) = receive fd in
          let pending = make_pending request in
          enqueue pending;
          send fd (Perf_probe.time "post_writer_queue_wait" (fun () ->
            await pending))
        done with End_of_file -> ()) in
    while true do
      let fd,_ = Unix.accept listener in
      ignore (Thread.create handle fd)
    done)

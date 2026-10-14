open Campfire

let with_broker f =
  let directory = Filename.temp_file "campfire-cable-bus-" "" in
  Sys.remove directory;
  Unix.mkdir directory 0o700;
  let path = Filename.concat directory "bus.sock" in
  let broker = Unix.fork () in
  if broker = 0 then (
    try Cable_bus.serve path with _ -> exit 1)
  else Fun.protect ~finally:(fun () ->
    (try Unix.kill broker Sys.sigterm with _ -> ());
    ignore (Unix.waitpid [] broker);
    if Sys.file_exists path then Unix.unlink path;
    Unix.rmdir directory) (fun () -> f path)

let collected () =
  let mutex = Mutex.create () in
  let received = ref [] in
  let add event =
    Mutex.lock mutex;
    received := event :: !received;
    Mutex.unlock mutex in
  let get () =
    Mutex.lock mutex;
    let events = List.rev !received in
    Mutex.unlock mutex;
    events in
  add,get

let await label get expected =
  let rec loop remaining =
    let events = get () in
    if List.length events >= expected then events
    else if remaining = 0 then Alcotest.fail (label ^ " timed out")
    else (Thread.delay 0.01; loop (remaining - 1)) in
  loop 200

let fanout () = with_broker (fun path ->
  let add_a,get_a = collected () in
  let add_b,get_b = collected () in
  let a = Cable_bus.connect path ~receive:add_a in
  Fun.protect ~finally:(fun () -> Cable_bus.close a) (fun () ->
    let b = Cable_bus.connect path ~receive:add_b in
    Fun.protect ~finally:(fun () -> Cable_bus.close b) (fun () ->
      Cable_bus.track a;
      Cable_bus.track b;
      Alcotest.(check bool) "no remote subscriptions" false
        (Cable_bus.any_remote_interests a);
      Cable_bus.subscribe b "room";
      Cable_bus.subscribe b "user";
      Alcotest.(check bool) "remote subscriptions visible" true
        (Cable_bus.any_remote_interests a);
      let message = String.make 65536 'x' in
      Cable_bus.publish a (Cable_bus.Broadcast ("room",message));
      Alcotest.(check bool) "large broadcast reaches peer" true
        (await "broadcast" get_b 1 = [Cable_bus.Broadcast ("room",message)]);
      let batch = Cable_bus.Batch ["room","first";"user","second"] in
      Cable_bus.publish a batch;
      Alcotest.(check bool) "ordered batch reaches peer" true
        (await "batch" get_b 2 = [Cable_bus.Broadcast ("room",message);batch]);
      Cable_bus.publish b (Cable_bus.Disconnect (42L,true));
      Alcotest.(check bool) "disconnect reaches peer" true
        (await "disconnect" get_a 1 = [Cable_bus.Disconnect (42L,true)]);
      Alcotest.(check int) "no self echo A" 1 (List.length (get_a ()));
      Alcotest.(check int) "no self echo B" 2 (List.length (get_b ()));
      Cable_bus.unsubscribe b "room";
      Cable_bus.unsubscribe b "user";
      Cable_bus.track b;
      Alcotest.(check bool) "remote subscriptions removed" false
        (Cable_bus.any_remote_interests a);
      Cable_bus.publish a (Cable_bus.Broadcast ("room","unsubscribed"));
      Thread.delay 0.02;
      Alcotest.(check int) "unsubscribed peer skipped" 2
        (List.length (get_b ()));
      Cable_bus.subscribe b "room";
      Cable_bus.publish a (Cable_bus.Broadcast ("room","subscribed"));
      Alcotest.(check int) "subscribed peer receives" 3
        (List.length (await "subscribed" get_b 3));
      Cable_bus.unsubscribe b "room";
      Cable_bus.track b;
      Cable_bus.publish a (Cable_bus.Broadcast ("room","after unsubscribe"));
      Thread.delay 0.02;
      Alcotest.(check int) "unsubscribed again" 3
        (List.length (get_b ())))))

let cable_delivery () = with_broker (fun path ->
  let database = Filename.temp_file "campfire-bus-db-" ".sqlite3" in
  Sys.remove database;
  let runtime = Db_runtime.open_db ~prepare:false database in
  Fun.protect ~finally:(fun () ->
    Db_runtime.close runtime;
    List.iter (fun file -> if Sys.file_exists file then Sys.remove file)
      [database;database ^ "-wal";database ^ "-shm"]) (fun () ->
    let make () = Cable_channels.create ~db:runtime
      ~secret_key_base:(String.make 64 'q')
      ~now:(fun () -> "2026-10-14T00:00:00Z") () in
    let first = make () and second = make () in
    let first_client = Cable_bus.connect path
      ~receive:(Cable_channels.receive_remote first) in
    Fun.protect ~finally:(fun () -> Cable_bus.close first_client) (fun () ->
      Cable_channels.attach_bus first first_client;
      let second_client = Cable_bus.connect path
        ~receive:(Cable_channels.receive_remote second) in
      Fun.protect ~finally:(fun () -> Cable_bus.close second_client) (fun () ->
        Cable_channels.attach_bus second second_client;
        Alcotest.(check bool) "idle remote hub" false
          (Cable_channels.may_have_subscribers first);
        let subscriber = Cable_ring.subscribe second.hub
          ~stream:"room:messages" ~identifier:"peer" in
        Cable_bus.subscribe second_client "room:messages";
        Alcotest.(check bool) "subscribed remote hub" true
          (Cable_channels.may_have_subscribers first);
        ignore (Cable_channels.broadcast first
          ~stream:"room:messages" ~payload:"{\"ok\":true}");
        let rec receive remaining =
          match Cable_ring.take_many second.hub [subscriber] ~limit:1 with
          | `Frames [("peer","{\"ok\":true}")] -> ()
          | _ when remaining = 0 -> Alcotest.fail "remote Cable delivery timed out"
          | _ -> Thread.delay 0.01; receive (remaining - 1) in
        receive 200;
        Cable_ring.unsubscribe second.hub subscriber;
        Cable_bus.unsubscribe second_client "room:messages"))))

let () = Alcotest.run "Cable broker" [
  "fanout", [Alcotest.test_case "cross-worker events and framing" `Quick fanout;
              Alcotest.test_case "Cable ring delivery" `Quick cable_delivery]
]

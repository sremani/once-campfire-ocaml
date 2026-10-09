open Campfire

let frames = function
  | `Frames items -> items
  | `Lagged _ -> Alcotest.fail "subscriber lagged unexpectedly"

let per_stream_capacity () =
  let hub = Cable_ring.create () in
  let a = Cable_ring.subscribe hub ~stream:"a" ~identifier:"one" in
  let b = Cable_ring.subscribe hub ~stream:"b" ~identifier:"two" in
  for n = 0 to 255 do
    Alcotest.(check int) "one A reader" 1
      (Cable_ring.broadcast hub ~stream:"a" ~payload:(string_of_int n))
  done;
  for n = 0 to 300 do
    ignore (Cable_ring.broadcast hub ~stream:"b" ~payload:(string_of_int n))
  done;
  let first = Cable_ring.take_many hub [a] ~limit:64 |> frames in
  Alcotest.(check int) "bounded batch" 64 (List.length first);
  Alcotest.(check (list string)) "A has no gaps from B flood"
    (List.init 64 string_of_int) (List.map snd first);
  Alcotest.(check bool) "B alone lagged" true
    (match Cable_ring.take_many hub [b] ~limit:64 with `Lagged [] -> true | _ -> false);
  for n = 256 to 320 do
    ignore (Cable_ring.broadcast hub ~stream:"a" ~payload:(string_of_int n))
  done;
  Alcotest.(check bool) "A lags at cursor gap 257" true
    (match Cable_ring.take_many hub [a] ~limit:64 with `Lagged [] -> true | _ -> false);
  Cable_ring.unsubscribe hub a;
  Cable_ring.unsubscribe hub b;
  Alcotest.(check int) "no orphaned stream rings" 0 (Cable_ring.stream_count hub)

let independent_cursors () =
  let hub = Cable_ring.create () in
  let a = Cable_ring.subscribe hub ~stream:"room" ~identifier:"first" in
  let b = Cable_ring.subscribe hub ~stream:"room" ~identifier:"second" in
  Alcotest.(check int) "two readers" 2
    (Cable_ring.broadcast hub ~stream:"room" ~payload:"hello");
  Alcotest.(check (list (pair string string))) "first receives" ["first","hello"]
    (frames (Cable_ring.take_many hub [a] ~limit:64));
  Alcotest.(check (list (pair string string))) "second still receives" ["second","hello"]
    (frames (Cable_ring.take_many hub [b] ~limit:64));
  Cable_ring.unsubscribe hub a;
  Alcotest.(check int) "one remaining reader" 1
    (Cable_ring.broadcast hub ~stream:"room" ~payload:"again");
  Alcotest.(check (list (pair string string))) "second receives again" ["second","again"]
    (frames (Cable_ring.take_many hub [b] ~limit:64));
  Cable_ring.unsubscribe hub b;
  Alcotest.(check int) "ring released" 0 (Cable_ring.stream_count hub)

let interleaved_order () =
  let hub = Cable_ring.create () in
  let a = Cable_ring.subscribe hub ~stream:"a" ~identifier:"A" in
  let b = Cable_ring.subscribe hub ~stream:"b" ~identifier:"B" in
  ignore (Cable_ring.broadcast hub ~stream:"a" ~payload:"one");
  ignore (Cable_ring.broadcast hub ~stream:"b" ~payload:"two");
  ignore (Cable_ring.broadcast hub ~stream:"a" ~payload:"three");
  Alcotest.(check (list (pair string string))) "cross-stream order"
    ["A","one";"B","two";"A","three"]
    (frames (Cable_ring.take_many hub [a;b] ~limit:64));
  Cable_ring.unsubscribe hub a;
  Cable_ring.unsubscribe hub b

let () = Alcotest.run "M5 Cable ring" [
  "hub", [
    Alcotest.test_case "capacity is per broadcasting" `Quick per_stream_capacity;
    Alcotest.test_case "independent subscriber cursors" `Quick independent_cursors;
    Alcotest.test_case "cross-stream delivery order" `Quick interleaved_order;
  ]
]

open Campfire

let test_shared () =
  let directory = Filename.temp_file "campfire-login-limits-" "" in
  Sys.remove directory;
  Unix.mkdir directory 0o700;
  Unix.putenv "CAMPFIRE_RATE_LIMIT_DIR" directory;
  Fun.protect ~finally:(fun () ->
    Sys.readdir directory |> Array.iter (fun name ->
      Unix.unlink (Filename.concat directory name));
    Unix.rmdir directory;
    Unix.putenv "CAMPFIRE_RATE_LIMIT_DIR" "") (fun () ->
    let reader,writer = Unix.pipe () in
    let child = Unix.fork () in
    if child = 0 then (
      Unix.close reader;
      let rejected = ref 0 in
      for _ = 1 to 6 do
        if Session_rate_limit.hit ~now:1000. ~ip:"192.0.2.1" then incr rejected
      done;
      let data = Bytes.of_string (string_of_int !rejected) in
      ignore (Unix.write writer data 0 (Bytes.length data));
      Unix.close writer;
      exit 0);
    Unix.close writer;
    let rejected = ref 0 in
    for _ = 1 to 6 do
      if Session_rate_limit.hit ~now:1000. ~ip:"192.0.2.1" then incr rejected
    done;
    let data = Bytes.create 10 in
    let length = Unix.read reader data 0 10 in
    Unix.close reader;
    let _,status = Unix.waitpid [] child in
    Alcotest.(check bool) "child succeeded" true (status = Unix.WEXITED 0);
    let child_rejected = int_of_string (Bytes.sub_string data 0 length) in
    Alcotest.(check int) "ten total attempts across workers" 2
      (!rejected + child_rejected);
    Alcotest.(check bool) "same IP stays limited" true
      (Session_rate_limit.hit ~now:1000. ~ip:"192.0.2.1");
    Alcotest.(check bool) "different IP independent" false
      (Session_rate_limit.hit ~now:1000. ~ip:"192.0.2.2");
    Alcotest.(check bool) "window expires" false
      (Session_rate_limit.hit ~now:1181. ~ip:"192.0.2.1"))

let () = Alcotest.run "Session rate limit" [
  "workers", [Alcotest.test_case "shared login window" `Quick test_shared]
]

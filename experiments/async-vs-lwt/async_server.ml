open Async

let callback ~body:_ _socket request =
  let status, headers, body = Common.response (Uri.path (Cohttp.Request.uri request)) in
  Cohttp_async.Server.respond_string ~status ~headers body

let () =
  let port = Common.port () in
  don't_wait_for
    (Cohttp_async.Server.create ~on_handler_error:`Ignore
       (Tcp.Where_to_listen.of_port port) callback >>| fun _ -> ());
  ignore (Scheduler.go ())

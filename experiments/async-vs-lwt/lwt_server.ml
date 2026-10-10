let callback _connection request _request_body =
  let status, headers, body = Common.response (Uri.path (Cohttp.Request.uri request)) in
  Cohttp_lwt_unix.Server.respond_string ~status ~headers ~body ()

let () =
  let port = Common.port () in
  let server = Cohttp_lwt_unix.Server.make ~callback () in
  Lwt_main.run (Cohttp_lwt_unix.Server.create ~mode:(`TCP (`Port port)) server)

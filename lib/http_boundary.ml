(** A small Cohttp request boundary for exercising sessions and forgery policy.
    The full controller router belongs to the later HTTP milestone. *)

let reply ?(set_cookies=[]) ?location ~status ~content_type body =
  let headers = Cohttp.Header.init_with "content-type" content_type in
  let headers = match location with None -> headers
    | Some value -> Cohttp.Header.add headers "location" value in
  let headers = List.fold_left (fun headers value -> Cohttp.Header.add headers "set-cookie" value)
      headers set_cookies in
  let response = Cohttp.Response.make ~status:(Cohttp.Code.status_of_code status) ~headers () in
  Lwt.return (response, Cohttp_lwt.Body.of_string body)

let json ?set_cookies ~status value =
  reply ?set_cookies ~status ~content_type:"application/json; charset=utf-8"
    (Yojson.Basic.to_string value)

let method_name request = Cohttp.Code.string_of_method (Cohttp.Request.meth request)

let request_base_url ~ssl headers =
  let host = Option.value (Cohttp.Header.get headers "host") ~default:"localhost" in
  (if ssl then "https://" else "http://") ^ host

let now_time now = match Ptime.of_rfc3339 now with
  | Ok (value, _, _) -> value
  | Error _ -> invalid_arg "HTTP boundary now must be RFC 3339"

let handle ~db ~secret_key_base ~now ~remote_ip ~ssl ~force_ssl request _body =
  let headers = Cohttp.Request.headers request in
  let method_ = method_name request in
  let path = Uri.path (Request_uri.get request) in
  if path <> "/whoami" then
    reply ~status:404 ~content_type:"text/plain; charset=utf-8" "Not found"
  else
    let csrf_request = {
      Csrf.method_;
      origin = Cohttp.Header.get headers "origin";
      base_url = request_base_url ~ssl headers;
      sec_fetch_site = Cohttp.Header.get headers "sec-fetch-site";
      ssl; force_ssl; origin_check = true;
    } in
    match Csrf.verify_request csrf_request with
    | Error rejection ->
        reply ~status:rejection.status ~content_type:"text/html; charset=utf-8"
          "<h1>Unprocessable</h1>"
    | Ok marked_for_same_origin_verification ->
        let cookie_headers = Cohttp.Header.get_multi headers "cookie" in
        let jar = Cookie_http.create ~headers:cookie_headers ~now:(now_time now) in
        let user_agent = Cohttp.Header.get headers "user-agent" in
        match Authentication.restore_headers ~db ~secret_key_base ~now ~method_
          ~remote_ip ~user_agent ~cookie_headers with
        | Error _ -> json ~status:500 (`Assoc ["error", `String "Internal server error"])
        | Ok Authentication.Banned_ip ->
            reply ~status:429 ~content_type:"text/html" ""
        | Ok (Authentication.Unauthenticated _) ->
            reply ~status:302 ~content_type:"text/html"
              ~location:(request_base_url ~ssl headers ^ "/session/new") ""
        | Ok (Authentication.Authenticated authenticated) ->
            let content_type = "application/json; charset=utf-8" in
            let xhr = Cohttp.Header.get headers "x-requested-with" = Some "XMLHttpRequest" in
            (match Csrf.verify_response ~marked_for_same_origin_verification
               ~content_type:(Some content_type) ~xhr with
             | Error rejection ->
                 reply ~status:rejection.status ~content_type:"text/html; charset=utf-8"
                   "<h1>Unprocessable</h1>"
             | Ok () ->
                 Option.iter (fun raw ->
                   Cookie_http.set jar "session_token"
                     { (Cookie_http.cookie raw) with permanent = true; httponly = true })
                   authenticated.refreshed_token_cookie;
                 let host = Option.value (Cohttp.Header.get headers "host") ~default:"localhost" in
                 let set_cookies = Cookie_http.set_cookie_headers jar ~ssl ~host in
                 json ~set_cookies ~status:200 (`Assoc [
                   "id", `String (Int64.to_string authenticated.user.id);
                   "name", `String authenticated.user.name]))

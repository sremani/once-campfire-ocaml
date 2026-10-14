(** Cohttp request context and Rails route dispatch. Controller modules supply
    endpoint handlers; this layer owns decoding, cookies, session and policy. *)

open Lwt.Infix

type response = Cohttp.Response.t * Cohttp_lwt.Body.t
type access = Public | User | Guest_only | Bot_allowed
type authenticated_by = Nothing | Session | Bot_key
type private_cache_state = {
  store : Http_cache.Private.t;
  observer : Http_cache.Observer.t;
  auth_entries : (string list, Authentication.authenticated * Db_accounts.User.t) Hashtbl.t;
  mutable auth_generation : int64 option;
  auth_mutex : Mutex.t;
}

let create_private_cache ~capacity runtime =
  if capacity <= 0 then None else
  Option.map (fun observer ->
    {store=Http_cache.Private.create ~capacity;observer;
     auth_entries=Hashtbl.create 64;auth_generation=None;
     auth_mutex=Mutex.create ()})
    (Http_cache.Observer.open_db runtime.Db_runtime.path)
let close_private_cache cache = Http_cache.Observer.close cache.observer

type context = {
  request : Cohttp.Request.t;
  route : Routes.match_;
  body : string;
  raw_post : string;
  method_ : string;
  original_method : string;
  path : string;
  params : Http_params.t;
  query_params : Http_params.t;
  request_params : Http_params.t;
  path_params : Http_params.t;
  format : Http_format.t list;
  cookies : Cookie_http.t;
  runtime : Db_runtime.t;
  cable : Cable_channels.t option;
  event_sink : Db_remaining.Event.sink;
  private_cache : private_cache_state option;
  cache_generation : int64 option;
  mutable private_ticket : Http_cache.Private.ticket option;
  mutable private_hit : bool;
  mutable page_parts : Http_cache.Page_parts.part list option;
  secret_key_base : string;
  remote_ip : string;
  now : string;
  ssl : bool;
  force_ssl : bool;
  mutable auth : Authentication.outcome option;
  mutable current_user : Db_accounts.User.t option;
  mutable bot_user : Db_accounts.User.t option;
  mutable authenticated_by : authenticated_by;
  mutable response_headers : (string * string) list;
  mutable session_data : (string * Yojson.Basic.t) list option;
  mutable session_changed : bool;
  mutable flash_loaded : bool;
  mutable flash_initial : Yojson.Basic.t option;
  mutable flash_replaced : bool;
  mutable skip_cookie_commit : bool;
  upload_workers : unit Lwt.t list ref;
}

type handler = context -> response Lwt.t
type before_action = context -> (unit, response) result Lwt.t
type endpoint = { action : handler; before_action : before_action }
type dispatch = string -> endpoint option

let header ctx name = Cohttp.Header.get (Cohttp.Request.headers ctx.request) name
let param ctx name = Http_params.find name ctx.params
let param_string ctx name = Http_params.find_string name ctx.params
let set_header ctx name value =
  ctx.response_headers <- (name, value) :: List.remove_assoc name ctx.response_headers

(** Register a newly detached upload worker before awaiting it. The returned
    promise resists request cancellation; cleanup waits for every registered
    worker before unlinking request-owned upload files. *)
let track_upload_worker ctx worker =
  let protected = Lwt.no_cancel worker in
  let completed = Lwt.catch
    (fun () -> protected >|= fun _ -> ())
    (fun _ -> Lwt.return_unit) in
  ctx.upload_workers := completed :: !(ctx.upload_workers);
  protected

let respond ?(headers=[]) ~status ~content_type body =
  let headers = ("content-type", content_type) :: headers |> Cohttp.Header.of_list in
  Cohttp.Response.make ~status:(Cohttp.Code.status_of_code status) ~headers (),
  Cohttp_lwt.Body.of_string body

let html ?(headers=[]) ~status body =
  let stylesheet_tag = "<link rel=\"stylesheet\"" in
  let rec has_stylesheet at =
    at + String.length stylesheet_tag <= String.length body &&
    (String.sub body at (String.length stylesheet_tag) = stylesheet_tag ||
     has_stylesheet (at + 1)) in
  let headers = if String.starts_with ~prefix:"<!DOCTYPE html>" body &&
    has_stylesheet 0 && not (List.mem_assoc "link" headers) then
    ("link", snd (Assets.stylesheet_tags ())) :: headers else headers in
  respond ~headers ~status ~content_type:"text/html; charset=utf-8" body
let text ?headers ~status body =
  respond ?headers ~status ~content_type:"text/plain; charset=utf-8" body
let json ?headers ~status value =
  respond ?headers ~status ~content_type:"application/json; charset=utf-8"
    (Yojson.Basic.to_string value)
let redirect ?(status=302) path =
  respond ~headers:["location", path] ~status ~content_type:"text/html; charset=utf-8" ""
let error ~status =
  if status = 413 then
    Cohttp.Response.make ~status:`Request_entity_too_large (),
    Cohttp_lwt.Body.empty
  else if status = 404 || status = 500 then
    let body = Option.value (Assets.file (if status = 404 then "/404.html" else "/500.html")) ~default:"" in
    respond ~status ~content_type:"text/html; charset=UTF-8"
      ~headers:["x-campfire-public-exception", "1";
                "content-length", string_of_int (String.length body)] body
  else if status = 406 then
    respond ~status ~content_type:"text/html; charset=UTF-8"
      ~headers:["x-campfire-public-exception", "1"; "content-length", "0"] ""
  else
  let label = match status with
    | 400 -> "Bad Request" | 403 -> "Forbidden" | 404 -> "Not Found"
    | 406 -> "Not Acceptable" | 422 -> "Unprocessable Entity"
    | 429 -> "Too Many Requests" | _ -> "Internal Server Error" in
  html ~status ("<h1>" ^ (if status = 422 then "Unprocessable" else
    if status = 404 then "Not found" else label) ^ "</h1>")

let hex bytes =
  let b = Buffer.create (2 * String.length bytes) in
  String.iter (fun c -> Buffer.add_string b (Printf.sprintf "%02x" (Char.code c))) bytes;
  Buffer.contents b

let load_session ctx = match ctx.session_data with
  | Some data -> data
  | None ->
      let raw = match Cookie_http.get ctx.cookies "_campfire_session" with
        | None -> []
        | Some value ->
            (match Perf_probe.time "ctx_rails_cookie" (fun () ->
               Encrypted_cookie.decrypt ~secret_key_base:ctx.secret_key_base
                 ~name:"_campfire_session" ~raw:value ~now:ctx.now) with
             | Some (`Assoc data) -> data | _ -> []) in
      let data = if List.mem_assoc "session_id" raw then raw
        else ("session_id", `String (hex (Secure_random.bytes 16))) :: raw in
      ctx.session_data <- Some data; data

let session_get ctx key = List.assoc_opt key (load_session ctx)
let session_set ctx key value =
  if key = "flash" then ctx.flash_replaced <- true;
  let data = load_session ctx in
  if List.assoc_opt key data <> Some value then (
    let data = if List.mem_assoc key data then
      List.map (fun (k, old) -> k, if k = key then value else old) data
      else data @ [key, value] in
    ctx.session_data <- Some data; ctx.session_changed <- true)
let session_remove ctx key =
  let data = load_session ctx in
  if List.mem_assoc key data then (
    ctx.session_data <- Some (List.remove_assoc key data);
    ctx.session_changed <- true)
let reset_session ctx =
  ctx.session_data <- Some ["session_id", `String (hex (Secure_random.bytes 16))];
  ctx.session_changed <- true;
  ctx.flash_loaded <- false;
  ctx.flash_initial <- None;
  ctx.flash_replaced <- false

(* ActionDispatch::Flash marks values loaded from the session for discard at
   request completion. A newly assigned flash stays for the next request. *)
let flash ctx =
  if not ctx.flash_loaded then (
    ctx.flash_initial <- session_get ctx "flash";
    ctx.flash_loaded <- true);
  let current = if ctx.flash_replaced then session_get ctx "flash"
    else ctx.flash_initial in
  match current with
  | Some (`Assoc fields) ->
      let discarded = match List.assoc_opt "discard" fields with
        | Some (`List values) -> List.filter_map (function `String s -> Some s | _ -> None) values
        | _ -> [] in
      (match List.assoc_opt "flashes" fields with
       | Some (`Assoc flashes) ->
           List.filter (fun (key, _) -> not (List.mem key discarded)) flashes
       | _ -> [])
  | _ -> []

let base_url ctx =
  let host = Option.value (header ctx "host") ~default:"localhost" in
  (if ctx.ssl then "https://" else "http://") ^ host

let private_lookup ctx =
  match ctx.private_cache,ctx.cache_generation,ctx.auth with
  | Some cache,Some generation,Some (Authentication.Authenticated identity)
      when ctx.authenticated_by=Session &&
        Http_cache.Private.eligible_request
          ~endpoint:ctx.route.endpoint ~original_method:ctx.original_method
          ~raw_post:ctx.raw_post ctx.request ->
      if flash ctx <> [] then (Perf_probe.bump "private_flash"; None) else
      (match Perf_probe.time "cache_version_check" (fun () ->
         Http_cache.Observer.version cache.observer) with
       | Some current when current=generation ->
           (match Http_cache.Private.key ~generation
               ~endpoint:ctx.route.endpoint ~user_id:identity.user.id
               ~session_id:identity.session.id ~origin:(base_url ctx)
               ctx.request with
            | None -> None
            | Some ticket ->
                (match Http_cache.Private.lookup cache.store
                    ~now:(Unix.gettimeofday ()) ~generation:current ticket with
                 | Some item ->
                     Perf_probe.bump "private_hit";
                     ctx.private_hit<-true;
                     let response=Cohttp.Response.make
                       ~status:(Cohttp.Code.status_of_code item.status)
                       ~headers:item.headers () in
                     Some (response,Cohttp_lwt.Body.of_string item.body)
                 | None ->
                     Perf_probe.bump "private_miss";
                     ctx.private_ticket<-Some ticket; None))
       | _ -> Perf_probe.bump "private_generation_changed"; None)
  | Some _,Some _,Some (Authentication.Authenticated _) ->
      Perf_probe.bump "private_ineligible"; None
  | _ -> Perf_probe.bump "private_unavailable"; None

let csrf_check ctx =
  let request = {
    Csrf.method_ = ctx.method_;
    origin = header ctx "origin";
    base_url = base_url ctx;
    sec_fetch_site = header ctx "sec-fetch-site";
    ssl = ctx.ssl; force_ssl = ctx.force_ssl; origin_check = true;
  } in
  match Csrf.verify_request request with
  | Ok _ -> Ok ()
  | Error rejection -> ctx.skip_cookie_commit <- true; Error (error ~status:rejection.status)

let readonly_auth_enabled = Sys.getenv_opt "CAMPFIRE_AUTH_READ" <> Some "0"
let joined_user_enabled = Sys.getenv_opt "CAMPFIRE_JOINED_USER" <> Some "0"
let auth_cache_enabled = Sys.getenv_opt "CAMPFIRE_AUTH_CACHE" <> Some "0"

let restore_auth ctx =
  let cookie_headers = Cohttp.Header.get_multi (Cohttp.Request.headers ctx.request) "cookie" in
  let user_agent = header ctx "user-agent" in
  let safe = ctx.method_ = "GET" || ctx.method_ = "HEAD" in
  let cache_slot = match ctx.private_cache, ctx.cache_generation with
    | Some cache, Some generation
        when safe && readonly_auth_enabled && auth_cache_enabled ->
        (match Http_cache.Observer.version cache.observer with
         | Some current when current = generation -> Some (cache,generation)
         | _ -> None)
    | _ -> None in
  let cache_get () = match cache_slot with
    | None -> None
    | Some (cache,generation) ->
        Mutex.lock cache.auth_mutex;
        Fun.protect ~finally:(fun () -> Mutex.unlock cache.auth_mutex) (fun () ->
          if cache.auth_generation <> Some generation then (
            Hashtbl.clear cache.auth_entries;
            cache.auth_generation <- Some generation);
          match Hashtbl.find_opt cache.auth_entries cookie_headers with
          | Some (identity,user) when not (Authentication.needs_refresh
              ~now:ctx.now identity.session) ->
              (match Authentication.cookie cookie_headers "session_token" with
               | Some raw ->
                   (match Signed_cookie.verify ~secret_key_base:ctx.secret_key_base
                       ~name:"session_token" ~raw ~now:ctx.now with
                    | Some token when Eqaf.equal token identity.session.token ->
                        let rails_session = Authentication.read_rails_session_headers
                          ~secret_key_base:ctx.secret_key_base ~now:ctx.now
                          cookie_headers in
                        Some ({identity with rails_session},user)
                    | _ -> None)
               | None -> None)
          | _ -> None) in
  let cache_put identity user = match cache_slot with
    | None -> ()
    | Some (cache,generation) ->
        if Http_cache.Observer.version cache.observer = Some generation then (
          Mutex.lock cache.auth_mutex;
          Fun.protect ~finally:(fun () -> Mutex.unlock cache.auth_mutex) (fun () ->
            if cache.auth_generation <> Some generation then (
              Hashtbl.clear cache.auth_entries;
              cache.auth_generation <- Some generation);
            if Hashtbl.length cache.auth_entries >= 256 then
              Hashtbl.clear cache.auth_entries;
            Hashtbl.replace cache.auth_entries cookie_headers (identity,user))) in
  let finish ~load_user = function
  | Error _ -> Lwt.return (Error (error ~status:500))
  | Ok (Authentication.Authenticated identity as outcome) ->
      ctx.auth <- Some outcome;
      ctx.authenticated_by <- Session;
      Option.iter (fun raw ->
        Cookie_http.set ctx.cookies "session_token"
          { (Cookie_http.cookie raw) with permanent = true; httponly = true })
        identity.refreshed_token_cookie;
      load_user identity.user.id
      >|= (function
        | Some user -> ctx.current_user <- Some user; Ok ()
        | None -> Error (error ~status:500))
  | Ok (Authentication.Unauthenticated _ as outcome) ->
      ctx.auth <- Some outcome; Lwt.return (Ok ())
  | Ok Authentication.Banned_ip ->
      ctx.auth <- Some Authentication.Banned_ip;
      ctx.skip_cookie_commit <- true;
      Lwt.return (Error (respond ~status:429 ~content_type:"text/html" "")) in
  let restore_on_writer () =
    Db_runtime.write_async ctx.runtime (fun tx ->
      Authentication.restore_headers ~db:(Db_runtime.conn tx)
        ~secret_key_base:ctx.secret_key_base ~now:ctx.now ~method_:ctx.method_
        ~remote_ip:ctx.remote_ip ~user_agent ~cookie_headers)
    >>= finish ~load_user:(fun user_id ->
      Db_runtime.read_async ctx.runtime (fun db ->
        Db_accounts.User.find_by_id db user_id)) in
  match cache_get () with
  | Some (identity,user) ->
      Perf_probe.bump "auth_cache_hit";
      finish ~load_user:(fun _ -> Lwt.return_some user)
        (Ok (Authentication.Authenticated identity))
  | None when not readonly_auth_enabled -> restore_on_writer ()
  | None ->
    Perf_probe.bump "auth_cache_miss";
    Db_runtime.read_async ctx.runtime (fun db ->
      let result = Authentication.restore_headers_readonly ~db
        ~secret_key_base:ctx.secret_key_base ~now:ctx.now ~method_:ctx.method_
        ~remote_ip:ctx.remote_ip ~user_agent ~cookie_headers in
      let user = match result with
        | Ok (Authentication.Ready (Authentication.Authenticated identity)) ->
            if joined_user_enabled then
              Some (Db_accounts.User.of_authenticated identity)
            else Perf_probe.time "auth_user_sql" (fun () ->
              Db_accounts.User.find_by_id db identity.user.id)
        | _ -> None in
      result,user) >>= function
    | Ok Authentication.Refresh_due, _ -> restore_on_writer ()
    | Ok (Authentication.Ready (Authentication.Authenticated identity as outcome)),
      Some user ->
        cache_put identity user;
        finish ~load_user:(fun _ -> Lwt.return_some user) (Ok outcome)
    | Ok (Authentication.Ready outcome), user ->
        finish ~load_user:(fun _ -> Lwt.return user) (Ok outcome)
    | Error error, _ ->
        finish ~load_user:(fun _ -> Lwt.return_none) (Error error)

let reject_banned_ip ctx =
  if ctx.method_ = "GET" || ctx.method_ = "HEAD" then Lwt.return (Ok ())
  else Db_runtime.read_async ctx.runtime (fun db -> Db_remaining.Ban.banned db ctx.remote_ip)
    >|= fun banned ->
      if banned then (
        ctx.skip_cookie_commit <- true;
        Error (respond ~status:429 ~content_type:"text/html" ""))
      else Ok ()

(* Auth restoration checks bans for unsafe methods in the same reader job as
   the session lookup. Public endpoints do not restore auth, so they still
   need their own ban lookup. The opt-in old path supports bracketed profiles. *)
let ban_preflight ctx access =
  if access = Public || Sys.getenv_opt "CAMPFIRE_BAN_PREFLIGHT" = Some "1"
  then reject_banned_ip ctx
  else Lwt.return (Ok ())

let restore_bot_key ctx =
  match Http_params.find "bot_key" ctx.params with
  | None | Some Http_params.Nil | Some (Http_params.Text "") -> Lwt.return (Ok ())
  | Some (Http_params.Text key) ->
      let key = String.trim key in
      Db_runtime.read_async ctx.runtime (fun db -> Db_accounts.User.authenticate_bot db key)
      >|= fun bot ->
        ctx.bot_user <- bot;
        if Option.is_some bot then (
          ctx.current_user <- bot;
          ctx.authenticated_by <- Bot_key);
        Ok ()
  | Some _ -> Lwt.return (Error (error ~status:500))

let allow_browser ctx =
  match header ctx "user-agent" with
  | None -> Lwt.return (Ok ())
  | Some raw when Unicode_lower.blank raw -> Lwt.return (Ok ())
  | Some raw ->
      let platform=User_agent.application_platform (Some raw) in
      if not (User_agent.browser_blocked platform) then Lwt.return (Ok ())
      else
        Db_runtime.read_async ctx.runtime Db_accounts.Account.first >|= fun account ->
        let endpoint=ctx.route.Routes.endpoint in
        let own_layout=String.starts_with ~prefix:"messages#" endpoint ||
          String.starts_with ~prefix:"messages/by_bots#" endpoint in
        let frame=not own_layout && Option.is_some (header ctx "turbo-frame") in
        let body=Views_browser.render ~frame ~account ~view:(User_agent.to_view platform) () in
        Error (html ~status:200 body)

let before ?(access=User) ?(csrf=true) () ctx =
  let version = match Sys.getenv_opt "APP_VERSION", Sys.getenv_opt "GIT_REVISION" with
    | Some version, _ -> version
    | None, Some revision -> revision
    | None, None -> "0" in
  set_header ctx "x-version" version;
  Option.iter (set_header ctx "x-rev") (Sys.getenv_opt "GIT_REVISION");
  ban_preflight ctx access >>= function
  | Error _ as rejection -> Lwt.return rejection
  | Ok () ->
  let auth_needed = access <> Public in
  (if auth_needed then restore_auth ctx else Lwt.return (Ok ())) >>= function
  | Error _ as rejection -> Lwt.return rejection
  | Ok () ->
      (if (access = User || access = Bot_allowed) && ctx.authenticated_by = Nothing then restore_bot_key ctx
       else Lwt.return (Ok ())) >>= function
      | Error _ as rejection -> Lwt.return rejection
      | Ok () ->
      let denied_bot = access <> Bot_allowed &&
        (match ctx.current_user with
         | Some user -> Db_accounts.User.is_bot user
         | None -> false) in
      let access_result = match access, ctx.auth with
        | Public, _ -> Ok ()
        | Guest_only, Some (Authentication.Authenticated _) -> Ok ()
        | Guest_only, _ -> Ok ()
        | _ when denied_bot -> Error (respond ~status:403 ~content_type:"text/html" "")
        | (User | Bot_allowed), Some (Authentication.Authenticated _) -> Ok ()
        | Bot_allowed, _ when ctx.authenticated_by = Bot_key -> Ok ()
        | _ ->
            let uri = Request_uri.get ctx.request in
            let path = match Uri.path uri with "" -> "/" | path -> path in
            let path = match Uri.verbatim_query uri with
              | None -> path | Some query -> path ^ "?" ^ query in
            let url = base_url ctx ^ path in
            session_set ctx "return_to_after_authenticating" (`String url);
            Error (redirect (base_url ctx ^ "/session/new")) in
      (match access_result with
       | Error _ as rejection -> Lwt.return rejection
       | Ok () ->
           let csrf_result = if csrf && ctx.authenticated_by <> Bot_key then csrf_check ctx
             else Ok () in
           match csrf_result with
           | Error _ as rejection -> Lwt.return rejection
           | Ok () -> allow_browser ctx >|= function
             | Error _ as rejection -> rejection
             | Ok () when access=Guest_only &&
                 (match ctx.auth with Some (Authentication.Authenticated _) -> true | _ -> false) ->
                 Error (redirect (base_url ctx ^ "/"))
             | Ok () -> Ok ())

let default_before_action = before ()

let commit ctx (response, body) =
  if Cohttp.Header.mem (Cohttp.Response.headers response)
       "x-campfire-public-exception" then response, body
  else (
    if ctx.flash_loaded && not ctx.flash_replaced &&
       Option.is_some (session_get ctx "flash") then session_remove ctx "flash";
    if not ctx.skip_cookie_commit && ctx.session_changed then (
      let data = Option.value ctx.session_data ~default:[]
        |> List.filter (fun (_, value) -> value <> `Null) in
      if List.for_all (fun (key, _) -> key = "session_id") data then
        Cookie_http.delete ctx.cookies "_campfire_session"
      else
        ignore (Cookie_http.set_encrypted ctx.cookies
          ~secret_key_base:ctx.secret_key_base "_campfire_session" (`Assoc data)
          { (Cookie_http.cookie "") with permanent = true; httponly = true }));
    let cookies = if ctx.skip_cookie_commit then [] else
      let host = Option.value (header ctx "host") ~default:"localhost" in
      Cookie_http.set_cookie_headers ctx.cookies ~ssl:ctx.ssl ~host in
    let headers = Cohttp.Response.headers response in
    let rendered_with_accept =
      (match Cohttp.Header.get headers "content-type" with
       | Some content_type ->
           String.starts_with ~prefix:"text/html" content_type ||
           String.starts_with ~prefix:"text/vnd.turbo-stream.html" content_type
       | None -> false) &&
      (match body with `String text -> text <> "" | `Strings parts -> parts <> []
        | _ -> false) in
    let headers = if rendered_with_accept && not (Cohttp.Header.mem headers "vary") &&
        Http_format.should_apply_vary_header
          ?format_param:(param_string ctx "format")
          ?accept:(header ctx "accept")
          ?content_type:(header ctx "content-type")
          ~xhr:(header ctx "x-requested-with" = Some "XMLHttpRequest") ()
      then Cohttp.Header.add headers "vary" "Accept" else headers in
    let headers = List.fold_left (fun headers (name, value) ->
      if Cohttp.Header.mem headers name then headers else Cohttp.Header.add headers name value)
      headers ctx.response_headers in
    let headers = List.fold_left (fun headers value -> Cohttp.Header.add headers "set-cookie" value)
      headers cookies in
    let headers = List.fold_left (fun headers (name,value) ->
      if Cohttp.Header.mem headers name then headers else Cohttp.Header.add headers name value)
      headers ["x-frame-options","SAMEORIGIN";
               "x-xss-protection","0";
               "x-content-type-options","nosniff";
               "x-permitted-cross-domain-policies","none";
               "referrer-policy","strict-origin-when-cross-origin"] in
    { response with headers }, body)

let body_params ~method_ content_type body =
  match Routes.media_type content_type with
  | None when method_ = "POST" -> Http_params.parse_form body
  | Some "application/x-www-form-urlencoded" -> Http_params.parse_form body
  | Some "application/json" | Some "text/x-json" |
    Some "application/jsonrequest" | Some "application/problem+json" ->
      if body = "" then Ok [] else Http_params.parse_json body
  | Some "multipart/form-data" | Some "multipart/related" | Some "multipart/mixed" ->
      let content_type = Option.value content_type ~default:"" in
      if Http_params.content_type_parameter content_type "boundary" = None then
        Http_params.parse_form body
      else Error Http_params.Parse (* Multipart requests use the streaming path below. *)
  | _ -> Ok []

let read_body_bounded ~limit body =
  if body = `Empty then Lwt.return (Ok "") else
  let stream = Cohttp_lwt.Body.to_stream body in
  let buffer = Buffer.create (min limit 8192) in
  let rec read size =
    Lwt_stream.get stream >>= function
    | None -> Lwt.return (Ok (Buffer.contents buffer))
    | Some chunk ->
        let size = size + String.length chunk in
        if size > limit then Lwt.return (Error ())
        else (Buffer.add_string buffer chunk; read size)
  in read 0

let parse_request_body ?(on_error=(fun (_:Http_params.error) -> ()))
    ~content_type ~raw_method ?max_body_bytes body =
  let multipart = match Routes.media_type content_type with
    | Some ("multipart/form-data" | "multipart/related" | "multipart/mixed") ->
        (match Option.bind content_type (fun value ->
           Http_params.content_type_parameter value "boundary") with
         | Some boundary when boundary <> "" -> true | _ -> false)
    | _ -> false in
  if multipart then
    let default_limit = Int64.mul 10L (Int64.mul 1024L (Int64.mul 1024L 1024L)) in
    let limit = match max_body_bytes with
      | None -> default_limit
      | Some value -> Int64.min default_limit (Int64.of_int value) in
    Http_params.parse_multipart_stream
      ~content_type:(Option.value content_type ~default:"") ~limit
      (Cohttp_lwt.Body.to_stream body) >|= (function
      | Ok (params, paths) -> Ok ("", params, paths)
      | Error Http_params.Too_large -> Error 413
      | Error reason -> on_error reason; Error 400)
  else
    let default_limit = 16 * 1024 * 1024 in
    let limit = Option.fold ~none:default_limit ~some:(min default_limit) max_body_bytes in
    read_body_bounded ~limit body >|= function
    | Error () -> Error 413
    | Ok body ->
        (match body_params ~method_:raw_method content_type body with
         | Ok params -> Ok (body, params, [])
         | Error Http_params.Too_large -> Error 413
         | Error reason -> on_error reason; Error 400)

let now_utc () =
  let now = Option.get (Ptime.of_float_s (Unix.gettimeofday ())) in
  Authentication.utc_rfc3339 ~frac_s:6 now

(* The pinned Rust table maps these declared actions to ActionNotFound.  They
   bypass controller response finalization and render PublicExceptions. *)
let action_not_found = function
  | "first_runs#new" | "first_runs#edit" | "first_runs#update" |
    "first_runs#destroy" | "sessions#edit" | "sessions#show" |
    "sessions#update" | "accounts/users#create" | "accounts/users#new" |
    "accounts/users#edit" | "accounts/users#show" | "accounts/bots#show" |
    "accounts#new" | "accounts#show" | "accounts#destroy" |
    "accounts#create" | "users/profiles#new" | "users/profiles#edit" |
    "users/profiles#destroy" | "users/profiles#create" |
    "users/push_subscriptions#new" | "users/push_subscriptions#edit" |
    "users/push_subscriptions#show" | "users/push_subscriptions#update" |
    "messages#new" | "rooms#create" | "rooms#new" | "rooms#edit" |
    "rooms#update" | "rooms/directs#update" | "messages/boosts#edit" |
    "messages/boosts#show" | "messages/boosts#update" -> true
  | _ -> false

let handle_uncompressed ~runtime ~secret_key_base ?cable ?private_cache
    ?(capture_context=(fun _ -> ()))
    ?(event_sink=(fun _ -> ())) ?(now=now_utc ()) ?(remote_ip="127.0.0.1")
    ?(ssl=false) ?(force_ssl=false) ?(action_not_found_pages=false)
    ?max_body_bytes ~dispatch request body =
  let headers = Cohttp.Request.headers request in
  let content_type = Cohttp.Header.get headers "content-type" in
  let uri = Request_uri.get request in
  let path = Uri.path uri in
  (* Uri.of_string repairs malformed percent escapes. Rails parses the raw
     request target and rejects them, so retain Cohttp's unmodified resource. *)
  let resource = Cohttp.Request.resource request in
  let query = match String.index_opt resource '?' with
    | None -> ""
    | Some i -> String.sub resource (i + 1) (String.length resource - i - 1) in
  let raw_method = Cohttp.Code.string_of_method (Cohttp.Request.meth request) in
  let uploaded_paths = ref [] in
  let upload_workers = ref [] in
  Lwt.finalize (fun () ->
    Perf_probe.time_lwt "body_parse" (fun () ->
      parse_request_body ~on_error:Http_request_log.rejected
        ~content_type ~raw_method ?max_body_bytes body) >>= function
    | Error status -> Lwt.return (error ~status)
    | Ok (body, request_params, paths) ->
        uploaded_paths := paths;
        match Http_params.parse_query query with
        | Error reason ->
            Http_request_log.rejected reason;
            Lwt.return (respond ~status:400 ~content_type:"text/html; charset=UTF-8"
              ~headers:["x-campfire-public-exception", "1"; "content-length", "0"] "")
        | Ok query_params ->
      let form_method = if Routes.form_data_media_type content_type then
        Http_params.find_string "_method" request_params else None in
      let header_method = Cohttp.Header.get headers "x-http-method-override" in
      let selected = Routes.effective_method ?content_type ?form_method ?header_method raw_method in
      let route = Routes.lookup_catalog selected.effective_method path in
      match route with
      | None -> Lwt.return (error ~status:404)
      | Some { Routes.endpoint = "rooms/settings#show"; _ } ->
          Lwt.return (error ~status:500)
      | Some route when action_not_found_pages && action_not_found route.endpoint ->
          Lwt.return (error ~status:404)
      | Some route ->
          (match dispatch route.endpoint with
           | None -> Lwt.return (error ~status:404)
           | Some endpoint ->
               let path_params = List.map (fun (key, value) -> key, Http_params.Text value) route.params in
               let path_params = match String.index_opt route.endpoint '#' with
                 | None -> path_params
                 | Some at ->
                     let controller = String.sub route.endpoint 0 at in
                     let action = String.sub route.endpoint (at + 1)
                       (String.length route.endpoint - at - 1) in
                     Http_params.set "action" (Http_params.Text action)
                       (Http_params.set "controller" (Http_params.Text controller) path_params) in
               let params = Http_params.merge (Http_params.merge request_params query_params) path_params in
               let now_time = Authentication.now_time now in
               let cookies = Cookie_http.create ~headers:(Cohttp.Header.get_multi headers "cookie") ~now:now_time in
               let xhr = Cohttp.Header.get headers "x-requested-with" = Some "XMLHttpRequest" in
               let format = Http_format.parse_formats
                 ?format_param:(Http_params.find_string "format" params)
                 ?accept:(Cohttp.Header.get headers "accept") ?content_type ~path ~xhr () in
               match format with
               | Error _ -> Lwt.return (error ~status:406)
               | Ok format ->
               let ctx = {
                 request; route; body; raw_post = body;
                 method_ = selected.effective_method; original_method = raw_method; path;
                 params; query_params; request_params; path_params; format; cookies; runtime;
                 cable; event_sink; private_cache;
                 cache_generation=Option.bind private_cache (fun cache ->
                   Perf_probe.time "cache_version_initial" (fun () ->
                     Http_cache.Observer.version cache.observer));
                 private_ticket=None;private_hit=false;page_parts=None;
                 secret_key_base; remote_ip; now; ssl; force_ssl; auth = None;
                 current_user = None;
                 bot_user = None; authenticated_by = Nothing;
                 response_headers = []; session_data = None; session_changed = false;
                 flash_loaded = false; flash_initial = None; flash_replaced = false;
                 skip_cookie_commit = false;
                 upload_workers;
               } in
               capture_context ctx;
               Lwt.catch (fun () ->
                 Perf_probe.time_lwt ("before:" ^ route.endpoint)
                   (fun () -> endpoint.before_action ctx) >>= function
                 | Error response -> Lwt.return (Perf_probe.time "commit" (fun () -> commit ctx response))
                 | Ok () -> Perf_probe.time_lwt ("action:" ^ route.endpoint)
                     (fun () -> endpoint.action ctx) >|= fun response ->
                       Perf_probe.time "commit" (fun () -> commit ctx response))
                 (fun cause ->
                   Http_request_log.failed ~path cause;
                   Lwt.return (error ~status:500))))
    (fun () ->
      Lwt.no_cancel (Lwt.join !upload_workers) >>= fun () ->
      Http_params.cleanup_uploads !uploaded_paths;
      Lwt.return_unit)

let static_response request =
  let headers = Cohttp.Request.headers request in
  let optional name = Cohttp.Header.get headers name in
  let method_ = Cohttp.Code.string_of_method (Cohttp.Request.meth request) in
  let path = Uri.path (Request_uri.get request) in
  match Assets.serve ~method_ ~path ?accept_encoding:(optional "accept-encoding")
      ?range:(optional "range") ?if_modified_since:(optional "if-modified-since") () with
  | None -> None
  | Some served ->
      let headers = Cohttp.Header.of_list served.Assets.headers in
      let response = Cohttp.Response.make
        ~status:(Cohttp.Code.status_of_code served.status) ~headers () in
      Some (response, Cohttp_lwt.Body.of_string served.body)

let response_header name value (response, body) =
  let headers = Cohttp.Header.replace (Cohttp.Response.headers response) name value in
  {response with headers}, body

let static_recheck = Sys.getenv_opt "CAMPFIRE_STATIC_RECHECK" = Some "1"
let static_path_filter = Sys.getenv_opt "CAMPFIRE_STATIC_PATH_FILTER" <> Some "0"
let front_private_fast = Sys.getenv_opt "CAMPFIRE_FRONT_PRIVATE_FAST" <> Some "0"

let known_dynamic_path path =
  path = "/up" || path = "/searches" ||
  path = "/users/me/sidebar" ||
  String.starts_with ~prefix:"/rooms/" path

let https_redirect ~trusted_front request =
  let headers = Cohttp.Request.headers request in
  let host = Option.value ~default:"localhost"
    (if trusted_front then Cohttp.Header.get headers "x-forwarded-host"
     else Cohttp.Header.get headers "host") in
  let host = String.split_on_char ',' host |> List.rev |> List.hd |> String.trim in
  let host = match String.rindex_opt host ':' with
    | Some colon when String.length host > colon + 1 &&
      String.for_all (function '0'..'9' -> true | _ -> false)
        (String.sub host (colon + 1) (String.length host - colon - 1)) ->
        String.sub host 0 colon
    | _ -> host in
  let uri = Request_uri.get request in
  let path = match Uri.path uri with "" -> "/" | path -> path in
  let path = match Uri.verbatim_query uri with None -> path
    | Some query -> path ^ "?" ^ query in
  let code = match Cohttp.Request.meth request with
    | `GET | `HEAD -> 301 | _ -> 308 in
  let headers = Cohttp.Header.of_list ["content-type","text/html";
    "location","https://" ^ host ^ path] in
  Cohttp.Response.make ~status:(Cohttp.Code.status_of_code code) ~headers (),
    Cohttp_lwt.Body.empty

let handle ~runtime ~secret_key_base ?cable ?event_sink ?front_cache
    ?private_cache ?now ?remote_ip
    ?(ssl=false) ?(force_ssl=false) ?(action_not_found_pages=false)
    ?max_body_bytes ~dispatch request body =
  let started = Unix.gettimeofday () in
  let declared_too_large = match max_body_bytes,
    Cohttp.Header.get (Cohttp.Request.headers request) "content-length" with
    | Some max,Some value ->
        (match Int64.of_string_opt value with
         | Some n -> n > Int64.of_int max
         | None -> false)
    | _ -> false in
  if declared_too_large then Lwt.return (error ~status:413) else
  let public_exception = ref false in
  let is_static = ref false in
  let run () =
    let context = ref None in
    let static = Perf_probe.time "static_lookup" (fun () ->
      if static_path_filter && known_dynamic_path
        (Uri.path (Request_uri.get request)) then None
      else static_response request) in
    is_static := Option.is_some static;
    let response = match static with
      | Some response -> Lwt.return response
      | None -> Perf_probe.time_lwt "app_route" (fun () ->
          handle_uncompressed ~runtime ~secret_key_base ?cable
            ?private_cache ~capture_context:(fun ctx -> context:=Some ctx) ?event_sink
            ?now ?remote_ip ~ssl ~force_ssl
            ~action_not_found_pages ?max_body_bytes ~dispatch request body) in
    response >>= fun response ->
    public_exception := Cohttp.Header.mem (Cohttp.Response.headers (fst response))
      "x-campfire-public-exception";
    let digestible = match snd response with `Stream _ -> false | _ -> true in
    Perf_probe.time_lwt "cache_finish" (fun () ->
      if Option.is_some static then Lwt.return response
      else Http_cache.finish ~digestible ~request response) >>= fun response ->
    Perf_probe.time_lwt "gzip_apply" (fun () -> match !context with
     | Some ctx when ctx.private_hit -> Lwt.return response
     | Some ctx -> Http_gzip.apply ?parts:ctx.page_parts request response
     | None -> Http_gzip.apply request response) >>= fun (response,body) ->
    (match !context with
     | Some ctx when not ctx.private_hit &&
         Cohttp.Request.meth request=`GET &&
         Cohttp.Response.status response=`OK ->
         (match ctx.private_ticket,ctx.private_cache,body with
          | Some _,Some _,`Stream _ -> Lwt.return (response,body)
          | Some ticket,Some cache,body ->
              if not (Http_cache.Private.cacheable_headers
                (Cohttp.Response.headers response)) then
                Lwt.return (response,body)
              else Cohttp_lwt.Body.length body >>= fun (length,body) ->
              if length>Int64.of_int Http_cache.Private.max_body then
                Lwt.return (response,body)
              else Cohttp_lwt.Body.to_string body >|= fun bytes ->
                let length=Int64.of_int (String.length bytes) in
                let headers=Cohttp.Header.replace
                  (Cohttp.Response.headers response) "content-length"
                  (Int64.to_string length) in
                let response={response with headers;
                  encoding=Cohttp.Transfer.Fixed length} in
                (match Http_cache.Observer.version cache.observer with
                 | Some generation ->
                     let stored = Http_cache.Private.store cache.store
                       ~now:(Unix.gettimeofday ()) ~generation ticket
                       ~status:200 ~headers ~body:bytes in
                     Perf_probe.bump (if stored then "private_store" else "private_store_rejected")
                 | None -> ());
                response,Cohttp_lwt.Body.of_string bytes
          | _ -> Lwt.return (response,body))
     | _ -> Lwt.return (response,body)) in
  let result = match front_cache with
  | None -> run ()
  | Some cache ->
      let now = Unix.gettimeofday () in
      let generation = 0L in
      if not (Http_cache.Front.request_allowed request) then
        run () >|= response_header "x-cache" "bypass"
      else match Perf_probe.time "front_find" (fun () ->
        if front_private_fast && known_dynamic_path
          (Uri.path (Request_uri.get request)) then None
        else Http_cache.Front.find cache ~now ~generation request) with
        | Some item ->
            is_static := item.static;
            let not_modified = Http_cache.Front.was_not_modified request item in
            let status = if not_modified then 304 else item.status in
            let headers = Cohttp.Header.replace item.headers "x-cache" "hit" in
            let headers = if not_modified then
              headers |> fun h -> Cohttp.Header.remove h "content-type"
              |> fun h -> Cohttp.Header.remove h "content-length"
              else headers in
            let response = Cohttp.Response.make
              ~status:(Cohttp.Code.status_of_code status) ~headers () in
            let body = if not_modified then "" else item.body in
            Lwt.return (response, Cohttp_lwt.Body.of_string body)
        | None -> run () >>= fun (response, body) ->
            let status = Cohttp.Code.code_of_status (Cohttp.Response.status response) in
            let headers = Cohttp.Response.headers response in
            let cacheable = Option.is_some (Http_cache.Front.lifetime status headers) in
            let headers = if cacheable then Cohttp.Header.remove headers "set-cookie"
              else headers in
            let headers = Cohttp.Header.replace headers "x-cache" "miss" in
            let response = {response with headers} in
            (if cacheable then
               let declared = Option.bind
                 (Cohttp.Header.get headers "content-length") Int64.of_string_opt in
               (* A send_file response is streamed even when it has a known,
                  bounded length. Record those bytes for the public cache as
                  the Rust front does. Leave unknown and large streams alone. *)
               let was_stream = match body with `Stream _ -> true | _ -> false in
               let recordable = match body with
                 | `Stream _ -> (match declared with
                     | Some length -> length >= 0L &&
                         length <= Int64.of_int cache.max_item_size
                     | None -> false)
                 | _ -> true in
               if not recordable then Lwt.return body
               else Cohttp_lwt.Body.length body >>= fun (length, body) ->
                 if length > Int64.of_int cache.max_item_size ||
                    (was_stream && Some length <> declared)
                 then Lwt.return body
                 else Cohttp_lwt.Body.to_string body >|= fun bytes ->
                   ignore (Http_cache.Front.store cache ~now ~generation
                     ~static:!is_static request
                     ~status ~headers ~body:bytes);
                   Cohttp_lwt.Body.of_string bytes
             else Lwt.return body) >|= fun body -> response, body in
  Perf_probe.time_lwt "front_result" (fun () -> result) >>= fun (response,body) ->
  Perf_probe.time_lwt "response_finalize" (fun () ->
    let response,body = if Cohttp.Code.code_of_status
      (Cohttp.Response.status response) = 413 then error ~status:413
      else response,body in
    let path = Uri.path (Request_uri.get request) in
    let status = Cohttp.Code.code_of_status (Cohttp.Response.status response) in
    let headers = Cohttp.Response.headers response in
    (* PublicExceptions sets Content-Length: 0 itself. Rack::Deflater leaves
       those responses untouched, including Vary. The internal marker was
       removed by Http_cache.finish, so retain this one bit across finishing. *)
    let empty_public_exception = !public_exception &&
      Cohttp.Header.get headers "content-length" = Some "0" in
    let headers = if not empty_public_exception && Option.is_some front_cache &&
       not (Http_cache.Front.request_allowed request) &&
       Cohttp.Header.mem headers "vary" then
      (* The front writes its own Vary field before the app's fields on a
         bypassed request. Their order is observable on the wire. *)
      let application_vary = Cohttp.Header.get_multi headers "vary" in
      let headers = Cohttp.Header.remove headers "vary"
        |> fun h -> Cohttp.Header.add h "vary" "Accept-Encoding" in
      List.fold_left (fun h value -> Cohttp.Header.add h "vary" value)
        headers application_vary
    else headers in
    (* Thruster's front compression adds one Vary even when Rack::Deflater
       skipped an empty PublicExceptions response. *)
    let headers = if Cohttp.Header.mem headers "vary" then headers
      else Cohttp.Header.add headers "vary" "Accept-Encoding" in
    let storage_redirect = status = 302 && String.starts_with
      ~prefix:"/rails/active_storage/blobs/" path in
    let headers = if (status = 200 || storage_redirect) &&
       not (Cohttp.Header.mem headers "date") &&
       (storage_redirect ||
        (Option.value (Cohttp.Header.get headers "cache-control") ~default:""
         |> fun value -> String.split_on_char ',' value
            |> List.exists (fun part -> String.trim part = "public"))) then
      Cohttp.Header.add headers "date"
        (Storage_file_server.httpdate (Unix.gettimeofday ()))
    else headers in
    let headers = if path = "/up" ||
       List.mem path ["/recede_historical_location"; "/resume_historical_location";
                      "/refresh_historical_location"] || status = 406 then
      headers |> fun h -> Cohttp.Header.remove h "x-version"
      |> fun h -> Cohttp.Header.remove h "x-rev"
    else headers in
    let headers = if path = "/account/logo" ||
       (String.starts_with ~prefix:"/users/" path && String.ends_with ~suffix:"/avatar" path) ||
       status = 406 then
      List.fold_left Cohttp.Header.remove headers
        ["x-frame-options"; "x-xss-protection"; "x-content-type-options";
         "x-permitted-cross-domain-policies"; "referrer-policy"]
    else headers in
    let headers = if status = 200 &&
       (path = "/account/logo" || String.starts_with ~prefix:"/rails/active_storage/blobs/proxy/" path) &&
       not (Cohttp.Header.mem headers "content-transfer-encoding") then
      Cohttp.Header.add headers "content-transfer-encoding" "binary"
    else headers in
    let response = { response with headers } in
    let was_static = if static_recheck then Option.is_some (static_response request)
      else !is_static in
    let response,body = if was_static then response,body else
      let incoming = Cohttp.Header.get (Cohttp.Request.headers request) "x-request-id" in
      let request_id = match incoming with
        | Some id when String.trim id <> "" ->
            String.to_seq id |> List.of_seq
            |> List.filter (function
                 | 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' | '-' | '@' -> true
                 | _ -> false)
            |> List.to_seq |> String.of_seq
            |> fun id -> String.sub id 0 (min 255 (String.length id))
        | _ ->
            let id = hex (Secure_random.bytes 16) in
            String.sub id 0 8 ^ "-" ^ String.sub id 8 4 ^ "-" ^
            String.sub id 12 4 ^ "-" ^ String.sub id 16 4 ^ "-" ^
            String.sub id 20 12 in
      let response,body = response_header "x-request-id" request_id (response,body) in
      if Cohttp.Header.mem (Cohttp.Response.headers response) "x-runtime" then response,body
      else response_header "x-runtime"
        (Printf.sprintf "%.6f" (max 0. (Unix.gettimeofday () -. started)))
        (response,body) in
    let response,body = if force_ssl && ssl then response_header "strict-transport-security"
      "max-age=63072000; includeSubDomains" (response,body)
    else response,body in
    let status = Cohttp.Code.code_of_status (Cohttp.Response.status response) in
    let headers = Cohttp.Response.headers response in
    if Cohttp.Header.mem headers "content-length" ||
       Cohttp.Header.mem headers "transfer-encoding" ||
       Cohttp.Header.get headers "content-encoding" = Some "gzip" ||
       status = 204 || status = 304 then Lwt.return (response,body)
    else match body with
      | `Stream _ -> Lwt.return (response,body)
      | _ ->
          Cohttp_lwt.Body.length body >|= fun (length,body) ->
          let headers = Cohttp.Header.replace
            (Cohttp.Response.headers response) "content-length" (Int64.to_string length) in
          (* Cohttp.Response carries framing separately from its headers.
             Updating only the header leaves a Chunked writer that sends its
             chunk prefix as apparent body bytes to a fixed-length proxy. *)
          { response with headers; encoding = Cohttp.Transfer.Fixed length }, body)

let serve ?(port=3000) ?(bind_ip="127.0.0.1") ?front_config ?stop ?track_request ?cable_run ?cable_config ?cable ?event_sink
    ?front_cache ?private_cache
    ~runtime ~secret_key_base ?(ssl=false)
    ?(force_ssl=false) ?(action_not_found_pages=false)
    ?max_body_bytes ~dispatch () =
  let cable_config = Option.value cable_config
    ~default:{ Cable_transport.default_config with assume_ssl=ssl } in
  let front_cache = Option.value front_cache ~default:(Http_cache.Front.create
    ~capacity:(64 * 1024 * 1024) ~max_item_size:(1024 * 1024)) in
  let owned_private_cache = match private_cache with
    | Some cache -> Some cache
    | None ->
        let mb=Option.bind (Sys.getenv_opt "CAMPFIRE_RESPONSE_CACHE_MB") int_of_string_opt
          |> Option.value ~default:64 |> max 0 |> min 1024 in
        create_private_cache ~capacity:(mb * 1024 * 1024) runtime in
  let target_limits = Option.value front_config
    ~default:(Front_config.from_env ()) in
  let callback (flow, _) request body =
    let peer = match flow with
      | Conduit_lwt_unix.TCP tcp -> Ipaddr.to_string tcp.ip
      | _ -> "127.0.0.1" in
    let request,remote_ip,ssl,trusted_front = match front_config with
      | None -> request,peer,ssl,false
      | Some config ->
          let request,remote_ip,front_ssl = Front_proxy.prepare ~config ~peer request in
          request,remote_ip,Option.value front_ssl ~default:ssl,
            Option.is_some front_ssl in
    let cable_config = { cable_config with Cable_transport.assume_ssl=ssl } in
    let cable_too_large =
      match max_body_bytes,
        Cohttp.Header.get (Cohttp.Request.headers request) "content-length" with
      | Some max,Some value ->
          (match Int64.of_string_opt value with
           | Some n -> n > Int64.of_int max
           | None -> false)
      | _ -> false in
    let respond () = if force_ssl && not ssl then
      Lwt.return (`Response (https_redirect ~trusted_front request))
    else if cable_too_large then
      Lwt.return (`Response (error ~status:413))
    else match cable_run with
    | Some run when Uri.path (Request_uri.get request) = "/cable" ->
        Cable_transport.handle ~config:cable_config request ~run:(run request)
    | _ ->
        handle ~runtime ~secret_key_base ?cable ?event_sink
          ~front_cache ?private_cache:owned_private_cache ~remote_ip ~ssl ~force_ssl
          ~action_not_found_pages ?max_body_bytes ~dispatch request body
        >|= fun response -> `Response response in
    match track_request with None -> respond () | Some track -> track respond in
  let socket = Lwt_unix.socket
    (if String.contains bind_ip ':' then Unix.PF_INET6 else Unix.PF_INET)
    Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt socket Unix.SO_REUSEADDR true;
  if Sys.getenv_opt "CAMPFIRE_REUSEPORT" = Some "1" then
    Lwt_unix.setsockopt socket Unix.SO_REUSEPORT true;
  Lwt.finalize
    (fun () ->
      Lwt_unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_of_string bind_ip,port))
      >>= fun () ->
      Lwt_unix.listen socket 128;
      Front_target.serve ?stop ~socket
        ~read_timeout:target_limits.http_read_timeout
        ~write_timeout:target_limits.http_write_timeout
        ~idle_timeout:target_limits.http_idle_timeout
        ~callback ())
    (fun () ->
      Lwt.catch (fun () -> Lwt_unix.close socket) (fun _ -> Lwt.return_unit)
      >>= fun () ->
      (match private_cache with None -> Option.iter close_private_cache owned_private_cache
       | Some _ -> ());
      Lwt.return_unit)

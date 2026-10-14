(** Authentication against the existing Rails sessions table.

    The signed token and encrypted CookieStore payloads are separate cookies.  The
    token identifies a database row; the CookieStore payload carries Rails session
    state such as flash and return URLs and is never accepted as authentication. *)

type user_status = Active | Deactivated | Banned

type user = { id : int64; name : string; status : user_status }

type user_details = {
  email_address : string option;
  password_digest : string option;
  role : int;
  bio : string option;
  bot_token : string option;
  created_at : string;
  updated_at : string;
}

type session = {
  id : int64;
  user_id : int64;
  token : string;
  ip_address : string option;
  user_agent : string option;
  last_active_at : string;
}

type authenticated = {
  user : user;
  user_details : user_details;
  session : session;
  rails_session : Yojson.Basic.t option;
  (** A fresh raw signed value is issued when activity is refreshed. *)
  refreshed_token_cookie : string option;
}

type rejection = Missing_cookie | Invalid_cookie | Revoked_session | Inactive_user
type outcome = Authenticated of authenticated | Unauthenticated of rejection | Banned_ip

let cookie headers name = Cookie_http.find name (Cookie_http.parse_headers headers)

let parse_time value =
  let value = String.trim value in
  let len = String.length value in
  let value =
    if len >= 19 && value.[10] = ' ' then
      String.sub value 0 10 ^ "T" ^ String.sub value 11 (len - 11) ^ "Z"
    else value in
  match Ptime.of_rfc3339 value with Ok (time, _, _) -> Some time | Error _ -> None

let utc_rfc3339 ~frac_s time =
  let value = Ptime.to_rfc3339 ~frac_s ~tz_offset_s:0 time in
  let len = String.length value in
  if len >= 6 && (String.sub value (len - 6) 6 = "-00:00" ||
                 String.sub value (len - 6) 6 = "+00:00")
  then String.sub value 0 (len - 6) ^ "Z"
  else value

let sql_time now =
  let value = utc_rfc3339 ~frac_s:6 now in
  String.sub value 0 10 ^ " " ^ String.sub value 11 (String.length value - 12)

let now_time now = match parse_time now with
  | Some time -> time
  | None -> invalid_arg "Authentication: now must be an RFC 3339 timestamp"

let permanent_expiry ~now =
  let time = now_time now in
  let value = utc_rfc3339 ~frac_s:3 time in
  let year = int_of_string (String.sub value 0 4) + 20 in
  let month = int_of_string (String.sub value 5 2) in
  let day = int_of_string (String.sub value 8 2) in
  let day = if month = 2 && day = 29 &&
    (year mod 4 <> 0 || (year mod 100 = 0 && year mod 400 <> 0)) then 28 else day in
  Printf.sprintf "%04d-%02d-%02d%s" year month day (String.sub value 10 (String.length value - 10))

let issue_token_cookie ~secret_key_base ~now token =
  Signed_cookie.generate ~secret_key_base ~name:"session_token" ~value:token
    ~expires_at:(Some (permanent_expiry ~now))

let read_rails_session_headers ~secret_key_base ~now headers =
  Option.bind (cookie headers "_campfire_session") (fun raw ->
    match Encrypted_cookie.decrypt ~secret_key_base ~name:"_campfire_session" ~raw ~now with
    | Some (`Assoc _ as data) -> Some data
    | _ -> None)

let read_rails_session ~secret_key_base ~now header =
  read_rails_session_headers ~secret_key_base ~now [header]

let issue_rails_session ~secret_key_base ~now data =
  match data with
  | `Assoc _ ->
      Encrypted_cookie.encrypt ~secret_key_base ~name:"_campfire_session" ~value:data
        ~expires_at:(Some (permanent_expiry ~now))
  | _ -> invalid_arg "Authentication: Rails session data must be a JSON object"

let column_option stmt n = match Sqlite3.column stmt n with
  | Sqlite3.Data.NULL -> None
  | _ -> Some (Sqlite3.column_text stmt n)

let with_statement db query f =
  if Db_runtime.auth_statement_cache_enabled then
    Db_runtime.with_cached_statement db query f
  else
    let stmt = Sqlite3.prepare db query in
    Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () -> f stmt)

let check_rc context = function
  | Sqlite3.Rc.OK -> ()
  | rc -> failwith (context ^ ": " ^ Sqlite3.Rc.to_string rc)

let bind_text stmt n value = check_rc "bind" (Sqlite3.bind stmt n (Sqlite3.Data.TEXT value))
let bind_int64 stmt n value = check_rc "bind" (Sqlite3.bind stmt n (Sqlite3.Data.INT value))

let banned_ip db ip =
  Perf_probe.time "auth_ban_sql" (fun () ->
  with_statement db "SELECT 1 FROM bans WHERE ip_address = ? LIMIT 1" (fun stmt ->
    bind_text stmt 1 ip;
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW -> true
    | Sqlite3.Rc.DONE -> false
    | rc -> failwith ("ban lookup: " ^ Sqlite3.Rc.to_string rc)))

let find_session db token =
  Perf_probe.time "auth_session_sql" (fun () ->
  with_statement db
    "SELECT s.id,s.user_id,s.token,s.ip_address,s.user_agent,s.last_active_at,u.id,u.name,u.status,u.email_address,u.password_digest,u.role,u.bio,u.bot_token,u.created_at,u.updated_at FROM sessions s LEFT JOIN users u ON u.id=s.user_id WHERE s.token=? LIMIT 1"
    (fun stmt ->
      bind_text stmt 1 token;
      match Sqlite3.step stmt with
      | Sqlite3.Rc.DONE -> None
      | Sqlite3.Rc.ROW ->
          let session = {
            id = Sqlite3.column_int64 stmt 0;
            user_id = Sqlite3.column_int64 stmt 1;
            token = Sqlite3.column_text stmt 2;
            ip_address = column_option stmt 3;
            user_agent = column_option stmt 4;
            last_active_at = Sqlite3.column_text stmt 5;
          } in
          let user = match Sqlite3.column stmt 6 with
            | Sqlite3.Data.NULL -> None
            | _ ->
                let status = match Sqlite3.column_int stmt 8 with
                  | 0 -> Active | 1 -> Deactivated | 2 -> Banned
                  | n -> failwith ("unknown user status " ^ string_of_int n) in
                let user = { id = Sqlite3.column_int64 stmt 6;
                             name = Sqlite3.column_text stmt 7; status } in
                let details = {
                  email_address = column_option stmt 9;
                  password_digest = column_option stmt 10;
                  role = Sqlite3.column_int stmt 11;
                  bio = column_option stmt 12;
                  bot_token = column_option stmt 13;
                  created_at = Sqlite3.column_text stmt 14;
                  updated_at = Sqlite3.column_text stmt 15;
                } in
                Some (user, details) in
          Some (session, user)
      | rc -> failwith ("session lookup: " ^ Sqlite3.Rc.to_string rc)))

let needs_refresh ~now session =
  match parse_time session.last_active_at with
  | None -> failwith "invalid sessions.last_active_at"
  | Some last ->
      match Ptime.diff (now_time now) last |> Ptime.Span.to_float_s with
      | seconds -> seconds > 3600.

let refresh db ~now ~ip_address ~user_agent session =
  (* Active Record omits the fractional suffix when a timestamp lands exactly
     on a second.  The app clock is frozen at whole seconds in parity seeds. *)
  let last_active_at = sql_time (now_time now) in
  let last_active_at = if String.ends_with ~suffix:".000000" last_active_at then
    String.sub last_active_at 0 (String.length last_active_at - 7)
    else last_active_at in
  with_statement db
    "UPDATE sessions SET ip_address=?,last_active_at=?,updated_at=?,user_agent=? WHERE id=?"
    (fun stmt ->
      let bind_optional n = function
        | None -> check_rc "bind" (Sqlite3.bind stmt n Sqlite3.Data.NULL)
        | Some value -> bind_text stmt n value in
      bind_optional 1 ip_address;
      bind_text stmt 2 last_active_at;
      bind_text stmt 3 last_active_at;
      bind_optional 4 user_agent;
      bind_int64 stmt 5 session.id;
      match Sqlite3.step stmt with
      | Sqlite3.Rc.DONE -> { session with ip_address; user_agent; last_active_at }
      | rc -> failwith ("session refresh: " ^ Sqlite3.Rc.to_string rc))

let is_safe_method = function "GET" | "HEAD" -> true | _ -> false

type read_result = Ready of outcome | Refresh_due

(** A reader can restore fresh sessions for every HTTP method. Unsafe methods
    also check the IP ban on that reader. An hourly refresh retries on the
    writer, preserving the existing cookie and activity update semantics. *)
let restore_headers_step ~may_refresh ~db ~secret_key_base ~now ~method_
    ~remote_ip ~user_agent ~cookie_headers =
  try
    if not (is_safe_method method_) && banned_ip db remote_ip then Ok (Ready Banned_ip)
    else match cookie cookie_headers "session_token" with
      | None -> Ok (Ready (Unauthenticated Missing_cookie))
      | Some raw ->
          match Perf_probe.time "auth_signed_cookie" (fun () ->
            Signed_cookie.verify ~secret_key_base ~name:"session_token" ~raw ~now) with
          | None -> Ok (Ready (Unauthenticated Invalid_cookie))
          | Some token ->
              match find_session db token with
              | None -> Ok (Ready (Unauthenticated Revoked_session))
              | Some (_, None) -> Ok (Ready (Unauthenticated Revoked_session))
              | Some (_, Some ({status = (Deactivated | Banned); _}, _)) ->
                  Ok (Ready (Unauthenticated Inactive_user))
              | Some (session, Some (user, user_details)) ->
                  let refresh_due = needs_refresh ~now session in
                  if refresh_due && not may_refresh then Ok Refresh_due else
                  let session = if refresh_due then
                    refresh db ~now ~ip_address:(Some remote_ip) ~user_agent session
                    else session in
                  let refreshed_token_cookie = if refresh_due then
                    Some (issue_token_cookie ~secret_key_base ~now token) else None in
                  let rails_session = Perf_probe.time "auth_rails_cookie" (fun () ->
                    read_rails_session_headers ~secret_key_base ~now cookie_headers) in
                  Ok (Ready (Authenticated
                    {user; user_details; session; rails_session; refreshed_token_cookie}))
  with
  | Sqlite3.SqliteError error | Failure error -> Error error

(** Restores the signed database session. [db] must be writable only if an hourly
    refresh is due. SQL errors are returned and never treated as failed auth. *)
let restore_headers ~db ~secret_key_base ~now ~method_ ~remote_ip ~user_agent ~cookie_headers =
  match restore_headers_step ~may_refresh:true ~db ~secret_key_base ~now
      ~method_ ~remote_ip ~user_agent ~cookie_headers with
  | Ok (Ready outcome) -> Ok outcome
  | Ok Refresh_due -> assert false
  | Error error -> Error error

let restore_headers_readonly ~db ~secret_key_base ~now ~method_ ~remote_ip
    ~user_agent ~cookie_headers =
  restore_headers_step ~may_refresh:false ~db ~secret_key_base ~now
    ~method_ ~remote_ip ~user_agent ~cookie_headers

let restore ~db ~secret_key_base ~now ~method_ ~remote_ip ~user_agent ~cookie_header =
  restore_headers ~db ~secret_key_base ~now ~method_ ~remote_ip ~user_agent
    ~cookie_headers:[cookie_header]

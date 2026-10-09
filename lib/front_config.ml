(** Thruster-compatible front settings. The protocol boundary is Caddy 2; the
    application keeps its existing public cache and gzip implementation. *)

type t = {
  target_port : int;
  target_bind : string;
  http_port : int;
  https_port : int;
  tls_domains : string list;
  acme_directory : string;
  eab_kid : string;
  eab_hmac_key : string;
  storage_path : string;
  max_request_body : int;
  cache_size : int;
  max_cache_item_size : int;
  gzip_compression_enabled : bool;
  gzip_compression_disable_on_auth : bool;
  gzip_compression_jitter : int;
  http_idle_timeout : int;
  http_read_timeout : int;
  http_write_timeout : int;
  h2c_enabled : bool;
  forward_headers : bool;
  debug : bool;
  log_requests : bool;
}

let tls_enabled c = c.tls_domains <> []

let parse_bool = function
  | "1" | "t" | "T" | "TRUE" | "true" | "True" -> Some true
  | "0" | "f" | "F" | "FALSE" | "false" | "False" -> Some false
  | _ -> None

let from_lookup get =
  let find key = match get ("THRUSTER_" ^ key) with
    | Some _ as value -> value
    | None -> get key in
  let string key default = Option.value (find key) ~default in
  let integer key default = match find key with
    | None -> default
    | Some raw -> (match int_of_string_opt raw with Some n -> n | None -> default) in
  let port key default =
    let value = integer key default in
    if value >= 0 && value <= 65535 then value else default in
  let seconds key default = max 0 (integer key default) in
  let boolean key default =
    Option.bind (find key) parse_bool |> Option.value ~default in
  let tls_domains =
    string "TLS_DOMAIN" "" |> String.split_on_char ','
    |> List.map String.trim |> List.filter ((<>) "") in
  let target_bind =
    let value = string "TARGET_BIND" "127.0.0.1" in
    match Ipaddr.of_string value with Ok _ -> value | Error _ -> "127.0.0.1" in
  {
    target_port = port "TARGET_PORT" 3000;
    target_bind;
    http_port = port "HTTP_PORT" 80;
    https_port = port "HTTPS_PORT" 443;
    tls_domains;
    acme_directory = string "ACME_DIRECTORY" "https://acme-v02.api.letsencrypt.org/directory";
    eab_kid = string "EAB_KID" "";
    eab_hmac_key = string "EAB_HMAC_KEY" "";
    storage_path = string "STORAGE_PATH" "./storage/thruster";
    max_request_body = integer "MAX_REQUEST_BODY" 0;
    cache_size = integer "CACHE_SIZE" (64 * 1024 * 1024);
    max_cache_item_size = integer "MAX_CACHE_ITEM_SIZE" (1024 * 1024);
    gzip_compression_enabled = boolean "GZIP_COMPRESSION_ENABLED" true;
    gzip_compression_disable_on_auth = boolean "GZIP_COMPRESSION_DISABLE_ON_AUTH" false;
    gzip_compression_jitter = integer "GZIP_COMPRESSION_JITTER" 32;
    http_idle_timeout = seconds "HTTP_IDLE_TIMEOUT" 60;
    http_read_timeout = seconds "HTTP_READ_TIMEOUT" 30;
    http_write_timeout = seconds "HTTP_WRITE_TIMEOUT" 30;
    h2c_enabled = boolean "H2C_ENABLED" false;
    forward_headers = boolean "FORWARD_HEADERS" (tls_domains = []);
    debug = boolean "DEBUG" false;
    log_requests = boolean "LOG_REQUESTS" true;
  }

let from_env () = from_lookup Sys.getenv_opt

let address port = Printf.sprintf ":%d" port

let quote s =
  (* Caddyfile quoted tokens use Go-style escapes. Reject line breaks to avoid
     turning environment values into directives. *)
  if String.contains s '\n' || String.contains s '\r' then
    invalid_arg "Front_config: newline in configuration value";
  let escaped = Buffer.create (String.length s) in
  String.iter (function
    | ('"' | '\\') as c -> Buffer.add_char escaped '\\'; Buffer.add_char escaped c
    | c -> Buffer.add_char escaped c) s;
  "\"" ^ Buffer.contents escaped ^ "\""

let domain s =
  let s = String.lowercase_ascii s in
  let labels = String.split_on_char '.' s in
  let valid_label label =
    let length = String.length label in
    length > 0 && length <= 63 &&
    label.[0] <> '-' && label.[length - 1] <> '-' &&
    String.for_all (function
      | 'a'..'z' | '0'..'9' | '-' -> true
      | _ -> false) label in
  if String.length s > 253 || not (List.for_all valid_label labels) then
    invalid_arg ("Front_config: invalid TLS_DOMAIN " ^ quote s);
  s

let acme_issuer_key c =
  let uri = Uri.of_string c.acme_directory in
  let host = Option.value (Uri.host uri) ~default:"" in
  if Uri.scheme uri <> Some "https" || host = "" then
    invalid_arg "Front_config: ACME_DIRECTORY must be an HTTPS URL";
  let authority = host ^ (match Uri.port uri with
    | Some port -> "-" ^ string_of_int port | None -> "") in
  let path = Uri.path uri |> String.split_on_char '/' |> List.filter ((<>) "")
    |> String.concat "-" in
  let key = authority ^ (if path = "" then "" else "-" ^ path) in
  if not (String.for_all (function
      | 'a'..'z' | 'A'..'Z' | '0'..'9' | '.' | '-' | '_' -> true
      | _ -> false) key) then
    invalid_arg "Front_config: invalid ACME_DIRECTORY issuer key";
  key

let reverse_proxy c =
  let target = if String.contains c.target_bind ':' then
    Printf.sprintf "[%s]:%d" c.target_bind c.target_port
    else Printf.sprintf "%s:%d" c.target_bind c.target_port in
  let forwarding = if c.forward_headers then
    "header_up X-Campfire-Original-Forwarded-For {http.request.header.X-Forwarded-For}\n" ^
    "    header_up X-Campfire-Original-Forwarded-Host {http.request.header.X-Forwarded-Host}\n" ^
    "    header_up X-Campfire-Original-Forwarded-Proto {http.request.header.X-Forwarded-Proto}\n"
    else "" in
  (* Go's proxy transport otherwise adds Accept-Encoding: gzip when the client
     sent none, then transparently decodes the upstream body and drops its
     Content-Length. The app already negotiates gzip, so pass the request's
     encoding through unchanged. *)
  Printf.sprintf "reverse_proxy %s {\n    header_up -Forwarded\n    header_up X-Forwarded-For {remote_host}\n    header_up X-Forwarded-Host {host}\n    header_up X-Forwarded-Proto {scheme}\n    header_up X-Campfire-Front caddy\n    transport http {\n      compression off\n    }\n    %s  }"
    target forwarding

let caddyfile c =
  if c.target_port = c.http_port ||
     (tls_enabled c && c.target_port = c.https_port) then
    invalid_arg "Front_config: target and front ports must differ";
  let protocols = if tls_enabled c then "    protocols h1 h2\n"
    else if c.h2c_enabled then "    protocols h1 h2c\n"
    else "    protocols h1\n" in
  (* Go's HTTP reader admits roughly 4 KiB above MaxHeaderBytes for parser
     slack. Set the Caddy value lower so a 65 KiB field is rejected at the
     front before the 64 KiB target closes the upstream connection. *)
  let global = Printf.sprintf
    "{\n  admin off\n  http_port %d\n  https_port %d\n  storage file_system %s\n  auto_https disable_redirects\n  servers {\n    max_header_size 60KiB\n%s    timeouts {\n      read_header %ds\n      read_body %ds\n      write %ds\n      idle %ds\n    }\n  }\n}\n\n"
    c.http_port c.https_port (quote (Filename.concat c.storage_path "caddy"))
    protocols c.http_read_timeout c.http_read_timeout c.http_write_timeout c.http_idle_timeout in
  let proxy = reverse_proxy c in
  if not (tls_enabled c) then
    (* No encode directive: Http_gzip has already negotiated content coding. *)
    global ^ Printf.sprintf "http://%s {\n  %s\n}\n"
      (address c.http_port) proxy
  else
    let normalized = List.map domain c.tls_domains in
    let domains = List.map (fun d -> "https://" ^ d ^ address c.https_port) normalized in
    let domains = String.concat ", " domains in
    let redirects =
      List.mapi (fun i domain ->
        Printf.sprintf "  @allowed%d host %s\n  handle @allowed%d {\n    redir https://%s{uri} permanent\n  }\n"
          i (quote domain) i domain) normalized |> String.concat "" in
    let tls =
      "tls {\n    ca " ^ quote c.acme_directory ^ "\n" ^
      (if c.eab_kid <> "" && c.eab_hmac_key <> "" then
         "    eab " ^ quote c.eab_kid ^ " " ^ quote c.eab_hmac_key ^ "\n"
       else "") ^ "  }" in
    global ^ Printf.sprintf
      "http://%s {\n%s  respond \"Misdirected Request\" 421\n}\n\n%s {\n  %s\n  %s\n}\n"
      (address c.http_port) redirects domains tls proxy

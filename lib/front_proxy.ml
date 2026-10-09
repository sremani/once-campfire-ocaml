(** The single trusted boundary between Caddy and the Cohttp application. *)

let loopback ip =
  match Ipaddr.of_string ip with
  | Ok (Ipaddr.V4 ip) -> String.starts_with ~prefix:"127." (Ipaddr.V4.to_string ip)
  | Ok (Ipaddr.V6 ip) -> Ipaddr.V6.to_string ip = "::1"
  | Error _ -> false

let valid_ip raw =
  let raw = String.trim raw in
  match Ipaddr.of_string raw with
  | Ok ip -> Some (Ipaddr.to_string ip)
  | Error _ -> None

let first_ip raw =
  String.split_on_char ',' raw |> List.find_map valid_ip

let prepare ~config ~peer request =
  let headers = Cohttp.Request.headers request in
  let header name = Cohttp.Header.get headers name in
  let from_front = loopback peer && header "x-campfire-front" = Some "caddy" in
  if not from_front then request, peer, None else
  let original name = if config.Front_config.forward_headers then
    Option.bind (header ("x-campfire-original-forwarded-" ^ name))
      (fun value -> if String.trim value = "" then None else Some value)
    else None in
  let remote_ip = match Option.bind (original "for") first_ip with
    | Some ip -> ip
    | None -> Option.bind (header "x-forwarded-for") first_ip
        |> Option.value ~default:peer in
  (* Caddy's {host} placeholder drops a nonstandard port. Its upstream Host
     header keeps the full authority, which Rails uses for origin checks. *)
  let host = Option.value (original "host")
    ~default:(Option.value (header "host") ~default:"") in
  let proto = Option.value (original "proto")
    ~default:(Option.value (header "x-forwarded-proto") ~default:"http") in
  let ssl = String.lowercase_ascii (String.trim proto) = "https" in
  let headers = List.fold_left Cohttp.Header.remove headers
    ["forwarded"; "x-campfire-front"; "x-campfire-original-forwarded-for";
     "x-campfire-original-forwarded-host"; "x-campfire-original-forwarded-proto"] in
  let headers = Cohttp.Header.replace headers "x-forwarded-for" remote_ip in
  let headers = Cohttp.Header.replace headers "x-forwarded-proto"
    (if ssl then "https" else "http") in
  let headers = if host = "" then headers else
    Cohttp.Header.replace
      (Cohttp.Header.replace headers "host" host) "x-forwarded-host" host in
  let headers = if Cohttp.Header.get headers "x-request-start" = None then
    Cohttp.Header.replace headers "x-request-start"
      (Printf.sprintf "t=%.0f" (Unix.gettimeofday () *. 1000.)) else headers in
  { request with headers }, remote_ip, Some ssl

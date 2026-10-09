(** Surfguard's default address policy. Names are resolved once and the returned
    address is subsequently pinned by [Outbound_http]. *)

type error = Violation of string | Unresolvable
type resolver = string -> (Ipaddr.t list, string) result

let v4_ranges = List.map Ipaddr.V4.Prefix.of_string_exn [
  "0.0.0.0/8"; "10.0.0.0/8"; "100.64.0.0/10"; "127.0.0.0/8";
  "168.63.129.16/32"; "169.254.0.0/16"; "172.16.0.0/12";
  "192.0.0.0/24"; "192.0.2.0/24"; "192.88.99.0/24";
  "192.168.0.0/16"; "198.18.0.0/15"; "198.51.100.0/24";
  "203.0.113.0/24"; "224.0.0.0/4"; "240.0.0.0/4"]

let v6_ranges = List.map Ipaddr.V6.Prefix.of_string_exn [
  "::/128"; "100::/64"; "100:0:0:1::/64"; "2001::/32";
  "2001:2::/48"; "2001:db8::/32"; "2002::/16"; "3fff::/20";
  "5f00::/16"; "fec0::/10"; "ff00::/8"]

let allocated_v6 = List.map Ipaddr.V6.Prefix.of_string_exn [
  "2001::/23"; "2001:200::/23"; "2001:400::/23"; "2001:600::/23";
  "2001:800::/22"; "2001:c00::/23"; "2001:e00::/23";
  "2001:1200::/23"; "2001:1400::/22"; "2001:1800::/23";
  "2001:1a00::/23"; "2001:1c00::/22"; "2001:2000::/19";
  "2001:4000::/23"; "2001:4200::/23"; "2001:4400::/23";
  "2001:4600::/23"; "2001:4800::/23"; "2001:4a00::/23";
  "2001:4c00::/23"; "2001:5000::/20"; "2001:8000::/19";
  "2001:a000::/20"; "2001:b000::/20"; "2002::/16";
  "2003::/18"; "2400::/12"; "2410::/12"; "2600::/12";
  "2610::/23"; "2620::/23"; "2630::/12"; "2800::/12";
  "2a00::/12"; "2a10::/12"; "2c00::/12"]

let v6_prefix = Ipaddr.V6.Prefix.of_string_exn
let in_v6 ip prefix = Ipaddr.V6.Prefix.mem ip (v6_prefix prefix)
let any_v6 ip prefixes = List.exists (Ipaddr.V6.Prefix.mem ip) prefixes
let blocked_v4 ip = List.exists (Ipaddr.V4.Prefix.mem ip) v4_ranges

let embedded_v4 ip =
  let octets = Ipaddr.V6.to_octets ip in
  Ipaddr.V4.of_octets_exn (String.sub octets 12 4)

let blocked_address = function
  | Ipaddr.V4 ip -> blocked_v4 ip
  | Ipaddr.V6 ip ->
    if in_v6 ip "::ffff:0:0/96" || in_v6 ip "::/96" ||
       in_v6 ip "64:ff9b:1::/48" then true
    else if in_v6 ip "64:ff9b::/96" || in_v6 ip "::ffff:0:0:0/96"
    then blocked_v4 (embedded_v4 ip)
    else if in_v6 ip "2001:3::/32" || in_v6 ip "2001:4:112::/48"
    then false
    else if in_v6 ip "fc00::/7" || in_v6 ip "fe80::/10" ||
            in_v6 ip "2001::/23" || any_v6 ip v6_ranges
    then true
    else not (any_v6 ip allocated_v6)

let ascii_host host =
  let n = String.length host in
  n > 0 && n <= 255 &&
  String.for_all (fun c -> Char.code c < 128 && c <> '\000' && c <> '%') host

let is_digit c = c >= '0' && c <= '9'
let is_hex c = is_digit c || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
let legacy_ipv4_shape host =
  let parts = String.split_on_char '.' host |> List.filter ((<>) "") in
  List.length parts >= 1 && List.length parts <= 4 &&
  List.for_all (fun part ->
    let n = String.length part in
    if n = 0 then false
    else if n >= 2 && part.[0] = '0' && (part.[1] = 'x' || part.[1] = 'X')
    then n > 2 && String.for_all is_hex (String.sub part 2 (n-2))
    else String.for_all is_digit part) parts

let valid_dns_name host =
  let host = if String.ends_with ~suffix:"." host then
    String.sub host 0 (String.length host-1) else host in
  String.split_on_char '.' host |> List.for_all (fun label ->
    let n = String.length label in
    n > 0 && n <= 63 &&
    let alnum c = is_digit c || (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') in
    alnum label.[0] && alnum label.[n-1] &&
    String.for_all (fun c -> alnum c || c = '-') label)

let inet_aton host =
  let parts = String.split_on_char '.' host in
  let len = List.length parts in
  if len < 1 || len > 4 then None else
  let parse part =
    if part = "" then None else
    let n = String.length part in
    let base, digits =
      if n >= 2 && part.[0]='0' && (part.[1]='x' || part.[1]='X')
      then 16, String.sub part 2 (n-2)
      else if n > 1 && part.[0]='0' then 8, String.sub part 1 (n-1)
      else 10, part in
    if digits = "" && base = 16 then None else
    let digits = if digits="" then "0" else digits in
    try
      let x = String.fold_left (fun acc c ->
        let v = if is_digit c then Char.code c - 48
          else if c >= 'a' && c <= 'f' then Char.code c - 87
          else if c >= 'A' && c <= 'F' then Char.code c - 55
          else raise Exit in
        if v >= base then raise Exit;
        let next = Int64.add (Int64.mul acc (Int64.of_int base)) (Int64.of_int v) in
        if next > 0xffff_ffffL then raise Exit; next) 0L digits in
      Some x
    with _ -> None in
  match List.map parse parts with
  | xs when List.exists Option.is_none xs -> None
  | xs ->
    let values = List.map Option.get xs in
    let rev = List.rev values in
    match rev with
    | [] -> None
    | last::leading_rev ->
      let leading = List.rev leading_rev in
      let bits = 32 - 8 * List.length leading in
      let limit = Int64.shift_left 1L bits in
      if List.exists (fun x -> x > 255L) leading || last >= limit then None
      else
        let value = List.fold_left (fun (i,acc) x ->
          i+1, Int64.logor acc (Int64.shift_left x (24-8*i)))
          (0,last) leading |> snd in
        let byte shift = Int64.(to_int (logand (shift_right_logical value shift) 255L)) in
        Some (Ipaddr.V4.of_octets_exn
          (String.init 4 (fun i -> Char.chr (byte (24-8*i)))))

let literal host =
  let bare = if String.starts_with ~prefix:"[" host &&
      String.ends_with ~suffix:"]" host then
      String.sub host 1 (String.length host - 2) else host in
  match Ipaddr.V6.of_string bare with
  | Ok ip -> Some (Ipaddr.V6 ip)
  | Error _ -> Option.map (fun ip -> Ipaddr.V4 ip) (inet_aton host)

let system_resolver host =
  try
    let answers = Unix.getaddrinfo host "0" [Unix.AI_SOCKTYPE Unix.SOCK_STREAM]
      |> List.filter_map (fun a -> match a.Unix.ai_addr with
        | Unix.ADDR_INET (addr,_) ->
          (match Ipaddr.of_string (Unix.string_of_inet_addr addr) with
           | Ok ip -> Some ip | Error _ -> None)
        | _ -> None) in
    Ok answers
  with _ -> Error "resolution failed"

let resolve_public_ips ?(resolver=system_resolver) host =
  if not (ascii_host host) then Ok []
  else
    let malformed = legacy_ipv4_shape host &&
      (String.contains host '%' || String.contains host '/' ||
       String.split_on_char '.' host |> List.exists ((=) "")) in
    if malformed ||
       (not (String.contains host ':') && not (legacy_ipv4_shape host)
        && not (valid_dns_name host) && literal host = None)
    then Ok []
    else
    let answers = match literal host with
      | Some ip -> Ok [ip]
      | None when String.contains host ':' || legacy_ipv4_shape host -> Ok []
      | None -> resolver host in
    match answers with
    | Error _ -> Error Unresolvable
    | Ok answers when answers = [] || List.length answers > 256 -> Error Unresolvable
    | Ok answers ->
      let unique = List.fold_left (fun acc ip ->
        if List.mem ip acc then acc else acc @ [ip]) [] answers in
      let public = List.filter (fun ip -> not (blocked_address ip)) unique in
      let v4,v6 = List.partition (function Ipaddr.V4 _ -> true | _ -> false) public in
      Ok (v4 @ v6)

let resolve ?resolver host =
  match resolve_public_ips ?resolver host with
  | Error _ as error -> error
  | Ok (ip::_) -> Ok ip
  | Ok [] -> Error (Violation host)

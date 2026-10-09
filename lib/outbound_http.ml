(** One bounded HTTP/1.1 exchange. libcurl owns TLS validation and transparent
    gzip/deflate decoding. [pinned_ip] is installed with CURLOPT_RESOLVE, so the
    URL host remains the TLS certificate name and HTTP Host. Redirects are never
    followed here; guarded callers must validate and pin each new location. *)

type request = {
  url : string;
  meth : string;
  pinned_ip : string option;
  headers : (string * string) list;
  body : string;
  connect_timeout : float;
  read_timeout : float;
  deadline : float;
  max_body : int;
  ca_bundle : string option;
}

type response = {
  status : int;
  reason : string;
  headers : (string * string) list;
  body : string;
}

external perform_raw : string * string * string * (string * string) list *
  string * int * int * int * int * string ->
  (int * string * string, string) result = "caml_campfire_curl_perform"

let milliseconds value = max 1 (int_of_float (ceil (value *. 1000.)))

let parse_headers raw =
  let blocks = String.split_on_char '\n' raw in
  let rec consume reason headers = function
    | [] -> reason, List.rev headers
    | line::rest ->
      let line = String.trim line in
      if String.starts_with ~prefix:"HTTP/" line then
        let reason = match String.index_opt line ' ' with
          | None -> ""
          | Some first ->
            (match String.index_from_opt line (first + 1) ' ' with
             | None -> "" | Some second -> String.sub line (second + 1)
               (String.length line - second - 1)) in
        consume reason [] rest
      else if line = "" then consume reason headers rest
      else match String.index_opt line ':' with
        | None -> consume reason headers rest
        | Some pos ->
          let key = String.sub line 0 pos in
          let value = String.sub line (pos + 1) (String.length line-pos-1)
            |> String.trim in
          consume reason ((key,value)::headers) rest in
  consume "" [] blocks

let header response key =
  let found = List.filter_map (fun (k,v) ->
    if String.equal (String.lowercase_ascii k) (String.lowercase_ascii key)
    then Some v else None) response.headers in
  match found with [] -> None | _ -> Some (String.concat ", " found)

let content_type response =
  match header response "content-type" with
  | None -> None
  | Some value ->
    let media = String.split_on_char ';' value |> List.hd in
    Some (String.trim media)

let perform request =
  let remaining = request.deadline -. Unix.gettimeofday () in
  if remaining <= 0. then Error "deadline exceeded"
  else
    let uri = try Some (Uri.of_string request.url) with _ -> None in
    match uri with
    | None -> Error "invalid URL"
    | Some uri ->
      let scheme = Uri.scheme uri and host = Uri.host uri in
      if (scheme <> Some "http" && scheme <> Some "https") || host = None
      then Error "invalid HTTP URL"
      else
      let pin = Option.value ~default:"" request.pinned_ip in
      if pin <> "" && Result.is_error (Ipaddr.of_string pin)
      then Error "invalid pinned IP"
      else
      let open_ms = milliseconds (min remaining request.connect_timeout)
      and read_ms = milliseconds (min remaining request.read_timeout)
      and deadline_ms = milliseconds remaining in
      match perform_raw (request.url,request.meth,pin,request.headers,
          request.body,open_ms,read_ms,deadline_ms,request.max_body,
          Option.value ~default:"" request.ca_bundle) with
      | Error _ as error -> error
      | Ok (status,raw_headers,body) ->
        let reason,headers = parse_headers raw_headers in
        Ok {status;reason;headers;body}

let perform_lwt request = Lwt_preemptive.detach perform request

let net_http_headers ?(connection_close=false) ?(host=None) extra =
  let has key = List.exists (fun (k,_) ->
    String.equal (String.lowercase_ascii k) (String.lowercase_ascii key)) extra in
  let add key value headers = if has key then headers else headers @ [key,value] in
  let headers = add "Accept-Encoding"
    "gzip;q=1.0,deflate;q=0.6,identity;q=0.3" extra in
  let headers = add "Accept" "*/*" headers in
  let headers = add "User-Agent" "Ruby" headers in
  let headers = match host with None -> headers | Some value -> add "Host" value headers in
  if connection_close then add "Connection" "close" headers else headers

let web_push_exchange (request:Web_push.request) =
  {url=request.endpoint;meth="POST";
   pinned_ip=Some request.pinned_ip;headers=request.headers;body=request.body;
   connect_timeout=request.open_timeout;read_timeout=request.read_timeout;
   deadline=request.deadline;max_body=64*1024;ca_bundle=None}

let web_push_outbound (request:Web_push.request) =
  match Ipaddr.of_string request.pinned_ip with
  | Error _ -> Error "invalid pinned IP"
  | Ok ip when Network_guard.blocked_address ip -> Error "private pinned IP"
  | Ok _ ->
    Result.map (fun (response:response) ->
      {Web_push.status=response.status;reason=response.reason})
      (perform (web_push_exchange request))

(** Ordered Net::HTTP-like webhook exchange. This transport is deliberately
    separate from guarded OpenGraph and Web Push: administrators may point bot
    webhooks at internal services. Conduit connects directly, without proxies,
    and OpenSSL verifies HTTPS against the original URL hostname. *)

open Lwt.Infix

type inflater
external inflater_create : bool -> inflater = "caml_campfire_webhook_inflater"
external inflater_feed : inflater -> string -> int -> bool ->
  (string,string) result = "caml_campfire_webhook_inflate"

exception Open_timeout
exception Read_timeout
exception Whole_timeout
exception Body_too_large
exception Inflate_error of string

let timeout seconds exception_ work =
  Lwt.catch (fun () -> Lwt_unix.with_timeout seconds work)
    (function Lwt_unix.Timeout -> Lwt.fail exception_ | error -> Lwt.fail error)

let choose_ip host =
  match Ipaddr.of_string host with
  | Ok ip -> Lwt.return ip
  | Error _ ->
    Lwt_unix.getaddrinfo host "0" [Unix.AI_SOCKTYPE Unix.SOCK_STREAM]
    >|= fun addresses ->
    let rec first = function
      | [] -> failwith ("getaddrinfo: "^host)
      | a::rest ->
        (match a.Unix.ai_addr with
         | Unix.ADDR_INET (addr,_) ->
           (match Ipaddr.of_string (Unix.string_of_inet_addr addr) with
            | Ok ip -> ip | Error _ -> first rest)
         | _ -> first rest) in
    first addresses

let tls_context ca_bundle =
  match ca_bundle with
  | None -> Lwt.return (Lazy.force Conduit_lwt_unix.default_ctx)
  | Some path ->
    let ssl_ctx=Conduit_lwt_unix_ssl.Client.create_ctx () in
    Ssl.load_verify_locations ssl_ctx path "";
    Conduit_lwt_unix.init ~ssl_ctx ()

let response_header response key =
  Cohttp.Header.get (Cohttp.Response.headers response) key

let read_response ~read_timeout ~max_body ic =
  let module Response = Cohttp_lwt_unix.Response in
  timeout read_timeout Read_timeout (fun () -> Response.read ic) >>= function
  | `Eof -> Lwt.fail_with "Server closed connection prematurely"
  | `Invalid reason -> Lwt.fail_with ("Failed to read response: "^reason)
  | `Ok response ->
    let status=Cohttp.Response.status response |> Cohttp.Code.code_of_status in
    let headers=Cohttp.Header.to_list (Cohttp.Response.headers response) in
    let content_encoding=response_header response "content-encoding"
      |> Option.map String.lowercase_ascii in
    let inflater=if Option.is_some (response_header response "content-range") then None
      else match content_encoding with
      | Some ("gzip" | "x-gzip" | "deflate") -> Some (inflater_create true)
      | _ -> None in
    let body=Buffer.create 4096 in
    let append chunk final =
      let remaining=max_body-Buffer.length body in
      let decoded=match inflater with
        | None -> Ok chunk
        | Some decoder -> inflater_feed decoder chunk remaining final in
      match decoded with
      | Error "body too large" -> raise Body_too_large
      | Error message -> raise (Inflate_error message)
      | Ok decoded ->
        if String.length decoded>remaining then raise Body_too_large;
        Buffer.add_string body decoded in
    let rec chunks reader =
      timeout read_timeout Read_timeout (fun () -> Response.read_body_chunk reader)
      >>= function
      | Cohttp.Transfer.Done -> append "" true;Lwt.return_unit
      | Cohttp.Transfer.Final_chunk chunk -> append chunk true;Lwt.return_unit
      | Cohttp.Transfer.Chunk chunk -> append chunk false;chunks reader in
    let read_body=match Response.has_body response with
      | `No -> Lwt.return_unit
      | `Yes | `Unknown -> chunks (Response.make_body_reader response ic) in
    read_body >|= fun () ->
    {Outbound_http.status;reason="";headers;body=Buffer.contents body}

let perform (request:Outbound_http.request) =
  let work () =
    let uri=Uri.of_string request.url in
    let host=match Uri.host uri with Some h when h<>"" -> h
      | _ -> invalid_arg "webhook URL has no host" in
    let https=Uri.scheme uri=Some "https" in
    let port=Option.value ~default:(if https then 443 else 80) (Uri.port uri) in
    let resolve=match request.pinned_ip with
      | Some pin ->
        (match Ipaddr.of_string pin with
         | Ok ip -> Lwt.return ip | Error _ -> Lwt.fail_with "invalid pinned IP")
      | None -> choose_ip host in
    timeout request.connect_timeout Open_timeout (fun () ->
      resolve >>= fun ip ->
      tls_context request.ca_bundle >>= fun ctx ->
      let endpoint : Conduit_lwt_unix.client =
        if https then `OpenSSL (`Hostname host,`IP ip,`Port port)
        else `TCP (`IP ip,`Port port) in
      Conduit_lwt_unix.connect ~ctx endpoint) >>= fun (_,ic,oc) ->
    let close () =
      Lwt.catch (fun () -> Lwt_io.close ic) (fun _ -> Lwt.return_unit)
      >>= fun () ->
      Lwt.catch (fun () -> Lwt_io.close oc) (fun _ -> Lwt.return_unit) in
    Lwt.finalize (fun () ->
      let headers=Cohttp.Header.of_list request.headers in
      let req=Cohttp_lwt_unix.Request.make_for_client ~headers
        ~chunked:false ~body_length:(Int64.of_int (String.length request.body))
        (Cohttp.Code.method_of_string request.meth) uri in
      Cohttp_lwt_unix.Request.write
        (fun writer -> Cohttp_lwt_unix.Request.write_body writer request.body)
        req oc >>= fun () ->
      Lwt_io.flush oc >>= fun () ->
      read_response ~read_timeout:request.read_timeout
        ~max_body:request.max_body ic) close in
  let remaining=request.deadline-.Unix.gettimeofday () in
  if remaining<=0. then Lwt.return_error "whole-call timeout"
  else
    Lwt.catch (fun () ->
      timeout remaining Whole_timeout work >|= fun response -> Ok response)
      (function
       | Open_timeout -> Lwt.return_error "open timeout"
       | Read_timeout -> Lwt.return_error "read timeout"
       | Whole_timeout -> Lwt.return_error "whole-call timeout"
       | Body_too_large -> Lwt.return_error "body too large"
       | Inflate_error message -> Lwt.return_error message
       | error -> Lwt.return_error (Printexc.to_string error))

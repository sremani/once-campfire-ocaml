open Campfire

let check label condition = Alcotest.(check bool) label true condition
let member key json = Yojson.Basic.Util.member key json
let as_string json = Yojson.Basic.Util.to_string json
let as_list json = Yojson.Basic.Util.to_list json
let as_int json = Yojson.Basic.Util.to_int json
let optional_string json = try Some (as_string json) with _ -> None
let fixture name =
  let local="fixtures/"^name in
  Yojson.Basic.from_file (if Sys.file_exists local then local else "test/"^local)

let test_guard_matrix () =
  let blocked = [
    "0.0.0.0";"10.1.2.3";"100.64.0.1";"127.0.0.1";
    "168.63.129.16";"169.254.169.254";"172.16.0.0";
    "192.0.0.8";"192.0.2.1";"192.88.99.1";"192.168.1.1";
    "198.18.0.1";"198.51.100.1";"203.0.113.1";
    "224.0.0.1";"240.0.0.1";"255.255.255.255";
    "::";"::1";"::ffff:192.168.1.1";"::ffff:8.8.8.8";
    "::8.8.8.8";"64:ff9b::a00:1";"64:ff9b:1::1";
    "::ffff:0:a00:1";"fc00::1";"fd00::1";"fe80::1";
    "fec0::1";"ff02::1";"2001::1";"2001:db8::1";
    "2002::1";"3fff::1";"5f00::1";"100::1";
    "2001:2::1";"4000::1";"2001:10::1"] in
  let public = [
    "8.8.8.8";"1.1.1.1";"93.184.216.34";"142.250.185.206";
    "172.32.0.1";"100.128.0.1";"192.0.1.1";
    "2606:2800:220:1:248:1893:25c8:1946";
    "2a00:1450:4001:82a::200e";"2001:3::1";
    "2001:4:112::1";"64:ff9b::808:808";
    "::ffff:0:808:808";"2c0f:ffff::1"] in
  List.iter (fun s -> check (s^" blocked")
    (Network_guard.blocked_address (Ipaddr.of_string_exn s))) blocked;
  List.iter (fun s -> check (s^" public")
    (not (Network_guard.blocked_address (Ipaddr.of_string_exn s)))) public

let test_legacy_and_dns () =
  let calls = ref [] in
  let resolver host = calls:= !calls@[host];
    match host with
    | "mixed.example" -> Ok (List.map Ipaddr.of_string_exn [
      "10.0.0.1";"2606:2800:220:1:248:1893:25c8:1946";
      "::1";"93.184.216.39"])
    | "private.example" -> Ok [Ipaddr.of_string_exn "192.168.1.10"]
    | _ -> Error "not found" in
  let answer host = Network_guard.resolve ~resolver host in
  List.iter (fun s -> check (s^" numeric denied")
    (match answer s with Error (Network_guard.Violation _) -> true | _ -> false))
    ["127.1";"0x7f.1";"2130706433";"0177.0.0.01";
     "10.0.258";"127.0.0.1";"[::1]";"01.2.3.4.";
     "under_score.example";"a..b";"host%eth0";"exämple.com"];
  check "mixed first public v4"
    (answer "mixed.example" = Ok (Ipaddr.of_string_exn "93.184.216.39"));
  check "private answer denied"
    (match answer "private.example" with Error (Network_guard.Violation _) -> true | _ -> false);
  Alcotest.(check (list string)) "DNS used only for names"
    ["mixed.example";"private.example"] !calls

let test_webhook_reply () =
  let open Webhook in
  check "text reply" (reply ~status:200 ~content_type:(Some "text/html") "<b>x</b>" =
    Ok (Text "<b>x</b>"));
  check "non-200 text is attachment"
    (reply ~status:201 ~content_type:(Some "text/plain") "x" =
      Ok (Attachment {data="x";filename="attachment.text";content_type="text/plain"}));
  check "synonym canonicalized" (reply ~status:200
    ~content_type:(Some "application/x-gzip") "x" =
    Ok (Attachment {data="x";filename="attachment.gzip";content_type="application/gzip"}));
  check "invalid MIME rejected" (match reply ~status:200
    ~content_type:(Some "a/b c") "x" with Error (Invalid_mime_type _) -> true | _ -> false)

let test_pinned_http () =
  let listener=Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt listener Unix.SO_REUSEADDR true;
  Unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_loopback,0));
  Unix.listen listener 1;
  let port=match Unix.getsockname listener with
    | Unix.ADDR_INET (_,port) -> port | _ -> assert false in
  let captured=ref "" in
  let server=Thread.create (fun () ->
    let peer,_=Unix.accept listener in
    let input=Bytes.create 4096 in
    let got=Unix.read peer input 0 4096 in
    captured:=Bytes.sub_string input 0 got;
    let response="HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok" in
    ignore (Unix.write_substring peer response 0 (String.length response));
    Unix.close peer;Unix.close listener) () in
  let url=Printf.sprintf "http://pinned.example.invalid:%d/path?q=1" port in
  let request={Outbound_http.url;meth="GET";pinned_ip=Some "127.0.0.1";
    headers=Outbound_http.net_http_headers [];
    body="";connect_timeout=2.;read_timeout=2.;
    deadline=Unix.gettimeofday ()+.3.;max_body=32;ca_bundle=None} in
  let result=Outbound_http.perform request in
  Thread.join server;
  (match result with
   | Error message -> Alcotest.fail ("pinned exchange: "^message)
   | Ok response ->
     Alcotest.(check int) "status" 200 response.status;
     Alcotest.(check string) "body" "ok" response.body);
  check "request target" (String.starts_with ~prefix:"GET /path?q=1 HTTP/1.1" !captured);
  check "original Host sent" (String.contains !captured 'H' &&
    (let host=Printf.sprintf "Host: pinned.example.invalid:%d" port in
     let rec contains at =
       at+String.length host <= String.length !captured &&
       (String.sub !captured at (String.length host)=host || contains (at+1)) in
     contains 0))

let test_tls_host_verification () =
  let fixture_path name =
    let local="fixtures/integrations_tls/"^name in
    if Sys.file_exists local then local else "test/"^local in
  let listener=Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_loopback,0));
  let port=match Unix.getsockname listener with
    | Unix.ADDR_INET (_,port) -> port | _ -> assert false in
  Unix.close listener;
  let args=[|"openssl";"s_server";"-accept";string_of_int port;
    "-cert";fixture_path "server.pem";"-key";fixture_path "server.key";
    "-www";"-naccept";"4"|] in
  let null=Unix.openfile "/dev/null" [Unix.O_WRONLY] 0 in
  let pid=Unix.create_process "openssl" args Unix.stdin null null in
  Unix.close null;
  Fun.protect ~finally:(fun () ->
    (try Unix.kill pid Sys.sigterm with _ -> ());
    ignore (try Unix.waitpid [] pid with _ -> 0,Unix.WEXITED 0)) (fun () ->
    Unix.sleepf 0.15;
    let request host = {Outbound_http.url=Printf.sprintf
      "https://%s:%d/" host port;
      meth="GET";pinned_ip=Some "127.0.0.1";headers=[];body="";
      connect_timeout=3.;read_timeout=3.;deadline=Unix.gettimeofday ()+.5.;
      max_body=65536;ca_bundle=Some (fixture_path "ca.pem")} in
    let trusted=Outbound_http.perform (request "www.example.com") in
    check "trusted fixture with pinned IP"
      (match trusted with Ok response -> response.status=200 | _ -> false);
    let wrong_host=Outbound_http.perform (request "wrong.example.com") in
    check "TLS certificate checked against original URL host"
      (match wrong_host with Error _ -> true | _ -> false);
    let webhook_trusted=Lwt_main.run (Webhook_transport.perform (request "www.example.com")) in
    check "webhook TLS trusts fixture CA"
      (match webhook_trusted with Ok response -> response.status=200 | _ -> false);
    let webhook_wrong=Lwt_main.run (Webhook_transport.perform (request "wrong.example.com")) in
    check "webhook TLS verifies original hostname"
      (match webhook_wrong with Error _ -> true | _ -> false))

let with_loopback_server serve use =
  let listener=Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_loopback,0));
  Unix.listen listener 1;
  let port=match Unix.getsockname listener with
    | Unix.ADDR_INET (_,port) -> port | _ -> assert false in
  let captured=ref "" in
  let server=Thread.create (fun () ->
    let peer,_=Unix.accept listener in
    let input=Bytes.create 4096 in
    let got=Unix.read peer input 0 4096 in
    captured:=Bytes.sub_string input 0 got;
    (try serve peer with _ -> ());
    Unix.close peer;Unix.close listener) () in
  let outcome=use port in
  Thread.join server;
  outcome,!captured

let test_webhook_wire () =
  let outcome,wire=with_loopback_server (fun peer ->
    let response="HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok" in
    ignore (Unix.write_substring peer response 0 (String.length response)))
    (fun port -> Lwt_main.run (Webhook.deliver
      (Printf.sprintf "http://127.0.0.1:%d/text" port) "{\"message\":\"hi\"}")) in
  if Sys.getenv_opt "DEBUG_WIRE"=Some "1" then
    prerr_endline (match outcome with
      | Ok {Webhook.status;reply=Webhook.Text text} -> Printf.sprintf
        "status=%s text=%S" (match status with None -> "none" | Some s -> string_of_int s) text
      | Ok _ -> "other webhook outcome"
      | Error (Webhook.Network message) -> "network error: "^message
      | Error _ -> "other webhook error");
  check "live webhook reply" (outcome=Ok {Webhook.status=Some 200;reply=Webhook.Text "ok"});
  let expected=match fixture "webhook_expected.json" |> as_list with
    | first::_ -> member "requests" first |> as_list |> List.hd | _ -> assert false in
  let header_wire=match String.index_opt wire '\n' with
    | None -> wire
    | Some _ ->
      let rec find i =
        if i+3>=String.length wire then wire
        else if String.sub wire i 4="\r\n\r\n" then String.sub wire 0 i
        else find (i+1) in find 0 in
  let head=String.split_on_char '\n' header_wire |> List.map String.trim in
  let actual_headers=List.filter_map (fun line -> match String.index_opt line ':' with
    | None -> None
    | Some pos -> Some (String.sub line 0 pos,
      String.sub line (pos+1) (String.length line-pos-1) |> String.trim)) head in
  let actual_headers=List.filter (fun (key,_) -> key<>"") actual_headers in
  check "webhook Host on loopback" (match List.assoc_opt "Host" actual_headers with
    | Some value -> String.starts_with ~prefix:"127.0.0.1:" value
    | None -> false);
  let expected_headers=member "headers" expected |> as_list |>
    List.map (fun pair -> match as_list pair with
      | [a;b] -> let key=as_string a and value=as_string b in
        key,(if key="Host" then Option.value ~default:"" (List.assoc_opt "Host" actual_headers)
          else value)
      | _ -> assert false) in
  if actual_headers<>expected_headers then
    Alcotest.fail ("webhook wire header order/content differs: "^
      String.concat " | " (List.map (fun (k,v)->k^": "^v) actual_headers));
  check "webhook body present" (String.ends_with ~suffix:"{\"message\":\"hi\"}" wire)

let test_gzip_size_limit () =
  let compressed=Http_gzip.compress (String.make 1024 'x') in
  let serve peer =
    let headers=Printf.sprintf
      "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
      (String.length compressed) in
    ignore (Unix.write_substring peer headers 0 (String.length headers));
    ignore (Unix.write_substring peer compressed 0 (String.length compressed)) in
  let perform max_body port =
    Outbound_http.perform {url=Printf.sprintf "http://127.0.0.1:%d/x" port;
      meth="GET";pinned_ip=Some "127.0.0.1";headers=[];body="";
      connect_timeout=2.;read_timeout=2.;deadline=Unix.gettimeofday ()+.3.;
      max_body;ca_bundle=None} in
  let accepted,_=with_loopback_server serve (perform 1024) in
  check "exact decompressed size accepted" (match accepted with
    | Ok response -> String.length response.body=1024 | _ -> false);
  let denied,_=with_loopback_server serve (perform 1023) in
  check "decompressed size capped" (denied=Error "body too large");
  let webhook max_body port =
    let request={Outbound_http.url=Printf.sprintf "http://127.0.0.1:%d/x" port;
      meth="GET";pinned_ip=None;headers=[];body="";
      connect_timeout=2.;read_timeout=2.;deadline=Unix.gettimeofday ()+.3.;
      max_body;ca_bundle=None} in
    Lwt_main.run (Webhook_transport.perform request) in
  let accepted,_=with_loopback_server serve (webhook 1024) in
  check "webhook exact decompressed size accepted" (match accepted with
    | Ok response -> String.length response.body=1024 | _ -> false);
  let denied,_=with_loopback_server serve (webhook 1023) in
  check "webhook decoded size capped" (denied=Error "body too large")

let test_webhook_encoding_aliases () =
  let plain="compressed webhook reply" in
  let compressed=Http_gzip.compress plain in
  let one content_encoding content_range =
    let serve peer =
      let extra=if content_range then "Content-Range: bytes 0-1/2\r\n" else "" in
      let headers=Printf.sprintf
        "HTTP/1.1 200 OK\r\nContent-Encoding: %s\r\n%sContent-Length: %d\r\nConnection: close\r\n\r\n"
        content_encoding extra (String.length compressed) in
      ignore (Unix.write_substring peer headers 0 (String.length headers));
      ignore (Unix.write_substring peer compressed 0 (String.length compressed)) in
    with_loopback_server serve (fun port ->
      Lwt_main.run (Webhook_transport.perform {
        url=Printf.sprintf "http://127.0.0.1:%d/x" port;
        meth="GET";pinned_ip=None;headers=[];body="";
        connect_timeout=2.;read_timeout=2.;deadline=Unix.gettimeofday ()+.3.;
        max_body=1024;ca_bundle=None})) |> fst in
  List.iter (fun encoding -> check (encoding^" auto-decoded")
    (match one encoding false with Ok response -> response.body=plain | _ -> false))
    ["gzip";"x-gzip";"deflate"];
  check "range body remains encoded" (match one "gzip" true with
    | Ok response -> response.body=compressed | _ -> false)

let test_concatenated_gzip_members () =
  let plain="first member" ^ "second member" in
  let encoded=Http_gzip.compress "first member" ^ Http_gzip.compress "second member" in
  let decode limit =
    let decoder=Webhook_transport.inflater_create true in
    let output=Buffer.create 32 in
    let rec feed index =
      if index=String.length encoded then Ok (Buffer.contents output)
      else
        let byte=String.sub encoded index 1 in
        match Webhook_transport.inflater_feed decoder byte
          (limit-Buffer.length output) (index=String.length encoded-1) with
        | Error reason -> Error reason
        | Ok part -> Buffer.add_string output part;feed (index+1) in
    feed 0 in
  check "one-byte gzip chunks cross member boundary" (decode (String.length plain)=Ok plain);
  check "second member counts toward decoded size cap"
    (decode (String.length plain-1)=Error "body too large");
  let decoder=Webhook_transport.inflater_create true in
  let truncated=String.sub encoded 0 (String.length encoded-1) in
  check "truncated second member is rejected"
    (Webhook_transport.inflater_feed decoder truncated 1024 true=
      Error "incomplete compressed response")

let test_whole_call_deadline () =
  let serve peer =
    let headers="HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n" in
    ignore (Unix.write_substring peer headers 0 (String.length headers));
    for _=1 to 10 do
      Unix.sleepf 0.05;
      (try ignore (Unix.write_substring peer "x" 0 1) with _ -> ())
    done in
  let started=Unix.gettimeofday () in
  let result,_=with_loopback_server serve (fun port ->
    Outbound_http.perform {url=Printf.sprintf "http://127.0.0.1:%d/x" port;
      meth="GET";pinned_ip=Some "127.0.0.1";headers=[];body="";
      connect_timeout=1.;read_timeout=1.;deadline=Unix.gettimeofday ()+.0.2;
      max_body=100;ca_bundle=None}) in
  check "trickling call hits total deadline" (match result with Error _ -> true | _ -> false);
  check "deadline stayed bounded" (Unix.gettimeofday ()-.started<1.);
  let webhook,_=with_loopback_server serve (fun port ->
    Lwt_main.run (Webhook_transport.perform {
      url=Printf.sprintf "http://127.0.0.1:%d/x" port;
      meth="GET";pinned_ip=None;headers=[];body="";
      connect_timeout=1.;read_timeout=1.;deadline=Unix.gettimeofday ()+.0.2;
      max_body=100;ca_bundle=None})) in
  check "webhook whole-call deadline" (webhook=Error "whole-call timeout")

let test_read_timeout () =
  let serve peer =
    let headers="HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n" in
    ignore (Unix.write_substring peer headers 0 (String.length headers));
    Unix.sleepf 1.6;
    (try ignore (Unix.write_substring peer "x" 0 1) with _ -> ()) in
  let result,_=with_loopback_server serve (fun port ->
    Outbound_http.perform {url=Printf.sprintf "http://127.0.0.1:%d/x" port;
      meth="GET";pinned_ip=Some "127.0.0.1";headers=[];body="";
      connect_timeout=1.;read_timeout=1.;
      deadline=Unix.gettimeofday ()+.3.;max_body=100;ca_bundle=None}) in
  check "idle body read times out" (match result with
    | Error "read timeout" -> true | _ -> false);
  let webhook,_=with_loopback_server serve (fun port ->
    Lwt_main.run (Webhook_transport.perform {
      url=Printf.sprintf "http://127.0.0.1:%d/x" port;
      meth="GET";pinned_ip=None;headers=[];body="";
      connect_timeout=1.;read_timeout=0.15;
      deadline=Unix.gettimeofday ()+.3.;max_body=100;ca_bundle=None})) in
  check "webhook idle read timeout" (webhook=Error "read timeout")

let test_opengraph_oracle () =
  let spec=fixture "opengraph_cases.json" in
  let expected=fixture "opengraph_expected.json" |> as_list in
  let cases=member "cases" spec |> as_list in
  let routes=member "routes" spec |> as_list in
  let hosts=member "hosts" spec |> Yojson.Basic.Util.to_assoc in
  let failures=ref [] in
  List.iter2 (fun case wanted ->
    let name=member "name" case |> as_string in
    let url=member "url" case |> as_string in
    let lookups=ref [] and requests=ref [] in
    let counts=Hashtbl.create 10 in
    let resolver host =
      lookups:= !lookups@[host];
      match List.assoc_opt host hosts with
      | None -> Error "unresolvable"
      | Some answers ->
        let choices=as_list answers in
        let current=Option.value ~default:0 (Hashtbl.find_opt counts host) in
        Hashtbl.replace counts host (current+1);
        let answer=List.nth choices (min current (List.length choices-1)) |> as_list in
        Ok (List.map (fun value -> Ipaddr.of_string_exn (as_string value)) answer) in
    let perform (request:Outbound_http.request) =
      let uri=Uri.of_string request.url in
      let host=Option.value ~default:"" (Uri.host uri) in
      let target=Opengraph.request_target uri in
      let header name = List.assoc_opt name request.headers |> Option.value ~default:"" in
      requests:= !requests@[`List (List.map (fun value -> `String value)
        [request.meth;header "Host";target;header "Accept";
         header "Accept-Encoding";header "User-Agent"])];
      let route=List.find_opt (fun route ->
        member "method" route=`String request.meth &&
        (let value=member "host" route in value=`String host || value=`String "*") &&
        member "path" route=`String target) routes in
      let response=match route with
        | None -> {Outbound_http.status=404;reason="Not Found";headers=[];body=""}
        | Some route ->
          let headers=member "headers" route |> as_list |>
            List.map (fun pair -> match as_list pair with
              | [a;b] -> as_string a,as_string b | _ -> assert false) in
          let body=match optional_string (member "body_b64" route) with
            | Some encoded -> Base64.decode_exn encoded
            | None -> Option.value ~default:"" (optional_string (member "body" route)) in
          let body=match member "body_repeat" route with
            | `List [`String ch;`Int n] -> body^String.make n ch.[0]
            | _ -> body in
          let body=match member "pad_to" route with
            | `Int n when n>String.length body -> body^String.make (n-String.length body) ' '
            | _ -> body in
          {Outbound_http.status=member "status" route |> as_int;
            reason="OK";headers;body} in
      Lwt.return (if String.length response.body>request.max_body then
        Error "body too large" else Ok response) in
    let outcome=Lwt_main.run (Opengraph.unfurl_with ~resolver ~perform url) in
    let status,body=match outcome with
      | Opengraph.Json body -> 200,Some body
      | Opengraph.No_content -> 204,None
      | Opengraph.Raised _ -> 500,None in
    let response=member "response" wanted in
    let expected_status=member "status" response |> as_int in
    let expected_body=optional_string (member "body" response) in
    let expected_lookups=member "lookups" wanted |> as_list |> List.map as_string in
    let expected_requests=member "requests" wanted |> as_list in
    let mismatch=ref [] in
    if status<>expected_status then mismatch:="status"::!mismatch;
    if body<>expected_body then mismatch:="body"::!mismatch;
    if !lookups<>expected_lookups then mismatch:="lookups"::!mismatch;
    if !requests<>expected_requests then mismatch:="requests"::!mismatch;
    if !mismatch<>[] then (
      if Sys.getenv_opt "DEBUG_OG"=Some "1" then
        prerr_endline (name^"\n actual="^Yojson.Basic.to_string (`Assoc [
          "status",`Int status;"body",(match body with None -> `Null | Some x -> `String x);
          "lookups",`List (List.map (fun x -> `String x) !lookups);
          "requests",`List !requests])^"\n wanted="^Yojson.Basic.to_string wanted);
      failures:= !failures@[name^": "^String.concat ", " (List.rev !mismatch)]))
    cases expected;
  if !failures<>[] then Alcotest.fail
    (Printf.sprintf "%d/%d oracle cases differ:\n%s"
      (List.length !failures) (List.length cases) (String.concat "\n" !failures))

let test_webhook_oracle () =
  let cases=fixture "webhook_cases.json" |> as_list in
  let expected=fixture "webhook_expected.json" |> as_list in
  let failures=ref [] in
  List.iter2 (fun case wanted ->
    let name=member "name" case |> as_string in
    let status=member "status" case |> as_int in
    let headers=member "headers" case |> as_list |>
      List.map (fun pair -> match as_list pair with
        | [a;b] -> as_string a,as_string b | _ -> assert false) in
    let body=match optional_string (member "body_b64" case) with
      | Some encoded -> Base64.decode_exn encoded
      | None -> Option.value ~default:"" (optional_string (member "body" case)) in
    let request=ref None in
    let perform (outbound:Outbound_http.request) =
      request:=Some outbound;
      let response={Outbound_http.status;reason="OK";headers;body} in
      Lwt.return (if name="slow" then Error "read timeout"
        else if name="refused" then Error "connection refused"
        else Ok response) in
    let url=match optional_string (member "url" case) with
      | Some url -> url | None -> "http://127.0.0.1:46247/"^name in
    let actual=Lwt_main.run (Webhook.deliver_with ~perform url "{\"message\":\"hi\"}") in
    let expected_reply=member "reply" wanted in
    let actual_reply=match actual with
      | Ok {Webhook.reply=Webhook.None_reply;_} -> `Null
      | Ok {Webhook.reply=Webhook.Text text;_} -> `Assoc ["text_b64",`String (Base64.encode_string text)]
      | Ok {Webhook.reply=Webhook.Attachment value;_} ->
        `Assoc ["attachment",`Assoc [
          "filename",`String value.filename;
          "content_type",`String value.content_type;
          "body_b64",`String (Base64.encode_string value.data)]]
      | Error _ -> `Null in
    let wanted_reply=match expected_reply with
      | `Null -> `Null
      | `Assoc fields when List.mem_assoc "attachment" fields ->
        let a=member "attachment" expected_reply in
        `Assoc ["attachment",`Assoc [
          "filename",member "filename" a;
          "content_type",member "content_type" a;
          "body_b64",member "body_b64" a]]
      | _ -> `Assoc ["text_b64",member "text_b64" expected_reply] in
    let actual_status=match actual with Ok d -> d.Webhook.status | Error _ -> None in
    let wanted_status=match member "status" wanted with `Int n -> Some n | _ -> None in
    let error_matches=match member "error" wanted,actual with
      | `Null,Ok _ -> true
      | `String "Mime::Type::InvalidMimeType",Error (Webhook.Invalid_mime_type _) -> true
      | `String "Errno::ECONNREFUSED",Error (Webhook.Network _) -> true
      | _ -> false in
    let expected_headers=match member "requests" wanted with
      | `List (`Assoc request::_) ->
        (match List.assoc_opt "headers" request with
         | Some (`List pairs) -> List.map (fun pair -> match as_list pair with
           | [a;b] -> let a=as_string a and b=as_string b in
             a,(if a="Host" then "127.0.0.1:46247" else b)
           | _ -> assert false) pairs
         | _ -> [])
      | _ -> [] in
    let actual_headers=match !request with None -> [] | Some req -> req.Outbound_http.headers in
    let mismatch=ref [] in
    if actual_status<>wanted_status then mismatch:="status"::!mismatch;
    if actual_reply<>wanted_reply then mismatch:="reply"::!mismatch;
    if not error_matches then mismatch:="error"::!mismatch;
    if expected_headers<>[] && actual_headers<>expected_headers then mismatch:="headers"::!mismatch;
    if !mismatch<>[] then failures:= !failures@[name^": "^String.concat ", " !mismatch])
    cases expected;
  if !failures<>[] then Alcotest.fail
    (Printf.sprintf "%d/%d webhook oracle cases differ:\n%s"
      (List.length !failures) (List.length cases) (String.concat "\n" !failures))

let () =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  Alcotest.run "M5-T4 network integrations" [
  "guard",[Alcotest.test_case "Surfguard ranges" `Quick test_guard_matrix;
    Alcotest.test_case "numeric hosts and DNS" `Quick test_legacy_and_dns];
  "webhook",[Alcotest.test_case "reply mapping" `Quick test_webhook_reply;
    Alcotest.test_case "19 pinned oracle cases" `Quick test_webhook_oracle;
    Alcotest.test_case "live request wire" `Quick test_webhook_wire];
  "transport",[Alcotest.test_case "pinned host and address" `Quick test_pinned_http;
    Alcotest.test_case "TLS verifies URL host" `Quick test_tls_host_verification;
    Alcotest.test_case "gzip decoded-size cap" `Quick test_gzip_size_limit;
    Alcotest.test_case "webhook encoding aliases" `Quick test_webhook_encoding_aliases;
    Alcotest.test_case "concatenated gzip members" `Quick test_concatenated_gzip_members;
    Alcotest.test_case "whole-call trickle deadline" `Quick test_whole_call_deadline;
    Alcotest.test_case "idle read timeout" `Quick test_read_timeout];
  "opengraph",[Alcotest.test_case "90 pinned oracle cases" `Quick test_opengraph_oracle]]

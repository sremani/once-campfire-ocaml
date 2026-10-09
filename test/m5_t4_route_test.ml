open Campfire

let secret=String.make 64 'u'
let now="2026-10-09T12:00:00Z"
let member name json=Yojson.Basic.Util.member name json
let string json=Yojson.Basic.Util.to_string json
let list json=Yojson.Basic.Util.to_list json
let integer json=Yojson.Basic.Util.to_int json
let optional_string json=try Some (string json) with _ -> None
let fixture name =
  let local="fixtures/"^name in
  Yojson.Basic.from_file (if Sys.file_exists local then local else "test/"^local)

let rec reference_root path remaining =
  if remaining=0 then failwith "pinned seed missing" else
  let root=Filename.concat path "once-campfire-rust" in
  if Sys.file_exists (Filename.concat root "parity/.seed/default/db/production.sqlite3")
  then root else reference_root (Filename.dirname path) (remaining-1)

let with_seed f =
  let source=Filename.concat (reference_root (Sys.getcwd ()) 8)
    "parity/.seed/default/db/production.sqlite3" in
  let from=Sqlite3.db_open ~mode:`READONLY source in
  let path=Filename.temp_file "campfire-m5-t4-routes" ".sqlite3" in
  Sys.remove path;
  let escaped=String.concat "''" (String.split_on_char '\'' path) in
  let copied=Sqlite3.exec from ("VACUUM INTO '"^escaped^"'") in
  ignore (Sqlite3.db_close from);
  if copied<>Sqlite3.Rc.OK then failwith "seed copy failed";
  let runtime=Db_runtime.open_db ~readers:2 ~prepare:false path in
  Fun.protect ~finally:(fun () ->
    Db_runtime.close runtime;
    List.iter (fun file -> if Sys.file_exists file then Sys.remove file)
      [path;path^"-wal";path^"-shm"])
    (fun () -> f runtime)

let cookie runtime =
  let session=Db_runtime.write runtime (fun tx ->
    Db_accounts.Session.start (Db_runtime.conn tx) ~now
      ~user_id:127326141L ~user_agent:None ~ip_address:None) in
  "session_token="^Authentication.issue_token_cookie
    ~secret_key_base:secret ~now session.token

let request runtime cookie url =
  let headers=Cohttp.Header.of_list [
    "host","chat.example.com";
    "origin","https://chat.example.com";
    "sec-fetch-site","same-origin";
    "cookie",cookie;
    "content-type","application/x-www-form-urlencoded";
    "accept","application/json"] in
  let req=Cohttp.Request.make ~meth:`POST ~headers
    (Uri.of_string "https://chat.example.com/unfurl_link") in
  let body=Uri.encoded_of_query ["url",[url]] in
  let response,body=Lwt_main.run (Http_app.handle ~runtime
    ~secret_key_base:secret ~now ~ssl:true ~force_ssl:true
    ~dispatch:App_dispatch.endpoint req (Cohttp_lwt.Body.of_string body)) in
  Cohttp.Code.code_of_status (Cohttp.Response.status response),
    Lwt_main.run (Cohttp_lwt.Body.to_string body)

let route_fake spec =
  let routes=member "routes" spec |> list in
  let hosts=member "hosts" spec |> Yojson.Basic.Util.to_assoc in
  let counts=Hashtbl.create 8 in
  let lookups=ref [] and requests=ref [] in
  let resolver host =
    lookups:= !lookups@[host];
    match List.assoc_opt host hosts with
    | None -> Error "unresolvable"
    | Some answers ->
      let choices=list answers in
      let current=Option.value ~default:0 (Hashtbl.find_opt counts host) in
      Hashtbl.replace counts host (current+1);
      let answer=List.nth choices (min current (List.length choices-1)) |> list in
      Ok (List.map (fun value -> Ipaddr.of_string_exn (string value)) answer) in
  let perform (request:Outbound_http.request) =
    let uri=Uri.of_string request.url in
    let host=Option.value ~default:"" (Uri.host uri) in
    let target=Opengraph.request_target uri in
    let header name=List.assoc_opt name request.headers |> Option.value ~default:"" in
    requests:= !requests@[`List (List.map (fun value -> `String value)
      [request.meth;header "Host";target;header "Accept";
       header "Accept-Encoding";header "User-Agent"])];
    let route=List.find_opt (fun route ->
      member "method" route=`String request.meth &&
      (let route_host=member "host" route in
        route_host=`String host || route_host=`String "*") &&
      member "path" route=`String target) routes in
    let response=match route with
      | None -> {Outbound_http.status=404;reason="Not Found";headers=[];body=""}
      | Some route ->
        let headers=member "headers" route |> list |>
          List.map (fun pair -> match list pair with
            | [a;b] -> string a,string b | _ -> assert false) in
        let body=match optional_string (member "body_b64" route) with
          | Some encoded -> Base64.decode_exn encoded
          | None -> Option.value ~default:"" (optional_string (member "body" route)) in
        let body=match member "body_repeat" route with
          | `List [`String ch;`Int n] -> body^String.make n ch.[0]
          | _ -> body in
        let body=match member "pad_to" route with
          | `Int n when n>String.length body -> body^String.make (n-String.length body) ' '
          | _ -> body in
        {Outbound_http.status=member "status" route |> integer;
         reason="OK";headers;body} in
    Lwt.return (if String.length response.body>request.max_body then
      Error "body too large" else Ok response) in
  resolver,perform,lookups,requests

let test_all_seeded_routes () = with_seed (fun runtime ->
  let spec=fixture "opengraph_cases.json" in
  let cases=member "cases" spec |> list in
  let expected=fixture "opengraph_expected.json" |> list in
  let session_cookie=cookie runtime in
  let failures=ref [] in
  List.iter2 (fun case wanted ->
    let name=member "name" case |> string in
    let resolver,perform,lookups,requests=route_fake spec in
    Controller_aux.register_unfurl
      (Opengraph.controller_adapter_with ~resolver ~perform);
    let status,body=request runtime session_cookie (member "url" case |> string) in
    let response=member "response" wanted in
    let wanted_status=member "status" response |> integer in
    let wanted_body=optional_string (member "body" response) in
    let wanted_lookups=member "lookups" wanted |> list |> List.map string in
    let wanted_requests=member "requests" wanted |> list in
    let mismatches=ref [] in
    if status<>wanted_status then mismatches:="status"::!mismatches;
    if wanted_body<>None && Some body<>wanted_body then mismatches:="body"::!mismatches;
    if wanted_status=204 && body<>"" then mismatches:="unexpected 204 body"::!mismatches;
    if !lookups<>wanted_lookups then mismatches:="lookups"::!mismatches;
    if !requests<>wanted_requests then mismatches:="requests"::!mismatches;
    if !mismatches<>[] then failures:=
      !failures@[Printf.sprintf "%s: %s (status=%d body=%S lookups=%s requests=%s)"
        name (String.concat ", " (List.rev !mismatches)) status body
        (String.concat "," !lookups)
        (Yojson.Basic.to_string (`List !requests))])
    cases expected;
  if !failures<>[] then Alcotest.fail
    (Printf.sprintf "%d/%d seeded HTTP routes differ:\n%s"
      (List.length !failures) (List.length cases) (String.concat "\n" !failures)))

let ()=Alcotest.run "M5-T4 seeded route integration" [
  "unfurl",[Alcotest.test_case "90 full HTTP routes" `Quick test_all_seeded_routes]]

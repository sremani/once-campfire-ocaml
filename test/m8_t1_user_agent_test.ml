open Campfire
module U = Campfire.User_agent
module J = Yojson.Basic.Util
let fixture = Yojson.Basic.from_file "fixtures/campfire_user_agents.json"
let list key = J.member key fixture |> J.to_list
let get key obj = J.member key obj
let str = function `String s -> Some s | _ -> None
let label case = match get "ua" case with `String s -> s | _ -> "<nil>"
let error = function U.No_method -> "NoMethodError" | U.Argument -> "ArgumentError"
let json_string_result = function
  | Ok None -> `Null | Ok (Some s) -> `String s
  | Error e -> `Assoc ["error",`String (error e)]
let json_bool_result = function
  | Ok b -> `Bool b | Error e -> `Assoc ["error",`String (error e)]
let check label field expected actual =
  if expected<>actual then Alcotest.failf "%s %s: expected %s, got %s" label field
    (Yojson.Basic.to_string expected) (Yojson.Basic.to_string actual)
let check_agents () =
  let cases=list "user_agents" in
  Alcotest.(check int) "agent count" 385 (List.length cases);
  List.iteri (fun i c ->
    let raw=get "ua" c |> str in let a=U.parse (Option.value raw ~default:"") in
    let p=U.application_platform raw in let ap=get "application_platform" c in
    let l=Printf.sprintf "%d:%s" i (label c) in
    let chk field result = check l field (get field c) result in
    chk "browser" (json_string_result (U.try_browser a));
    chk "version" (json_string_result (U.try_version a));
    chk "platform" (json_string_result (U.try_platform a));
    chk "os" (json_string_result (U.try_os a));
    chk "bot" (`Bool (U.bot a));
    chk "mobile" (json_bool_result (U.try_mobile a));
    chk "blocked" (json_bool_result (U.try_browser_blocked p));
    let b=U.try_browser a and os=U.try_operating_system p in
    let fields=[
      "ios",`Bool (U.app_ios p);"android",`Bool (U.app_android p);
      "mac",`Bool (U.app_mac p);"apple_messages",`Bool (U.app_apple_messages p);
      "mobile",`Bool (U.app_mobile p);"desktop",`Bool (not (U.app_mobile p));
      "chrome",json_bool_result (U.browser_matches b ["Chrome"]);
      "firefox",json_bool_result (U.browser_matches b ["Firefox";"FxiOS"]);
      "safari",json_bool_result (U.browser_matches b ["Safari"]);
      "edge",json_bool_result (U.browser_matches b ["Edg"]);
      "windows",(match os with Error e -> `Assoc ["error",`String (error e)] | Ok os -> `Bool (os=Some "Windows"));
      "operating_system",json_string_result os;"browser",json_string_result b] in
    List.iter (fun (field,result) -> check l ("application_platform."^field) (get field ap) result) fields;
    let view=U.to_view p in
    let view_fields=["ios",`Bool view.ios;"android",`Bool view.android;"mac",`Bool view.mac;
      "apple_messages",`Bool view.apple_messages;"mobile",`Bool view.mobile;
      "desktop",`Bool view.desktop;"chrome",`Bool view.chrome;"firefox",`Bool view.firefox;
      "safari",`Bool view.safari;"edge",`Bool view.edge;"windows",`Bool view.windows;
      "operating_system",`String view.operating_system;"browser",`String view.browser] in
    List.iter (fun (field,actual) ->
      let expected=get field ap in
      let expected=match expected with `Null | `Assoc _ ->
        (match actual with `String _ -> `String "" | _ -> `Bool false) | x -> x in
      check l ("view."^field) expected actual) view_fields
  ) cases
let check_versions () =
  let versions=list "versions" in
  Alcotest.(check int) "version count" 44 (List.length versions);
  List.iter (fun v ->
    let s=get "string" v |> J.to_string in
    check s "nil" (get "nil" v) (`Bool (U.Version.is_nil s));
    let segments=U.Version.to_a s |> List.map (function
      | U.Version.Int n -> `String ("i:"^n) | U.Version.Str s -> `String ("s:"^s)) in
    check s "to_a" (get "to_a" v) (`List segments)) versions;
  let comparisons=list "comparisons" in
  Alcotest.(check int) "comparison count" 352 (List.length comparisons);
  List.iter (fun c ->
    let a=get "a" c |> J.to_string and b=get "b" c |> J.to_string in
    let cmp=U.Version.compare a b in
    check (a^" <> "^b) "cmp" (get "cmp" c) (`Int (Int.compare cmp 0));
    check (a^" <> "^b) "lt" (get "lt" c) (`Bool (cmp<0));
    check (a^" <> "^b) "eq" (get "eq" c) (`Bool (a=b))) comparisons
let check_password_vectors () =
  let fixture=Yojson.Basic.from_file "fixtures/rails_compat.json" in
  let passwords=get "passwords" fixture in
  let checks=get "checks" passwords |> J.to_list in
  Alcotest.(check int) "pinned password checks" 40 (List.length checks);
  List.iteri (fun i c ->
    let digest=get "digest" c |> J.to_string
    and password=get "password" c |> J.to_string
    and expected=get "expected" c |> J.to_bool in
    Alcotest.(check bool) ("password check "^string_of_int i)
      expected (Campfire.Db_accounts.Password.verify ~password digest)) checks;
  let digests=get "digests" passwords |> J.to_list in
  Alcotest.(check int) "pinned digests" 5 (List.length digests);
  List.iter (fun c -> Alcotest.(check bool) "digest syntax" true
    (Campfire.Db_accounts.Password.valid_digest (get "digest" c |> J.to_string))) digests;
  Alcotest.(check bool) "seeded digest syntax" true
    (Campfire.Db_accounts.Password.valid_digest (get "seeded_user_digest" passwords |> J.to_string))
let check_storage_vector_sections () =
  let storage=Yojson.Basic.from_file "fixtures/storage.json" in
  let rails=Yojson.Basic.from_file "fixtures/rails_compat.json" in
  let secret=get "secret_key_base" rails |> J.to_string in
  let prefix=get "secret_key_base_prefix" storage |> J.to_string in
  Alcotest.(check string) "storage secret prefix" prefix
    (String.sub secret 0 (String.length prefix));
  let arguments=Storage_media.video_preview_arguments in
  let actual=match arguments with
    | ["-vf";filter;"-frames:v";frames;"-f";format] ->
        "-vf '"^filter^"' -frames:v "^frames^" -f "^format
    | _ -> Alcotest.fail "unexpected video preview argument shape" in
  Alcotest.(check string) "pinned ffmpeg preview argv"
    (get "video_preview_arguments" storage |> J.to_string) actual
let check_page_decision () =
  let missing=U.page_request None in
  Alcotest.(check bool) "no UA skips blocker" false missing.checked;
  Alcotest.(check bool) "no UA unblocked" false missing.blocked;
  Alcotest.(check string) "no UA defaults" "Mozilla" missing.view.browser;
  let old=U.page_request (Some "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15") in
  Alcotest.(check bool) "old Safari checked" true old.checked;
  Alcotest.(check bool) "old Safari blocked" true old.blocked;
  Alcotest.(check string) "Safari view" "Safari" old.view.browser;
  let blank=U.page_request (Some "\xe3\x80\x80") in
  Alcotest.(check bool) "Unicode whitespace skips blocker" false blank.checked;
  let bot=U.page_request (Some "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html) Chrome/1.0") in
  Alcotest.(check bool) "old bot allowed" false bot.blocked
let check_http_browser_guard () =
  let path=Filename.temp_file "m8-browser-" ".sqlite3" in
  let runtime=Db_runtime.open_db path in
  Fun.protect ~finally:(fun () -> Db_runtime.close runtime;Sys.remove path) (fun () ->
    let dispatch endpoint = if endpoint="sessions#new" then Some Http_app.{
      before_action=before ~access:Public ();
      action=(fun _ -> Lwt.return (text ~status:201 "action reached"))} else None in
    let send ?(accept="text/html") ?frame ua =
      let headers=["host","chat.example.test";"accept",accept;"user-agent",ua] @
        (match frame with None -> [] | Some value -> ["turbo-frame",value]) in
      let request=Cohttp.Request.make ~headers:(Cohttp.Header.of_list headers)
        (Uri.of_string "http://chat.example.test/session/new") in
      let response,body=Lwt_main.run (Http_app.handle ~runtime ~secret_key_base:"test-only"
        ~dispatch request Cohttp_lwt.Body.empty) in
      response,Lwt_main.run (Cohttp_lwt.Body.to_string body) in
    let old="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15" in
    let response,body=send ~accept:"application/json" old in
    Alcotest.(check int) "old browser renders 200 even for JSON accept" 200
      (Cohttp.Code.code_of_status (Cohttp.Response.status response));
    Alcotest.(check bool) "HTML content type" true
      (String.starts_with ~prefix:"text/html" (Option.value (Cohttp.Header.get (Cohttp.Response.headers response) "content-type") ~default:""));
    Alcotest.(check bool) "incompatible content" true (U.contains body "Upgrade to a supported web browser");
    Alcotest.(check bool) "browser assets" true (U.contains body "browsers/safari");
    let frame_response,frame_body=send ~frame:"browser_dialog" old in
    Alcotest.(check int) "frame blocked" 200 (Cohttp.Code.code_of_status (Cohttp.Response.status frame_response));
    Alcotest.(check bool) "frame layout" true (String.starts_with ~prefix:"<html>" frame_body);
    Alcotest.(check bool) "frame has no full layout" false (U.contains frame_body "<!DOCTYPE html>");
    let response,body=send "Chrome/140.0" in
    Alcotest.(check int) "current browser reaches action" 201
      (Cohttp.Code.code_of_status (Cohttp.Response.status response));
    Alcotest.(check string) "action result" "action reached" body)
let () = Alcotest.run "M8 user-agent corpus" [
  "agents",[Alcotest.test_case "385 complete cases" `Quick check_agents];
  "versions",[Alcotest.test_case "44 versions and 352 comparisons" `Quick check_versions];
  "page",[Alcotest.test_case "request decision and defaults" `Quick check_page_decision];
  "passwords",[Alcotest.test_case "40 pinned Rails bcrypt checks" `Quick check_password_vectors];
  "HTTP",[Alcotest.test_case "browser before action" `Quick check_http_browser_guard];
  "storage corpus",[Alcotest.test_case "uncovered metadata sections" `Quick check_storage_vector_sections]]

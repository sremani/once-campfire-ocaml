let vectors = Yojson.Basic.from_file "fixtures/campfire_routes.json"

let string_field json key = Yojson.Basic.Util.(json |> member key |> to_string)

let assoc_strings json =
  Yojson.Basic.Util.to_assoc json
  |> List.map (fun (key, value) -> (key, Yojson.Basic.Util.to_string value))
  |> List.sort compare

let test_inventory () =
  let open Yojson.Basic.Util in
  let expected = vectors |> member "routes" |> to_list in
  Alcotest.(check int) "route count" 177 (List.length Campfire.Route_catalog.routes);
  Alcotest.(check int) "fixture count" 177 (List.length expected);
  List.iter2 (fun (verb, path, endpoint, defaults) item ->
    let description = verb ^ " " ^ path in
    Alcotest.(check string) (description ^ " verb") (string_field item "verb") verb;
    Alcotest.(check string) (description ^ " path") (string_field item "path") path;
    Alcotest.(check string) (description ^ " endpoint") (string_field item "endpoint") endpoint;
    Alcotest.(check (list (pair string string))) (description ^ " defaults")
      (assoc_strings (member "defaults" item)) (List.sort compare defaults))
    Campfire.Route_catalog.routes expected

let test_recognitions () =
  let open Yojson.Basic.Util in
  let cases = vectors |> member "recognitions" |> to_list in
  Alcotest.(check int) "recognition count" 111 (List.length cases);
  List.iter (fun item ->
    let verb = string_field item "verb" in
    let path = string_field item "path" in
    let label = verb ^ " " ^ path in
    let expected_endpoint = match member "endpoint" item with
      | `Null -> None | `String value -> Some value | _ -> Alcotest.fail "bad endpoint fixture" in
    let actual = Campfire.Routes.recognize verb path in
    let actual_endpoint = Option.map (fun route -> route.Campfire.Routes.endpoint) actual in
    Alcotest.(check (option string)) (label ^ " endpoint") expected_endpoint actual_endpoint;
    match actual with
    | None -> Alcotest.(check (list (pair string string))) (label ^ " negative params") [] (assoc_strings (member "params" item))
    | Some route -> Alcotest.(check (list (pair string string))) (label ^ " params")
        (assoc_strings (member "params" item)) (List.sort compare route.Campfire.Routes.params)) cases

let test_controller_resolution_exception () =
  let route = Campfire.Routes.lookup_catalog "GET" "/rooms/1/settings" in
  let endpoint = Option.map (fun item -> item.Campfire.Routes.endpoint) route in
  Alcotest.(check (option string)) "catalog still declares settings"
    (Some "rooms/settings#show") endpoint;
  Alcotest.(check bool) "Rails recognize_path cannot resolve absent controller" true
    (Option.is_none (Campfire.Routes.recognize "GET" "/rooms/1/settings"))

let test_method_override () =
  let check label ?content_type ?form_method ?header_method method_ expected original =
    let actual = Campfire.Routes.effective_method ?content_type ?form_method ?header_method method_ in
    Alcotest.(check string) (label ^ " effective") expected actual.effective_method;
    Alcotest.(check (option string)) (label ^ " original") original actual.original_method
  in
  check "form patch" ~content_type:"application/x-www-form-urlencoded; charset=UTF-8" ~form_method:"patch" "POST" "PATCH" (Some "POST");
  check "multipart delete" ~content_type:"multipart/form-data; boundary=x" ~form_method:"delete" "POST" "DELETE" (Some "POST");
  check "related get" ~content_type:"multipart/related" ~form_method:"get" "POST" "GET" (Some "POST");
  check "mixed head" ~content_type:"multipart/mixed" ~form_method:"head" "POST" "HEAD" (Some "POST");
  check "no content type" ~form_method:"put" "POST" "PUT" (Some "POST");
  check "header fallback" ~header_method:"patch" "POST" "PATCH" (Some "POST");
  check "form precedence" ~form_method:"delete" ~header_method:"patch" "POST" "DELETE" (Some "POST");
  check "invalid form blocks header" ~form_method:"bogus" ~header_method:"patch" "POST" "POST" None;
  check "blank form blocks header" ~form_method:"" ~header_method:"patch" "POST" "POST" None;
  check "json form ignored" ~content_type:"application/json" ~form_method:"delete" "POST" "POST" None;
  check "json header allowed" ~content_type:"application/json" ~form_method:"delete" ~header_method:"patch" "POST" "PATCH" (Some "POST");
  check "invalid header" ~header_method:"TRACE" "POST" "POST" None;
  check "post override" ~header_method:"post" "POST" "POST" (Some "POST");
  check "non-post ignores override" ~header_method:"delete" "GET" "GET" None;
  check "case-insensitive media" ~content_type:"Application/X-WWW-Form-Urlencoded, other" ~form_method:"link" "POST" "LINK" (Some "POST");
  check "allowed unlink" ~header_method:"unlink" "POST" "UNLINK" (Some "POST");
  let selection, route = Campfire.Routes.recognize_request ~form_method:"delete" "POST" "/session" in
  Alcotest.(check string) "request method" "DELETE" selection.effective_method;
  Alcotest.(check (option string)) "request route" (Some "sessions#destroy")
    (Option.map (fun item -> item.Campfire.Routes.endpoint) route)

let test_path_helpers () =
  let module P = Campfire.Route_helpers in
  Alcotest.(check string) "root" "/" (P.root ());
  Alcotest.(check string) "first_run" "/first_run" (P.first_run ());
  Alcotest.(check string) "session" "/session" (P.session ());
  Alcotest.(check string) "new_session" "/session/new" (P.new_session ());
  Alcotest.(check string) "session_transfer" "/session/transfers/ID" (P.session_transfer "ID");
  Alcotest.(check string) "account" "/account" (P.account ());
  Alcotest.(check string) "edit_account" "/account/edit" (P.edit_account ());
  Alcotest.(check string) "account_users" "/account/users" (P.account_users ());
  Alcotest.(check string) "account_user" "/account/users/ID" (P.account_user "ID");
  Alcotest.(check string) "edit_account_user" "/account/users/ID/edit" (P.edit_account_user "ID");
  Alcotest.(check string) "account_bots" "/account/bots" (P.account_bots ());
  Alcotest.(check string) "new_account_bot" "/account/bots/new" (P.new_account_bot ());
  Alcotest.(check string) "account_bot" "/account/bots/ID" (P.account_bot "ID");
  Alcotest.(check string) "edit_account_bot" "/account/bots/ID/edit" (P.edit_account_bot "ID");
  Alcotest.(check string) "account_bot_key" "/account/bots/BOT_ID/key" (P.account_bot_key "BOT_ID");
  Alcotest.(check string) "account_join_code" "/account/join_code" (P.account_join_code ());
  Alcotest.(check string) "account_logo" "/account/logo" (P.account_logo ());
  Alcotest.(check string) "account_custom_styles" "/account/custom_styles" (P.account_custom_styles ());
  Alcotest.(check string) "edit_account_custom_styles" "/account/custom_styles/edit" (P.edit_account_custom_styles ());
  Alcotest.(check string) "join" "/join/JOIN_CODE" (P.join "JOIN_CODE");
  Alcotest.(check string) "qr_code" "/qr_code/ID" (P.qr_code "ID");
  Alcotest.(check string) "user" "/users/ID" (P.user "ID");
  Alcotest.(check string) "user_avatar" "/users/USER_ID/avatar" (P.user_avatar "USER_ID");
  Alcotest.(check string) "user_ban" "/users/USER_ID/ban" (P.user_ban "USER_ID");
  Alcotest.(check string) "user_sidebar" "/users/me/sidebar" (P.user_sidebar ());
  Alcotest.(check string) "user_profile" "/users/me/profile" (P.user_profile ());
  Alcotest.(check string) "edit_user_profile" "/users/me/profile/edit" (P.edit_user_profile ());
  Alcotest.(check string) "user_push_subscriptions" "/users/me/push_subscriptions" (P.user_push_subscriptions ());
  Alcotest.(check string) "user_push_subscription" "/users/me/push_subscriptions/ID" (P.user_push_subscription "ID");
  Alcotest.(check string) "user_push_subscription_test_notifications" "/users/me/push_subscriptions/PUSH_SUBSCRIPTION_ID/test_notifications" (P.user_push_subscription_test_notifications "PUSH_SUBSCRIPTION_ID");
  Alcotest.(check string) "autocompletable_users" "/autocompletable/users" (P.autocompletable_users ());
  Alcotest.(check string) "rooms" "/rooms" (P.rooms ());
  Alcotest.(check string) "new_room" "/rooms/new" (P.new_room ());
  Alcotest.(check string) "room" "/rooms/ID" (P.room "ID");
  Alcotest.(check string) "edit_room" "/rooms/ID/edit" (P.edit_room "ID");
  Alcotest.(check string) "room_messages" "/rooms/ROOM_ID/messages" (P.room_messages "ROOM_ID");
  Alcotest.(check string) "new_room_message" "/rooms/ROOM_ID/messages/new" (P.new_room_message "ROOM_ID");
  Alcotest.(check string) "room_message" "/rooms/ROOM_ID/messages/ID" (P.room_message "ROOM_ID" "ID");
  Alcotest.(check string) "edit_room_message" "/rooms/ROOM_ID/messages/ID/edit" (P.edit_room_message "ROOM_ID" "ID");
  Alcotest.(check string) "room_bot_messages" "/rooms/ROOM_ID/BOT_KEY/messages" (P.room_bot_messages "ROOM_ID" "BOT_KEY");
  Alcotest.(check string) "room_bot_message" "/rooms/ROOM_ID/BOT_KEY/messages/ID" (P.room_bot_message "ROOM_ID" "BOT_KEY" "ID");
  Alcotest.(check string) "room_bot_message_boosts" "/rooms/ROOM_ID/BOT_KEY/messages/MESSAGE_ID/boosts" (P.room_bot_message_boosts "ROOM_ID" "BOT_KEY" "MESSAGE_ID");
  Alcotest.(check string) "room_bot_message_boost" "/rooms/ROOM_ID/BOT_KEY/messages/MESSAGE_ID/boosts/ID" (P.room_bot_message_boost "ROOM_ID" "BOT_KEY" "MESSAGE_ID" "ID");
  Alcotest.(check string) "room_refresh" "/rooms/ROOM_ID/refresh" (P.room_refresh "ROOM_ID");
  Alcotest.(check string) "room_settings" "/rooms/ROOM_ID/settings" (P.room_settings "ROOM_ID");
  Alcotest.(check string) "room_involvement" "/rooms/ROOM_ID/involvement" (P.room_involvement "ROOM_ID");
  Alcotest.(check string) "room_at_message" "/rooms/ROOM_ID/@MESSAGE_ID" (P.room_at_message "ROOM_ID" "MESSAGE_ID");
  Alcotest.(check string) "rooms_opens" "/rooms/opens" (P.rooms_opens ());
  Alcotest.(check string) "new_rooms_open" "/rooms/opens/new" (P.new_rooms_open ());
  Alcotest.(check string) "rooms_open" "/rooms/opens/ID" (P.rooms_open "ID");
  Alcotest.(check string) "edit_rooms_open" "/rooms/opens/ID/edit" (P.edit_rooms_open "ID");
  Alcotest.(check string) "rooms_closeds" "/rooms/closeds" (P.rooms_closeds ());
  Alcotest.(check string) "new_rooms_closed" "/rooms/closeds/new" (P.new_rooms_closed ());
  Alcotest.(check string) "rooms_closed" "/rooms/closeds/ID" (P.rooms_closed "ID");
  Alcotest.(check string) "edit_rooms_closed" "/rooms/closeds/ID/edit" (P.edit_rooms_closed "ID");
  Alcotest.(check string) "rooms_directs" "/rooms/directs" (P.rooms_directs ());
  Alcotest.(check string) "new_rooms_direct" "/rooms/directs/new" (P.new_rooms_direct ());
  Alcotest.(check string) "rooms_direct" "/rooms/directs/ID" (P.rooms_direct "ID");
  Alcotest.(check string) "edit_rooms_direct" "/rooms/directs/ID/edit" (P.edit_rooms_direct "ID");
  Alcotest.(check string) "messages" "/messages" (P.messages ());
  Alcotest.(check string) "message" "/messages/ID" (P.message "ID");
  Alcotest.(check string) "edit_message" "/messages/ID/edit" (P.edit_message "ID");
  Alcotest.(check string) "message_boosts" "/messages/MESSAGE_ID/boosts" (P.message_boosts "MESSAGE_ID");
  Alcotest.(check string) "new_message_boost" "/messages/MESSAGE_ID/boosts/new" (P.new_message_boost "MESSAGE_ID");
  Alcotest.(check string) "message_boost" "/messages/MESSAGE_ID/boosts/ID" (P.message_boost "MESSAGE_ID" "ID");
  Alcotest.(check string) "searches" "/searches" (P.searches ());
  Alcotest.(check string) "clear_searches" "/searches/clear" (P.clear_searches ());
  Alcotest.(check string) "unfurl_link" "/unfurl_link" (P.unfurl_link ());
  Alcotest.(check string) "webmanifest" "/webmanifest" (P.webmanifest ());
  Alcotest.(check string) "service_worker" "/service-worker" (P.service_worker ());
  Alcotest.(check string) "rails_health_check" "/up" (P.rails_health_check ());
  Alcotest.(check string) "fresh user avatar" "/users/token/avatar?v=20240102030405"
    (P.fresh_user_avatar "token" "20240102030405");
  Alcotest.(check string) "fresh account logo default" "/account/logo" (P.fresh_account_logo ());
  Alcotest.(check string) "fresh account logo size" "/account/logo?size=128" (P.fresh_account_logo ~size:"128" ());
  Alcotest.(check string) "fresh account logo version" "/account/logo?v=20240102030405" (P.fresh_account_logo ~v:"20240102030405" ());
  Alcotest.(check string) "fresh account logo both" "/account/logo?size=128&v=20240102030405"
    (P.fresh_account_logo ~v:"20240102030405" ~size:"128" ())

let () = Alcotest.run "M1-T5 routes" [
  ("catalog", [Alcotest.test_case "full inventory" `Quick test_inventory;
                Alcotest.test_case "full recognitions" `Quick test_recognitions;
                Alcotest.test_case "controller resolution exception" `Quick test_controller_resolution_exception]);
  ("helpers", [Alcotest.test_case "all Rust helpers" `Quick test_path_helpers]);
  ("method override", [Alcotest.test_case "adapter semantics" `Quick test_method_override]);
]

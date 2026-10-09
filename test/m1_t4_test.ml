open Yojson.Basic.Util

let vectors = lazy (Yojson.Basic.from_file "fixtures/rails_compat.json")
let field value name = member name value
let str = to_string
let opt_str = function `String value -> Some value | `Null -> None | _ -> Alcotest.fail "expected nullable string"
let entries value = to_list value
let csrf () = field (Lazy.force vectors) "csrf"
let cookies () = field (Lazy.force vectors) "cookie_escaping"

let test_cookie_vectors () =
  cookies () |> entries |> List.iter (fun case ->
    let wire = str (field case "wire") in
    let parsed = str (field case "parsed") in
    (match opt_str (field case "raw") with
     | None -> ()
     | Some raw -> Alcotest.(check string) "Rack escape" wire (Campfire.Cookie_http.escape raw));
    Alcotest.(check string) "Rack unescape" parsed (Campfire.Cookie_http.unescape wire));
  let got = Campfire.Cookie_http.parse_headers ["a=1; b=x%20y+z;c=3; a=2; d"; "b=other; e=%zz"] in
  Alcotest.(check (list (pair string string))) "first wins across headers"
    ["a", "1"; "b", "x y z"; "c", "3"; "d", ""; "e", "%zz"] got;
  Alcotest.(check string) "bad UTF-8 preserved" "%FF" (Campfire.Cookie_http.unescape "%FF")

let time text = match Ptime.of_rfc3339 text with
  | Ok (value, _, _) -> value | Error _ -> Alcotest.fail ("invalid time " ^ text)

let test_cookie_jar () =
  let open Campfire.Cookie_http in
  let now = time "2024-06-01T12:00:00Z" in
  let jar = create ~headers:["last_room=42; token=old"] ~now in
  set jar "last_room" (cookie "42");
  Alcotest.(check (list string)) "unchanged omitted" [] (set_cookie_headers jar ~ssl:false ~host:"example.com");
  set jar "last_room" { (cookie "42") with permanent = true };
  Alcotest.(check (list string)) "calendar expiry"
    ["last_room=42; path=/; expires=Wed, 01 Jun 2044 12:00:00 GMT; samesite=lax"]
    (set_cookie_headers jar ~ssl:false ~host:"example.com");
  Alcotest.(check string) "leap day survives twenty calendar years"
    "2044-02-29T12:00:00Z"
    (Ptime.to_rfc3339 ~frac_s:0 ~tz_offset_s:0
       (permanent_expiry (time "2024-02-29T12:00:00Z")));
  set jar "x" { (cookie "a b+c/=") with domain = Some "example.com"; secure = true;
    httponly = true; same_site = Some Strict; partitioned = true };
  Alcotest.(check int) "secure dropped on plain HTTP" 1
    (List.length (set_cookie_headers jar ~ssl:false ~host:"example.com"));
  Alcotest.(check string) "secure attributes"
    "x=a+b%2Bc%2F%3D; domain=example.com; path=/; secure; httponly; samesite=strict; partitioned"
    (List.nth (set_cookie_headers jar ~ssl:true ~host:"example.com") 1);
  Alcotest.(check int) "onion exception" 2
    (List.length (set_cookie_headers jar ~ssl:false ~host:"chat.onion"));
  delete jar "missing";
  Alcotest.(check bool) "absent cookie deletion omitted" false (is_deleted jar "missing");
  delete jar "token";
  Alcotest.(check bool) "present cookie deletion" true (is_deleted jar "token");
  Alcotest.(check string) "deletion header"
    "token=; path=/; max-age=0; expires=Thu, 01 Jan 1970 00:00:00 GMT; samesite=lax"
    (List.hd (List.rev (set_cookie_headers jar ~ssl:true ~host:"example.com")));
  Alcotest.(check bool) "overflow boundary" true (Result.is_ok (check_overflow "x" (String.make 4095 'a')));
  Alcotest.(check bool) "overflow rejected" true (Result.is_error (check_overflow "x" (String.make 4096 'a')));
  let empty = create ~headers:[] ~now in
  set empty "s" { (cookie "1") with path = "/chat"; same_site = Some None_site };
  Alcotest.(check (list string)) "path and SameSite None"
    ["s=1; path=/chat; samesite=none"]
    (set_cookie_headers empty ~ssl:false ~host:"example.com");
  delete_with jar "last_room" { default_delete_options with path = "/chat"; domain = Some "example.com" };
  Alcotest.(check bool) "custom deletion options" true
    (List.mem "last_room=; domain=example.com; path=/chat; max-age=0; expires=Thu, 01 Jan 1970 00:00:00 GMT; samesite=lax"
      (set_cookie_headers jar ~ssl:true ~host:"example.com"))

let test_signed_headers () =
  let secret = field (Lazy.force vectors) "secret_key_base" |> str in
  field (Lazy.force vectors) "signed_cookies" |> fun signed -> field signed "generate" |> entries |> List.iter (fun case ->
    let name = str (field case "name") in
    let value = str (field case "value") in
    let expires = Option.map time (opt_str (field case "expires_at")) in
    let expected = str (field case "set_cookie") in
    let jar = Campfire.Cookie_http.create ~headers:[] ~now:(time "2026-01-01T12:00:00Z") in
    let c = { (Campfire.Cookie_http.cookie value) with expires;
      httponly = String.ends_with ~suffix:"; httponly; samesite=lax" expected } in
    (match Campfire.Cookie_http.set_signed jar ~secret_key_base:secret name c with
     | Ok () -> () | Error error -> Alcotest.fail error);
    Alcotest.(check (list string)) "signed Set-Cookie vector"
      [expected]
      (Campfire.Cookie_http.set_cookie_headers jar ~ssl:true ~host:"campfire.test"))

let test_csrf_vectors () =
  let v = csrf () in
  let session = field v "session_token" |> str in
  let global = Campfire.Csrf.global_token session |> Option.get in
  Alcotest.(check string) "global HMAC" (field v "global_token_hex" |> str)
    (Cstruct.of_string global |> Cstruct.to_hex_string);
  field v "global_tokens" |> entries |> List.iter (fun token ->
    let token = str token in
    let bytes = Campfire.Csrf.decode token |> Option.get in
    let pad = String.sub bytes 0 32 in
    Alcotest.(check string) "global mask reproduced" token
      (Campfire.Csrf.global_masked ~pad session |> Option.get);
    Alcotest.(check bool) "masked global" true
      (Campfire.Csrf.valid_token ~session_token:session ~token ~path:"/anything" ~method_:"POST"));
  field v "form_tokens" |> entries |> List.iter (fun case ->
    let page_path = field case "page_path" |> str in
    let action = field case "action" |> str in
    let method_ = field case "method" |> str in
    let path = Campfire.Csrf.form_action_path ~page_path action in
    Alcotest.(check string) ("action " ^ action)
      (field case "normalized_action_path" |> str) path;
    let raw = Campfire.Csrf.per_form_token session ~path ~method_ |> Option.get in
    Alcotest.(check string) ("per-form HMAC " ^ action)
      (field case "unmasked_hex" |> str)
      (Cstruct.of_string raw |> Cstruct.to_hex_string);
    Alcotest.(check bool) ("form token " ^ action) true
      (Campfire.Csrf.valid_token ~session_token:session ~token:(field case "token" |> str) ~path ~method_));
  let example = Campfire.Csrf.session_token () in
  Alcotest.(check int) "new session token has 32 bytes" 32
    (Campfire.Csrf.decode example |> Option.get |> String.length);
  field v "validity" |> entries |> List.iter (fun case ->
    Alcotest.(check bool) (field case "case" |> str)
      (field case "expected" |> to_bool)
      (Campfire.Csrf.valid_token ~session_token:session
         ~token:(field case "token" |> str)
         ~path:(field case "path" |> str) ~method_:(field case "method" |> str)))

let test_origin_vectors () =
  field (csrf ()) "origin" |> entries |> List.iter (fun case ->
    let origin = field case "origin" |> opt_str in
    let base_url = field case "base_url" |> str in
    let actual = Campfire.Csrf.valid_origin ~origin ~base_url in
    let expected = field case "expected" in
    let label = Option.value origin ~default:"(absent)" in
    (match expected, actual with
     | `Bool want, Ok got -> Alcotest.(check bool) label want got
     | `String "raises", Error _ -> ()
     | _ -> Alcotest.fail ("origin vector mismatch: " ^ label)))

let request ?origin ?site ?(ssl=true) ?(force_ssl=true) method_ =
  { Campfire.Csrf.method_; origin; base_url = "https://chat.example.com";
    sec_fetch_site = site; ssl; force_ssl; origin_check = true }

let test_csrf_http () =
  let open Campfire.Csrf in
  let accepted = function Ok _ -> true | Error _ -> false in
  List.iter (fun site -> Alcotest.(check bool) ("accepted " ^ site) true
    (verify_request (request ~site "POST") |> accepted)) ["same-origin"; "same-site"];
  List.iter (fun site ->
    let result = verify_request (request ?site "POST") in
    match result with
    | Ok _ -> Alcotest.fail "forged request accepted"
    | Error error ->
        Alcotest.(check int) "422" 422 error.status;
        Alcotest.(check bool) "no cookies on error" false error.commit_cookies)
    [Some "cross-site"; Some "none"; Some "bogus"; None];
  Alcotest.(check bool) "plain HTTP missing metadata" true
    (verify_request (request ~ssl:false ~force_ssl:false "POST") |> accepted);
  Alcotest.(check bool) "cross-site plain HTTP rejected" false
    (verify_request (request ~ssl:false ~force_ssl:false ~site:"cross-site" "POST") |> accepted);
  Alcotest.(check bool) "matching origin" true
    (verify_request (request ~origin:"https://chat.example.com" ~site:"same-origin" "POST") |> accepted);
  Alcotest.(check bool) "different origin" false
    (verify_request (request ~origin:"https://evil.example" ~site:"same-origin" "POST") |> accepted);
  Alcotest.(check bool) "null origin" false
    (verify_request (request ~origin:"null" ~site:"same-origin" "POST") |> accepted);
  let get_mark = verify_request (request "GET") |> Result.get_ok in
  Alcotest.(check bool) "GET marked" true get_mark;
  Alcotest.(check bool) "GET JavaScript non-XHR rejected" true
    (Result.is_error (verify_response ~marked_for_same_origin_verification:get_mark
      ~content_type:(Some "text/javascript; charset=utf-8") ~xhr:false));
  Alcotest.(check bool) "GET JavaScript XHR allowed" true
    (Result.is_ok (verify_response ~marked_for_same_origin_verification:get_mark
      ~content_type:(Some "application/javascript") ~xhr:true));
  Alcotest.(check bool) "GET HTML allowed" true
    (Result.is_ok (verify_response ~marked_for_same_origin_verification:get_mark
      ~content_type:(Some "text/html") ~xhr:false))

let () = Alcotest.run "M1-T4 HTTP compatibility" [
  "cookies", [
    Alcotest.test_case "Rack vectors" `Quick test_cookie_vectors;
    Alcotest.test_case "jar behavior" `Quick test_cookie_jar;
    Alcotest.test_case "signed headers" `Quick test_signed_headers];
  "csrf", [
    Alcotest.test_case "Rails vectors" `Quick test_csrf_vectors;
    Alcotest.test_case "Rails origin vectors" `Quick test_origin_vectors;
    Alcotest.test_case "HTTP policy" `Quick test_csrf_http]]

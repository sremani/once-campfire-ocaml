open Campfire
let check_ok label expected = function
  | Ok actual -> Alcotest.(check string) label expected actual
  | Error error -> Alcotest.failf "%s: %s" label error

let fixture_cases =
  let json = Yojson.Basic.from_file
    (if Sys.file_exists "fixtures/rich_text_expected.json"
     then "fixtures/rich_text_expected.json"
     else "test/fixtures/rich_text_expected.json") in
  Yojson.Basic.Util.(json |> member "cases" |> to_list)

let fixture_mentions =
  let fixture_file = if Sys.file_exists "fixtures/rich_text_expected.json"
    then "fixtures/rich_text_expected.json" else "test/fixtures/rich_text_expected.json" in
  let users = Yojson.Basic.Util.(Yojson.Basic.from_file fixture_file |> member "users" |> to_list) in
  let lookup = List.map (fun row ->
    let open Yojson.Basic.Util in
    let sgid = row |> member "attachable_sgid" |> to_string in
    sgid, { Rich_text.id=Int64.of_int (row |> member "id" |> to_int);
      name=row |> member "name" |> to_string;
      title=row |> member "title" |> to_string;
      attachable_sgid=sgid;
      user_path=row |> member "user_path" |> to_string;
      avatar_path=row |> member "avatar_path" |> to_string }) users in
  lookup

let fixture_resolver : Rich_text.resolver = fun sgid -> List.assoc_opt sgid fixture_mentions
let fixture_gid_resolver : Rich_text.gid_resolver = fun raw ->
  match Global_id.parse raw with
  | Some gid when gid.app = "campfire" && gid.model_name = "User" ->
    (match Int64.of_string_opt gid.id with
     | None -> None
     | Some id -> List.find_map (fun (_,user) -> if user.Rich_text.id = id then Some user else None) fixture_mentions)
  | _ -> None

let named name =
  match List.find_opt (fun c -> Yojson.Basic.Util.(c |> member "name" |> to_string) = name) fixture_cases with
  | None -> failwith ("missing fixture " ^ name)
  | Some c -> c

let get_string json key = Yojson.Basic.Util.(json |> member key |> to_string)
let case_host case = get_string case "host"
let expected case key =
  let value = Yojson.Basic.Util.(case |> member key |> member "ok") in
  match value with `String value -> Some value | `Null -> None | _ -> None

let test_corpus () =
  List.iter (fun name ->
    let case = named name in
    let body = get_string case "body" in
    (match expected case "presentation" with
     | Some target -> check_ok (name ^ " render") target (Rich_text.render ~resolve_sgid:fixture_resolver ~resolve_gid:fixture_gid_resolver ~request_host:(case_host case) body)
     | None -> ());
    (match expected case "plain_text" with
     | Some target -> check_ok (name ^ " plain") target (Rich_text.to_plain_text ~resolve_sgid:fixture_resolver ~resolve_gid:fixture_gid_resolver body)
     | None -> ());
    (match Rich_text.editable_value ~resolve_sgid:fixture_resolver ~resolve_gid:fixture_gid_resolver ~request_host:(case_host case) body, expected case "editable" with
     | Ok actual, target -> Alcotest.(check (option string)) (name ^ " editable") target actual
     | Error error, _ -> Alcotest.failf "%s editable: %s" name error))
    ["fixture first"; "empty body"; "plain text with markup characters";
     "lexxy paragraph"; "lexxy paragraphs"; "lexxy strong em";
     "lexxy link"; "trix plain div"; "autolink plain url";
     "autolink www"; "autolink existing link"; "autolink email";
     "lexxy numbered list"; "lexxy nested list"; "lexxy list with value";
     "xss script tag"; "xss svg onload"; "trix figure attachment";
     "lexxy mention"; "lexxy two mentions"; "unicode nbsp"]

let test_policy () =
  check_ok "unsafe href" "<a>x</a>" (Rich_text.sanitize "<a href='javascript:alert(1)' onclick='x'>x</a>");
  check_ok "foreign tree" "ok" (Rich_text.sanitize "<svg><script>alert(1)</script></svg>ok");
  check_ok "event handlers" "<span>safe</span>" (Rich_text.sanitize "<span onmouseover='x'>safe</span>");
  check_ok "safe href" "<a href=\"https://example.com/a?b=1&amp;c=2\">x</a>"
    (Rich_text.sanitize "<a href='https://example.com/a?b=1&amp;c=2'>x</a>");
  check_ok "encoded javascript separator" "<a>x</a>"
    (Rich_text.sanitize "<a href='javascript%3Aalert(1)'>x</a>");
  check_ok "safe highlight CSS" "<mark style=\"color: var(--highlight-1);background-color: var(--highlight-bg-2);\">x</mark>"
    (Rich_text.sanitize "<mark style='color: var(--highlight-1);background-color: var(--highlight-bg-2);'>x</mark>");
  check_ok "unsafe CSS stripped" "<span style=\"color: #f00;\">x</span>"
    (Rich_text.sanitize "<span style='color: #f00; background: url(javascript:x)'>x</span>");
  let injection = "<span title=\"a>b http://example.com/x <img src=x onerror=alert(1)>\">t</span>" in
  (match Rich_text.render injection with
   | Error e -> Alcotest.fail e
   | Ok html ->
     Alcotest.(check bool) "attribute text escaped" true
       (let needle = "&lt;img" in
        let rec contains i = i + String.length needle <= String.length html &&
          (String.sub html i (String.length needle) = needle || contains (i+1)) in contains 0))

let test_bounds () =
  let assert_error label body =
    match Rich_text.render body, Rich_text.to_plain_text body with
    | Error _, Error _ -> () | _ -> Alcotest.failf "%s was accepted" label in
  let deep = String.concat "" (List.init 401 (fun _ -> "<div>")) in
  assert_error "depth 401" deep;
  Alcotest.(check string) "message rescue" "" (Rich_text.present_message deep);
  assert_error "401 attributes" ("<p " ^ String.concat " " (List.init 401 (fun i -> Printf.sprintf "a%d=%d" i i)) ^ ">x</p>");
  assert_error "body size" (String.make (16*1024*1024 + 1) 'a');
  let started = Sys.time () in
  assert_error "80,000 nested elements" (String.concat "" (List.init 80_000 (fun _ -> "<div>")));
  Alcotest.(check bool) "deep input rejected quickly" true (Sys.time () -. started < 5.)

let test_autolink_scale () =
  let count = 4096 in
  let body = String.concat "" (List.init count (fun _ -> "<p>www.a.com</p>")) in
  let started = Sys.time () in
  let html = match Rich_text.render body with
    | Ok html -> html | Error error -> Alcotest.fail error in
  let needle = "href=\"http://www.a.com\"" in
  let rec count_at i total =
    if i + String.length needle > String.length html then total
    else if String.sub html i (String.length needle) = needle then
      count_at (i+String.length needle) (total+1)
    else count_at (i+1) total in
  Alcotest.(check int) "all domains linked" count (count_at 0 0);
  Alcotest.(check bool) "autolinking stays bounded" true (Sys.time () -. started < 5.)

let test_mentions () =
  let case = named "lexxy mention" in
  let body = get_string case "body" in
  (match expected case "plain_text" with
   | Some target -> check_ok "mention plain" target
      (Rich_text.to_plain_text ~resolve_sgid:fixture_resolver ~resolve_gid:fixture_gid_resolver body)
   | None -> Alcotest.fail "missing mention oracle");
  Alcotest.(check (list int64)) "mention IDs" [1L]
    (match Rich_text.mentioned_user_ids ~resolve_sgid:fixture_resolver body with
     | Ok ids -> ids | Error e -> Alcotest.fail e)

let test_og_corpus () =
  List.iter (fun name ->
    let case = named name in
    let body = get_string case "body" in
    (match expected case "presentation" with
     | Some target -> check_ok (name ^ " presentation") target
       (Rich_text.render ~resolve_sgid:fixture_resolver ~resolve_gid:fixture_gid_resolver ~request_host:(case_host case) body)
     | None -> Alcotest.fail "missing presentation oracle");
    (match expected case "plain_text" with
     | Some target -> check_ok (name ^ " plain") target
       (Rich_text.to_plain_text ~resolve_sgid:fixture_resolver ~resolve_gid:fixture_gid_resolver body)
     | None -> Alcotest.fail "missing plain oracle"))
    ["lexxy embed solo"; "lexxy embed with text"; "trix unfurl basecamp solo"]

let test_media_corpus () =
  List.iter (fun name ->
    let case = named name in
    let body = get_string case "body" in
    (match expected case "presentation" with
     | Some target -> check_ok (name ^ " presentation") target
       (Rich_text.render ~resolve_sgid:fixture_resolver ~resolve_gid:fixture_gid_resolver ~request_host:(case_host case) body)
     | None -> Alcotest.fail "missing presentation oracle");
    (match expected case "plain_text" with
     | Some target -> check_ok (name ^ " plain") target
       (Rich_text.to_plain_text ~resolve_sgid:fixture_resolver ~resolve_gid:fixture_gid_resolver body)
     | None -> Alcotest.fail "missing plain oracle"))
    ["remote image"; "remote image no caption"; "remote image rooted path";
     "remote video"; "remote video caption"]

let test_autolink_corpus () =
  let cases = List.filter (fun c ->
    String.starts_with ~prefix:"autolink " (get_string c "name")) fixture_cases in
  Alcotest.(check bool) "pinned autolink cases exist" true (List.length cases >= 20);
  List.iter (fun case ->
    match expected case "presentation" with
    | Some target -> check_ok (get_string case "name") target
      (Rich_text.render ~resolve_sgid:fixture_resolver ~resolve_gid:fixture_gid_resolver ~request_host:(case_host case) (get_string case "body"))
    | None -> Alcotest.fail "missing autolink oracle") cases

let test_malformed_tree_corpus () =
  List.iter (fun number ->
    let name=Printf.sprintf "fuzz %d" number in
    let case=named name in
    Alcotest.(check string) (name ^ " rescued presentation") ""
      (Rich_text.present_message ~resolve_sgid:fixture_resolver
        ~resolve_gid:fixture_gid_resolver ~request_host:(case_host case)
        (get_string case "body")))
    [45;97;125;144;177;210;216;230;274;294];
  List.iter (fun number ->
    let name=Printf.sprintf "fuzz %d" number in
    let case=named name in
    match Rich_text.editable_value ~resolve_sgid:fixture_resolver
      ~resolve_gid:fixture_gid_resolver ~request_host:(case_host case)
      (get_string case "body") with
    | Error error -> Alcotest.failf "%s: %s" name error
    | Ok actual -> Alcotest.(check (option string))
      (name ^ " HTML5 reparenting") (expected case "editable") actual)
    [43;331]

let scan () =
  let total = List.length fixture_cases in
  let count = ref 0 and render_ok = ref 0 and plain_ok = ref 0 and edit_ok = ref 0 in
  let core_total = ref 0 and core_render = ref 0 and core_plain = ref 0 and core_edit = ref 0 in
  List.iter (fun c ->
    let name = get_string c "name" and body = get_string c "body" in
    let core = not (String.starts_with ~prefix:"fuzz " name) in
    if core then incr core_total;
    let compare label expected actual hits =
      let passed = match expected, actual with
        | Some expected, Ok actual -> expected = actual
        | None, Error _ -> true
        | _ -> false in
      if passed then (incr hits;
        if core then (match label with "presentation" -> incr core_render
          | "plain" -> incr core_plain | _ -> incr core_edit))
      else if (Array.length Sys.argv > 1 && Sys.argv.(1) = "--scan-all") ||
              (Array.length Sys.argv > 1 && Sys.argv.(1) = "--scan-plain" && core && label = "plain") ||
              (Array.length Sys.argv > 1 && Sys.argv.(1) = "--scan-render" && core && label = "presentation") ||
              (Array.length Sys.argv > 1 && Sys.argv.(1) = "--scan-edit" && core && label = "editable") ||
              (!count < 30 && Sys.argv.(1) = "--scan")
      then (Printf.printf "%s: %s\n" name label; incr count) in
    let presentation =
      match expected c "presentation" with
      | Some _ -> Ok (Rich_text.present_message ~resolve_sgid:fixture_resolver
          ~resolve_gid:fixture_gid_resolver ~request_host:(case_host c) body)
      | None -> Rich_text.render ~resolve_sgid:fixture_resolver
          ~resolve_gid:fixture_gid_resolver ~request_host:(case_host c) body in
    compare "presentation" (expected c "presentation") presentation render_ok;
    compare "plain" (expected c "plain_text") (Rich_text.to_plain_text ~resolve_sgid:fixture_resolver ~resolve_gid:fixture_gid_resolver body) plain_ok;
    let editable = match Rich_text.editable_value ~resolve_sgid:fixture_resolver ~resolve_gid:fixture_gid_resolver ~request_host:(case_host c) body with
      | Error e -> Error e
      | Ok None -> Ok "<none>"
      | Ok (Some text) -> Ok text in
    let editable_expected =
      let result = Yojson.Basic.Util.(c |> member "editable") in
      if Yojson.Basic.Util.(result |> member "error") <> `Null then None
      else Some (Option.value (expected c "editable") ~default:"<none>") in
    compare "editable" editable_expected editable edit_ok)
    fixture_cases;
  Printf.printf "corpus %d: render %d, plain %d, editable %d\n"
    total !render_ok !plain_ok !edit_ok;
  Printf.printf "curated %d: render %d, plain %d, editable %d\n"
    !core_total !core_render !core_plain !core_edit

let dump_json () =
  let wrap = function
    | Ok value -> `Assoc ["ok",`String value]
    | Error error -> `Assoc ["error",`String error] in
  let cases = List.map (fun c ->
    let body = get_string c "body" in
    let host = case_host c in
    let presentation = Rich_text.render ~resolve_sgid:fixture_resolver
      ~resolve_gid:fixture_gid_resolver ~request_host:host body in
    let plain = Rich_text.to_plain_text ~resolve_sgid:fixture_resolver
      ~resolve_gid:fixture_gid_resolver body in
    let editable = Rich_text.editable_value ~resolve_sgid:fixture_resolver
      ~resolve_gid:fixture_gid_resolver ~request_host:host body
      |> Result.map (Option.value ~default:"<none>") in
    `Assoc ["name",`String (get_string c "name");
      "presentation",wrap presentation; "plain_text",wrap plain;
      "editable",wrap editable]) fixture_cases in
  print_endline (Yojson.Basic.to_string (`List cases))

let () = if Array.length Sys.argv > 2 && Sys.argv.(1) = "--case" then (
  let c = named Sys.argv.(2) in
  let body = get_string c "body" in
  let report label actual = match actual with
    | Ok value -> Printf.printf "%s actual: %S\n" label value
    | Error e -> Printf.printf "%s error: %s\n" label e in
  report "presentation" (Rich_text.render ~resolve_sgid:fixture_resolver ~resolve_gid:fixture_gid_resolver ~request_host:(case_host c) body);
  report "plain" (Rich_text.to_plain_text ~resolve_sgid:fixture_resolver ~resolve_gid:fixture_gid_resolver body);
  report "editable" (Result.map (Option.value ~default:"<none>")
    (Rich_text.editable_value ~resolve_sgid:fixture_resolver ~resolve_gid:fixture_gid_resolver ~request_host:(case_host c) body)))
else if Array.length Sys.argv > 1 &&
  List.mem Sys.argv.(1) ["--scan"; "--scan-all"; "--scan-plain"; "--scan-render"; "--scan-edit"] then scan ()
else if Array.length Sys.argv > 1 && Sys.argv.(1) = "--dump-json" then dump_json ()
else Alcotest.run "M4-T3 Action Text" [
  "Rails corpus", [Alcotest.test_case "basic vectors" `Quick test_corpus];
  "security", [Alcotest.test_case "safe HTML policy" `Quick test_policy;
                 Alcotest.test_case "parser bounds" `Quick test_bounds;
                 Alcotest.test_case "autolink scale" `Quick test_autolink_scale];
  "attachments", [Alcotest.test_case "SGID mention" `Quick test_mentions]
  ; "opengraph", [Alcotest.test_case "Rails render/plain" `Quick test_og_corpus]
  ; "media", [Alcotest.test_case "Rails render/plain" `Quick test_media_corpus]
  ; "autolink", [Alcotest.test_case "Rails full curated set" `Quick test_autolink_corpus]
  ; "malformed", [Alcotest.test_case "attachment and HTML5 trees" `Quick
      test_malformed_tree_corpus]
]

let vectors = lazy (Yojson.Basic.from_file "fixtures/rails_compat.json")
open Yojson.Basic.Util

let field value name = member name value
let string value = to_string value
let nullable_string = function `String s -> Some s | `Null -> None | _ -> invalid_arg "string or null"
let list value = to_list value
let secret () = string (field (Lazy.force vectors) "secret_key_base")
let rotated_secret () = string (field (Lazy.force vectors) "rotated_secret_key_base")
let fixture name = field (Lazy.force vectors) name

let check_option name expected actual =
  if expected <> actual then
    Alcotest.failf "%s: expected %s; got %s" name
      (match expected with None -> "none" | Some x -> x)
      (match actual with None -> "none" | Some x -> x)

let test_signed_generation () =
  fixture "signed_ids" |> fun v -> field v "generate" |> list |> List.iter (fun case ->
    let model = field case "model" |> string in
    let id = field case "id" |> to_int in
    let purpose = field case "purpose" |> nullable_string in
    let expires_at = field case "expires_at" |> nullable_string in
    let actual = Campfire.Signed_id.generate ~secret_key_base:(secret ())
      ~model ~id ~purpose ~expires_at in
    Alcotest.(check string) (model ^ " " ^ string_of_int id)
      (field case "signed_id" |> string) actual)

let test_signed_verification () =
  fixture "signed_ids" |> fun v -> field v "verify" |> list |> List.iter (fun case ->
    let model = field case "model" |> string in
    let purpose = field case "purpose" |> nullable_string in
    let raw = field case "signed_id" |> string in
    let now = field case "now" |> string in
    let expected = match field case "expected" with
      | `Null -> None | `Int i -> Some i | `String s -> Some (int_of_string s)
      | _ -> Alcotest.fail "unexpected signed ID fixture" in
    let actual = Campfire.Signed_id.verify ~secret_key_base:(secret ())
      ~model ~raw ~purpose ~now () in
    Alcotest.(check (option int)) (field case "case" |> string) expected actual)

let test_global_ids () =
  fixture "global_ids" |> list |> List.iter (fun case ->
    let gid = Campfire.Global_id.make
      ~model_name:(field case "model_name" |> string)
      ~id:(field case "id" |> string) in
    let raw = field case "gid" |> string in
    let param = field case "param" |> string in
    Alcotest.(check string) "gid string" raw (Campfire.Global_id.to_string gid);
    Alcotest.(check string) "gid param" param (Campfire.Global_id.to_param gid);
    Alcotest.(check bool) "gid parse" true (Campfire.Global_id.parse raw = Some gid);
    Alcotest.(check bool) "gid from param" true (Campfire.Global_id.from_param param = Some gid));
  Alcotest.(check bool) "missing ID" true
    (Campfire.Global_id.parse "gid://campfire/User" = None);
  Alcotest.(check bool) "query dropped" true
    (Campfire.Global_id.parse "gid://campfire/User/1?expires_in" =
      Some (Campfire.Global_id.make ~model_name:"User" ~id:"1"))

let test_sgid_generation () =
  fixture "sgids" |> fun v -> field v "generate" |> list |> List.iter (fun case ->
    let gid = field case "gid" |> string |> Campfire.Global_id.parse |> Option.get in
    let purpose = field case "purpose" |> string in
    let expires_at = field case "expires_at" |> nullable_string in
    let data = field case "data" |> string in
    let actual =
      if String.ends_with ~suffix:"?expires_in" data then
        Campfire.Global_id.attachable_sgid ~secret_key_base:(secret ()) ~gid
      else Campfire.Global_id.sgid ~secret_key_base:(secret ()) ~gid ~purpose ~expires_at in
    Alcotest.(check string) data (field case "sgid" |> string) actual)

let test_sgid_verification () =
  fixture "sgids" |> fun v -> field v "verify" |> list |> List.iter (fun case ->
    let raw = field case "sgid" |> string in
    let purpose = field case "purpose" |> string in
    let now = field case "now" |> string in
    let expected = Option.bind (nullable_string (field case "expected"))
      Campfire.Global_id.parse in
    let actual = Campfire.Global_id.locate_signed
      ~secret_key_base:(secret ()) ~raw ~purpose ~now () in
    Alcotest.(check bool) (field case "case" |> string) true (expected = actual))

let test_turbo_generation () =
  fixture "turbo_stream_names" |> fun v -> field v "generate" |> list |> List.iter (fun case ->
    let parts = field case "parts" |> list |> List.map string in
    Alcotest.(check string) "joined stream name"
      (field case "stream_name" |> string) (Campfire.Turbo_stream.stream_name parts);
    Alcotest.(check string) "signed stream"
      (field case "signed" |> string)
      (Campfire.Turbo_stream.signed_stream_name ~secret_key_base:(secret ()) parts))

let test_turbo_verification () =
  fixture "turbo_stream_names" |> fun v -> field v "verify" |> list |> List.iter (fun case ->
    let expected = match field case "expected" with
      | `Null -> None | `String s -> Some s | `Int i -> Some (string_of_int i)
      | _ -> Alcotest.fail "unexpected Turbo fixture" in
    let actual = Campfire.Turbo_stream.verified_stream_name
      ~secret_key_base:(secret ()) (field case "signed" |> string) in
    check_option (field case "case" |> string) expected actual)

let test_app_verifier_generation () =
  fixture "app_verifiers" |> fun v -> field v "generate" |> list |> List.iter (fun case ->
    let name = field case "name" |> string in
    let data_json = field case "data_json" |> string in
    let purpose = field case "purpose" |> nullable_string in
    let expires_at = field case "expires_at" |> nullable_string in
    let actual = Campfire.App_verifier.generate_raw ~secret_key_base:(secret ())
      ~name ~data_json ~purpose ~expires_at in
    Alcotest.(check string) (name ^ " " ^ data_json)
      (field case "message" |> string) actual)

let test_app_verifier_verification () =
  fixture "app_verifiers" |> fun v -> field v "verify" |> list |> List.iter (fun case ->
    let name = field case "name" |> string in
    let raw = field case "message" |> string in
    let purpose = field case "purpose" |> nullable_string in
    let now = field case "now" |> string in
    let expected = field case "expected_json" |> nullable_string in
    let actual = Campfire.App_verifier.verify_raw ~secret_key_base:(secret ())
      ~name ~raw ~purpose ~now () in
    check_option (field case "case" |> string) expected actual)

let test_unverified_sgid_rejection () =
  let dangerous_cases = [
    "tampered user sgid"; "no signature part"; "standard base64 payload";
    "envelope without data or message"; "not an envelope"; "not a gid";
    "empty"; "not json"; "not base64"; "json array";
  ] in
  let cases = fixture "unverified_sgids" |> list in
  List.iter (fun name ->
    let case = List.find (fun c -> field c "case" = `String name) cases in
    let raw = field case "sgid" |> string in
    Alcotest.(check bool) name true
      (Campfire.Global_id.locate_signed ~secret_key_base:(secret ())
         ~raw ~purpose:"attachable" ~now:"2026-01-01T12:00:00.000Z" () = None))
    dangerous_cases

let test_rotations () =
  let now = "2026-01-01T12:00:00.000Z" in
  let signed = fixture "signed_ids" |> fun v -> field v "verify" |> list
    |> List.find (fun c -> field c "case" = `String "signed with rotated secret")
    |> fun c -> field c "signed_id" |> string in
  Alcotest.(check (option int)) "signed ID rotation" (Some 1)
    (Campfire.Signed_id.verify ~secret_key_base:(secret ())
      ~rotated_secret_key_bases:[rotated_secret ()] ~model:"User" ~raw:signed
      ~purpose:(Some "avatar") ~now ());
  let sgid = fixture "sgids" |> fun v -> field v "verify" |> list
    |> List.find (fun c -> field c "case" = `String "signed with rotated secret")
    |> fun c -> field c "sgid" |> string in
  Alcotest.(check bool) "SGID rotation" true
    (Campfire.Global_id.locate_signed ~secret_key_base:(secret ())
       ~rotated_secret_key_bases:[rotated_secret ()] ~raw:sgid
       ~purpose:"attachable" ~now () =
       Some (Campfire.Global_id.make ~model_name:"User" ~id:"1"));
  let turbo = fixture "turbo_stream_names" |> fun v -> field v "verify" |> list
    |> List.find (fun c -> field c "case" = `String "signed with rotated secret")
    |> fun c -> field c "signed" |> string in
  check_option "Turbo rotation" (Some "rooms")
    (Campfire.Turbo_stream.verified_stream_name ~secret_key_base:(secret ())
       ~rotated_secret_key_bases:[rotated_secret ()] turbo);
  let expiring_id = Campfire.Signed_id.generate
      ~secret_key_base:(rotated_secret ()) ~model:"User" ~id:7
      ~purpose:(Some "transfer") ~expires_at:(Some "2026-01-01T13:00:00.000Z") in
  let verify_id ~purpose ~now = Campfire.Signed_id.verify
      ~secret_key_base:(secret ()) ~rotated_secret_key_bases:[rotated_secret ()]
      ~model:"User" ~raw:expiring_id ~purpose ~now () in
  Alcotest.(check (option int)) "old key before expiry" (Some 7)
    (verify_id ~purpose:(Some "transfer") ~now);
  Alcotest.(check (option int)) "old key wrong purpose" None
    (verify_id ~purpose:(Some "avatar") ~now);
  Alcotest.(check (option int)) "old key at expiry" None
    (verify_id ~purpose:(Some "transfer") ~now:"2026-01-01T13:00:00.000Z");
  let gid = Campfire.Global_id.make ~model_name:"User" ~id:"7" in
  let expiring_sgid = Campfire.Global_id.sgid
      ~secret_key_base:(rotated_secret ()) ~gid ~purpose:"attachable"
      ~expires_at:(Some "2026-01-01T13:00:00.000Z") in
  let locate ~purpose ~now = Campfire.Global_id.locate_signed
      ~secret_key_base:(secret ()) ~rotated_secret_key_bases:[rotated_secret ()]
      ~raw:expiring_sgid ~purpose ~now () in
  Alcotest.(check bool) "old SGID before expiry" true
    (locate ~purpose:"attachable" ~now = Some gid);
  Alcotest.(check bool) "old SGID wrong purpose" true
    (locate ~purpose:"default" ~now = None);
  Alcotest.(check bool) "old SGID at expiry" true
    (locate ~purpose:"attachable" ~now:"2026-01-01T13:00:00.000Z" = None)

let test_reject_forgery () =
  let now = "2026-01-01T12:00:00.000Z" in
  let attacker = "attacker-key" in
  let forged_signed = Campfire.Signed_id.generate ~secret_key_base:attacker
    ~model:"User" ~id:1 ~purpose:(Some "avatar") ~expires_at:None in
  Alcotest.(check (option int)) "forged signed ID" None
    (Campfire.Signed_id.verify ~secret_key_base:(secret ()) ~model:"User"
       ~raw:forged_signed ~purpose:(Some "avatar") ~now ());
  let gid = Campfire.Global_id.make ~model_name:"User" ~id:"1" in
  let forged_sgid = Campfire.Global_id.sgid ~secret_key_base:attacker ~gid
      ~purpose:"attachable" ~expires_at:None in
  Alcotest.(check bool) "forged SGID" true
    (Campfire.Global_id.locate_signed ~secret_key_base:(secret ())
       ~raw:forged_sgid ~purpose:"attachable" ~now () = None);
  let forged_turbo = Campfire.Turbo_stream.signed_stream_name
      ~secret_key_base:attacker ["rooms"] in
  check_option "forged Turbo" None
    (Campfire.Turbo_stream.verified_stream_name
       ~secret_key_base:(secret ()) forged_turbo)

let () = Alcotest.run "signed identifiers" [
  "signed IDs", [
    Alcotest.test_case "generate upstream vectors" `Quick test_signed_generation;
    Alcotest.test_case "verify upstream vectors" `Quick test_signed_verification;
  ];
  "GlobalIDs", [Alcotest.test_case "upstream vectors" `Quick test_global_ids];
  "SGIDs", [
    Alcotest.test_case "generate upstream vectors" `Quick test_sgid_generation;
    Alcotest.test_case "verify upstream vectors" `Quick test_sgid_verification;
  ];
  "Turbo", [
    Alcotest.test_case "generate upstream vectors" `Quick test_turbo_generation;
    Alcotest.test_case "verify upstream vectors" `Quick test_turbo_verification;
  ];
  "app verifiers", [
    Alcotest.test_case "generate upstream vectors" `Quick test_app_verifier_generation;
    Alcotest.test_case "verify upstream vectors" `Quick test_app_verifier_verification;
  ];
  "security", [
    Alcotest.test_case "explicit key rotations" `Quick test_rotations;
    Alcotest.test_case "reject forged tokens" `Quick test_reject_forgery;
    Alcotest.test_case "reject unverified SGID forms" `Quick test_unverified_sgid_rejection;
  ];
]

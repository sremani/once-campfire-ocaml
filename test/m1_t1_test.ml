let get j k = Yojson.Safe.Util.member k j
let str = Yojson.Safe.Util.to_string
let list = Yojson.Safe.Util.to_list
let required j k = str (get j k)
let option f = function `Null -> None | x -> Some (f x)
let read () = Yojson.Safe.from_file "fixtures/ruby_core.json"

let failures = ref []
let check label expected actual =
  if expected <> actual then
    failures := (Printf.sprintf "%s: expected %S, got %S" label expected actual) :: !failures
let check_value label expected actual =
  if expected <> actual then failures := (label ^ ": mismatch") :: !failures
let finish () = match List.rev !failures with
  | [] -> ()
  | xs -> Alcotest.failf "%d mismatches:\n%s" (List.length xs) (String.concat "\n" (List.filteri (fun i _ -> i < 30) xs))

let test_string_vectors () =
  failures := [];
  read () |> fun data -> get data "strings" |> list |> List.iteri (fun i v ->
    let input = required v "input" and label = string_of_int i in
    check (label ^ " strip") (required v "strip") (Campfire.Ruby_compat.strip input);
    check (label ^ " html") (required v "html_escape") (Campfire.Ruby_compat.html_escape input);
    check (label ^ " cgi") (required v "cgi_escape") (Campfire.Ruby_compat.cgi_escape input);
    check (label ^ " url") (required v "url_encode") (Campfire.Ruby_compat.url_encode input);
    check (label ^ " rack") (required v "rack_escape") (Campfire.Ruby_compat.rack_escape input);
    let expected_int = try Int64.of_string (required v "to_i") with _ ->
      if String.starts_with ~prefix:"-" (required v "to_i") then Int64.min_int else Int64.max_int in
    check (label ^ " int") (Int64.to_string expected_int) (Int64.to_string (Campfire.Ruby_compat.to_i input));
    check_value (label ^ " integer cast")
      (option (fun x -> try Some (Int64.of_string (str x)) with _ -> None) (get v "integer_cast") |> Option.join)
      (Campfire.Ruby_compat.integer_cast input);
    let expected = required v "to_f" in
    let expected = if expected = "Infinity" then infinity else if expected = "-Infinity" then neg_infinity else float_of_string expected in
    let actual = Campfire.Ruby_compat.to_f input in
    if Int64.bits_of_float expected <> Int64.bits_of_float actual then
      failures := (Printf.sprintf "%s float %S: expected %s got %.17g" label input
        (required v "to_f") actual) :: !failures);
  finish ()

let test_float_vectors () =
  failures := [];
  read () |> fun data -> get data "floats" |> list |> List.iteri (fun i v ->
    let bits = Int64.of_string ("0x" ^ required v "bits") in
    let actual = Campfire.Ruby_compat.float_to_s (Int64.float_of_bits bits) in
    check (string_of_int i ^ " float_to_s") (required v "to_s") actual);
  finish ()

let test_ranges () =
  failures := [];
  read () |> fun data -> get data "byte_ranges" |> list |> List.iteri (fun i v ->
    let header = option str (get v "header") in
    let size = Int64.of_int (Yojson.Safe.Util.to_int (get v "size")) in
    let expected = option (fun x -> list x |> List.map (fun pair ->
      match list pair with [a;b] -> (Int64.of_int (Yojson.Safe.Util.to_int a), Int64.of_int (Yojson.Safe.Util.to_int b))
      | _ -> failwith "bad range fixture")) (get v "ranges") in
    check_value (string_of_int i ^ " ranges") expected (Campfire.Ruby_compat.byte_ranges header size));
  finish ()

let parse_time s = match Ptime.of_rfc3339 s with Ok (t,_,_) -> t | Error _ -> failwith s

let test_rails_format () =
  let module F = Campfire.Rails_format in
  Alcotest.(check (option string)) "marshal string"
    (Some "gid://campfire/User/1")
    (F.load_marshaled_string "\004\008I\"\026gid://campfire/User/1\006:\006ET");
  Alcotest.(check (option string)) "marshal wrong type" None (F.load_marshaled_string "\004\008i\006");
  List.iter (fun (name, payload) ->
    Alcotest.(check (option string)) name None (F.load_marshaled_string payload)) [
      "marshal truncated signature", "\004";
      "marshal truncated length", "\004\008\"\002\044";
      "marshal negative length", "\004\008\"\250";
      "marshal truncated data", "\004\008\"\008ab";
      "marshal wrong signature", "\004\007\"\006x";
    ];
  Alcotest.(check (option string)) "urlsafe unpadded" (Some "A") (F.urlsafe_decode "QQ");
  Alcotest.(check (option string)) "urlsafe partial pad" None (F.urlsafe_decode "QQ=");
  Alcotest.(check (option string)) "urlsafe mixed alphabets" (Some "\251\239\255") (F.urlsafe_decode "++__");
  List.iter (fun s -> Alcotest.(check (option string)) ("strict base64 " ^ s) None (F.strict_decode s))
    ["QQ"; "QQ="; "QR=="; "QQ==\n"; "QQ==="];
  Alcotest.(check string) "json escaping"
    "{\"key\":\"\\u003c/\\u003e\\u0026\"}"
    (F.encode (`Assoc ["key", `String "</>&"]));
  Alcotest.(check string) "JSON control and separators"
    "\"\\u001f\\n\\t\\b\\f\127é\226\128\168\""
    (F.generate (`String "\031\n\t\b\012\127é\226\128\168"));
  Alcotest.(check bool) "invalid JSON" true (F.parse "{broken" = None);
  Alcotest.(check bool) "invalid UTF-8 JSON" true (F.parse "\"\255\"" = None);
  Alcotest.(check bool) "invalid UTF-8 null serializer" true
    (F.load F.Null "\255" = Error F.Invalid_message);
  Alcotest.(check string) "json float" "[0.00001,1e+15,-0.0]"
    (F.generate (`List [`Float 1e-5; `Float 1e15; `Float (-0.)]));
  List.iter (fun (f, expected) -> Alcotest.(check string) ("JSON float " ^ expected) expected
    (F.generate (`Float f))) [
      320., "320.0"; 1.25e-5, "0.0000125"; 1e-7, "0.0000001";
      1e-10, "1e-10"; 1e14, "100000000000000.0";
      123456789012345.6, "123456789012345.6";
      1.5e15, "1.5e+15"; 1e16, "1e+16";
      5e-324, "5e-324";
    ];
  let expires_at = parse_time "2046-01-01T12:00:00.123999Z" in
  let now = parse_time "2046-01-01T12:00:00Z" in
  let serialized = F.serialize_with_metadata F.Json (`String "<id>")
    ~purpose:(Some "attachable") ~expires_at:(Some expires_at) in
  Alcotest.(check string) "metadata JSON"
    "{\"_rails\":{\"data\":\"<id>\",\"exp\":\"2046-01-01T12:00:00.123Z\",\"pur\":\"attachable\"}}"
    serialized;
  Alcotest.(check bool) "metadata decode" true
    (F.deserialize_with_metadata F.Json serialized ~purpose:(Some "attachable") ~now
       ~decode_legacy_message:F.strict_decode = Ok (`String "<id>"));
  Alcotest.(check bool) "metadata expiry" true
    (F.deserialize_with_metadata F.Json serialized ~purpose:(Some "attachable") ~now:expires_at
       ~decode_legacy_message:F.strict_decode = Error F.Expired);
  Alcotest.(check bool) "metadata purpose" true
    (F.deserialize_with_metadata F.Json serialized ~purpose:(Some "different") ~now
       ~decode_legacy_message:F.strict_decode = Error F.Purpose_mismatch);
  let decode bytes = F.deserialize_with_metadata F.Json bytes ~purpose:(Some "attachable") ~now
      ~decode_legacy_message:F.strict_decode in
  Alcotest.(check bool) "malformed metadata" true
    (decode "{\"_rails\":3}" = Error F.Invalid_message);
  Alcotest.(check bool) "wrong expiry type" true
    (decode "{\"_rails\":{\"data\":1,\"exp\":42,\"pur\":\"attachable\"}}" = Error F.Invalid_message);
  Alcotest.(check bool) "invalid expiry timestamp" true
    (decode "{\"_rails\":{\"data\":1,\"exp\":\"tomorrow\",\"pur\":\"attachable\"}}" = Error F.Invalid_message);
  Alcotest.(check bool) "missing purpose" true
    (decode "{\"_rails\":{\"data\":1}}" = Error F.Purpose_mismatch);
  Alcotest.(check bool) "plain value with purpose" true
    (decode "42" = Error F.Purpose_mismatch);
  Alcotest.(check bool) "invalid JSON payload" true
    (decode "{broken" = Error F.Invalid_message);
  let legacy = F.serialize_with_metadata F.Null (`String "hello")
    ~purpose:(Some "p") ~expires_at:None in
  Alcotest.(check bool) "legacy envelope" true
    (F.deserialize_with_metadata F.Null legacy ~purpose:(Some "p") ~now
       ~decode_legacy_message:F.strict_decode = Ok (`String "hello"));
  Alcotest.(check bool) "legacy bad Base64" true
    (F.deserialize_with_metadata F.Null "{\"_rails\":{\"message\":\"QR==\",\"pur\":\"p\"}}"
       ~purpose:(Some "p") ~now ~decode_legacy_message:F.strict_decode = Error F.Invalid_signature);
  let marshaled = "\004\008I\"\010hello\006:\006ET" in
  Alcotest.(check bool) "Marshal fallback allowed" true
    (F.load (F.Json_with_fallback {allow_marshal=true}) marshaled = Ok (`String "hello"));
  Alcotest.(check bool) "Marshal fallback denied" true
    (F.load (F.Json_with_fallback {allow_marshal=false}) marshaled = Error F.Invalid_message);
  Alcotest.(check bool) "Marshal fallback replaces invalid UTF-8" true
    (F.load (F.Json_with_fallback {allow_marshal=true}) "\004\008\"\006\255" = Ok (`String "\239\191\189"))

let () = Alcotest.run "M1 T1 formats" [
  "ruby", [
    Alcotest.test_case "strings and numbers" `Quick test_string_vectors;
    Alcotest.test_case "float formatting" `Quick test_float_vectors;
    Alcotest.test_case "Rack byte ranges" `Quick test_ranges;
  ];
  "rails", [Alcotest.test_case "JSON, Marshal, Base64, metadata" `Quick test_rails_format]
]

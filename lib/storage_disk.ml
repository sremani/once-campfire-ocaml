(** Active Storage's local disk service and signed disk routes. File operations run
    outside the SQLite writer. A caller must [keep] a staged object only after its
    row transaction commits; [with_staged] removes the file on every other exit. *)

type t = { root : string; name : string }
type disk_key = { key : string; disposition : string; content_type : string option;
                  service_name : string }
type disk_token = { key : string; content_type : string option;
                    content_length : int64; checksum : string; service_name : string }
type staged = { service : t; key : string; mutable kept : bool }

exception Integrity
exception Invalid_key

let create ~root ~name = { root; name }
let generate_key () =
  let alphabet = "0123456789abcdefghijklmnopqrstuvwxyz" in
  let out = Bytes.create 28 in
  let rec fill position =
    if position < 28 then begin
      let random = Secure_random.bytes 64 in
      let rec consume index position =
        if position=28 || index=String.length random then position else
        let value=Char.code random.[index] in
        if value<252 then begin
          Bytes.set out position alphabet.[value mod 36];
          consume (index+1) (position+1)
        end else consume (index+1) position in
      fill (consume 0 position)
    end in
  fill 0; Bytes.to_string out

let valid_key key =
  String.length key >= 4 && String.for_all (function
    | '0'..'9' | 'a'..'z' -> true | _ -> false) key

let path_for service key =
  if not (valid_key key) then raise Invalid_key;
  Filename.concat (Filename.concat
    (Filename.concat service.root (String.sub key 0 2))
    (String.sub key 2 2)) key

let checksum_file path = Base64.encode_string (Digest.file path)
let checksum_bytes bytes = Base64.encode_string (Digest.string bytes)

let rec mkdir_p path =
  if path = "." || path = "/" || path = "" then ()
  else if Sys.file_exists path then ()
  else (mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST,_,_) when Sys.is_directory path -> ())

let copy_file ~source ~target =
  let input_channel = open_in_bin source in
  Fun.protect ~finally:(fun () -> close_in_noerr input_channel) (fun () ->
    let output_channel = open_out_bin target in
    Fun.protect ~finally:(fun () -> close_out_noerr output_channel) (fun () ->
      let buffer = Bytes.create (1024 * 1024) in
      let rec loop () =
        let count = input input_channel buffer 0 (Bytes.length buffer) in
        if count <> 0 then (output output_channel buffer 0 count; loop ()) in
      loop ()))

let delete service key =
  let path = path_for service key in
  try Sys.remove path with Sys_error _ when not (Sys.file_exists path) -> ()

let delete_legacy_variants service key =
  if not (valid_key key) then raise Invalid_key;
  let path=Filename.concat service.root
    (Filename.concat "va" (Filename.concat "ri"
      (Filename.concat "variants" key))) in
  let rec remove path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Array.iter (fun item -> remove (Filename.concat path item))
          (Sys.readdir path);
        Unix.rmdir path
      end else Sys.remove path in
  remove path

let exists service key = Sys.file_exists (path_for service key)

let upload_file service ~key ~source ?checksum () =
  let destination = path_for service key in
  mkdir_p (Filename.dirname destination);
  let temp = destination ^ ".upload-" ^
    (Secure_random.bytes 12 |> String.to_seq |> List.of_seq
     |> List.map (fun c -> Printf.sprintf "%02x" (Char.code c))
     |> String.concat "") in
  Fun.protect ~finally:(fun () -> if Sys.file_exists temp then Sys.remove temp)
    (fun () ->
      copy_file ~source ~target:temp;
      (match checksum with
       | Some expected when checksum_file temp <> expected -> raise Integrity
       | _ -> ());
      Sys.rename temp destination)

let upload_bytes service ~key ~bytes ?checksum () =
  let path = Filename.temp_file "ActiveStorage-upload-" "" in
  Fun.protect ~finally:(fun () -> if Sys.file_exists path then Sys.remove path) (fun () ->
    let output = open_out_bin path in
    Fun.protect ~finally:(fun () -> close_out_noerr output)
      (fun () -> output_string output bytes);
    upload_file service ~key ~source:path ?checksum ())

let stage_file service ~key ~source =
  upload_file service ~key ~source ();
  { service; key; kept = false }

let keep staged = staged.kept <- true
let cleanup staged = if not staged.kept then delete staged.service staged.key
let with_staged service ~key ~source f =
  let staged = stage_file service ~key ~source in
  Fun.protect ~finally:(fun () -> cleanup staged) (fun () -> f staged)

let open_verified service ~key ~checksum ?(prefix="ActiveStorage-") ?(suffix="") f =
  let source = path_for service key in
  let temp = Filename.temp_file prefix suffix in
  Fun.protect ~finally:(fun () -> if Sys.file_exists temp then Sys.remove temp) (fun () ->
    copy_file ~source ~target:temp;
    (match checksum with
     | Some expected when checksum_file temp <> expected -> raise Integrity
     | _ -> ());
    f temp)

let json_of_option f = function None -> `Null | Some x -> f x
let payload_key service ~key ~disposition ~content_type =
  `Assoc ["key", `String key; "disposition", `String disposition;
          "content_type", json_of_option (fun x -> `String x) content_type;
          "service_name", `String service.name]
let payload_token service ~key ~content_type ~content_length ~checksum =
  `Assoc ["key", `String key;
          "content_type", json_of_option (fun x -> `String x) content_type;
          "content_length", `Int (Int64.to_int content_length);
          "checksum", `String checksum; "service_name", `String service.name]

let signed ~secret_key_base ~purpose ?expires_at payload =
  App_verifier.generate_raw ~secret_key_base ~name:"ActiveStorage"
    ~data_json:(Rails_format.encode
      (Yojson.Safe.from_string (Yojson.Basic.to_string payload)))
    ~purpose:(Some purpose) ~expires_at

let verify ~secret_key_base ~purpose ~now raw =
  match App_verifier.verify_raw ~secret_key_base ~name:"ActiveStorage"
    ~raw ~purpose:(Some purpose) ~now () with
  | None -> None
  | Some json -> (try Some (Yojson.Basic.from_string json) with _ -> None)

let string_field name = function
  | `Assoc xs -> (match List.assoc_opt name xs with Some (`String s) -> Some s | _ -> None)
  | _ -> None
let optional_string_field name = function
  | `Assoc xs -> (match List.assoc_opt name xs with
    | Some (`String s) -> Some (Some s) | Some `Null -> Some None | _ -> None)
  | _ -> None

let decode_key service ~secret_key_base ~now raw =
  match verify ~secret_key_base ~purpose:"blob_key" ~now raw with
  | None -> None
  | Some payload ->
      (match string_field "key" payload, string_field "disposition" payload,
             optional_string_field "content_type" payload,
             string_field "service_name" payload with
       | Some key, Some disposition, Some content_type, Some service_name
         when service_name = service.name && valid_key key ->
           Some { key; disposition; content_type; service_name }
       | _ -> None)

let decode_token service ~secret_key_base ~now raw =
  match verify ~secret_key_base ~purpose:"blob_token" ~now raw with
  | None -> None
  | Some payload ->
      let length = match payload with
        | `Assoc xs -> (match List.assoc_opt "content_length" xs with
          | Some (`Int n) -> Some (Int64.of_int n) | _ -> None)
        | _ -> None in
      (match string_field "key" payload, optional_string_field "content_type" payload,
             length, string_field "checksum" payload,
             string_field "service_name" payload with
       | Some key, Some content_type, Some content_length, Some checksum,
         Some service_name when service_name = service.name && valid_key key ->
           Some { key; content_type; content_length; checksum; service_name }
       | _ -> None)

let escape keep s =
  let b = Buffer.create (String.length s) in
  String.iter (fun c -> if keep c then Buffer.add_char b c else
    Buffer.add_string b (Printf.sprintf "%%%02X" (Char.code c))) s;
  Buffer.contents b
let path_char = function
  | 'a'..'z' | 'A'..'Z' | '0'..'9' -> true
  | c -> String.contains "-._~!$&'()*+,;=:@/" c
let segment_char c = c <> '/' && path_char c
let escape_path = escape path_char
let escape_segment = escape segment_char
let rfc5987_char = function
  | 'a'..'z' | 'A'..'Z' | '0'..'9' -> true
  | c -> String.contains "!#$&+.^_`|~-" c
let traditional_char c = c = ' ' ||
  match c with
  | 'a'..'z' | 'A'..'Z' | '0'..'9' -> true
  | c -> String.contains "!#$+.^_`|~-" c

let sanitize_filename raw =
  let out = Buffer.create (String.length raw) in
  let decoder = Uutf.decoder (`String (Ruby_compat.strip raw)) in
  let rec loop () = match Uutf.decode decoder with
    | `Uchar u ->
        let code = Uchar.to_int u in
        if code = 0x202e || (code < 128 &&
          String.contains "%$|:;/<>?*\"\t\r\n\\" (Char.chr code))
        then Buffer.add_char out '-'
        else Uutf.Buffer.add_utf_8 out u;
        loop ()
    | `Malformed _ -> Buffer.add_string out "\xef\xbf\xbd"; loop ()
    | `End -> Buffer.contents out
    | `Await -> assert false in
  loop ()

let transliterate s =
  let out = Buffer.create (String.length s) in
  let decoder = Uutf.decoder (`String s) in
  let rec loop () = match Uutf.decode decoder with
    | `Uchar u ->
        let n = Uchar.to_int u in
        if n < 128 then Buffer.add_char out (Char.chr n) else
          Buffer.add_string out (match n with
            | 0x00e9 -> "e" | 0x00fc -> "u" | 0x00ef -> "i"
            | 0x00c6 -> "AE" | 0x0153 -> "oe" | 0x00df -> "ss"
            | _ -> "?");
        loop ()
    | `Malformed _ -> Buffer.add_char out '?'; loop ()
    | `End -> Buffer.contents out
    | `Await -> assert false in
  loop ()

let disposition kind filename =
  let kind = if kind = "attachment" then "attachment" else "inline" in
  let filename = sanitize_filename filename in
  kind ^ "; filename=\"" ^ escape traditional_char (transliterate filename) ^
    "\"; filename*=UTF-8''" ^ escape rfc5987_char filename

let disk_url_path service ~secret_key_base ~key ~filename ~content_type
    ~disposition:kind ?expires_at () =
  let sanitized = sanitize_filename filename in
  let payload = payload_key service ~key
    ~disposition:(disposition kind filename) ~content_type in
  let token = signed ~secret_key_base ~purpose:"blob_key" ?expires_at payload in
  "/rails/active_storage/disk/" ^ escape_segment token ^ "/" ^ escape_path sanitized

let direct_upload_path service ~secret_key_base ~key ~content_type
    ~content_length ~checksum ~expires_at =
  let payload = payload_token service ~key ~content_type ~content_length ~checksum in
  "/rails/active_storage/disk/" ^ escape_segment
    (signed ~secret_key_base ~purpose:"blob_token" ~expires_at payload)

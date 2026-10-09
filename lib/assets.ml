(** Pinned Propshaft output and ActionDispatch::Static behavior.

    [assets/files] contains the byte-for-byte output of the pinned Rust port's
    Rails-verified asset build. Set [CAMPFIRE_ASSETS_DIR] to the containing
    [assets] directory in an installed deployment. *)

exception Missing_asset of string

type response = { status : int; headers : (string * string) list; body : string }

let header response name =
  response.headers
  |> List.find_opt (fun (key, _) -> String.equal (String.lowercase_ascii key) (String.lowercase_ascii name))
  |> Option.map snd

let read_file path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () -> really_input_string channel (in_channel_length channel))

let rec find_root dir =
  let candidate = Filename.concat dir "assets/manifest.json" in
  if Sys.file_exists candidate then Filename.concat dir "assets"
  else let parent = Filename.dirname dir in
    if parent = dir then failwith "assets/manifest.json not found; set CAMPFIRE_ASSETS_DIR"
    else find_root parent

let root = lazy (match Sys.getenv_opt "CAMPFIRE_ASSETS_DIR" with
  | Some dir -> dir
  | None -> find_root (Sys.getcwd ()))

let manifest_json () = read_file (Filename.concat (Lazy.force root) "manifest.json")

let manifest = lazy (
  match Yojson.Basic.from_string (manifest_json ()) with
  | `Assoc entries ->
    entries |> List.map (fun (logical, value) ->
      let digested = Yojson.Basic.Util.(value |> member "digested_path" |> to_string) in
      logical, digested)
  | _ -> failwith "invalid asset manifest")

let manifest_table = lazy (
  let table = Hashtbl.create 400 in
  List.iter (fun (logical, digested) -> Hashtbl.add table logical digested) (Lazy.force manifest);
  table)

let digested_path logical = Hashtbl.find_opt (Lazy.force manifest_table) logical

let is_uri source =
  let lower = String.lowercase_ascii source in
  let starts prefix = String.starts_with ~prefix lower in
  if starts "//" || starts "cid:" || starts "data:" then true
  else
    let rec scheme_end i =
      if i + 2 >= String.length lower then None
      else if String.sub lower i 3 = "://" then Some i
      else scheme_end (i+1) in
    match scheme_end 0 with
    | Some i when i > 0 ->
      String.for_all (fun c -> c = '-' || (c >= 'a' && c <= 'z')) (String.sub lower 0 i)
    | _ -> false

let split_tail source =
  let q = String.index_opt source '?' and h = String.index_opt source '#' in
  let first = match q, h with
    | Some a, Some b -> Some (min a b)
    | Some a, None | None, Some a -> Some a
    | None, None -> None in
  match first with
  | Some i when i + 1 < String.length source -> String.sub source 0 i, String.sub source i (String.length source - i)
  | _ -> source, ""

let file_extension source =
  let base = List.hd (List.rev (String.split_on_char '/' source)) in
  let n = String.length base in
  let rec first_non_dot i = if i < n && base.[i] = '.' then first_non_dot (i+1) else i in
  let first = first_non_dot 0 in
  let rec last_dot i = if i < first then "" else if base.[i] = '.' then String.sub base i (n-i) else last_dot (i-1) in
  last_dot (n-1)

let compute_path ?extension source =
  if source = "" || is_uri source then Ok source else
  let source, tail = split_tail source in
  let source = match extension with Some ext when file_extension source <> ext -> source ^ ext | _ -> source in
  if String.starts_with ~prefix:"/" source then Ok (source ^ tail)
  else match digested_path source with
    | Some digest -> Ok ("/assets/" ^ digest ^ tail)
    | None -> Error ("The asset '" ^ source ^ "' was not found in the load path.")

let try_asset_path source = compute_path source
let unwrap = function Ok path -> path | Error error -> raise (Missing_asset error)
let asset_path source = unwrap (try_asset_path source)
let image_path = asset_path
let audio_path = asset_path
let javascript_path source = unwrap (compute_path ~extension:".js" source)
let stylesheet_path source = unwrap (compute_path ~extension:".css" source)
let asset_url base source =
  let path = asset_path source in
  if path = "" || is_uri path then path else
  let rec trim_end s = if String.ends_with ~suffix:"/" s then trim_end (String.sub s 0 (String.length s-1)) else s in
  trim_end base ^ (if String.starts_with ~prefix:"/" path then path else "/" ^ path)
let image_url = asset_url

let all_stylesheet_paths () =
  Lazy.force manifest |> List.filter_map (fun (logical, _) ->
    if file_extension logical = ".css" then Some logical else None) |> List.sort String.compare

type stylesheet_tags = { html : string; preload_links : string list }

let stylesheet_link_tag sources options =
  let html, preload_links = List.split (List.map (fun source ->
    let href = stylesheet_path source in
    let preload = if href <> "" && not (String.starts_with ~prefix:"data:" href) then
      ["<" ^ href ^ ">; rel=preload; as=style; nopush"] else [] in
    let attrs = options |> List.map (fun (name, value) ->
      " " ^ name ^ "=\"" ^ Ruby_compat.html_escape value ^ "\"") |> String.concat "" in
    "<link rel=\"stylesheet\" href=\"" ^ Ruby_compat.html_escape href ^ "\"" ^ attrs ^ " />", preload
  ) sources) in
  { html = String.concat "\n" html; preload_links = List.concat preload_links }

let stylesheet_link_tag_all options = stylesheet_link_tag (all_stylesheet_paths ()) options

let append_preload_links existing links =
  List.fold_left (fun header link ->
    if String.length header + String.length link > 1000 then header
    else header ^ (if header = "" then "" else ",") ^ link) existing links

let stylesheet_tags () =
  let tags = stylesheet_link_tag_all ["data-turbo-track", "reload"] in
  tags.html, append_preload_links "" tags.preload_links

let javascript_importmap_tags () = read_file (Filename.concat (Lazy.force root) "javascript_importmap_tags.html")

let built_at = lazy (read_file (Filename.concat (Lazy.force root) "built_at.txt"))

let files = lazy (
  let table = Hashtbl.create 400 in
  List.iter (fun (_, digested) -> Hashtbl.replace table ("/assets/" ^ digested) ()) (Lazy.force manifest);
  List.iter (fun path -> Hashtbl.replace table path ())
    ["/assets/.manifest.json"; "/robots.txt"; "/404.html"; "/422.html"; "/500.html"; "/502.html"];
  table)

let file path =
  if Hashtbl.mem (Lazy.force files) path then
    let full = Filename.concat (Filename.concat (Lazy.force root) "files") (String.sub path 1 (String.length path-1)) in
    if Sys.file_exists full then Some (read_file full) else None
  else None

let hex_value = function
  | '0'..'9' as c -> Some (Char.code c - Char.code '0')
  | 'a'..'f' as c -> Some (10 + Char.code c - Char.code 'a')
  | 'A'..'F' as c -> Some (10 + Char.code c - Char.code 'A')
  | _ -> None

let unescape_path path =
  let output = Buffer.create (String.length path) in
  let rec loop i =
    if i < String.length path then
      if path.[i] = '%' && i + 2 < String.length path then
        match hex_value path.[i+1], hex_value path.[i+2] with
        | Some hi, Some lo -> Buffer.add_char output (Char.chr (hi*16+lo)); loop (i+3)
        | _ -> Buffer.add_char output path.[i]; loop (i+1)
      else (Buffer.add_char output path.[i]; loop (i+1)) in
  loop 0; Buffer.contents output

let clean_path path =
  let path = if String.ends_with ~suffix:"/" path then String.sub path 0 (String.length path-1) else path in
  let path = unescape_path path in
  if String.contains path '\000' then None else
  let parts = String.split_on_char '/' path in
  let clean = List.fold_left (fun stack part -> match part, stack with
    | ("" | "."), _ -> stack
    | "..", _::rest -> rest
    | "..", [] -> []
    | _, _ -> part :: stack) [] parts |> List.rev in
  Some ((if String.starts_with ~prefix:"/" path then "/" else "") ^ String.concat "/" clean)

let mime_type ext = match String.lowercase_ascii ext with
  | ".avif" -> Some "image/avif" | ".css" -> Some "text/css" | ".csv" -> Some "text/csv"
  | ".gif" -> Some "image/gif" | ".gz" -> Some "application/x-gzip"
  | ".htm" | ".html" -> Some "text/html" | ".ico" -> Some "image/vnd.microsoft.icon"
  | ".jpeg" | ".jpg" -> Some "image/jpeg" | ".js" | ".mjs" -> Some "text/javascript"
  | ".json" -> Some "application/json" | ".m4a" -> Some "audio/mp4a-latm"
  | ".mp3" -> Some "audio/mpeg" | ".mp4" -> Some "video/mp4" | ".ogg" -> Some "application/ogg"
  | ".otf" -> Some "font/otf" | ".pdf" -> Some "application/pdf" | ".png" -> Some "image/png"
  | ".svg" -> Some "image/svg+xml" | ".ttf" -> Some "font/ttf" | ".txt" -> Some "text/plain"
  | ".wav" -> Some "audio/x-wav" | ".webm" -> Some "video/webm" | ".webp" -> Some "image/webp"
  | ".woff" -> Some "font/woff" | ".woff2" -> Some "font/woff2" | ".xml" -> Some "application/xml"
  | ".zip" -> Some "application/zip" | _ -> None

let compressible content_type =
  String.starts_with ~prefix:"text/" content_type || content_type = "application/javascript"
  || content_type = "image/svg+xml"

let accepts header encoding =
  let is_word = function 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' -> true | _ -> false in
  let match_word value =
    let value = String.lowercase_ascii value in
    let n = String.length encoding in
    let rec scan i =
      if i + n > String.length value then false
      else if String.sub value i n = encoding
        && (i = 0 || not (is_word value.[i-1]))
        && (i+n = String.length value || not (is_word value.[i+n])) then true
      else scan (i+1) in scan 0 in
  String.split_on_char ',' header |> List.exists (fun part ->
    let token = List.hd (String.split_on_char ';' part) |> String.trim in match_word token)

let try_file path content_type accept_encoding =
  if not (compressible content_type) then
    Option.map (fun body -> body, ["content-type", content_type]) (file path)
  else
    let headers = ref ["content-type", content_type] in
    let rec compressed = function
      | [] -> Option.map (fun body -> body, !headers) (file path)
      | (encoding, extension)::rest ->
        match file (path ^ extension) with
        | None -> compressed rest
        | Some body ->
          headers := !headers @ ["vary", "accept-encoding"];
          if accepts accept_encoding encoding then Some (body, !headers @ ["content-encoding", encoding])
          else compressed rest in
    compressed ["br", ".br"; "gzip", ".gz"]

let find_file path accept_encoding =
  match clean_path path with
  | None -> None
  | Some path ->
    let ext = file_extension path in
    let content_type = mime_type ext in
    let candidates = (path, Option.value content_type ~default:"text/plain") ::
      (if Option.is_none content_type && ext <> ".html" then
        [path ^ ".html", "text/html"; path ^ "/index.html", "text/html"] else []) in
    let rec find = function
      | [] -> None
      | (path, content_type)::rest ->
        match try_file path content_type accept_encoding with
        | Some result -> Some result | None -> find rest in
    find candidates

let serve ~method_ ~path ?accept_encoding ?range ?if_modified_since () =
  if method_ <> "GET" && method_ <> "HEAD" then None else
  match find_file path (Option.value accept_encoding ~default:"") with
  | None -> None
  | Some (contents, content_headers) ->
    let last_modified = Lazy.force built_at in
    if if_modified_since = Some last_modified then Some { status = 304; headers = []; body = "" }
    else
      let size = String.length contents in
      let base = ["last-modified", last_modified; "content-type", ""; "Cache-Control", "public, max-age=2592000"] in
      let status, headers, body = match Ruby_compat.byte_ranges range (Int64.of_int size) with
        | None -> 200, base @ ["content-length", string_of_int size], contents
        | Some [] ->
          let message = "Byte range unsatisfiable\n" in
          416, ["content-type", ""; "content-length", string_of_int (String.length message);
                "x-cascade", "pass"; "content-range", "bytes */" ^ string_of_int size], message
        | Some [first, last] ->
          let first = Int64.to_int first and last = Int64.to_int last in
          let body = String.sub contents first (last-first+1) in
          206, base @ ["content-range", Printf.sprintf "bytes %d-%d/%d" first last size;
                       "content-length", string_of_int (String.length body)], body
        | Some ranges ->
          let content_type = List.assoc "content-type" content_headers in
          let buffer = Buffer.create size in
          List.iter (fun (first, last) ->
            let first = Int64.to_int first and last = Int64.to_int last in
            Buffer.add_string buffer (Printf.sprintf
              "\r\n--AaB03x\r\ncontent-type: %s\r\ncontent-range: bytes %d-%d/%d\r\n\r\n"
              content_type first last size);
            Buffer.add_substring buffer contents first (last-first+1)) ranges;
          Buffer.add_string buffer "\r\n--AaB03x--\r\n";
          let body = Buffer.contents buffer in
          206, base @ ["content-length", string_of_int (String.length body)], body in
      let headers = List.fold_left (fun headers (name, value) ->
        if List.mem_assoc name headers then List.map (fun (key, current) ->
          if key = name then key, value else key, current) headers
        else headers @ [name, value]) headers content_headers in
      Some { status; headers; body = if method_ = "HEAD" then "" else body }

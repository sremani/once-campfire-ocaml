type error = string

type mention = {
  id : int64;
  name : string;
  title : string;
  attachable_sgid : string;
  user_path : string;
  avatar_path : string;
}

type resolver = string -> mention option
type gid_resolver = string -> mention option

type node = Text of string | Element of string * (string * string) list * node list * bool [@@warning "-37"]
external gumbo_parse : string -> (node list, string) result = "caml_campfire_gumbo_parse"

let max_input_bytes = 16 * 1024 * 1024
let parse_raw_nodes html =
  if String.length html > max_input_bytes then Error "rich-text input exceeds 16 MiB"
  else gumbo_parse html
let parse_nodes html = parse_raw_nodes (String.trim html)
let parse html = Result.map (fun _ -> ()) (parse_nodes html)
let attr attrs key = List.assoc_opt key attrs
let starts prefix text = String.starts_with ~prefix text
let escape = Ruby_compat.html_escape

let trix_attributes = [
  "sgid", "sgid"; "contentType", "content-type"; "url", "url";
  "href", "href"; "filename", "filename"; "filesize", "filesize";
  "width", "width"; "height", "height"; "previewable", "previewable";
  "content", "content"; "caption", "caption"; "presentation", "presentation"]

let ruby_json_value = function
  | `String value -> value
  | `Null -> ""
  | value -> Yojson.Basic.to_string value

let trix_json attrs key =
  match attr attrs key with
  | None -> Ok []
  | Some raw ->
    (match try Some (Yojson.Basic.from_string raw) with _ -> None with
     | None | Some `Null | Some (`Bool false) -> Ok []
     | Some (`Assoc fields) -> Ok fields
     | Some _ -> Error "Action Text Trix attributes must be JSON objects")

let rec normalize_node = function
  | Text _ as node -> Ok [node]
  | Element (name,attrs,children,html_namespace) ->
    (match attr attrs "data-trix-attachment" with
     | Some _ ->
       (match trix_json attrs "data-trix-attachment", trix_json attrs "data-trix-attributes" with
        | Error e, _ | _, Error e -> Error e
        | Ok fields1, Ok fields2 ->
          let fields = fields2 @ fields1 in
          let attachment_attrs = List.filter_map (fun (source,target) ->
            Option.map (fun value -> target, ruby_json_value value) (List.assoc_opt source fields)) trix_attributes in
          if attachment_attrs = [] then Ok []
          else Ok [Element ("action-text-attachment", attachment_attrs, [], true)])
     | None ->
       if name = "action-text-attachment" then Ok [Element (name,attrs,[],html_namespace)]
       else match normalize_nodes children with
         | Error e -> Error e
         | Ok children -> Ok [Element (name,attrs,children,html_namespace)])
and normalize_nodes nodes =
  let rec loop acc = function
    | [] -> Ok (List.concat (List.rev acc))
    | node :: rest ->
      (match normalize_node node with
       | Error e -> Error e | Ok nodes -> loop (nodes :: acc) rest)
  in loop [] nodes

let load_nodes html = Result.bind (parse_nodes html) normalize_nodes
let escape_text value =
  let out = Buffer.create (String.length value) in
  let rec loop i =
    if i < String.length value then
      if i+1 < String.length value && value.[i] = '\xC2' && value.[i+1] = '\xA0' then
        (Buffer.add_string out "&nbsp;"; loop (i+2))
      else (Buffer.add_string out (match value.[i] with
        | '&' -> "&amp;" | '<' -> "&lt;" | '>' -> "&gt;"
        | c -> String.make 1 c); loop (i+1)) in
  loop 0;
  Buffer.contents out

let replace_all input needle replacement =
  if needle = "" then input else
  let out = Buffer.create (String.length input) in
  let rec loop from =
    match String.index_from_opt input from needle.[0] with
    | None -> Buffer.add_substring out input from (String.length input - from)
    | Some i when i + String.length needle <= String.length input &&
                  String.sub input i (String.length needle) = needle ->
       Buffer.add_substring out input from (i-from);
       Buffer.add_string out replacement;
       loop (i + String.length needle)
    | Some i ->
       Buffer.add_substring out input from (i-from+1);
       loop (i+1)
  in loop 0; Buffer.contents out

let allowed_tags = [
  "a"; "abbr"; "acronym"; "address"; "b"; "big"; "blockquote"; "br";
  "cite"; "code"; "dd"; "del"; "dfn"; "div"; "dl"; "dt"; "em";
  "h1"; "h2"; "h3"; "h4"; "h5"; "h6"; "hr"; "i"; "img"; "ins"; "kbd";
  "li"; "mark"; "ol"; "p"; "pre"; "s"; "samp"; "small"; "span";
  "strong"; "sub"; "sup"; "table"; "tbody"; "thead"; "tfoot";
  "tr"; "th"; "td"; "time"; "tt"; "u"; "ul"; "var"; "figure";
  "figcaption"; "action-text-attachment"; "video"; "audio"; "source";
  "embed" ]
let filtered_tags = List.filter
  (fun tag -> not (List.mem tag ["video"; "audio"; "source"; "embed"; "img"]))
  allowed_tags
let presentation_tags =
  ["a"; "abbr"; "acronym"; "address"; "b"; "big"; "blockquote"; "br";
   "cite"; "code"; "dd"; "del"; "dfn"; "div"; "dl"; "dt"; "em";
   "h1"; "h2"; "h3"; "h4"; "h5"; "h6"; "hr"; "i"; "img"; "ins";
   "kbd"; "li"; "mark"; "ol"; "p"; "pre"; "s"; "samp"; "small";
   "span"; "strong"; "sub"; "sup"; "table"; "tbody"; "thead";
   "tfoot"; "tr"; "th"; "td"; "time"; "tt"; "u"; "ul"; "var"]
let allowed_attrs = [
  "abbr"; "alt"; "cite"; "class"; "datetime"; "height"; "href";
  "lang"; "src"; "title"; "width"; "xml:lang"; "sgid";
  "content-type"; "url"; "filename"; "filesize"; "previewable";
  "presentation"; "caption"; "content"; "controls"; "poster";
  "data-language"; "value"; "start"; "style" ]
let presentation_attrs = ["abbr"; "alt"; "cite"; "class"; "datetime";
  "height"; "href"; "lang"; "src"; "title"; "width"; "xml:lang";
  "data-language"]
let uri_attrs = ["href"; "src"; "url"; "poster"; "cite"]
let attachment_attrs = ["sgid"; "content-type"; "url"; "href";
  "filename"; "filesize"; "width"; "height"; "previewable";
  "presentation"; "caption"; "content"]
let void_tags = ["br"; "hr"; "img"; "source"; "embed"]

let safe_uri value =
  let value = String.trim value in
  if value = "" then false
  else let lower = String.to_seq value
      |> Seq.filter (fun c -> Char.code c > 32 && Char.code c <> 127 && c <> '`')
      |> String.of_seq |> String.lowercase_ascii
      |> fun s -> replace_all s "%3a" ":" in
    let before_path =
      let i = try String.index lower ':' with Not_found -> String.length lower in
      let p = try String.index lower '/' with Not_found -> String.length lower in
      let q = try String.index lower '?' with Not_found -> String.length lower in
      let h = try String.index lower '#' with Not_found -> String.length lower in
      i < min p (min q h) && i > 0 &&
      let scheme = String.sub lower 0 i in
      let scheme_char = function
        | 'a'..'z' | '0'..'9' | '+' | '-' | '.' -> true | _ -> false in
      (match scheme.[0] with 'a'..'z' -> true | _ -> false) &&
      String.for_all scheme_char scheme in
    if before_path then
      let allowed = ["afs"; "aim"; "callto"; "ed2k"; "fax"; "ftp"; "gopher";
        "http"; "https"; "irc"; "line"; "mailto"; "modem"; "news";
        "nntp"; "rsync"; "rtsp"; "sftp"; "sms"; "ssh"; "tag";
        "tel"; "telnet"; "urn"; "webcal"; "xmpp"] in
      let colon = String.index lower ':' in
      let scheme = String.sub lower 0 colon in
      if scheme = "data" then
        List.exists (fun media -> starts ("data:" ^ media) lower)
          ["image/gif"; "image/jpeg"; "image/png"; "text/css"; "text/plain"]
      else List.mem scheme allowed
    else true

let sanitize_uri_attr_value name value =
  if List.mem name ["href"; "src"; "name"] then
    value |> fun v -> replace_all v " " "%20" |> fun v -> replace_all v "\"" "%22"
  else value

let is_plain_color value =
  let lower = String.lowercase_ascii value in
  let all pred value = value <> "" && String.for_all pred value in
  let alpha = function 'a'..'z' -> true | _ -> false in
  let hex = function '0'..'9' | 'a'..'f' -> true | _ -> false in
  let custom = function 'a'..'z' | '0'..'9' | '_' | '-' -> true | _ -> false in
  let color_arg = function
    | 'a'..'z' | '0'..'9' | '.' | ',' | '%' | ' ' | '\t' | '\n' | '/' | '+' | '-' -> true
    | _ -> false in
  let function_arg prefix pred =
    let marker = prefix ^ "(" in
    if starts marker lower && String.ends_with ~suffix:")" lower then
      let body = String.sub lower (String.length marker)
        (String.length lower - String.length marker - 1) |> String.trim in
      all pred body
    else false in
  all alpha lower ||
  (String.length lower >= 4 && String.length lower <= 9 && lower.[0] = '#' &&
    all hex (String.sub lower 1 (String.length lower - 1))) ||
  (starts "var(" lower && String.ends_with ~suffix:")" lower &&
    let body = String.sub lower 4 (String.length lower - 5) |> String.trim in
    starts "--" body && all custom (String.sub body 2 (String.length body - 2))) ||
  List.exists (fun prefix -> function_arg prefix color_arg)
    ["rgb"; "rgba"; "hsl"; "hsla"]

let scrub_style value =
  let declarations = String.split_on_char ';' value
    |> List.filter_map (fun declaration ->
      let declaration = String.trim declaration in
      if declaration = "" then None else
      match String.index_opt declaration ':' with
      | None -> Some (String.lowercase_ascii declaration, "")
      | Some colon ->
        Some (String.sub declaration 0 colon |> String.trim |> String.lowercase_ascii,
          String.sub declaration (colon+1) (String.length declaration - colon - 1) |> String.trim)) in
  let allowed (property,color) =
    List.mem property ["color"; "background-color"] && is_plain_color color in
  let kept = List.filter allowed declarations in
  match kept with
  | [] -> None
  | _ when List.length kept = List.length declarations -> Some value
  | _ -> Some (String.concat "" (List.map (fun (property,color) ->
      property ^ ": " ^ color ^ ";") kept))

let sanitized_attrs_with allowed attrs =
  let rec loop previous_allowed acc = function
    | [] -> List.rev acc
    | (name,value)::rest ->
      let name = String.lowercase_ascii name in
      let value = if previous_allowed then sanitize_uri_attr_value name value else value in
      if name = "style" && List.mem name allowed then
        (* Action Text accepts the attribute before its CSS scrubber runs.
           That acceptance re-escapes later URL attributes. *)
        let acc = match scrub_style value with
          | Some value -> (name,value)::acc | None -> acc in
        loop true acc rest
      else if not (List.mem name allowed) ||
         (List.mem name uri_attrs && not (safe_uri value)) then
        loop previous_allowed acc rest
      else
        let value = sanitize_uri_attr_value name value in
        loop true ((name,value)::acc) rest in
  loop false [] attrs
let sanitized_attrs = sanitized_attrs_with allowed_attrs

let serialize_attrs attrs =
  String.concat "" (List.map (fun (name,value) -> " " ^ name ^ "=\"" ^ escape value ^ "\"") attrs)

let escape_nokogiri_attr value =
  let out = Buffer.create (String.length value) in
  String.iter (function
    | '&' -> Buffer.add_string out "&amp;"
    | '"' -> Buffer.add_string out "&quot;"
    | '\r' -> Buffer.add_char out '\n'
    | c -> Buffer.add_char out c) value;
  replace_all (Buffer.contents out) "\xc2\xa0" "&nbsp;"

let canonical_void_tags = ["area"; "base"; "br"; "col"; "embed"; "hr";
  "img"; "input"; "link"; "meta"; "param"; "source"; "track"; "wbr"]

let rec serialize_canonical = function
  | Text text -> escape_text text
  | Element ("#comment",_,children,_) -> "<!--" ^ String.concat "" (List.map (function Text text -> text | _ -> "") children) ^ "-->"
  | Element (name,attrs,children,html_namespace) ->
    let attrs = String.concat "" (List.map (fun (key,value) ->
      " " ^ key ^ "=\"" ^ escape_nokogiri_attr value ^ "\"") attrs) in
    let open_tag = "<" ^ name ^ attrs ^ ">" in
    if html_namespace && List.mem name canonical_void_tags then open_tag
    else let children =
      if html_namespace && List.mem name ["script"; "style"; "xmp"; "iframe"; "noembed";
                        "noframes"; "plaintext"; "noscript"] then
        String.concat "" (List.map (function Text text -> text | child -> serialize_canonical child) children)
      else
        let children =
          match name,children with
          | "pre", Text text :: rest when String.starts_with ~prefix:"\n" text ->
            Text (String.sub text 1 (String.length text - 1)) :: rest
          | _ -> children in
        String.concat "" (List.map serialize_canonical children) in
      open_tag ^ children ^ "</" ^ name ^ ">"

let rec sanitize_node = function
  | Text text -> escape_text text
  | Element (name, attrs, children, html_namespace) ->
      if not html_namespace || name = "#comment" then ""
      else let inner = String.concat "" (List.map sanitize_node children) in
        if not (List.mem name allowed_tags) then inner
        else let opening = "<" ^ name ^ serialize_attrs (sanitized_attrs attrs) ^ ">" in
          if List.mem name void_tags then opening
          else opening ^ inner ^ "</" ^ name ^ ">"
let sanitize html = Result.map (fun nodes -> String.concat "" (List.map sanitize_node nodes)) (parse_nodes html)

let rec text_content = function
  | Text value -> value
  | Element (_,_,children,_) -> String.concat "" (List.map text_content children)

let has_class attrs token =
  match attr attrs "class" with
  | None -> false
  | Some value -> List.mem token (String.split_on_char ' ' value)

let rec find_node predicate nodes =
  match nodes with
  | [] -> None
  | ((Element (_,_,children,_) as node) :: rest) ->
    if predicate node then Some node
    else (match find_node predicate children with
      | Some _ as found -> found | None -> find_node predicate rest)
  | Text _ :: rest -> find_node predicate rest

let og_content_type = "application/vnd.actiontext.opengraph-embed"
let contains_substring value needle =
  let rec scan i =
    i + String.length needle <= String.length value &&
    (String.sub value i (String.length needle) = needle || scan (i+1)) in
  scan 0
let is_og attrs =
  match attr attrs "content-type" with
  | Some value when contains_substring value og_content_type -> true
  | Some value ->
    let prefix = "application/vnd" and middle = "actiontext" and suffix = "opengraph-embed" in
    let rec scan i =
      let j = i + String.length prefix + 1 in
      let k = j + String.length middle + 1 in
      k + String.length suffix <= String.length value &&
      ((String.sub value i (String.length prefix) = prefix &&
        String.sub value j (String.length middle) = middle &&
        String.sub value k (String.length suffix) = suffix) || scan (i+1)) in
    scan 0
  | None -> false
let sgid_gid raw =
  if raw = "" || String.for_all (fun c -> c = '-') raw then Ok None
  else
    let rec separator i =
      if i + 1 >= String.length raw then String.length raw
      else if raw.[i] = '-' && raw.[i+1] = '-' then i
      else separator (i+1) in
    let encoded = String.sub raw 0 (separator 0) in
    match Message_verifier.decode encoded with
    | None -> Error "invalid SGID base64"
    | Some payload ->
      (match try Some (Yojson.Basic.from_string payload) with _ -> None with
       | None -> Error "invalid SGID JSON"
       | Some (`Assoc fields) ->
         (match List.assoc_opt "_rails" fields with
          | None | Some `Null -> Ok None
          | Some (`Assoc rails) ->
            (match List.assoc_opt "data" rails with
             | Some (`String gid) -> Ok (Some gid)
             | Some (`Int _) -> Ok None
             | _ ->
               (match List.assoc_opt "message" rails with
                | Some (`String encoded) ->
                  (match Message_verifier.decode encoded with
                   | None -> Error "invalid SGID Marshal base64"
                   | Some bytes ->
                     let prefix = "gid://campfire/" in
                     let rec find i =
                       if i + String.length prefix > String.length bytes then None
                       else if String.sub bytes i (String.length prefix) = prefix then Some i
                       else find (i+1) in
                     (match find 0 with
                      | None -> Ok None
                      | Some i ->
                        let j = ref (i+String.length prefix) in
                        while !j < String.length bytes &&
                          (match bytes.[!j] with 'A'..'Z' | 'a'..'z' | '0'..'9' | '/' | '_' -> true | _ -> false)
                        do incr j done;
                        Ok (Some (String.sub bytes i (!j-i)))))
                | Some _ -> Error "invalid SGID Marshal message"
                | None -> Ok None))
          | Some _ -> Error "invalid SGID Rails payload")
       | Some _ -> Error "invalid SGID JSON object")

let resolve_attachment_user ~resolve_sgid ~resolve_gid attrs =
  match attr attrs "sgid" with
  | None -> Ok (None,None)
  | Some raw ->
    (match resolve_sgid raw with
     | Some user -> Ok (Some user,None)
     | None ->
       (match sgid_gid raw with
        | Error e -> Error e
        | Ok gid ->
          let user = Option.bind gid resolve_gid in
          Ok (user,gid)))
let web_url ?request_host value =
  match value with
  | None -> None
  | Some value when String.trim value = "" || not (String.for_all (fun c -> Char.code c < 128) value) -> None
  | Some value ->
    let authority =
      match String.index_opt value ':' with
      | Some i when i+2 < String.length value && String.sub value i 3 = "://" ->
        let from = i+3 in
        let finish = ref from in
        while !finish < String.length value &&
          not (List.mem value.[!finish] ['/'; '?'; '#']) do incr finish done;
        String.sub value from (!finish-from)
      | _ -> "" in
    let parsed = try Some (Uri.of_string value) with _ -> None in
    (match parsed with
     | None -> None
     | Some uri ->
       let scheme = Uri.scheme uri |> Option.map String.lowercase_ascii in
       let host = Uri.host uri in
       (match scheme,host with
        | (Some "http" | Some "https"), Some host
          when String.contains host '.' &&
            not (String.contains host '%') &&
            not (String.contains authority '%') &&
            not (String.exists (fun c -> c = ' ' || c = '\t' || c = '\r' || c = '\n') value) &&
            (let host = String.lowercase_ascii host |> fun h -> if String.ends_with ~suffix:"." h then String.sub h 0 (String.length h-1) else h in
             let label = match String.rindex_opt host '.' with Some i -> String.sub host (i+1) (String.length host-i-1) | None -> host in
             let request_host = Option.value request_host ~default:"" |> String.lowercase_ascii in
             host <> request_host &&
             String.exists (function 'a'..'z' -> true | _ -> false) label &&
             not (starts "0x" label)) -> Some value
        | _ -> None))

let og_error attrs =
  let values = [attr attrs "href"; attr attrs "url"] |> List.filter_map Fun.id in
  List.find_map (fun value ->
    let lower = String.lowercase_ascii value in
    if starts "mailto:" lower && not (String.contains value '@') then
      Some "invalid mailto URL"
    else if starts "http://.../" lower || starts "https://.../" lower then
      Some "invalid dotted host"
    else None) values

let og_from_attrs ?request_host attrs =
  let content = Option.value (attr attrs "content") ~default:"" in
  let nodes = match load_nodes content with Ok nodes -> nodes | Error _ -> [] in
  let by_class class_name = find_node (function
    | Element (_,attrs,_,_) -> has_class attrs class_name
    | Text _ -> false) nodes in
  let children = function Some (Element (_,_,children,_)) -> children | _ -> [] in
  let title_node = by_class "og-embed__title" in
  let link = find_node (function Element ("a",_,_,_) -> true | _ -> false) (children title_node) in
  let image_node = by_class "og-embed__image" in
  let image = find_node (function Element ("img",_,_,_) -> true | _ -> false) (children image_node) in
  let node_attr key = function Some (Element (_,attrs,_,_)) -> attr attrs key | _ -> None in
  let node_text = function Some node -> Some (String.trim (text_content node)) | _ -> None in
  if (match attr attrs "filename" with Some value -> String.trim value <> "" | None -> false) then
    web_url ?request_host (attr attrs "href"),
    web_url ?request_host (attr attrs "url"),
    attr attrs "filename", attr attrs "caption"
  else
    web_url ?request_host (node_attr "href" link),
    web_url ?request_host (node_attr "src" image),
    (match node_text link with Some _ as found -> found | None -> node_text title_node),
    node_text (by_class "og-embed__description")

let truncate_chars max_length value =
  let count = ref 0 and stop = ref (String.length value) in
  ignore (Uutf.String.fold_utf_8 (fun () index _ ->
    if !count = max_length - 1 && !stop = String.length value then stop := index;
    incr count) () value);
  if !count <= max_length then value else String.sub value 0 !stop ^ "…"

let render_og ?request_host attrs =
  let href,url,filename,description = og_from_attrs ?request_host attrs in
  let title = match href,filename with
    | Some href, Some filename -> "<a rel=\"noreferrer\" target=\"_blank\" href=\"" ^
      escape href ^ "\">" ^ escape (truncate_chars 280 filename) ^ "</a>"
    | Some href, None -> "<a rel=\"noreferrer\" target=\"_blank\" href=\"" ^
      escape href ^ "\">" ^ escape href ^ "</a>"
    | None, Some filename -> escape (truncate_chars 280 filename)
    | None,None -> "" in
  let avatar = match url with Some url when starts "https://pbs.twimg.com/profile_images" url ->
    "og-embed--twitter-avatar" | _ -> "" in
  let image = match url with
    | None -> ""
    | Some url -> "        <div class=\"og-embed__image\">\n          <img src=\"" ^
      escape url ^ "\" class=\"image center\" alt=\"\">\n        </div>\n" in
  "<figure class=\"attachment attachment--content attachment--og\">\n" ^
  "  <actiontext-opengraph-embed>\n" ^
  "    <div class=\"og-embed gap " ^ avatar ^ "\">\n" ^
  "      <div class=\"og-embed__content\">\n" ^
  "        <div class=\"og-embed__title\">\n          " ^ title ^ "\n        </div>\n" ^
  "        <div class=\"og-embed__description\">" ^
  escape (truncate_chars 560 (Option.value description ~default:"")) ^ "</div>\n" ^
  "      </div>\n" ^ image ^
  "    </div>\n" ^
  "  </actiontext-opengraph-embed>\n</figure>"

let render_remote_image attrs =
  let url = Option.value (attr attrs "url") ~default:"" in
  if not (safe_uri url || starts "/" url) then Error "remote image URL is unsafe"
  else let dimensions = List.filter_map (fun key ->
    Option.map (fun value -> " " ^ key ^ "=\"" ^ escape value ^ "\"") (attr attrs key))
      ["width"; "height"] |> String.concat "" in
  let caption = match attr attrs "caption" with
    | None -> ""
    | Some caption -> "    <figcaption class=\"attachment__caption\">\n      " ^
      escape caption ^ "\n    </figcaption>\n" in
  Ok ("<figure class=\"attachment attachment--preview\">\n  <img" ^
      dimensions ^ " src=\"" ^ escape url ^ "\" />\n" ^ caption ^ "</figure>")

let render_remote_video attrs kind =
  let url = Option.value (attr attrs "url") ~default:"" in
  if not (safe_uri url || starts "/" url) then Error "remote video URL is unsafe"
  else let dimensions = List.filter_map (fun key ->
    Option.map (fun value -> " " ^ key ^ "=\"" ^ escape value ^ "\"") (attr attrs key))
      ["width"; "height"] |> String.concat "" in
  let caption = match attr attrs "caption" with
    | None -> ""
    | Some caption -> "    <figcaption class=\"attachment__caption\">\n      " ^
      escape caption ^ "\n    </figcaption>\n" in
  Ok ("<figure class=\"attachment attachment--preview attachment--video\">\n" ^
      "  <video controls=\"controls\"" ^ dimensions ^ ">\n" ^
      "    <source src=\"" ^ escape url ^ "\" type=\"" ^ escape kind ^ "\">\n" ^
      "</video>" ^ caption ^ "</figure>")

let chomp_newlines text =
  let i = ref (String.length text) in
  while !i > 0 && text.[!i-1] = '\n' do decr i done;
  String.sub text 0 !i
let block children = chomp_newlines (String.concat "" children) ^ "\n\n"
let append_line children = chomp_newlines (String.concat "" children) ^ "\n"
let quoted_block children =
  let value = block children in
  let is_space = function ' ' | '\t' | '\n' | '\011' | '\012' | '\r' -> true | _ -> false in
  let first = ref 0 and last = ref (String.length value - 1) in
  while !first < String.length value && is_space value.[!first] do incr first done;
  if !first = String.length value then "“”"
  else (
    while !last >= 0 && is_space value.[!last] do decr last done;
    String.sub value 0 !first ^ "“" ^
    String.sub value !first (!last - !first + 1) ^ "”" ^
    String.sub value (!last + 1) (String.length value - !last - 1))

let rec strip_nested_attachments = function
  | Text _ as node -> node
  | Element ("action-text-attachment",_,_,_) -> Text ""
  | Element (name,attrs,children,ns) ->
    Element (name,attrs,List.map strip_nested_attachments children,ns)

let rec plain_nodes ~resolve_sgid ~resolve_gid ~depth ~list_depth ~list_kind nodes =
  if depth > 400 then Error "rich-text nested content exceeds 400 levels"
  else let rec loop index acc = function
    | [] -> Ok (String.concat "" (List.rev acc))
    | node :: rest ->
        match plain_node ~resolve_sgid ~resolve_gid ~depth ~list_depth ~list_kind ~list_index:index node with
        | Error e -> Error e
        | Ok text ->
          let next = match node with Element _ when list_kind <> None -> index+1 | _ -> index in
          loop next (text :: acc) rest
  in loop 0 [] nodes
and plain_node ~resolve_sgid ~resolve_gid ~depth ~list_depth ~list_kind ~list_index = function
  | Text text -> Ok (chomp_newlines text)
  | Element (name, attrs, children, _) ->
      if List.mem name ["script"; "style"; "unsupported"; "#comment"] then Ok ""
      else if name = "action-text-attachment" then
        (match (if is_og attrs then Ok (None,None)
                else resolve_attachment_user ~resolve_sgid ~resolve_gid attrs) with
         | Error e -> Error e
         | Ok (None,_) when is_og attrs ->
           (match og_error attrs with Some e -> Error e | None -> Ok "")
         | Ok (Some user,_) ->
           (match load_nodes ("@" ^ user.name) with
            | Error e -> Error e
            | Ok nodes -> plain_nodes ~resolve_sgid ~resolve_gid ~depth:(depth+1) ~list_depth ~list_kind:None nodes)
         | Ok (None,_) ->
           (match attr attrs "content" with
            | Some content when attr attrs "content-type" = Some "text/html" ->
                (match sanitize content with
                 | Error e -> Error e
                 | Ok content ->
                   (match load_nodes content with
                    | Error e -> Error e
                    | Ok nodes -> plain_nodes ~resolve_sgid ~resolve_gid ~depth:(depth+1) ~list_depth ~list_kind:None
                        (List.map strip_nested_attachments nodes)))
            | _ ->
                let content_type = Option.value (attr attrs "content-type") ~default:"" in
                if starts "image/" content_type || content_type = "image" then
                  Ok ("[" ^ Option.value (attr attrs "caption") ~default:"Image" ^ "]")
                else if starts "video/" content_type then
                  Ok ("[" ^ Option.value (attr attrs "caption") ~default:(Option.value (attr attrs "filename") ~default:"Video") ^ "]")
                else if is_og attrs then Ok ""
                else Ok (Option.value (attr attrs "caption") ~default:"")))
      else if name = "br" then Ok "\n"
      else
        let next_depth = if name = "ul" || name = "ol" then list_depth + 1 else list_depth in
        let child_list_kind = if name = "ul" || name = "ol" then Some name else None in
        match plain_nodes ~resolve_sgid ~resolve_gid ~depth:(depth+1) ~list_depth:next_depth ~list_kind:child_list_kind children with
        | Error e -> Error e
        | Ok inner ->
          if name = "ul" || name = "ol" then
            Ok ((if list_depth > 0 then "\n" else "") ^ block [inner])
          else if name = "p" || name = "h1" then
            Ok (block [inner])
          else if name = "div" then Ok (append_line [inner])
          else if name = "figcaption" then Ok ("[" ^ chomp_newlines inner ^ "]")
          else if name = "blockquote" then Ok (quoted_block [inner])
          else if name = "li" then
            let bullet = if list_kind = Some "ol" then string_of_int (list_index+1) ^ "." else "•" in
            Ok (String.make (max 0 (list_depth - 1) * 2) ' ' ^ bullet ^ " " ^ chomp_newlines inner ^ "\n")
          else Ok inner

let to_plain_text ?(resolve_sgid=(fun _ -> None)) ?(resolve_gid=(fun _ -> None)) html =
  match load_nodes html with
  | Error e -> Error e
  | Ok nodes -> Result.map chomp_newlines (plain_nodes ~resolve_sgid ~resolve_gid ~depth:0 ~list_depth:0 ~list_kind:None nodes)

let render_mention user =
  "<span class=\"mention\" sgid=\"" ^ escape user.attachable_sgid ^
  "\"><a title=\"" ^ escape user.title ^
  "\" class=\"btn avatar\" data-turbo-frame=\"_top\" href=\"" ^
  escape user.user_path ^ "\"><img aria-hidden=\"true\" src=\"" ^
  escape user.avatar_path ^
  "\" width=\"48\" height=\"48\" /></a> " ^ escape user.name ^ "</span>"

let rec render_node ~resolve_sgid ~resolve_gid ?request_host ~depth = function
  | Text text -> Ok (escape_text text)
  | Element (name,attrs,children,html_namespace) ->
      if not html_namespace || not (List.mem name filtered_tags || (depth > 0 && name = "img")) then Ok ""
      else if name = "action-text-attachment" then
        (if is_og attrs then
           (match og_error attrs with Some e -> Error e | None -> Ok (render_og ?request_host attrs))
         else match resolve_attachment_user ~resolve_sgid ~resolve_gid attrs with
         | Error e -> Error e
         | Ok (Some user,_) -> Ok (render_mention user)
         | Ok (None,_) ->
           if not (List.exists (fun (name,_) -> List.mem name attachment_attrs)
                     (sanitized_attrs attrs)) then
             Error "Action Text attachment has no full attributes"
           else
           match attr attrs "content", attr attrs "content-type" with
           | Some content, Some kind when String.contains kind 'h' && starts "text/html" kind && depth < 8 ->
               (match sanitize content with
                | Error e -> Error e
                | Ok content when String.trim content = "" -> Ok "☒"
                | Ok content ->
                  (match load_nodes content with
                   | Error e -> Error e
                   | Ok nodes ->
                     (match render_nodes ~resolve_sgid ~resolve_gid ?request_host ~depth:(depth+1) nodes with
                      | Error e -> Error e
                      | Ok inner -> Ok ("<figure class=\"attachment attachment--content\">\n  " ^ inner ^ "\n\n</figure>"))))
           | _, Some kind when (kind = "image" || starts "image/" kind) && attr attrs "url" <> None ->
             render_remote_image attrs
           | _, Some kind when starts "video/" kind && attr attrs "url" <> None ->
             render_remote_video attrs kind
           | _ -> Ok "☒")
      else if name = "div" &&
        (let gallery_children = List.filter (function
          | Element ("action-text-attachment",child_attrs,_,_) -> attr child_attrs "presentation" = Some "gallery"
          | _ -> false) children in
         List.length gallery_children >= 2 &&
         List.for_all (function
           | Text text -> String.for_all (fun c -> c = ' ' || c = '\n') text
           | Element ("action-text-attachment",child_attrs,_,_) -> attr child_attrs "presentation" = Some "gallery"
           | _ -> false) children) then
        let members = List.filter (function Element _ -> true | Text _ -> false) children in
        (match render_nodes ~resolve_sgid ~resolve_gid ?request_host ~depth members with
         | Error e -> Error e
         | Ok inner -> Ok ("<div class=\"attachment-gallery attachment-gallery--" ^
             string_of_int (List.length members) ^ "\">\n  " ^ inner ^ "\n</div>"))
      else
        (match render_nodes ~resolve_sgid ~resolve_gid ?request_host ~depth children with
         | Error e -> Error e
         | Ok inner ->
           let opening = "<" ^ name ^ serialize_attrs (sanitized_attrs attrs) ^ ">" in
           Ok (if List.mem name void_tags then opening else opening ^ inner ^ "</" ^ name ^ ">"))
and render_nodes ~resolve_sgid ~resolve_gid ?request_host ~depth nodes =
  if depth > 400 then Error "rich-text nested content exceeds 400 levels"
  else let rec loop acc = function
    | [] -> Ok (String.concat "" (List.rev acc))
    | node :: rest ->
      (match render_node ~resolve_sgid ~resolve_gid ?request_host ~depth node with
       | Error e -> Error e | Ok html -> loop (html::acc) rest)
  in loop [] nodes

let rec attachments nodes =
  List.concat_map (function
    | Text _ -> []
    | (Element ("action-text-attachment",_,_,_) as node) -> [node]
    | Element (_,_,children,_) -> attachments children) nodes

let rec has_div nodes = List.exists (function
  | Text _ -> false
  | Element ("div",_,_,_) -> true
  | Element (_,_,children,_) -> has_div children) nodes

let normalize_tweet_url value =
  let lower = String.lowercase_ascii value in
  if not (contains_substring lower "x.com" || contains_substring lower "twitter.com") then value
  else
    let value = match String.index_opt value '?' with
      | Some i -> String.sub value 0 i | None -> value in
    let lower = String.lowercase_ascii value in
    let value = if starts "https://x.com/" lower then
      "https://twitter.com/" ^ String.sub value 14 (String.length value - 14)
    else if starts "http://x.com/" lower then
      "http://twitter.com/" ^ String.sub value 13 (String.length value - 13)
    else value in
    if starts "HTTPS://" value then "https://" ^ String.sub value 8 (String.length value - 8)
    else if starts "HTTP://" value then "http://" ^ String.sub value 7 (String.length value - 7)
    else value

let solo_unfurled ?request_host nodes html ~resolve_sgid =
  let embeds = List.filter (function
    | Element (_,attrs,_,_) -> is_og attrs
    | Text _ -> false) (attachments nodes) in
  match embeds with
  | [((Element (_,attrs,_,_)) as embed)] ->
    let href,_,_,_ = og_from_attrs ?request_host attrs in
    let plain = to_plain_text ~resolve_sgid html in
    (match href,plain with
     | Some href, Ok plain when normalize_tweet_url href = normalize_tweet_url plain ->
       let div_body = has_div nodes in
       let rec change node = match node with
         | Text _ -> Some node
         | Element ("div",attrs,_,ns) when div_body ->
           Some (Element ("div",attrs,[embed],ns))
         | Element ("p",_,children,_) when not div_body && attachments children = [] -> None
         | Element (name,attrs,children,ns) ->
           Some (Element (name,attrs,List.filter_map change children,ns)) in
       List.filter_map change nodes
     | _ -> nodes)
  | _ -> nodes

let fast_autolink_enabled = Sys.getenv_opt "CAMPFIRE_FAST_AUTOLINK" <> Some "0"

let starts_at value at prefix =
  let n = String.length prefix in
  if not fast_autolink_enabled then
    at + n <= String.length value && String.sub value at n = prefix
  else
    let rec same i =
      i = n || (String.unsafe_get value (at+i) = String.unsafe_get prefix i &&
                same (i+1)) in
    at >= 0 && at + n <= String.length value && same 0

let ascii_word = function
  | 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' -> true
  | _ -> false

let autolink_serialized_text text =
  (* rails_autolink runs after Nokogiri has serialized the sanitized DOM.
     Entities such as &nbsp; and &gt; therefore participate in URL matching. *)
  let n = String.length text in
  let lower = String.lowercase_ascii text in
  let out = Buffer.create (n + 32) in
  let schemes = ["ed2k"; "ftp"; "http"; "https"; "irc"; "mailto";
    "news"; "gopher"; "nntp"; "telnet"; "webcal"; "xmpp";
    "callto"; "feed"; "svn"; "urn"; "aim"; "rsync";
    "tag"; "ssh"; "sftp"; "rtsp"; "afs"; "file"] in
  let prefixes = if fast_autolink_enabled then
      List.map (fun scheme -> scheme ^ "://") schemes else [] in
  let token_end from =
    let i = ref from in
    while !i < n && not (List.mem text.[!i] [' '; '\t'; '\r'; '\n'; '\011'; '\012'; '"']) do incr i done;
    !i in
  let trimmed_end from finish =
    let i = ref finish in
    let brackets = [|'['; ']'; '('; ')'; '{'; '}'|] in
    let counts = Array.make 6 0 in
    let index c =
      let rec find k = if k = 6 then None else
        if brackets.(k) = c then Some k else find (k+1) in find 0 in
    for j=from to finish-1 do
      match index text.[j] with Some k -> counts.(k) <- counts.(k)+1 | None -> ()
    done;
    let continue = ref true in
    while !continue && !i > from do
      let c = text.[!i-1] in
      if Char.code c >= 128 then (
        let first = ref (!i-1) in
        while !first > from && (Char.code text.[!first] land 0xc0) = 0x80 do decr first done;
        let first_byte = Char.code text.[!first] in
        let symbol = if first_byte >= 0xe0 && first_byte < 0xf0 && !first+2 < !i then
          let codepoint = ((first_byte land 0x0f) lsl 12) lor
            ((Char.code text.[!first+1] land 0x3f) lsl 6) lor
            (Char.code text.[!first+2] land 0x3f) in
          codepoint >= 0x2600 && codepoint <= 0x27bf
        else false in
        if first_byte >= 0xf0 || symbol then i := !first
        else continue := false)
      else if c = '>' then (decr i; continue := false)
      else if List.mem c ['.'; ','; '!'; '?'; ')'; ']'; '}'; ':'; '\''] then (
        decr i;
        (match index c with Some k -> counts.(k) <- counts.(k)-1 | None -> ());
        let opening = match c with ')' -> Some '(' | ']' -> Some '[' | '}' -> Some '{' | _ -> None in
        match opening with
        | Some opening when
            (match index opening,index c with Some a,Some b -> counts.(a) > counts.(b) | _ -> false) ->
          incr i; continue := false
        | _ -> ())
      else continue := false
    done;
    !i in
  let add_link ~href ~label =
    Buffer.add_string out "<a target=\"_blank\" href=\"";
    Buffer.add_string out (replace_all href "\"" "&quot;");
    Buffer.add_string out "\">";
    Buffer.add_string out label;
    Buffer.add_string out "</a>" in
  let add_email email =
    let href = Buffer.create (String.length email + 16) in
    Buffer.add_string href "mailto:";
    String.iter (fun c ->
      if ascii_word c || List.mem c ['-'; '.'; '_'; '~'; '@'] then Buffer.add_char href c
      else Buffer.add_string href (Printf.sprintf "%%%02X" (Char.code c))) email;
    Buffer.add_string out "<a target=\"_blank\" href=\"";
    Buffer.add_string out (escape (Buffer.contents href));
    Buffer.add_string out "\">";
    Buffer.add_string out (replace_all email "'" "&#39;");
    Buffer.add_string out "</a>" in
  let rec loop i =
    if i >= n then () else
    let matching_prefix = if fast_autolink_enabled then
      List.find_opt (starts_at lower i) prefixes
      else Option.map (fun scheme -> scheme ^ "://")
        (List.find_opt (fun scheme ->
          starts_at lower i (scheme ^ "://")) schemes) in
    let scheme = match matching_prefix with
      | Some prefix -> Some (prefix,false)
      | None when starts_at lower i "www." -> Some ("www.",true)
      | None -> None in
    match scheme with
    | Some (prefix,bare) when i + String.length prefix < n ->
        let finish = token_end i in
        let linked_end = trimmed_end i finish in
        let label = String.sub text i (linked_end-i) in
        let label, trailing_gt =
          if String.ends_with ~suffix:"&gt;" label then
            String.sub label 0 (String.length label - 4), "&gt;"
          else label, "" in
        let valid_bare =
          if not bare then true else
          match String.rindex_opt label '.' with
          | Some dot -> dot > 3 && String.length label - dot - 1 >= 2
          | None -> false in
        if linked_end <= i + String.length prefix || not valid_bare then
          (Buffer.add_char out text.[i]; loop (i+1))
        else (
          add_link ~href:(if bare then "http://" ^ label else label) ~label;
          Buffer.add_string out (replace_all
            (String.sub text linked_end (finish-linked_end)) "'" "&#39;");
          Buffer.add_string out trailing_gt;
          loop finish)
    | _ ->
        let local_char = function
          | 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' | '.' | '!' | '#' | '$' | '%'
          | '&' | '\'' | '*' | '+' | '-' | '/' | '=' | '?' | '^' | '`' | '{' | '|'
          | '}' | '~' -> true | _ -> false in
        if local_char text.[i] && (i = 0 || not (local_char text.[i-1])) then (
          let at = ref i in
          while !at < n && local_char text.[!at] && text.[!at] <> '@' do incr at done;
          if !at < n && text.[!at] = '@' && !at > i then (
            let j = ref (!at+1) in
            while !j < n && (ascii_word text.[!j] || text.[!j] = '.' || text.[!j] = '-') &&
              not (starts_at lower !j "http://" || starts_at lower !j "https://" ||
                (starts_at lower !j "www." && !j > !at+1 &&
                 String.contains (String.sub text (!at+1) (!j - !at - 1)) '.')) do incr j done;
            let finish = trimmed_end (!at+1) !j in
            let domain = String.sub text (!at+1) (finish - !at - 1) in
            if String.contains domain '.' && not (String.ends_with ~suffix:"." domain) then (
              let email = String.sub text i (finish-i) in
              add_email email;
              loop finish)
            else (Buffer.add_char out text.[i]; loop (i+1)))
          else (Buffer.add_char out text.[i]; loop (i+1)))
        else if i+1 < n && text.[i] = '\xC2' && text.[i+1] = '\xA0' then
          (Buffer.add_string out "&nbsp;"; loop (i+2))
        else (Buffer.add_char out text.[i]; loop (i+1))
  in loop 0; Buffer.contents out

let rec present_node = function
  | Text text -> escape_text text
  | Element (name,attrs,children,html_namespace) ->
      if not html_namespace || name = "#comment" then "" else
      let children = String.concat "" (List.map present_node children) in
      if not (List.mem name presentation_tags) then children
      else let attrs = sanitized_attrs_with presentation_attrs attrs in
        let attrs = String.concat "" (List.map (fun (key,value) ->
          let value = escape_nokogiri_attr value
            |> fun v -> replace_all v "<" "&lt;"
            |> fun v -> replace_all v ">" "&gt;" in
          " " ^ key ^ "=\"" ^ value ^ "\"") attrs) in
        let opening = "<" ^ name ^ attrs ^ ">" in
        if List.mem name void_tags then opening else opening ^ children ^ "</" ^ name ^ ">"

let autolink_html html =
  let n = String.length html in
  let out = Buffer.create (n + 64) in
  let rec scan at anchor_depth =
    if at < n then
      if html.[at] = '<' then
        match String.index_from_opt html at '>' with
        | None -> Buffer.add_substring out html at (n-at)
        | Some finish ->
          let tag = String.sub html at (finish-at+1) in
          Buffer.add_string out tag;
          let anchor_depth =
            if tag = "</a>" then max 0 (anchor_depth-1)
            else if starts "<a " tag || tag = "<a>" then anchor_depth+1
            else anchor_depth in
          scan (finish+1) anchor_depth
      else
        let finish = match String.index_from_opt html at '<' with
          | None -> n | Some i -> i in
        let part = String.sub html at (finish-at) in
        Buffer.add_string out (if anchor_depth > 0 then part else autolink_serialized_text part);
        scan finish anchor_depth in
  scan 0 0;
  Buffer.contents out

let render ?(resolve_sgid=(fun _ -> None)) ?(resolve_gid=(fun _ -> None)) ?request_host html =
  match load_nodes html with
  | Error e -> Error e
  | Ok nodes ->
    let nodes = solo_unfurled ?request_host nodes html ~resolve_sgid in
    (match render_nodes ~resolve_sgid ~resolve_gid ?request_host ~depth:0 nodes with
     | Error e -> Error e
     | Ok body ->
       let layout = "<div class=\"lexxy-content\">\n  " ^ String.trim body ^ "\n</div>\n" in
       Result.map (fun nodes -> String.concat "" (List.map present_node nodes) |> autolink_html)
         (parse_raw_nodes layout))

let present_message ?(resolve_sgid=(fun _ -> None)) ?(resolve_gid=(fun _ -> None)) ?request_host html =
  match render ~resolve_sgid ~resolve_gid ?request_host html with Ok html -> html | Error _ -> ""

let rails_json_string value =
  Yojson.Basic.to_string (`String value)
  |> fun json -> replace_all json "&" "\\u0026"
  |> fun json -> replace_all json "<" "\\u003c"
  |> fun json -> replace_all json ">" "\\u003e"

let put_attr attrs key value =
  if List.mem_assoc key attrs then
    List.map (fun (name,old) -> name, if name = key then value else old) attrs
  else attrs @ [key,value]

let rec editable_node ~resolve_sgid ~resolve_gid ?request_host = function
  | Text _ as node -> Ok node
  | Element (name,attrs,children,html_namespace) ->
    let rec map_children acc = function
      | [] -> Ok (List.rev acc)
      | child::rest ->
        (match editable_node ~resolve_sgid ~resolve_gid ?request_host child with
         | Error _ as e -> e | Ok child -> map_children (child::acc) rest) in
    if name = "action-text-attachment" then
      (if is_og attrs then
         match og_error attrs with
         | Some e -> Error e
         | None ->
         let render_attrs = match attr attrs "href" with
           | Some href when String.contains href '"' -> List.remove_assoc "href" attrs
           | _ -> attrs in
         let content = render_og ?request_host render_attrs in
         let content = match attr attrs "url" with
           | Some url when String.trim url <> "" -> content
           | _ -> rails_json_string content in
         let attrs = put_attr attrs "content-type" og_content_type in
         Result.map (fun children -> Element (name,put_attr attrs "content" content,children,html_namespace))
           (map_children [] children)
       else match resolve_attachment_user ~resolve_sgid ~resolve_gid attrs with
       | Error e -> Error e
       | Ok (Some user,_) ->
           let attrs = attrs
             |> fun attrs -> put_attr attrs "content-type" "application/vnd.campfire.mention"
             |> fun attrs -> put_attr attrs "content" (rails_json_string (render_mention user)) in
           Result.map (fun children -> Element (name,attrs,children,html_namespace))
             (map_children [] children)
       | Ok (None,_) ->
         let kind = Option.value (attr attrs "content-type") ~default:"" in
         if ((String.contains kind 'h' && contains_substring kind "html" &&
              (match attr attrs "content" with Some value -> String.trim value <> "" | None -> false)) ||
             ((starts "image" kind || starts "video/" kind) && attr attrs "url" <> None))
         then Error "Action Text attachable has no attachable_content_type"
         else Ok (Text ""))
    else
      Result.map (fun children -> Element (name,attrs,children,html_namespace))
        (map_children [] children)

let rec normalize_mathml_editable = function
  | Text _ as node -> node
  | Element ("mtext",attrs,children,ns) ->
    let children = List.concat_map (fun child ->
      match child with
      | Element ("mglyph",mg_attrs,[Element ("style",style_attrs,[Text markup],style_ns)],mg_ns)
        when String.starts_with ~prefix:"<img" markup ->
          (match parse_nodes markup with
           | Ok [Element ("img",_,_,_) as image] ->
             [Element ("mglyph",mg_attrs,[Element ("style",style_attrs,[],style_ns)],mg_ns); image]
           | _ -> [normalize_mathml_editable child])
      | _ -> [normalize_mathml_editable child]) children in
    Element ("mtext",attrs,children,ns)
  | Element (name,attrs,children,ns) ->
    Element (name,attrs,List.map normalize_mathml_editable children,ns)

let editor_heading = function
  | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" -> true
  | _ -> false

let rec normalize_editor_tree ~in_form ~foreign nodes =
  List.concat_map (function
    | Text _ as node -> [node]
    | Element (name,attrs,children,html_namespace) ->
      let foreign_child = foreign || not html_namespace in
      let children = normalize_editor_tree
        ~in_form:(in_form || (name = "form" && html_namespace))
        ~foreign:foreign_child children in
      if name = "form" && html_namespace && in_form && not foreign then
        children
      else if html_namespace && editor_heading name then
        let rec split before = function
          | (Element (nested,_,_,true) :: _ as after) when editor_heading nested ->
            Some (List.rev before, after)
          | child :: rest -> split (child::before) rest
          | [] -> None in
        (match split [] children with
         | Some (before,after) ->
           Element (name,attrs,before,html_namespace) :: after
         | None -> [Element (name,attrs,children,html_namespace)])
      else [Element (name,attrs,children,html_namespace)]) nodes

let editable_value ?(resolve_sgid=(fun _ -> None)) ?(resolve_gid=(fun _ -> None)) ?request_host html =
  match parse_nodes html with
  | Error e -> Error e
  | Ok nodes ->
    let rec map acc = function
      | [] ->
        let body = String.concat "" (List.rev acc) in
        Ok (if String.trim body = "" then None else Some body)
      | node::rest ->
        (match editable_node ~resolve_sgid ~resolve_gid ?request_host node with
         | Error e -> Error e
         | Ok node -> map (serialize_canonical node::acc) rest) in
    map [] (normalize_editor_tree ~in_form:false ~foreign:false
      (List.map normalize_mathml_editable nodes))

let mentioned_user_ids ~resolve_sgid html =
  match load_nodes html with
  | Error e -> Error e
  | Ok nodes ->
    let seen = Hashtbl.create 8 in
    let ids = ref [] in
    let rec walk = function
      | Text _ -> ()
      | Element (name,attrs,children,_) ->
        if name = "action-text-attachment" then
          (match Option.bind (attr attrs "sgid") resolve_sgid with
           | Some user when not (Hashtbl.mem seen user.id) ->
             Hashtbl.add seen user.id (); ids := user.id :: !ids
           | _ -> ());
        List.iter walk children in
    List.iter walk nodes;
    Ok (List.rev !ids)

let without_recipient_mentions text ~recipient_name =
  replace_all text ("@" ^ recipient_name) "" |> String.trim

let require = function Ok value -> value | Error error -> invalid_arg error
let db_adapter_with_gid ~resolve_gid ~resolve_sgid = {
  Db_messages.to_plain_text = (fun db html ->
    to_plain_text ~resolve_sgid:(resolve_sgid db) ~resolve_gid:(resolve_gid db) html |> require);
  mentioned_user_ids = (fun db html ->
    mentioned_user_ids ~resolve_sgid:(resolve_sgid db) html |> require);
}

let db_adapter ~resolve_sgid =
  db_adapter_with_gid ~resolve_gid:(fun _ _ -> None) ~resolve_sgid

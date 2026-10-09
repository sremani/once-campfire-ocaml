(** Rails MIME negotiation over ActionDispatch's registration order. *)

type t = Html | Text | Js | Css | Json | Xml | Turbo_stream | All | Other of string
type error = Invalid_mime_type of string

let mime = function
  | Html -> "text/html" | Text -> "text/plain" | Js -> "text/javascript"
  | Css -> "text/css" | Json -> "application/json" | Xml -> "application/xml"
  | Turbo_stream -> "text/vnd.turbo-stream.html" | All -> "*/*" | Other s -> s

let registered = [
  Html; Text; Js; Css; Other "text/calendar"; Other "text/csv";
  Other "text/vcard"; Other "text/vtt"; Other "text/markdown";
  Other "image/png"; Other "image/jpeg"; Other "image/gif";
  Other "image/bmp"; Other "image/tiff"; Other "image/svg+xml";
  Other "image/webp"; Other "video/mpeg"; Other "audio/mpeg";
  Other "audio/ogg"; Other "audio/aac"; Other "video/webm";
  Other "video/mp4"; Other "font/otf"; Other "font/ttf";
  Other "font/woff"; Other "font/woff2"; Xml; Other "application/rss+xml";
  Other "application/atom+xml"; Other "application/x-yaml";
  Other "multipart/form-data"; Other "application/x-www-form-urlencoded";
  Json; Other "application/pdf"; Other "application/zip";
  Other "application/gzip"; Turbo_stream;
]

let extensions = [
  "html", Html; "xhtml", Html; "text", Text; "txt", Text;
  "js", Js; "css", Css; "json", Json; "xml", Xml;
  "svg", Other "image/svg+xml"; "png", Other "image/png";
  "jpg", Other "image/jpeg"; "jpeg", Other "image/jpeg";
  "gif", Other "image/gif"; "webp", Other "image/webp";
  "rss", Other "application/rss+xml"; "atom", Other "application/atom+xml";
  "pdf", Other "application/pdf"; "turbo_stream", Turbo_stream;
]
let synonyms = [
  "application/xhtml+xml", Html;
  "application/javascript", Js; "application/x-javascript", Js;
  "text/xml", Xml; "application/x-xml", Xml;
  "text/x-json", Json; "application/jsonrequest", Json;
  "application/problem+json", Json;
  "audio/mp4", Other "audio/aac";
  "text/yaml", Other "application/x-yaml";
  "application/x-gzip", Other "application/gzip";
]

let of_extension extension = List.assoc_opt extension extensions
let of_media_type media =
  if media = "*/*" then Some All
  else match List.assoc_opt media synonyms with
    | Some format -> Some format
    | None -> List.find_opt (fun value -> mime value = media) registered
let base_type value = String.split_on_char ';' value |> List.hd |> String.trim

let valid_mime media =
  let media = base_type media in
  if media = "*/*" then true
  else match String.split_on_char '/' media with
    | [kind; subtype] ->
        let valid_name name =
          String.length name > 0 && String.length name <= 127 &&
          let okay c = match c with
            | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9'
            | '!' | '#' | '$' | '&' | '-' | '^' | '_' | '.' | '+' -> true
            | _ -> false in
          String.for_all okay name in
        valid_name kind && (subtype = "*" || valid_name subtype)
    | _ -> false

let trailing_star media =
  let prefix = if String.starts_with ~prefix:"text/*" media then Some "text/"
    else if String.starts_with ~prefix:"application/*" media then Some "application/"
    else None in
  Option.map (fun prefix -> List.filter (fun value ->
    String.starts_with ~prefix (mime value) ||
    List.exists (fun (alias, format) -> format = value && String.starts_with ~prefix alias) synonyms)
      registered) prefix

let scan_accept_items header =
  let n = String.length header in
  let rec scan i acc =
    if i >= n then List.rev acc
    else if header.[i] = ',' || header.[i] = ' ' || header.[i] = '\t' || header.[i] = '"' then scan (i + 1) acc
    else
      let start = i in
      let rec finish j quoted =
        if j >= n then j
        else if header.[j] = '"' then finish (j + 1) (not quoted)
        else if header.[j] = ',' && not quoted then j
        else finish (j + 1) quoted in
      let stop = finish i false in
      scan (stop + 1) (String.sub header start (stop - start) :: acc)
  in scan 0 []

let find_q item from =
  let n = String.length item in
  let rec scan i =
    if i >= n then None
    else if item.[i] <> ';' then scan (i + 1)
    else
      let rec spaces j = if j < n && (item.[j] = ' ' || item.[j] = '\t') then spaces (j + 1) else j in
      let j = spaces (i + 1) in
      if j + 1 < n && item.[j] = 'q' && item.[j + 1] = '=' then
        Some (i, j + 2 + (if j + 2 < n && item.[j + 2] = '"' then 1 else 0))
      else scan (i + 1)
  in scan from

let parse_accept header =
  let weighted = scan_accept_items header |> List.mapi (fun index item ->
    let media, q = match find_q item 0 with
      | None -> String.trim item, None
      | Some (start, after) ->
          let media = String.sub item 0 start |> String.trim in
          let end_ = match find_q item after with
            | None -> String.length item | Some (stop, _) -> stop in
          let value = String.sub item after (end_ - after) in
          media, if value = "" && after = String.length item then None else Some value in
    let names = match trailing_star media with
      | Some values -> List.map mime values | None -> [media] in
    List.mapi (fun subindex media ->
      let q = match q with Some value -> Ruby_compat.to_f value
        | None when media = "*/*" -> 0.0 | None -> 1.0 in
      media, Float.trunc (q *. 100.), index * 100 + subindex) names)
    |> List.concat in
  let weighted = List.sort (fun (_, qa, ia) (_, qb, ib) ->
    let c = Float.compare qb qa in if c = 0 then Int.compare ia ib else c) weighted in
  let had_app_xml = List.exists (fun (media, _, _) -> media = "application/xml") weighted in
  let text_xml = List.find_opt (fun (media, _, _) -> media = "text/xml") weighted in
  let weighted = match text_xml with
    | None -> weighted
    | Some (_, q, _) ->
        let has_app = List.exists (fun (media, _, _) -> media = "application/xml") weighted in
        if has_app then
          List.filter (fun (media, _, _) -> media <> "text/xml") weighted
          |> List.map (fun (media, old_q, i) ->
            if media = "application/xml" then media, max q old_q, i else media, old_q, i)
        else List.map (fun (media, q, i) ->
          if media = "text/xml" then "application/xml", q, i else media, q, i) weighted in
  let weighted = List.sort (fun (ma, qa, ia) (mb, qb, ib) ->
    let c = Float.compare qb qa in
    if c <> 0 then c
    else if had_app_xml && ma = "application/xml" && String.ends_with ~suffix:"+xml" mb then 1
    else if had_app_xml && mb = "application/xml" && String.ends_with ~suffix:"+xml" ma then -1
    else Int.compare ia ib) weighted in
  let rec collect acc = function
    | [] -> Ok acc
    | (media, _, _) :: rest ->
        if not (valid_mime media) then Error (Invalid_mime_type media)
        else match of_media_type media with
          | None -> collect acc rest
          | Some format -> collect (if List.mem format acc then acc else acc @ [format]) rest
  in collect [] weighted

let browser_like accept =
  let compact = String.split_on_char ' ' accept |> String.concat "" in
  let rec find i =
    if i + 3 > String.length compact then false
    else if String.sub compact i 3 = "*/*" &&
      ((i > 0 && compact.[i - 1] = ',') ||
       (i + 3 < String.length compact && compact.[i + 3] = ','))
    then true else find (i + 1) in find 0

let parse_formats ?format_param ?accept ?content_type ~path ~xhr () =
  match format_param with
  | Some format -> Ok (Option.to_list (of_extension format))
  | None ->
      let accept_value = Option.value accept ~default:"" |> String.trim in
      if (xhr && (accept_value <> "" || content_type <> None)) ||
         (accept_value <> "" && not (browser_like accept_value)) then
        if accept_value <> "" then parse_accept accept_value
        else (match content_type with
          | None -> Ok []
          | Some content_type ->
              let media = base_type content_type |> String.lowercase_ascii in
              if valid_mime media then Ok (Option.to_list (of_media_type media))
              else Error (Invalid_mime_type media))
      else match String.rindex_opt path '.' with
        | Some i ->
            let ext = String.sub path (i + 1) (String.length path - i - 1) in
            (match of_extension ext with
             | Some format -> Ok [format]
             | None -> Ok [if xhr then Js else Html])
        | None -> Ok [if xhr then Js else Html]

let formats ?format_param ?accept ?content_type ~path ~xhr () =
  match parse_formats ?format_param ?accept ?content_type ~path ~xhr () with
  | Ok formats -> formats | Error _ -> []

let negotiate acceptable offered =
  if List.mem All acceptable then (match offered with [] -> None | first :: _ -> Some first)
  else List.find_opt (fun value -> List.mem value acceptable || value = All) offered

(** Guarded link unfurling, following the Rails/OpenGraph model and Rust port.
    Every GET and HEAD uses a publicly resolved address pinned by libcurl. *)

open Lwt.Infix

type outcome = Json of string | No_content | Raised of string
type resolver = Network_guard.resolver
type transport = Outbound_http.request -> (Outbound_http.response,string) result Lwt.t
type node = Text of string | Element of string * (string * string) list * node list * bool
external gumbo_parse : string -> (node list,string) result = "caml_campfire_gumbo_parse"

let max_body_size = 5 * 1024 * 1024
let max_redirects = 10
let max_concurrent = 16
let slots = Lwt_pool.create max_concurrent (fun () -> Lwt.return_unit)

let is_blank value =
  String.trim value = "" ||
  (try Uutf.String.fold_utf_8 (fun empty _ value ->
    empty && (match value with
      | `Uchar ch ->
        let n=Uchar.to_int ch in
        n=0xa0 || n=0x2000 || n=0x2001 || n=0x2002 || n=0x2003 ||
        n=0x2004 || n=0x2005 || n=0x2006 || n=0x2007 || n=0x2008 ||
        n=0x2009 || n=0x200a || n=0x2028 || n=0x2029 || n=0x202f ||
        n=0x205f || n=0x3000 || n<=0x20
      | `Malformed _ -> false)) true value
   with _ -> false)

let attr attrs key = List.assoc_opt key attrs

let decode_utf8_latin1 bytes =
  let output=Buffer.create (String.length bytes) in
  Uutf.String.fold_utf_8 (fun () _ decoded ->
    match decoded with
    | `Uchar ch -> Uutf.Buffer.add_utf_8 output ch
    | `Malformed bytes -> String.iter (fun byte ->
        Uutf.Buffer.add_utf_8 output (Uchar.of_int (Char.code byte))) bytes)
    () bytes;
  Buffer.contents output

let remove_og text =
  let output=Buffer.create (String.length text) in
  let rec loop i =
    if i>=String.length text then Buffer.contents output
    else if i+3<=String.length text && String.sub text i 3="og:"
    then loop (i+3)
    else (Buffer.add_char output text.[i];loop (i+1)) in
  loop 0

let rec metas_of_node = function
  | Text _ -> []
  | Element ("meta", attrs, children, _) -> attrs :: List.concat_map metas_of_node children
  | Element (_,_,children,_) -> List.concat_map metas_of_node children

let meta_encoding metas =
  match List.find_opt (fun attrs -> List.mem_assoc "charset" attrs) metas with
  | Some attrs -> attr attrs "charset"
  | None ->
    let matching = List.find_opt (fun attrs ->
      Option.is_some (attr attrs "content") &&
      match attr attrs "http-equiv" with
      | Some value -> String.lowercase_ascii value = "content-type"
      | None -> false) metas in
    match matching with
    | None -> None
    | Some attrs ->
      let value=Option.get (attr attrs "content") |> String.lowercase_ascii in
      let needle="charset=" in
      let rec find i =
        if i+String.length needle>String.length value then None
        else if String.sub value i (String.length needle)=needle then
          let start=i+String.length needle in
          let rec stop j = if j<String.length value &&
            (match value.[j] with 'a'..'z'|'0'..'9'|'_'|'-' -> true | _ -> false)
            then stop (j+1) else j in
          let last=stop start in
          if last=start then None else Some (String.sub value start (last-start))
        else find (i+1) in find 0

let attributes html =
  let metas = match gumbo_parse (decode_utf8_latin1 html) with
    | Error _ -> [] | Ok nodes -> List.concat_map metas_of_node nodes in
  let has_encoding = Option.is_some (meta_encoding metas) in
  let wanted=["title";"url";"image";"description"] in
  let values=Hashtbl.create 4 in
  List.iter (fun attrs ->
    let property=attr attrs "property" and name=attr attrs "name" in
    let is_og = (match property with Some p -> String.starts_with ~prefix:"og:" p | _ -> false) ||
      (match name with Some n -> String.starts_with ~prefix:"og:" n | _ -> false) in
    if is_og then
      let key=Option.value ~default:"" (match property with Some _ -> property | None -> name) in
      let key=remove_og key in
      let content=attr attrs "content" in
      match content with
      | Some content when List.mem key wanted && not (is_blank content) ->
        let content=if has_encoding then content else
          String.to_seq content |> Seq.filter (fun c -> Char.code c<128)
          |> String.of_seq in
        Hashtbl.replace values key content
      | _ -> ()) metas;
  List.filter_map (fun key -> Option.map (fun value -> key,Some value)
    (Hashtbl.find_opt values key)) wanted

let rec text_of_nodes nodes =
  String.concat "" (List.map (function
    | Text value -> value
    | Element (_,_,children,_) -> text_of_nodes children) nodes)

let strip_tags value =
  match gumbo_parse value with
  | Error _ -> value
  | Ok nodes -> text_of_nodes nodes

let sanitize value =
  let value=strip_tags value in
  let output=Buffer.create (String.length value) in
  Uutf.String.fold_utf_8 (fun () _ decoded ->
    match decoded with
    | `Uchar ch ->
      let n=Uchar.to_int ch in
      if n=38 then Buffer.add_string output "&amp;"
      else if n=60 then Buffer.add_string output "&lt;"
      else if n=62 then Buffer.add_string output "&gt;"
      else if n=160 then Buffer.add_string output "&nbsp;"
      else Uutf.Buffer.add_utf_8 output ch
    | `Malformed _ -> ()) () value;
  Buffer.contents output

let valid_url_chars url =
  String.for_all (fun c -> Char.code c>=33 && Char.code c<127) url

let uri_http url =
  if not (valid_url_chars url) then None
  else try
    let uri=Uri.of_string url in
    let scheme=Uri.scheme uri |> Option.map String.lowercase_ascii in
    match scheme,Uri.host uri with
    | (Some "http" | Some "https"),Some host when host<>"" ->
      let port=Uri.port uri in
      if (match port with Some p -> p<1 || p>65535 | None -> false)
      then None else Some (uri,host)
    | _ -> None
  with _ -> None

let media_url url =
  let suffixes=["zip";"tar";"tar.gz";"tar.bz2";"tar.xz";"gz";"bz2";
    "rar";"7z";"dmg";"exe";"msi";"pkg";"deb";"iso";
    "jpg";"jpeg";"png";"gif";"bmp";"mp4";"mov";"avi";
    "mkv";"wmv";"flv";"heic";"heif";"mp3";"wav";
    "ogg";"aac";"wma";"webm";"ogv";"mpg";"mpeg"] in
  match uri_http url with
  | None -> false
  | Some (uri,_) ->
    let path=Uri.path uri in
    List.exists (fun ext ->
      let pattern="."^ext in
      let rec find i =
        if i+String.length pattern>String.length path then false
        else if String.sub path i (String.length pattern)=pattern &&
          (let after=i+String.length pattern in
           after=String.length path ||
           (match path.[after] with
            | 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' -> false
            | _ -> true)) then true
        else find (i+1) in find 0) suffixes

let host_header uri host =
  let https=Uri.scheme uri |> Option.map String.lowercase_ascii = Some "https" in
  let port=Option.value ~default:(if https then 443 else 80) (Uri.port uri) in
  if port=(if https then 443 else 80) then host
  else host^":"^string_of_int port

let request_target uri =
  let path=match Uri.path uri with "" -> "/" | value -> value in
  match Uri.verbatim_query uri with
  | None -> path | Some query -> path^"?"^query

let location_valid ~resolver url =
  match uri_http url with
  | Some (_,host) ->
    (match Network_guard.resolve ~resolver host with Ok ip -> Some ip | Error _ -> None)
  | None ->
    (* Rails checks the host even when the scheme is unsupported. *)
    (try if not (valid_url_chars url) then None else
      match Uri.host (Uri.of_string url) with
     | None -> None
     | Some host -> ignore (Network_guard.resolve ~resolver host);None
     with _ -> None)

let fetch ~resolver ~perform ~deadline ~meth url first_ip =
  let rec loop count url ip =
    if count>=max_redirects then Lwt.return_none
    else match uri_http url with
    | None -> Lwt.return_none
    | Some (uri,host) ->
      let request={Outbound_http.url;meth;pinned_ip=Some (Ipaddr.to_string ip);
        headers=Outbound_http.net_http_headers
          ~host:(Some (host_header uri host)) [];
        body="";connect_timeout=5.;read_timeout=5.;
        deadline;max_body=(if meth="HEAD" then 64*1024 else max_body_size);
        ca_bundle=None} in
      perform request >>= function
      | Error _ -> Lwt.return_none
      | Ok (response:Outbound_http.response) when response.status>=300 && response.status<400 ->
        (match Outbound_http.header response "location" with
         | None -> Lwt.return_none
         | Some next ->
           (match if uri_http next=None then None else location_valid ~resolver next with
            | None -> Lwt.return_none
            | Some ip -> loop (count+1) next ip))
      | Ok response -> Lwt.return_some response in
  loop 0 url first_ip

let read_html ~resolver ~perform ~deadline url =
  match location_valid ~resolver url with
  | None -> Lwt.return_none
  | Some _ when media_url url -> Lwt.return_none
  | Some ip ->
    fetch ~resolver ~perform ~deadline ~meth:"GET" url ip >|= function
    | Some response when response.status=200 &&
        Outbound_http.content_type response=Some "text/html" &&
        (match Outbound_http.header response "content-length" with
         | None -> true
         | Some value -> (try Int64.of_string value <= Int64.of_int max_body_size
            with _ -> false)) && String.length response.body<=max_body_size ->
      Some response.body
    | _ -> None

let image_type ~resolver ~perform ~deadline url =
  match location_valid ~resolver url with
  | None -> Lwt.return_none
  | Some ip ->
    fetch ~resolver ~perform ~deadline ~meth:"HEAD" url ip >|= function
    | None -> None
    | Some response -> Outbound_http.header response "content-type"

let replace_domain uri host = Uri.with_host uri (Some host) |> Uri.to_string

let from_url ~resolver ~perform ~deadline url =
  let tweet=match uri_http url with
    | Some (uri,host) ->
      List.mem host ["twitter.com";"www.twitter.com";"x.com";"www.x.com"] &&
      Uri.path uri<>"" && Uri.path uri<>"/"
    | None -> false in
  let fetched_url=if tweet then match uri_http url with
    | Some (uri,_) -> replace_domain uri "fxtwitter.com" | None -> url
    else url in
  read_html ~resolver ~perform ~deadline fetched_url >>= fun page ->
  if tweet && page=None then Lwt.return (Raised "NoMethodError")
  else
    let attrs=attributes (Option.value ~default:"" page) in
    let get key=List.assoc_opt key attrs |> Option.join in
    let canonical=get "url" in
    let canonical=match canonical with
      | None -> url
      | Some value ->
        (match location_valid ~resolver value with
         | Some _ -> value | None -> url) in
    let image=get "image" in
    (match image with
     | None -> Lwt.return_none
     | Some image ->
       image_type ~resolver ~perform ~deadline image >|= function
       | Some mime when List.mem (String.lowercase_ascii mime)
           ["image/jpeg";"image/png";"image/gif";"image/webp"] -> Some image
       | _ -> None) >>= fun image ->
    let assign key value attrs =
      if List.mem_assoc key attrs then
        List.map (fun (k,v) -> if k=key then k,value else k,v) attrs
      else attrs@[key,value] in
    let attrs=assign "url" (Some canonical) attrs |> assign "image" image in
    let attrs=List.fold_left (fun attrs key ->
      assign key (Option.map sanitize (get key)) attrs) attrs ["title";"description"] in
    let get key=List.assoc_opt key attrs |> Option.join in
    let present key=match get key with Some v -> not (is_blank v) | None -> false in
    let image_valid=match image with
        | None -> true
        | Some value -> Option.is_some (location_valid ~resolver value) in
    if not (present "title" && present "url" && present "description") ||
       not image_valid then Lwt.return No_content
      else
        let fields=List.map (fun (k,v) -> k,
          match v with None -> `Null | Some value -> `String value) attrs in
        let fields=fields@["context_for_validation",`Assoc ["context",`Null];
          "errors",`Assoc []] in
        let json=Yojson.Basic.to_string (`Assoc fields) in
        let output=Buffer.create (String.length json) in
        String.iter (function
          | '&' -> Buffer.add_string output "\\u0026"
          | '<' -> Buffer.add_string output "\\u003c"
          | '>' -> Buffer.add_string output "\\u003e"
          | c -> Buffer.add_char output c) json;
        Lwt.return (Json (Buffer.contents output))

let unfurl_with ?(resolver=Network_guard.system_resolver)
    ?(perform=Outbound_http.perform_lwt) ?(deadline=10.) url =
  let until=Unix.gettimeofday ()+.deadline in
  let job () =
    if String.starts_with ~prefix:"mailto:" url then Lwt.return (Raised "NoMethodError")
    else from_url ~resolver ~perform ~deadline:until url in
  Lwt.catch (fun () -> Lwt_unix.with_timeout deadline (fun () ->
    Lwt_pool.use slots job)) (function
    | Lwt_unix.Timeout -> Lwt.return No_content
    | _ -> Lwt.return No_content)

let unfurl url = unfurl_with url

let controller_adapter_with ?resolver ?perform url =
  unfurl_with ?resolver ?perform url >>= function
  | Json body -> Lwt.return_some body
  | No_content -> Lwt.return_none
  | Raised reason -> Lwt.fail_with reason

let controller_adapter url = controller_adapter_with url

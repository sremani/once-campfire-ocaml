(** Rack::Deflater response handling using the system zlib gzip encoder. *)

open Lwt.Infix

external compress : string -> string = "campfire_gzip"

type encoding = Gzip | Identity | Unacceptable

let quality text =
  let prefix = "q=" in
  if not (String.starts_with ~prefix text) then 1.0
  else
    let value = String.sub text 2 (String.length text - 2) in
    let rec digits i =
      if i < String.length value &&
         (match value.[i] with '0' .. '9' | '.' -> true | _ -> false)
      then digits (i + 1) else i in
    let count = digits 0 in
    if count = 0 then 1.0
    else Ruby_compat.to_f (String.sub value 0 count)

let parse_accept header =
  String.split_on_char ',' header
  |> List.filter_map (fun part ->
      let fields = String.split_on_char ';' part in
      let name = String.trim (List.hd fields) in
      if name = "" then None
      else
        let q = match List.tl fields with
          | [] -> 1.0
          | parameter :: _ -> quality (String.trim parameter) in
        Some (name, q))

let select accept =
  let pairs = parse_accept accept |> fun xs ->
    List.filteri (fun i _ -> i < 16) xs in
  let explicit name = List.mem_assoc name pairs in
  let expanded = List.concat_map (fun (name, q) ->
    if name = "*" then
      (if explicit "gzip" then [] else ["gzip", q]) @
      (if explicit "identity" then [] else ["identity", q])
    else [name, q]) pairs in
  let preference name = if name = "gzip" then 0 else if name = "identity" then 1 else 2 in
  let sorted = List.stable_sort (fun (name_a, qa) (name_b, qb) ->
    let order = Float.compare qb qa in
    if order <> 0 then order else Int.compare (preference name_a) (preference name_b)) expanded in
  let zeroed name = List.exists (fun (candidate, q) -> candidate = name && q = 0.0) expanded in
  let candidates = List.map fst sorted in
  let candidates = if List.mem "identity" candidates then candidates else candidates @ ["identity"] in
  let candidates = List.filter (fun name -> not (zeroed name)) candidates in
  let rec choose = function
    | [] -> Unacceptable
    | "gzip" :: _ -> Gzip
    | "identity" :: _ -> Identity
    | _ :: rest -> choose rest in
  choose candidates

let has_word value word =
  String.split_on_char ',' value
  |> List.exists (fun item -> String.trim item = word)

let should_deflate response =
  let status = Cohttp.Code.code_of_status (Cohttp.Response.status response) in
  let headers = Cohttp.Response.headers response in
  not (status <= 199 || status = 204 || status = 304) &&
  not (Option.value (Cohttp.Header.get headers "cache-control") ~default:""
       |> fun value -> has_word value "no-transform") &&
  (match Cohttp.Header.get headers "content-encoding" with
   | None -> true
   | Some value -> has_word value "identity") &&
  Cohttp.Header.get headers "content-length" <> Some "0"

let add_vary headers =
  let values = Cohttp.Header.get_multi headers "vary"
    |> List.concat_map (String.split_on_char ',')
    |> List.map String.trim in
  if List.exists (fun value -> value = "*" || String.lowercase_ascii value = "accept-encoding") values
  then headers
  else Cohttp.Header.replace headers "vary" (String.concat "," (values @ ["Accept-Encoding"]))

let apply ?parts request (response, body) =
  if not (should_deflate response) then Lwt.return (response, body)
  else
    let headers = Cohttp.Response.headers response |> add_vary in
    let accept = Cohttp.Header.get (Cohttp.Request.headers request) "accept-encoding"
      |> Option.value ~default:"" in
    match select accept with
    | Identity -> Lwt.return ({response with headers}, body)
    | Unacceptable ->
        let path = Uri.path (Request_uri.get request) in
        let message = "An acceptable encoding for the requested resource " ^ path ^
          " could not be found." in
        let headers = Cohttp.Header.of_list ["content-type", "text/plain";
          "content-length", string_of_int (String.length message)] in
        Lwt.return (Cohttp.Response.make ~status:`Not_acceptable ~headers (),
          Cohttp_lwt.Body.of_string message)
    | Gzip when Cohttp.Request.meth request = `HEAD ->
        (* Rack::Deflater still selects the representation for HEAD. The
           adapter has already dropped its body; only the gzip headers remain. *)
        let headers = headers
          |> fun h -> Cohttp.Header.replace h "content-encoding" "gzip"
          |> fun h -> Cohttp.Header.remove h "content-length" in
        Lwt.return ({response with headers}, Cohttp_lwt.Body.empty)
    | Gzip ->
        let wrap encoded =
          let headers = headers
            |> fun h -> Cohttp.Header.replace h "content-encoding" "gzip"
            |> fun h -> Cohttp.Header.remove h "content-length" in
          Cohttp.Response.make ~status:(Cohttp.Response.status response)
            ~headers (), Cohttp_lwt.Body.of_string encoded in
        (match parts,body with
         | Some parts, `Strings chunks when
             List.fold_left (fun size chunk -> size + String.length chunk) 0 chunks =
               Http_cache.Page_parts.length parts ->
             let mtime=Option.bind
               (Cohttp.Header.get headers "last-modified")
               Http_cache.parse_httpdate
               |> Option.map (fun time ->
                 Ptime.to_float_s time |> Int64.of_float |> Int64.to_int)
               |> Option.value ~default:0 in
             Lwt.return (wrap (Http_cache.Page_parts.gzip ~mtime parts))
         | _ -> Cohttp_lwt.Body.to_string body >|= fun plain ->
             wrap (compress plain))

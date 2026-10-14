(** Rails route recognition used as the front controller's route catalog. *)

type match_ = { endpoint : string; params : (string * string) list }

let normalized_path path =
  let path = String.split_on_char '?' path |> List.hd in
  let segments = String.split_on_char '/' path |> List.filter ((<>) "") in
  segments

let strip_format segment =
  match String.rindex_opt segment '.' with
  | None -> (segment, None)
  | Some index when index = 0 -> (segment, None)
  | Some index ->
      let base = String.sub segment 0 index in
      let format = String.sub segment (index + 1) (String.length segment - index - 1) in
      if format = "" then (segment, None) else (base, Some format)

let pattern_segments pattern =
  let suffix = "(.:format)" in
  let len = String.length pattern in
  let pattern =
    if len >= String.length suffix &&
       String.sub pattern (len - String.length suffix) (String.length suffix) = suffix
    then String.sub pattern 0 (len - String.length suffix)
    else pattern
  in
  normalized_path pattern

(* Route declarations do not change while the server runs. Splitting every
   declaration for every request dominated the route lookup allocation profile. *)
let compiled_routes =
  List.map (fun (verb, pattern, endpoint, defaults) ->
      (verb, pattern_segments pattern, endpoint, defaults)) Route_catalog.routes

let first_literal = function
  | [] -> Some ""
  | first :: _ when String.length first > 0 &&
      (first.[0] = ':' || first.[0] = '*' ||
       (String.length first > 1 && first.[0] = '@' && first.[1] = ':')) -> None
  | first :: _ -> Some first

(* Preserve catalog order inside each bucket. Dynamic first segments remain in
   every bucket, so they retain the same precedence as the Rails declaration. *)
let indexed_catalog =
  let verbs = List.map (fun (verb, _, _, _) -> verb) compiled_routes
    |> List.sort_uniq String.compare in
  List.map (fun verb ->
    let routes = List.filter (fun (candidate, _, _, _) -> candidate = verb)
        compiled_routes in
    let generic = List.filter (fun (_, pattern, _, _) ->
        first_literal pattern = None) routes in
    let literals = List.filter_map (fun (_, pattern, _, _) ->
        first_literal pattern) routes |> List.sort_uniq String.compare in
    let buckets = Hashtbl.create (List.length literals) in
    List.iter (fun literal ->
      Hashtbl.add buckets literal (List.filter (fun (_, pattern, _, _) ->
        match first_literal pattern with
        | None -> true | Some first -> first = literal) routes)) literals;
    verb, routes, generic, buckets) verbs

let route_index_enabled = Sys.getenv_opt "CAMPFIRE_ROUTE_INDEX" <> Some "0"

type path_segment = { raw : string; decoded : string }
let decode_segment raw = { raw; decoded = Uri.pct_decode raw }


let rec match_segments patterns segments params =
  match patterns, segments with
  | [], [] -> Some params
  | pattern :: rest, segment :: tail when String.length pattern > 0 && pattern.[0] = '*' ->
      if rest <> [] then None
      else Some ((String.sub pattern 1 (String.length pattern - 1),
                  String.concat "/" (List.map (fun segment -> segment.decoded)
                    (segment :: tail))) :: params)
  | pattern :: rest, segment :: tail ->
      let decoded = segment.decoded in
      let len = String.length pattern in
      if len > 0 && pattern.[0] = ':' && not (String.contains segment.raw '.') then
        match_segments rest tail ((String.sub pattern 1 (len - 1), decoded) :: params)
      else if len > 1 && pattern.[0] = '@' && pattern.[1] = ':' && String.length segment.raw > 1 && segment.raw.[0] = '@' then
        match_segments rest tail ((String.sub pattern 2 (len - 2), Uri.pct_decode (String.sub segment.raw 1 (String.length segment.raw - 1))) :: params)
      else if pattern = decoded then match_segments rest tail params
      else None
  | _ -> None

let lookup_catalog method_ path =
  let method_ = if method_ = "HEAD" then "GET" else method_ in
  let segments = normalized_path path in
  let candidates =
    match List.rev segments with
    | [] -> [([], None)]
    | last :: rest ->
        let base, format = strip_format last in
        (match format with
         | None -> [(segments, None)]
         | Some value -> [(List.rev (base :: rest), Some value); (segments, None)])
  in
  let candidates = List.map (fun (path, format) ->
      List.map decode_segment path, format) candidates in
  let routes = if not route_index_enabled then compiled_routes else
    match List.find_opt (fun (verb, _, _, _) -> verb = method_) indexed_catalog with
    | None -> []
    | Some (_, all, generic, buckets) ->
        let first = match candidates with
          | (segment :: _, _) :: _ -> segment.decoded
          | _ -> "" in
        let one_segment_format = match candidates with
          | ([_], Some _) :: _ -> true | _ -> false in
        if one_segment_format then all else
        Option.value (Hashtbl.find_opt buckets first) ~default:generic in
  let rec find_route = function
    | [] -> None
    | (verb, pattern, endpoint, defaults) :: rest when verb = method_ ->
        let rec find_candidate = function
          | [] -> find_route rest
          | (segments, format) :: candidates ->
              (match match_segments pattern segments [] with
               | None -> find_candidate candidates
               | Some params ->
                   let params = List.rev params in
                   let params = List.fold_left (fun acc (key, value) ->
                       if List.mem_assoc key acc then acc else (key, value) :: acc) params defaults in
                   let params = match format with None -> params | Some value -> ("format", value) :: List.remove_assoc "format" params in
                   Some { endpoint; params })
        in
        find_candidate candidates
    | _ :: rest -> find_route rest
  in
  find_route routes

(** Rails [recognize_path] checks that the target controller resolves. The pinned
    Rails reference declares [rooms/settings#show], but has no corresponding
    controller, so that route is present in the catalog while recognition raises
    [ActionController::RoutingError]. Keep the distinction explicit: the HTTP
    dispatcher can still inspect the declared route with [lookup_catalog]. *)
let recognize method_ path =
  match lookup_catalog method_ path with
  | Some { endpoint = "rooms/settings#show"; _ } -> None
  | route -> route

type method_selection = {
  effective_method : string;
  original_method : string option;
}

let media_type content_type =
  match content_type with
  | None -> None
  | Some content_type ->
      let base =
        content_type |> String.split_on_char ';' |> List.hd
        |> String.split_on_char ',' |> List.hd
        |> String.trim |> String.lowercase_ascii
      in
      if base = "" then None else Some base

let form_data_media_type content_type =
  match media_type content_type with
  | None -> true
  | Some media ->
      List.mem media ["application/x-www-form-urlencoded"; "multipart/form-data";
                      "multipart/related"; "multipart/mixed"]

(** Mirrors [kit::adapter::method_override] once form parsing has supplied
    [_method]. A present, invalid form value still takes precedence over the
    header. The original method is recorded only when a permitted override is
    applied, including POST-to-POST. *)
let effective_method ?content_type ?form_method ?header_method method_ =
  if method_ <> "POST" then { effective_method = method_; original_method = None }
  else
    let candidate =
      match form_method with
      | Some _ when form_data_media_type content_type -> form_method
      | _ -> header_method
    in
    match candidate with
    | None -> { effective_method = method_; original_method = None }
    | Some value ->
        let value = String.uppercase_ascii value in
        if List.mem value
             ["GET"; "HEAD"; "PUT"; "POST"; "DELETE"; "OPTIONS"; "PATCH";
              "LINK"; "UNLINK"]
        then { effective_method = value; original_method = Some "POST" }
        else { effective_method = method_; original_method = None }

let recognize_request ?content_type ?form_method ?header_method method_ path =
  let selection = effective_method ?content_type ?form_method ?header_method method_ in
  (selection, recognize selection.effective_method path)

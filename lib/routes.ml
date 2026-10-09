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

let rec match_segments patterns segments params =
  match patterns, segments with
  | [], [] -> Some params
  | pattern :: rest, segment :: tail when String.length pattern > 0 && pattern.[0] = '*' ->
      if rest <> [] then None
      else Some ((String.sub pattern 1 (String.length pattern - 1),
                  String.concat "/" (List.map Uri.pct_decode (segment :: tail))) :: params)
  | pattern :: rest, segment :: tail ->
      let decoded = Uri.pct_decode segment in
      let len = String.length pattern in
      if len > 0 && pattern.[0] = ':' && not (String.contains segment '.') then
        match_segments rest tail ((String.sub pattern 1 (len - 1), decoded) :: params)
      else if len > 1 && pattern.[0] = '@' && pattern.[1] = ':' && String.length segment > 1 && segment.[0] = '@' then
        match_segments rest tail ((String.sub pattern 2 (len - 2), Uri.pct_decode (String.sub segment 1 (String.length segment - 1))) :: params)
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
  let rec find_route = function
    | [] -> None
    | (verb, pattern, endpoint, defaults) :: rest when verb = method_ ->
        let pattern = pattern_segments pattern in
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
  find_route Route_catalog.routes

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

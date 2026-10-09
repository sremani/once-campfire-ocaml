(** Rails 8.2 ParamBuilder semantics for query strings and request bodies. *)

open Lwt.Infix

type upload = {
  filename : string;
  content_type : string option;
  headers : string;
  path : string;
  size : int64;
}

type value =
  | Nil
  | Text of string
  | Json_scalar of Yojson.Basic.t
  | File of upload
  | Array of value list
  | Object of t
and t = (string * value) list

type error = Invalid of string | Type of string | Too_deep | Limit of string | Too_large | Parse

let get key map = List.assoc_opt key map
let set key value map =
  if List.mem_assoc key map then List.map (fun (k, v) -> (k, if k = key then value else v)) map
  else map @ [key, value]
let merge left right = List.fold_left (fun acc (k, v) -> set k v acc) left right
let find key map = get key map
let string = function Text s -> Some s | _ -> None
let find_string key map = Option.bind (find key map) string

let rec to_json_value = function
  | Nil -> `Null
  | Text s -> `String s
  | Json_scalar value -> value
  | File file -> `Assoc ["original_filename", `String file.filename;
                          "content_type", (match file.content_type with None -> `Null | Some s -> `String s)]
  | Array items -> `List (List.map to_json_value items)
  | Object map -> `Assoc (List.map (fun (k, v) -> k, to_json_value v) map)
let to_json map = to_json_value (Object map)

let rec of_json = function
  | `Null -> Nil
  | `String s -> Text s
  | `List xs -> Array (List.filter_map (function `Null -> None | x -> Some (of_json x)) xs)
  | `Assoc xs -> Object (List.map (fun (k, v) -> k, of_json v) xs)
  | value -> Json_scalar value

let parse_json body =
  try
    let value = of_json (Yojson.Basic.from_string body) in
    Ok (match value with Object map -> map | other -> ["_json", other])
  with Yojson.Json_error _ -> Error Parse

let valid_utf8 s =
  Uutf.String.fold_utf_8 (fun valid _ -> function `Malformed _ -> false | _ -> valid) true s

let decode_component s =
  let len = String.length s in
  let out = Buffer.create len in
  let hex c = match c with
    | '0' .. '9' -> Char.code c - Char.code '0'
    | 'a' .. 'f' -> Char.code c - Char.code 'a' + 10
    | 'A' .. 'F' -> Char.code c - Char.code 'A' + 10
    | _ -> -1 in
  let rec loop i =
    if i >= len then Ok (Buffer.contents out)
    else match s.[i] with
      | '+' -> Buffer.add_char out ' '; loop (i + 1)
      | '%' when i + 2 < len ->
          let hi, lo = hex s.[i + 1], hex s.[i + 2] in
          if hi < 0 || lo < 0 then Error (Invalid ("invalid %-encoding (" ^ s ^ ")"))
          else (Buffer.add_char out (Char.chr (hi * 16 + lo)); loop (i + 3))
      | '%' -> Error (Invalid ("invalid %-encoding (" ^ s ^ ")"))
      | c -> Buffer.add_char out c; loop (i + 1)
  in loop 0

let top_level_key name =
  match String.index_from_opt name (min 1 (String.length name)) '[' with
  | Some i -> String.sub name 0 i
  | None -> name

let split_pairs qs =
  String.split_on_char '&' qs
  |> List.mapi (fun i p -> if i = 0 then p else
       let rec spaces j = if j < String.length p && p.[j] = ' ' then spaces (j + 1) else j in
       let j = spaces 0 in String.sub p j (String.length p - j))
  |> List.filter ((<>) "")

let decode_pair part =
  let key, value = match String.index_opt part '=' with
    | None -> part, None
    | Some i -> String.sub part 0 i, Some (String.sub part (i + 1) (String.length part - i - 1)) in
  match decode_component key with
  | Error _ as error -> error
  | Ok key -> match value with
      | None -> Ok (key, Nil)
      | Some value -> match decode_component value with
          | Error _ as error -> error
          | Ok value -> Ok (key, Text value)

let hash_has_key map key =
  if String.contains key '[' && String.contains key ']' &&
     (let rec contains_array i = i + 1 < String.length key &&
        (key.[i] = '[' && key.[i + 1] = ']' || contains_array (i + 1)) in
      contains_array 0)
  then false
  else
    let parts = String.split_on_char '[' (String.map (function ']' -> '[' | c -> c) key)
      |> List.filter ((<>) "") in
    let rec go map = function
      | [] -> true
      | part :: rest -> match get part map with
        | None -> false
        | Some (Object nested) -> go nested rest
        | Some _ -> rest = []
    in go map parts

type stored = Params | Single_array of value list | Empty
let as_value map = function Params -> Object map | Single_array xs -> Array xs | Empty -> Nil

let error_type expected key = Error (Type ("expected " ^ expected ^ " for param `" ^ key ^ "'"))

let rec store map name value depth =
  if depth >= 100 then Error Too_deep
  else
    let key, after =
      if depth = 0 then
        match String.index_from_opt name (min 1 (String.length name)) '[' with
        | None -> name, ""
        | Some i -> String.sub name 0 i, String.sub name i (String.length name - i)
      else if String.starts_with ~prefix:"[]" name then
        "[]", String.sub name 2 (String.length name - 2)
      else if String.starts_with ~prefix:"[" name then
        match String.index_from_opt name 1 ']' with
        | Some i -> String.sub name 1 (i - 1), String.sub name (i + 1) (String.length name - i - 1)
        | None -> name, ""
      else name, "" in
    if key = "" then Ok (map, Empty)
    else if after = "" then
      if key = "[]" && depth <> 0 then
        Ok (map, Single_array (if value = Nil then [] else [value]))
      else Ok (set key value map, Params)
    else if after = "[" then Ok (set name value map, Params)
    else
      let array_slot () = match get key map with
        | None | Some Nil -> Ok []
        | Some (Array xs) -> Ok xs
        | Some _ -> error_type "Array" key in
      if after = "[]" then
        match array_slot () with
        | Error _ as e -> e
        | Ok xs -> Ok (set key (Array (if value = Nil then xs else xs @ [value])) map, Params)
      else if String.starts_with ~prefix:"[]" after then
        let nested = String.sub after 2 (String.length after - 2) in
        let child_key =
          if String.length nested >= 2 && nested.[0] = '[' &&
             nested.[String.length nested - 1] = ']' then
            let inner = String.sub nested 1 (String.length nested - 2) in
            if inner <> "" && not (String.contains inner '[') && not (String.contains inner ']')
            then inner else nested
          else nested in
        (match array_slot () with
         | Error _ as e -> e
         | Ok xs ->
             let append () =
               match store [] child_key value (depth + 1) with
               | Error _ as e -> e
               | Ok (child, stored) -> Ok (set key (Array (xs @ [as_value child stored])) map, Params) in
             (match List.rev xs with
              | Object last :: reversed when not (hash_has_key last child_key) ->
                  (match store last child_key value (depth + 1) with
                   | Error _ as e -> e
                   | Ok (child, _) ->
                       Ok (set key (Array (List.rev (Object child :: reversed))) map, Params))
              | _ -> append ()))
      else
        let child = match get key map with
          | None | Some Nil -> Ok []
          | Some (Object child) -> Ok child
          | Some _ -> error_type "Hash" key in
        (match child with
         | Error _ as e -> e
         | Ok child -> match store child after value (depth + 1) with
             | Error _ as e -> e
             | Ok (child, stored) -> Ok (set key (as_value child stored) map, Params))

let from_pairs pairs =
  let rec loop map = function
    | [] -> Ok map
    | (key, value) :: rest ->
        if top_level_key key = "" then loop map rest
        else if not (valid_utf8 key) ||
                (match value with Text s -> not (valid_utf8 s) | _ -> false)
        then Error (Invalid "Invalid encoding for parameter")
        else match store map key value 0 with
          | Error _ as e -> e
          | Ok (map, _) -> loop map rest
  in loop [] pairs

let parse_query query =
  let rec decode acc = function
    | [] -> from_pairs (List.rev acc)
    | part :: rest -> match decode_pair part with
      | Error _ as e -> e
      | Ok pair -> decode (pair :: acc) rest
  in decode [] (split_pairs query)

let parse_form body =
  let max_bytes = 4 * 1024 * 1024 and max_params = 4096 in
  if String.length body > max_bytes then Error (Limit "total query size exceeds limit (4194304)")
  else
    let body = if String.ends_with ~suffix:"\000" body then
      String.sub body 0 (String.length body - 1) else body in
    if List.length (String.split_on_char '&' body) > max_params then
      Error (Limit "total number of query parameters exceeds limit (4096)")
    else if not (valid_utf8 body) then Error (Invalid "Invalid encoding for parameter")
    else parse_query body

let find_sub text needle from =
  let last = String.length text - String.length needle in
  let rec scan i =
    if i > last then None
    else if String.sub text i (String.length needle) = needle then Some i
    else scan (i + 1)
  in scan from

let unquote s =
  let s = String.trim s in
  let n = String.length s in
  if n >= 2 && s.[0] = '"' && s.[n - 1] = '"' then String.sub s 1 (n - 2)
  else s

let content_type_parameter content_type name =
  String.split_on_char ';' content_type
  |> List.find_map (fun field ->
      match String.index_opt field '=' with
      | None -> None
      | Some i ->
          let key = String.sub field 0 i |> String.trim |> String.lowercase_ascii in
          if key = name then Some (String.sub field (i + 1) (String.length field - i - 1) |> unquote)
          else None)

type multipart_source = {
  stream : string Lwt_stream.t;
  mutable pending : string;
  mutable eof : bool;
  mutable received : int64;
  limit : int64;
}

exception Multipart_failure of error

let cleanup_uploads paths =
  List.iter (fun path -> try Sys.remove path with Sys_error _ -> ()) paths

let read_more source =
  let rec next () =
    if source.eof then Lwt.return_false
    else Lwt_stream.get source.stream >>= function
      | None -> source.eof <- true; Lwt.return_false
      | Some "" -> next ()
      | Some chunk ->
          let received = Int64.add source.received (Int64.of_int (String.length chunk)) in
          if received > source.limit then Lwt.fail (Multipart_failure Too_large)
          else (
            source.received <- received;
            source.pending <- source.pending ^ chunk;
            Lwt.return_true)
  in next ()

let rec ensure source length =
  if String.length source.pending >= length || source.eof then Lwt.return_unit
  else read_more source >>= fun _ -> ensure source length

let remove_prefix source length =
  source.pending <- String.sub source.pending length (String.length source.pending - length)

let parse_part_headers headers =
  let lines = String.split_on_char '\n' headers |> List.map String.trim in
  let header name = List.find_map (fun line ->
    match String.index_opt line ':' with
    | None -> None
    | Some i when String.lowercase_ascii (String.sub line 0 i) = name ->
        Some (String.sub line (i + 1) (String.length line - i - 1) |> String.trim)
    | _ -> None) lines in
  match header "content-disposition" with
  | None -> raise (Multipart_failure Parse)
  | Some disposition ->
      match content_type_parameter disposition "name" with
      | None -> raise (Multipart_failure Parse)
      | Some name -> name, content_type_parameter disposition "filename", header "content-type"

let read_part_headers source =
  let rec scan () =
    match find_sub source.pending "\r\n\r\n" 0 with
    | Some at ->
        let headers = String.sub source.pending 0 at in
        remove_prefix source (at + 4);
        Lwt.return headers
    | None when String.length source.pending > 65536 ->
        Lwt.fail (Multipart_failure Parse)
    | None ->
        read_more source >>= (function
        | false -> Lwt.fail (Multipart_failure Parse)
        | true -> scan ())
  in scan ()

type delimiter_match = Found of int | Pending of int | Absent

let find_delimiter source delimiter =
  let text = source.pending in
  let n = String.length text and width = String.length delimiter in
  let rec scan from = match String.index_from_opt text from '\r' with
    | None -> Absent
    | Some at when at + width > n -> Pending at
    | Some at when String.sub text at width = delimiter ->
        let after = at + width in
        if after + 2 > n then Pending at
        else if String.sub text after 2 = "--" || String.sub text after 2 = "\r\n" then Found at
        else scan (at + 1)
    | Some at -> scan (at + 1)
  in scan 0

let read_part_data source ~delimiter ~emit =
  let rec scan () =
    match find_delimiter source delimiter with
    | Found at ->
        let data = String.sub source.pending 0 at in
        emit data >>= fun () ->
        remove_prefix source (at + String.length delimiter);
        Lwt.return_unit
    | Pending at ->
        let data = String.sub source.pending 0 at in
        emit data >>= fun () ->
        remove_prefix source at;
        read_more source >>= (function
        | false -> Lwt.fail (Multipart_failure Parse)
        | true -> scan ())
    | Absent when source.eof -> Lwt.fail (Multipart_failure Parse)
    | Absent ->
        let safe = max 0 (String.length source.pending - String.length delimiter - 1) in
        let data = String.sub source.pending 0 safe in
        emit data >>= fun () ->
        remove_prefix source safe;
        read_more source >>= fun _ -> scan ()
  in scan ()

(** Streams each file to a request-owned temporary path. The caller must clean
    the returned paths when request processing completes. Errors and cancellation
    clean all paths created before a result is returned. *)
let parse_multipart_stream ?(on_temp=(fun _ -> ())) ~content_type ~limit stream =
  match content_type_parameter content_type "boundary" with
  | None | Some "" -> Lwt.return (Error Parse)
  | Some boundary ->
      let source = { stream; pending = ""; eof = false; received = 0L; limit } in
      let marker = "--" ^ boundary in
      let delimiter = "\r\n" ^ marker in
      let owned = ref [] and transferred = ref false in
      let cleanup () =
        if not !transferred then cleanup_uploads !owned;
        Lwt.return_unit in
      Lwt.finalize (fun () ->
        let parts = ref 0 and files = ref 0 and text_bytes = ref 0 in
        let rec read_parts acc =
          ensure source 2 >>= fun () ->
          if String.starts_with ~prefix:"--" source.pending then (
            remove_prefix source 2;
            ensure source 2 >>= fun () ->
            if source.pending <> "" && not (String.starts_with ~prefix:"\r\n" source.pending)
            then Lwt.fail (Multipart_failure Parse)
            else
              (match from_pairs (List.rev acc) with
               | Error error -> Lwt.fail (Multipart_failure error)
               | Ok params -> Lwt.return params))
          else if String.starts_with ~prefix:"\r\n" source.pending then (
            remove_prefix source 2;
            incr parts;
            if !parts > 4096 then Lwt.fail (Multipart_failure (Limit "too many multipart parts"))
            else read_part_headers source >>= fun headers ->
              let name, filename, content_type = parse_part_headers headers in
              match filename with
              | Some "" ->
                  read_part_data source ~delimiter ~emit:(fun _ -> Lwt.return_unit) >>= fun () ->
                  read_parts acc
              | Some filename ->
                  incr files;
                  if !files > 128 then Lwt.fail (Multipart_failure (Limit "too many files"))
                  else
                    let path = Filename.temp_file "RackMultipart" ".tmp" in
                    owned := path :: !owned;
                    on_temp path;
                    let size = ref 0L in
                    Lwt_io.with_file ~mode:Lwt_io.output path (fun output ->
                      read_part_data source ~delimiter ~emit:(fun chunk ->
                        size := Int64.add !size (Int64.of_int (String.length chunk));
                        Lwt_io.write output chunk)) >>= fun () ->
                    let value = File { filename; content_type; headers; path; size = !size } in
                    read_parts ((name, value) :: acc)
              | None ->
                  let text = Buffer.create 256 in
                  read_part_data source ~delimiter ~emit:(fun chunk ->
                    text_bytes := !text_bytes + String.length chunk;
                    if !text_bytes > 16 * 1024 * 1024 then
                      Lwt.fail (Multipart_failure Too_large)
                    else (Buffer.add_string text chunk; Lwt.return_unit)) >>= fun () ->
                  read_parts ((name, Text (Buffer.contents text)) :: acc))
          else Lwt.fail (Multipart_failure Parse) in
        Lwt.catch (fun () ->
          ensure source (String.length marker) >>= fun () ->
          if not (String.starts_with ~prefix:marker source.pending) then
            Lwt.fail (Multipart_failure Parse)
          else (
            remove_prefix source (String.length marker);
            read_parts [] >>= fun params ->
            transferred := true;
            Lwt.return (Ok (params, List.rev !owned))))
          (function Multipart_failure error -> Lwt.return (Error error)
                  | exn -> Lwt.fail exn)) cleanup

let parse_nested query = match parse_query query with Ok value -> to_json value | Error _ -> `Null

let blank = function
  | Nil -> true
  | Json_scalar (`Bool false) -> true
  | Text s -> String.trim s = ""
  | Array [] | Object [] -> true
  | _ -> false

let require key map = match find key map with
  | Some (Json_scalar (`Bool false) as value) -> Ok value
  | Some value when not (blank value) -> Ok value
  | _ -> Error (Invalid ("param is missing or the value is empty: " ^ key))

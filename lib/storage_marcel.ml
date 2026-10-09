(** Marcel 1.1.0 identification using the generated tables from the pinned Rails
    bundle. The table data is produced by [tools/generate_marcel_tables.py]. *)

type match_ = { offset:int; range_end:int option; value:string option;
                children:match_ list }

let field json name = match json with
  | `Assoc entries -> List.assoc name entries
  | _ -> invalid_arg "Marcel table object"
let text = function `String s -> s | _ -> invalid_arg "Marcel table string"
let number = function `Int n -> n | _ -> invalid_arg "Marcel table integer"
let optional f = function `Null -> None | x -> Some (f x)
let pairs value = match value with
  | `List xs -> List.map (function
    | `List [a;b] -> text a,b
    | _ -> invalid_arg "Marcel table pair") xs
  | _ -> invalid_arg "Marcel table pairs"
let hex_decode value =
  String.init (String.length value/2) (fun i ->
    Char.chr (int_of_string ("0x" ^ String.sub value (i*2) 2)))

let rec decode_match value =
  { offset = number (field value "offset");
    range_end = optional number (field value "range_end");
    value = optional (fun x -> hex_decode (text x)) (field value "value");
    children = (match field value "children" with
      | `List xs -> List.map decode_match xs | _ -> invalid_arg "Marcel children") }

type tables = {
  extensions:(string * string) list;
  type_exts:(string * string list) list;
  parents:(string * string list) list;
  magic:(string * match_ list) list;
  prefix_len:int;
}

let rec reach m =
  let own = match m.value,m.range_end with
    | None,_ -> 0
    | Some value,None -> m.offset + String.length value
    | Some value,Some finish -> finish + String.length value in
  List.fold_left (fun n child -> max n (reach child)) own m.children

let tables = lazy (
  let json = Yojson.Basic.from_string Storage_marcel_tables.json in
  let extensions = List.map (fun (name,value) -> name,text value)
    (pairs (field json "extensions")) in
  let list_pairs name = List.map (fun (k,v) ->
    k,(match v with `List xs -> List.map text xs | _ -> invalid_arg name))
    (pairs (field json name)) in
  let magic = List.map (fun (name,value) ->
    name,(match value with `List xs -> List.map decode_match xs | _ -> invalid_arg "magic"))
    (pairs (field json "magic")) in
  let prefix_len = List.fold_left (fun n (_,matches) ->
    List.fold_left (fun n m -> max n (reach m)) n matches) 0 magic in
  { extensions; type_exts=list_pairs "type_exts";
    parents=list_pairs "type_parents"; magic; prefix_len })

let magic_prefix_len () = (Lazy.force tables).prefix_len

let basename name =
  let rec trim n = if n>0 && name.[n-1]='/' then trim (n-1) else n in
  let len=trim (String.length name) in
  if len=0 then if name="" then "" else "/"
  else match String.rindex_from_opt name (len-1) '/' with
    | None -> String.sub name 0 len
    | Some pos -> String.sub name (pos+1) (len-pos-1)

let extension_with_delimiter name =
  let base=basename name in
  let rec dots n = if n<String.length base && base.[n]='.' then dots (n+1) else n in
  let first=dots 0 in
  let suffix=String.sub base first (String.length base-first) in
  match String.rindex_opt suffix '.' with
  | None -> ""
  | Some n -> String.sub suffix n (String.length suffix-n)

let extension name =
  let with_dot=extension_with_delimiter name in
  if with_dot="" then "" else String.sub with_dot 1 (String.length with_dot-1)

let base_without_extension name =
  let base=basename name in
  let ext=extension_with_delimiter name in
  if ext<>"" && String.length base>String.length ext &&
     String.ends_with ~suffix:ext base then
    String.sub base 0 (String.length base-String.length ext)
  else base

let by_extension name =
  let ext=String.lowercase_ascii name in
  let ext=if String.starts_with ~prefix:"." ext then
    String.sub ext 1 (String.length ext-1) else ext in
  List.assoc_opt ext (Lazy.force tables).extensions

let parents_of name =
  Option.value (List.assoc_opt name (Lazy.force tables).parents) ~default:[]

let rec is_child child parent =
  child=parent || List.exists (fun p -> is_child p parent) (parents_of child)

let matches_value data m =
  match m.value with
  | None -> false
  | Some value ->
      let n=String.length data and length=String.length value in
      let available = match m.range_end with
        | None -> length
        | Some finish -> finish-m.offset+length in
      if m.offset>=n && available>0 then false else
      let window = if available=0 then "" else
        String.sub data m.offset (min available (n-m.offset)) in
      match m.range_end with
      | None -> window=value
      | Some _ when length=0 -> true
      | Some _ ->
          let rec search at =
            at+length<=String.length window &&
            (String.sub window at length=value || search (at+1)) in
          search 0

let rec matches_any data matches =
  List.exists (fun m -> matches_value data m &&
    (m.children=[] || matches_any data m.children)) matches

let by_magic data =
  List.find_map (fun (name,matches) ->
    if matches_any data matches then Some (String.lowercase_ascii name) else None)
    (Lazy.force tables).magic

let declared_type = function
  | None -> None
  | Some declared ->
      let declared=String.lowercase_ascii declared in
      let stop=ref 0 in
      while !stop<String.length declared &&
        not (String.contains ";, \t\n\r\011\012" declared.[!stop]) do incr stop done;
      let media=String.sub declared 0 !stop in
      if media<>"application/octet-stream" && String.contains media '/'
      then Some media else None

let most_specific candidates =
  let unique=List.fold_left (fun acc -> function
    | None -> acc
    | Some value when List.mem value acc -> acc
    | Some value -> acc@[value]) [] candidates in
  match unique with
  | [] -> "application/octet-stream"
  | first::rest -> List.fold_left (fun picked candidate ->
      if is_child candidate picked then candidate else picked) first rest

let for_extension name = most_specific [by_extension name]

let identify data ~name ~declared =
  let filename_type=Option.bind name (fun n -> by_extension (extension n)) in
  most_specific [by_magic data; declared_type declared; filename_type]

let identify_file path ~name ~declared =
  let input=open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr input) (fun () ->
    let prefix=really_input_string input
      (min (in_channel_length input) (magic_prefix_len ())) in
    identify prefix ~name ~declared)

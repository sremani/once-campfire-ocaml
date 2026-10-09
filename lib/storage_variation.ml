(** Ordered Active Storage transformations. Symbol values survive direct Ruby
    definitions; decoded signed keys have string values. Their Marshal digests
    differ, so the distinction belongs in this type. *)

type value = Nil | Bool of bool | Int of int64 | Symbol of string | Str of string
  | Array of value list | Hash of (string * value) list
type t = (string * value) list

let resize_to_limit ?format width height =
  ["resize_to_limit",Array [Int (Int64.of_int width);Int (Int64.of_int height)]] @
  match format with None -> [] | Some s -> ["format",Symbol s]

let format_only format = ["format",Symbol format]

let default_to variation defaults =
  let merged=List.map (fun (key,value) ->
    key,Option.value (List.assoc_opt key variation) ~default:value) defaults in
  merged @ List.filter (fun (key,_) -> not (List.mem_assoc key defaults)) variation

let of_json json =
  let rec decode = function
    | `Null -> Nil | `Bool b -> Bool b | `Int n -> Int (Int64.of_int n)
    | `Intlit n -> Int (Int64.of_string n)
    | `String s -> Str s | `List xs -> Array (List.map decode xs)
    | `Assoc xs -> Hash (List.map (fun (k,v) -> k,decode v) xs)
    | _ -> invalid_arg "unsupported variation value" in
  match decode json with Hash entries -> entries
    | _ -> invalid_arg "transformations must be a hash"

let rec json_value = function
  | Nil -> `Null | Bool b -> `Bool b | Int n -> `Intlit (Int64.to_string n)
  | Symbol s | Str s -> `String s
  | Array xs -> `List (List.map json_value xs)
  | Hash entries -> `Assoc (List.map (fun (k,v) -> k,json_value v) entries)
let to_json variation = json_value (Hash variation)

let key ~secret_key_base variation =
  App_verifier.generate_raw ~secret_key_base ~name:"ActiveStorage"
    ~data_json:(Rails_format.encode (to_json variation))
    ~purpose:(Some "variation") ~expires_at:None

let from_key ~secret_key_base ~now raw =
  match Storage_disk.verify ~secret_key_base ~purpose:"variation" ~now raw with
  | None -> None
  | Some json -> (try Some (of_json (Yojson.Safe.from_string
      (Yojson.Basic.to_string json))) with Invalid_argument _ -> None)

let marshal variation =
  let out=Buffer.create 128 and symbols=ref [] in
  let byte n = Buffer.add_char out (Char.chr (n land 255)) in
  let long n =
    if n=0L then byte 0
    else if n>0L && n<123L then byte (Int64.to_int n+5)
    else if n<0L && n>(-124L) then byte (Int64.to_int (Int64.logand (Int64.sub n 5L) 255L))
    else begin
      let rec bytes x count acc =
        let b=Int64.to_int (Int64.logand x 255L) in
        let next=Int64.shift_right x 8 in
        let acc=b::acc in
        if next=0L || next=(-1L) then count+1,List.rev acc,next<0L
        else bytes next (count+1) acc in
      let count,values,negative=bytes n 0 [] in
      byte (if negative then 256-count else count);
      List.iter byte values
    end in
  let bytes s = long (Int64.of_int (String.length s)); Buffer.add_string out s in
  let symbol s =
    let rec find_index index = function
      | [] -> None
      | name::rest -> if name=s then Some index else find_index (index+1) rest in
    match find_index 0 !symbols with
    | Some n -> byte (Char.code ';');long (Int64.of_int n)
    | None -> symbols:= !symbols@[s];byte (Char.code ':');bytes s in
  let rec value = function
    | Nil -> byte (Char.code '0')
    | Bool true -> byte (Char.code 'T')
    | Bool false -> byte (Char.code 'F')
    | Int n when n>=Int64.neg (Int64.shift_left 1L 30) &&
                 n<Int64.shift_left 1L 30 ->
        byte (Char.code 'i'); long n
    | Int n ->
        byte (Char.code 'l');byte (if n<0L then Char.code '-' else Char.code '+');
        let magnitude=if n<0L then Int64.neg n else n in
        let rec digits n acc =
          if n=0L then List.rev acc else digits (Int64.shift_right_logical n 8)
            (Int64.to_int (Int64.logand n 255L)::acc) in
        let digits=digits magnitude [] in
        let digits=if List.length digits mod 2=1 then digits@[0] else digits in
        long (Int64.of_int (List.length digits/2));List.iter byte digits
    | Symbol s -> symbol s
    | Str s ->
        byte (Char.code 'I');byte (Char.code '"');bytes s;
        long 1L;symbol "E";byte (Char.code 'T')
    | Array xs ->
        byte (Char.code '[');long (Int64.of_int (List.length xs));List.iter value xs
    | Hash entries ->
        byte (Char.code '{');long (Int64.of_int (List.length entries));
        List.iter (fun (key,item) -> symbol key;value item) entries in
  byte 4;byte 8;value (Hash variation);Buffer.contents out

let digest variation =
  Mirage_crypto.Hash.SHA1.digest (Cstruct.of_string (marshal variation))
  |> Cstruct.to_string |> Base64.encode_string

let format variation =
  let name=match List.assoc_opt "format" variation with
    | None -> "png"
    | Some (Symbol s | Str s) -> s
    | _ -> invalid_arg "invalid variant format" in
  if Storage_marcel.by_extension name=None then
    invalid_arg ("invalid variant format: " ^ name);
  name

let content_type variation = Storage_marcel.for_extension (format variation)

let operations variation =
  let blank = function
    | Nil | Bool false | Str "" | Array [] | Hash [] -> true
    | _ -> false in
  let dimension = function
    | Nil -> None
    | Int n when n>=Int64.of_int32 Int32.min_int && n<=Int64.of_int32 Int32.max_int ->
        Some (Int64.to_int n)
    | _ -> invalid_arg "resize_to_limit argument" in
  List.filter_map (fun (name,arg) -> match name,arg with
    | "format",_ -> None
    | "combine_options",_ -> invalid_arg "combine_options is not supported"
    | _,value when blank value -> None
    | "resize_to_limit",Array [width;height] ->
        let width=dimension width and height=dimension height in
        if width=None && height=None then
          invalid_arg "either width or height must be specified";
        Some (width,height)
    | _ -> invalid_arg ("unsupported transformation " ^ name)) variation

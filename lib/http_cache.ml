(** Rails/Rack response validators and the Rust front cache's public eligibility rules.
    Call [finish] after controller headers and cookies have been committed, before gzip. *)

open Lwt.Infix

type cache_control = {
  max_age : int option;
  public : bool;
  private_ : bool;
  must_revalidate : bool;
  no_cache : bool;
  no_store : bool;
  must_understand : bool;
  stale_while_revalidate : int option;
  stale_if_error : int option;
  immutable : bool;
  extras : string list;
}

let empty_control = {
  max_age=None; public=false; private_=false; must_revalidate=false;
  no_cache=false; no_store=false; must_understand=false;
  stale_while_revalidate=None; stale_if_error=None; immutable=false; extras=[];
}

let control_header c =
  if c = empty_control then None else
  let prefixed name = function None -> [] | Some n -> [name ^ "=" ^ string_of_int n] in
  let options =
    if c.no_store then
      (if c.private_ then ["private"] else []) @
      (if c.must_understand then ["must-understand"] else []) @ ["no-store"]
    else if c.no_cache then
      (if c.public then ["public"] else []) @ ["no-cache"] @ c.extras
    else
      prefixed "max-age" c.max_age @
      [if c.public then "public" else "private"] @
      (if c.must_revalidate then ["must-revalidate"] else []) @
      prefixed "stale-while-revalidate" c.stale_while_revalidate @
      prefixed "stale-if-error" c.stale_if_error @
      (if c.immutable then ["immutable"] else []) @ c.extras in
  Some (String.concat ", " options)

let hex bytes =
  let chars = "0123456789abcdef" in
  let out = Bytes.create (String.length bytes * 2) in
  String.iteri (fun i c ->
    let n = Char.code c in
    Bytes.set out (2*i) chars.[n lsr 4];
    Bytes.set out (2*i+1) chars.[n land 15]) bytes;
  Bytes.unsafe_to_string out

let sha256 text =
  Mirage_crypto.Hash.SHA256.digest (Cstruct.of_string text)
  |> Cstruct.to_string

let rack_etag body =
  if body = "" then None
  else Some ("W/\"" ^ String.sub (hex (sha256 body)) 0 32 ^ "\"")

(* Cohttp's finite [`Strings] body need not be joined to compute Rack's ETag.
   Feed bounded slices, so a large already materialized response does not
   require another full-size string or Cstruct allocation. *)
let finite_etag body =
  let chunks = match body with
    | `Empty -> Some [] | `String value -> Some [value]
    | `Strings values -> Some values | `Stream _ -> None in
  Option.map (fun chunks ->
    let state = ref Mirage_crypto.Hash.SHA256.empty in
    let length = ref 0 in
    List.iter (fun value ->
      let size = String.length value in
      length := !length + size;
      let rec feed offset =
        if offset < size then (
          let n = min 65536 (size - offset) in
          state := Mirage_crypto.Hash.SHA256.feed !state
            (Cstruct.of_string (String.sub value offset n));
          feed (offset + n)) in
      feed 0) chunks;
    let etag = if !length = 0 then None else
      Some ("W/\"" ^ String.sub (hex (Cstruct.to_string
        (Mirage_crypto.Hash.SHA256.get !state))) 0 32 ^ "\"") in
    etag, !length) chunks

module Page_parts = struct
  (* [text] omits fragments; each offset is the byte position in that text
     where a fragment was inserted. These offsets must come from the renderer,
     never from searching the final HTML for duplicate fragment bytes. *)
  type part = Text of string | Fragment of string * string
  external deflate_piece : string -> string -> string * int32 =
    "campfire_deflate_piece"
  external combine_crc : int32 -> int32 -> int64 -> int32 =
    "campfire_crc32_combine"
  let min_fragment = 1024
  let max_glue = 256

  let splice ~text fragments =
    let between = Buffer.create 1024 in
    let parts = ref [] in
    let position = ref 0 in
    let valid = ref true in
    List.iter (fun (offset, fragment) ->
      if offset < !position || offset > String.length text then valid := false
      else if !valid then (
        Buffer.add_substring between text !position (offset - !position);
        position := offset;
        if String.length fragment < min_fragment then
          Buffer.add_string between fragment
        else (
          let gap = Buffer.contents between in
          Buffer.clear between;
          let follows_fragment = match !parts with Fragment _ :: _ -> true | _ -> false in
          if follows_fragment && String.length gap <= max_glue then
            parts := Fragment (gap, fragment) :: !parts
          else (
            if gap <> "" then parts := Text gap :: !parts;
            parts := Fragment ("", fragment) :: !parts)))) fragments;
    if not !valid then None else (
      Buffer.add_substring between text !position (String.length text - !position);
      let rest = Buffer.contents between in
      if rest <> "" then parts := Text rest :: !parts;
      let parts = List.rev !parts in
      if List.exists (function Fragment _ -> true | _ -> false) parts
      then Some parts else None)

  let etag parts =
    let state = ref Mirage_crypto.Hash.SHA256.empty in
    let feed text = state := Mirage_crypto.Hash.SHA256.feed !state
      (Cstruct.of_string text) in
    let feed_len length =
      let n = Int64.of_int length in
      let bytes = String.init 8 (fun i ->
        Char.chr (Int64.to_int (Int64.logand 255L
          (Int64.shift_right_logical n (i * 8))))) in
      feed bytes in
    List.iter (function
      | Text text ->
          feed "T";
          feed_len (String.length text);
          feed (sha256 text)
      | Fragment (glue, fragment) ->
          feed "F";
          feed_len (String.length glue);
          feed glue;
          feed_len (String.length fragment);
          feed (sha256 fragment)) parts;
    String.sub (hex (Cstruct.to_string
      (Mirage_crypto.Hash.SHA256.get !state))) 0 32

  let of_offsets ~text fragments = Option.map etag (splice ~text fragments)

  (* Cohttp writes each string separately for an identity response. Fragment
     glue is a separate frame, as in the pinned Rust PlainBody iterator. *)
  let chunks parts = List.concat_map (function
    | Text text -> [text]
    | Fragment ("", fragment) -> [fragment]
    | Fragment (glue, fragment) -> [glue; fragment]) parts

  let body parts = Cohttp_lwt.Body.of_string_list (chunks parts)

  let length parts = List.fold_left (fun size -> function
    | Text text -> size + String.length text
    | Fragment (glue, fragment) ->
        size + String.length glue + String.length fragment) 0 parts

  (* The pinned PageParts compressor emits a raw sync-flushed piece per part,
     followed by an empty final block. libz and zlib-rs choose different
     deflate matches, so this has the same framing and decoded bytes, though
     its compressed bytes are not identical to the Rust implementation. *)
  let gzip ?(mtime=0) parts =
    let output=Buffer.create 4096 in
    let byte value = Buffer.add_char output (Char.chr (value land 255)) in
    let little32 value =
      for i=0 to 3 do byte (Int32.to_int
        (Int32.logand 255l (Int32.shift_right_logical value (i*8)))) done in
    byte 0x1f; byte 0x8b; byte 8; byte 0;
    little32 (Int32.of_int mtime); byte 0; byte 3;
    let before=ref "" and checksum=ref 0l and total=ref 0L in
    List.iter (fun part ->
      let data,next_before=match part with
        | Text text -> text,text
        | Fragment (glue,fragment) -> glue ^ fragment,fragment in
      let piece,crc=deflate_piece !before data in
      Buffer.add_string output piece;
      checksum := combine_crc !checksum crc (Int64.of_int (String.length data));
      total := Int64.add !total (Int64.of_int (String.length data));
      before := next_before) parts;
    byte 3; byte 0;
    little32 !checksum;
    little32 (Int64.to_int32 !total);
    Buffer.contents output
end

let combined_etag ?(strong=false) ?(frame=false) ?template ?(flash=[]) validator =
  let parts = (match validator with None -> [] | Some text -> [text]) @
    (if frame then ["frame"] else []) @
    (match template with None -> [] | Some text -> [text]) @
    (if flash=[] then [] else [String.concat "&" flash]) in
  let digest = String.sub (hex (sha256 (String.concat "/" parts))) 0 32 in
  (if strong then "\"" else "W/\"") ^ digest ^ "\""

(* serde_json::Value's Debug representation is what the pinned Rust
   ETagWithFlash etagger includes after each flash key. *)
let rec rust_json_debug = function
  | `Null -> "Null"
  | `Bool value -> "Bool(" ^ string_of_bool value ^ ")"
  | `Int value -> "Number(" ^ string_of_int value ^ ")"
  | `Float value -> "Number(" ^ Yojson.Basic.to_string (`Float value) ^ ")"
  | `String value -> "String(" ^ Yojson.Basic.to_string (`String value) ^ ")"
  | `List values -> "Array [" ^
      String.concat ", " (List.map rust_json_debug values) ^ "]"
  | `Assoc values -> "Object {" ^
      (List.sort (fun (left,_) (right,_) -> String.compare left right) values
       |> List.map (fun (key,value) ->
         Yojson.Basic.to_string (`String key) ^ ": " ^ rust_json_debug value)
       |> String.concat ", ") ^ "}"

let flash_etaggers values =
  List.sort (fun (left,_) (right,_) -> String.compare left right) values
  |> List.map (fun (key,value) ->
    key ^ "=Some(" ^ rust_json_debug value ^ ")")

let httpdate time = Storage_file_server.httpdate (Ptime.to_float_s time)

let parse_httpdate value =
  let months = [|"Jan";"Feb";"Mar";"Apr";"May";"Jun";
                  "Jul";"Aug";"Sep";"Oct";"Nov";"Dec"|] in
  try
    let value = String.trim value in
    let day, month, year, hour, minute, second =
      Scanf.sscanf value "%3s, %d %3s %d %d:%d:%d GMT"
        (fun _ day month year hour minute second -> day,month,year,hour,minute,second) in
    let month = 1 + (let rec find n =
      if n = 12 then raise Not_found else if months.(n) = month then n else find (n+1) in find 0) in
    Ptime.of_date_time ((year,month,day), ((hour,minute,second),0))
  with _ -> None

let is_fresh request headers =
  let req = Cohttp.Request.headers request in
  match Cohttp.Header.get req "if-none-match" with
  | Some candidates ->
      (match Cohttp.Header.get headers "etag" with
       | None -> false
       | Some etag -> String.split_on_char ',' candidates
           |> List.exists (fun item -> let item=String.trim item in item=etag || item="*"))
  | None ->
      (match Option.bind (Cohttp.Header.get req "if-modified-since") parse_httpdate,
             Option.bind (Cohttp.Header.get headers "last-modified") parse_httpdate with
       | Some since, Some modified -> Ptime.compare since modified >= 0
       | _ -> false)

let fresh_when ?(strong=false) ?(frame=false) ?template ?(flash=[])
    ?last_modified ?(public=false) ?validator request headers =
  let headers =
    if Option.is_some validator || Option.is_some template then
      Cohttp.Header.replace headers "etag"
        (combined_etag ~strong ~frame ?template ~flash validator)
    else headers in
  let headers = match last_modified with
    | None -> headers
    | Some time -> Cohttp.Header.replace headers "last-modified" (httpdate time) in
  let control = if public then {empty_control with public=true}
    else empty_control in
  headers, control, is_fresh request headers

(** A rendered byte page with Rails [fresh_when(etag: body_digest,
    template: ...)] semantics. Call only for finite, already rendered pages;
    page-part rendering may supply its own digest instead. The response
    finalizer turns a matching request validator into a 304. *)
let rendered_freshness ~request ~template (response, body) =
  let status = Cohttp.Code.code_of_status (Cohttp.Response.status response) in
  if status<>200 then Lwt.return (response,body) else
  Cohttp_lwt.Body.to_string body >|= fun bytes ->
  let frame = match Cohttp.Header.get (Cohttp.Request.headers request) "turbo-frame" with
    | Some id -> String.trim id <> ""
    | None -> false in
  let validator = hex (sha256 bytes) in
  let headers,_,_ = fresh_when ~frame ~template ~validator request
    (Cohttp.Response.headers response) in
  let headers = Cohttp.Header.remove headers "last-modified" in
  {response with headers}, Cohttp_lwt.Body.of_string bytes

let expires_in ~now seconds ?(public=false) ?(must_revalidate=false)
    ?stale_while_revalidate ?stale_if_error ?(immutable=false) headers =
  let headers = if Cohttp.Header.mem headers "date" then headers
    else Cohttp.Header.add headers "date" (httpdate now) in
  headers, {empty_control with max_age=Some seconds; public; must_revalidate;
    stale_while_revalidate; stale_if_error; immutable}

let apply_control control headers =
  if Cohttp.Header.mem headers "cache-control" then headers
  else let control =
    if control = empty_control &&
       (Cohttp.Header.mem headers "etag" || Cohttp.Header.mem headers "last-modified")
    then {empty_control with max_age=Some 0; must_revalidate=true}
    else control in
    match control_header control with
    | None -> headers
    | Some text -> Cohttp.Header.add headers "cache-control" text

let finish ?(digestible=true) ?(control=empty_control) ~request (response, body) =
  let status = Cohttp.Code.code_of_status (Cohttp.Response.status response) in
  let method_ = Cohttp.Code.string_of_method (Cohttp.Request.meth request) in
  let public_exception = Cohttp.Header.mem (Cohttp.Response.headers response)
    "x-campfire-public-exception" in
  let headers = Cohttp.Response.headers response
    |> fun headers -> Cohttp.Header.remove headers "x-campfire-public-exception"
    |> apply_control control in
  let needs_digest = digestible && (status=200 || status=201) &&
    not (Cohttp.Header.mem headers "etag" || Cohttp.Header.mem headers "last-modified") in
  (if needs_digest then
     (match finite_etag body with
      | Some (etag, length) ->
          let headers = match etag with
            | None -> headers
            | Some etag -> Cohttp.Header.replace headers "etag" etag in
          Lwt.return (headers, body, Option.is_some etag,
            Some (string_of_int length))
      | None -> Lwt.return (headers, body, false, None))
   else if method_="HEAD" && status=200 && digestible &&
     not (Cohttp.Header.mem headers "content-length") then
     Cohttp_lwt.Body.length body >|= fun (length, body) ->
       headers, body, false, Some (Int64.to_string length)
   else Lwt.return (headers, body, false, None))
  >|= fun (headers, body, digested, body_length) ->
    let headers = if public_exception || Cohttp.Header.mem headers "cache-control" then headers
      else Cohttp.Header.add headers "cache-control"
        (if digested then "max-age=0, private, must-revalidate" else "no-cache") in
    let conditional = (method_="GET" || method_="HEAD") && status=200 &&
      is_fresh request headers in
    if conditional then
      let headers = headers |> fun h -> Cohttp.Header.remove h "content-type"
        |> fun h -> Cohttp.Header.remove h "content-length" in
      ({response with status=`Not_modified; headers}, Cohttp_lwt.Body.empty)
    else if method_="HEAD" then
      let headers = match body_length with
        | Some length when status=200 && not (Cohttp.Header.mem headers "content-length") ->
            Cohttp.Header.add headers "content-length" length
        | _ -> headers in
      ({response with headers}, Cohttp_lwt.Body.empty)
    else ({response with headers}, body)

module Front = struct
  let max_cacheable_uri = 2048
  let entry_overhead = 256

  type item = { status:int; headers:Cohttp.Header.t; body:string;
    static:bool;
    variant:(string * string) list; expires_at:float; mutable accessed_at:float;
    size:int; generation:int64 }
  type t = { capacity:int; max_item_size:int; items:(string,item) Hashtbl.t;
    mutable size:int }

  let create ~capacity ~max_item_size =
    {capacity=max 0 capacity; max_item_size=max 0 max_item_size;
     items=Hashtbl.create 128; size=0}

  let request_allowed request =
    let method_ = Cohttp.Code.string_of_method (Cohttp.Request.meth request) in
    let headers = Cohttp.Request.headers request in
    let uri = Request_uri.get request in
    let path = Uri.path uri in
    let query = Option.value (Uri.verbatim_query uri) ~default:"" in
    let length = String.length path + if query="" then 0 else 1+String.length query in
    (method_="GET" || method_="HEAD") &&
    Cohttp.Header.get headers "connection" <> Some "Upgrade" &&
    Cohttp.Header.get headers "upgrade" <> Some "websocket" &&
    Cohttp.Header.get headers "range" = None && length <= max_cacheable_uri

  let directive words name =
    List.find_map (fun word ->
      let word=String.trim word in
      let prefix=name ^ "=" in
      if String.starts_with ~prefix word then
        let value=String.sub word (String.length prefix) (String.length word-String.length prefix) in
        int_of_string_opt value else None) words

  let lifetime status headers =
    if status<200 || status>399 || status=304 then None else
    let vary = Option.value (Cohttp.Header.get headers "vary") ~default:"" in
    if String.contains vary '*' then None else
    let cc = Option.value (Cohttp.Header.get headers "cache-control") ~default:"" in
    let words = String.split_on_char ',' cc |> List.map String.trim in
    if not (List.mem "public" words) || List.mem "no-cache" words then None
    else match directive words "s-max-age" with
      | Some n when n>0 -> Some n
      | Some _ -> None
      | None -> (match directive words "max-age" with Some n when n>0 -> Some n | _ -> None)

  let vary_names headers =
    Option.value (Cohttp.Header.get headers "vary") ~default:""
    |> String.split_on_char ',' |> List.map (fun s -> String.lowercase_ascii (String.trim s))
    |> List.filter ((<>) "") |> List.sort String.compare

  let base_key request =
    let uri=Request_uri.get request in
    let headers=Cohttp.Request.headers request in
    let host=Option.value (Cohttp.Header.get headers "host")
      ~default:(Option.value (Uri.host uri) ~default:"") in
    String.concat "\n" [Cohttp.Code.string_of_method (Cohttp.Request.meth request);
      Uri.path uri; Option.value (Uri.verbatim_query uri) ~default:""; host]

  let variant request names =
    let headers=Cohttp.Request.headers request in
    List.map (fun name -> name, Option.value (Cohttp.Header.get headers name) ~default:"") names

  let variant_key base pairs =
    List.fold_left (fun key (name,value) -> key ^ "\n" ^ name ^ "=" ^ value) base pairs

  let remove t key =
    match Hashtbl.find_opt t.items key with
    | None -> ()
    | Some item -> t.size <- t.size-item.size; Hashtbl.remove t.items key

  let find t ~now ~generation request =
    if not (request_allowed request) then None else
    let base=base_key request in
    let valid item = item.generation=generation && item.expires_at>=now &&
      item.variant=variant request (List.map fst item.variant) in
    let get key = match Hashtbl.find_opt t.items key with
      | Some item when valid item -> item.accessed_at <- now; Some item
      | _ -> None in
    match get base with
    | Some item -> Some item
    | None ->
        (match Hashtbl.find_opt t.items base with
         | None -> None
         | Some first -> get (variant_key base (variant request (List.map fst first.variant))))

  let item_size key headers body variant =
    let header_size = Cohttp.Header.to_list headers |>
      List.fold_left (fun n (name,value) -> n+String.length name+String.length value) 0 in
    let variant_size = List.fold_left (fun n (name,value) ->
      n+String.length name+String.length value) 0 variant in
    String.length body + String.length key + header_size + variant_size + entry_overhead

  let store t ~now ~generation ?(static=false) request ~status ~headers ~body =
    match lifetime status headers with
    | None -> false
    | Some _ when not (request_allowed request) -> false
    | Some seconds ->
        let base=base_key request in
        let variant=variant request (vary_names headers) in
        let key=if Hashtbl.mem t.items base then
          let first=Hashtbl.find t.items base in
          if first.variant=variant then base else variant_key base variant
          else base in
        let headers=Cohttp.Header.remove headers "set-cookie" in
        let headers=Cohttp.Header.remove headers "x-cache" in
        let size=item_size key headers body variant in
        if size>t.capacity || size>t.max_item_size then false else (
          remove t key;
          while t.size+size>t.capacity && Hashtbl.length t.items>0 do
            let victim=Hashtbl.fold (fun key item choice ->
              match choice with None -> Some (key,item)
              | Some (_,old) when item.expires_at<now || item.accessed_at<old.accessed_at -> Some (key,item)
              | Some _ -> choice) t.items None |> Option.get |> fst in
            remove t victim
          done;
          Hashtbl.add t.items key {status;headers;body;variant;static;
            expires_at=now+.float_of_int seconds;accessed_at=now;size;generation};
          t.size<-t.size+size; true)

  let was_not_modified request item =
    match Cohttp.Header.get item.headers "etag" with
    | None -> false
    | Some etag ->
        Cohttp.Header.get (Cohttp.Request.headers request) "if-none-match"
        |> Option.value ~default:"" |> String.split_on_char ','
        |> List.exists (fun value -> String.trim value=etag)
end

(** Completed authenticated responses. The caller must authenticate and authorize each request,
    then supply a freshly read SQLite generation both at lookup and at admission. *)
module Private = struct
  let ttl = 15.
  let max_body = 1024 * 1024
  let max_key_input = 8192
  let max_item_size = 2 * 1024 * 1024

  type ticket = { generation:int64; key:string }
  type item = { status:int; headers:Cohttp.Header.t; body:string;
    expires_at:float; mutable accessed_at:float; size:int }
  type t = { capacity:int; items:(string,item) Hashtbl.t; mutable size:int }

  let create ~capacity = {capacity=max 0 capacity;items=Hashtbl.create 128;size=0}

  let has_directive headers names =
    Cohttp.Header.get_multi headers "cache-control" |> List.exists (fun value ->
      String.split_on_char ',' value |> List.exists (fun directive ->
        let directive=String.trim directive in
        let name=List.hd (String.split_on_char '=' directive) in
        List.exists (String.equal (String.lowercase_ascii name)) names))

  let eligible_request ~endpoint ~original_method ~raw_post request =
    let method_=Cohttp.Code.string_of_method (Cohttp.Request.meth request) in
    let headers=Cohttp.Request.headers request in
    List.mem endpoint ["rooms#show";"messages#index";
      "users/sidebars#show";"searches#index"] &&
    (method_="GET" || method_="HEAD") && original_method=method_ &&
    raw_post="" && Cohttp.Header.get headers "range"=None &&
    Cohttp.Header.get headers "upgrade"=None &&
    not (has_directive headers ["no-cache";"no-store"]) &&
    (match Cohttp.Header.get headers "pragma" with
     | Some value -> String.lowercase_ascii value <> "no-cache"
     | None -> true)

  let key ~generation ~endpoint ~user_id ~session_id ~origin request =
    let buffer=Buffer.create 512 in
    let length=ref 0 in
    let add field =
      length:= !length+String.length field+8;
      let n=Int64.of_int (String.length field) in
      for shift=0 to 7 do
        Buffer.add_char buffer
          (Char.chr (Int64.to_int (Int64.logand 255L (Int64.shift_right_logical n (shift*8)))))
      done;
      Buffer.add_string buffer field in
    let int64_bytes n = String.init 8 (fun i ->
      Char.chr (Int64.to_int (Int64.logand 255L (Int64.shift_right_logical n (i*8))))) in
    List.iter add [int64_bytes generation;endpoint;int64_bytes user_id;
      int64_bytes session_id;Uri.to_string (Request_uri.get request);origin];
    let excluded=["if-none-match";"if-modified-since";"x-request-id";"x-request-start"] in
    let headers=Cohttp.Request.headers request in
    let names=Cohttp.Header.to_list headers |> List.map fst
      |> List.map String.lowercase_ascii |> List.sort_uniq String.compare
      |> List.filter (fun name -> not (List.mem name excluded)) in
    List.iter (fun name ->
      add name;
      List.iter add (Cohttp.Header.get_multi headers name);
      add "") names;
    if !length>max_key_input then None
    else Some {generation;key=hex (sha256 (Buffer.contents buffer))}

  let cacheable_headers headers =
    not (has_directive headers ["no-store";"no-transform"])

  let remove t key = match Hashtbl.find_opt t.items key with
    | None -> ()
    | Some item -> t.size<-t.size-item.size; Hashtbl.remove t.items key

  let lookup t ~now ~generation ticket =
    if ticket.generation<>generation then None else
    match Hashtbl.find_opt t.items ticket.key with
    | Some item when item.expires_at>=now ->
        item.accessed_at<-now; Some item
    | _ -> None

  let store t ~now ~generation ticket ~status ~headers ~body =
    if ticket.generation<>generation || status<>200 ||
       String.length body>max_body || not (cacheable_headers headers) then false
    else
      let headers=List.fold_left Cohttp.Header.remove headers
        ["set-cookie";"date";"x-request-id";"x-runtime"] in
      let headers=Cohttp.Header.replace headers "content-length"
        (string_of_int (String.length body)) in
      let size=Front.item_size ticket.key headers body [] in
      if size>max_item_size || size>t.capacity then false else (
        remove t ticket.key;
        while t.size+size>t.capacity && Hashtbl.length t.items>0 do
          let victim=Hashtbl.fold (fun key item choice ->
            match choice with None -> Some (key,item)
            | Some (_,old) when item.expires_at<now || item.accessed_at<old.accessed_at -> Some (key,item)
            | Some _ -> choice) t.items None |> Option.get |> fst in
          remove t victim
        done;
        Hashtbl.add t.items ticket.key {status;headers;body;
          expires_at=now+.ttl;accessed_at=now;size};
        t.size<-t.size+size; true)
end

(** A long-lived, separate SQLite connection sees commits from the runtime's writer
    through [PRAGMA data_version]. A connection opened for each request would always
    start from its own baseline and could not invalidate completed responses. *)
module Observer = struct
  type t = { db:Sqlite3.db; mutex:Mutex.t;
    statement:Sqlite3.stmt option;
    mutable data_version:int64; mutable generation:int64 }

  let prepared_enabled = Sys.getenv_opt "CAMPFIRE_OBSERVER_STMT" <> Some "0"

  let step_version statement =
    match Sqlite3.step statement with
       | Sqlite3.Rc.ROW -> Some (Sqlite3.column_int64 statement 0)
       | _ -> None

  let read_version db = function
    | Some statement ->
        ignore (Sqlite3.reset statement);
        Fun.protect ~finally:(fun () -> ignore (Sqlite3.reset statement))
          (fun () -> step_version statement)
    | None ->
        let statement=Sqlite3.prepare db "PRAGMA data_version" in
        Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize statement))
          (fun () -> step_version statement)

  let open_db path =
    let db=Sqlite3.db_open ~mode:`READONLY path in
    let statement = if prepared_enabled then
      Some (Sqlite3.prepare db "PRAGMA data_version") else None in
    match read_version db statement with
    | Some data_version ->
        Some {db;mutex=Mutex.create ();statement;data_version;generation=0L}
    | None ->
        Option.iter (fun statement -> ignore (Sqlite3.finalize statement)) statement;
        ignore (Sqlite3.db_close db); None

  let version t =
    Mutex.lock t.mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) (fun () ->
      match read_version t.db t.statement with
      | None -> None
      | Some current ->
          if current<>t.data_version then (
            t.data_version<-current;
            t.generation<-Int64.succ t.generation);
          Some t.generation)

  let close t =
    Option.iter (fun statement -> ignore (Sqlite3.finalize statement)) t.statement;
    ignore (Sqlite3.db_close t.db)
end

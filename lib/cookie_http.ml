(** Rack 3.2 cookie headers and ActionDispatch's HTTP cookie jar behavior. *)

type same_site = Lax | Strict | None_site

type cookie = {
  value : string;
  path : string;
  domain : string option;
  expires : Ptime.t option;
  permanent : bool;
  secure : bool;
  httponly : bool;
  same_site : same_site option;
  partitioned : bool;
}

let cookie value = {
  value; path = "/"; domain = None; expires = None; permanent = false;
  secure = false; httponly = false; same_site = Some Lax; partitioned = false;
}

type delete_options = { path : string; domain : string option; same_site : same_site option }
let default_delete_options = { path = "/"; domain = None; same_site = Some Lax }
let max_cookie_size = 4096

let escape = Ruby_compat.rack_escape

let hex c =
  if c >= '0' && c <= '9' then Some (Char.code c - 48)
  else if c >= 'a' && c <= 'f' then Some (Char.code c - 87)
  else if c >= 'A' && c <= 'F' then Some (Char.code c - 55)
  else None

let valid_utf8 s =
  let rec scan i =
    if i = String.length s then true
    else let b = Char.code s.[i] in
      if b < 0x80 then scan (i + 1)
      else
        let count, min_value =
          if b land 0xe0 = 0xc0 then 2, 0x80
          else if b land 0xf0 = 0xe0 then 3, 0x800
          else if b land 0xf8 = 0xf0 then 4, 0x10000
          else 0, 0 in
        if count = 0 || i + count > String.length s then false
        else
          let value = ref (b land (0x7f lsr count)) in
          let ok = ref true in
          for j = i + 1 to i + count - 1 do
            let byte = Char.code s.[j] in
            if byte land 0xc0 <> 0x80 then ok := false;
            value := (!value lsl 6) lor (byte land 0x3f)
          done;
          !ok && !value >= min_value && !value <= 0x10ffff &&
          not (!value >= 0xd800 && !value <= 0xdfff) && scan (i + count)
  in scan 0

let unescape wire =
  let out = Buffer.create (String.length wire) in
  let rec scan i =
    if i = String.length wire then
      let result = Buffer.contents out in
      if valid_utf8 result then result else wire
    else match wire.[i] with
      | '+' -> Buffer.add_char out ' '; scan (i + 1)
      | '%' when i + 2 < String.length wire ->
          (match hex wire.[i + 1], hex wire.[i + 2] with
           | Some hi, Some lo -> Buffer.add_char out (Char.chr ((hi lsl 4) lor lo)); scan (i + 3)
           | _ -> wire)
      | '%' -> wire
      | c -> Buffer.add_char out c; scan (i + 1)
  in scan 0

let parse_headers headers =
  let seen = Hashtbl.create 16 in
  let result = ref [] in
  List.iter (fun header ->
    String.split_on_char ';' header |> List.iteri (fun i part ->
      let part = if i = 0 then part else
          let n = String.length part in
          let start = ref 0 in
          while !start < n && part.[!start] = ' ' do incr start done;
          String.sub part !start (n - !start) in
      if part <> "" then
        let name, value = match String.index_opt part '=' with
          | None -> part, ""
          | Some n -> String.sub part 0 n, String.sub part (n + 1) (String.length part - n - 1) in
        if not (Hashtbl.mem seen name) then begin
          Hashtbl.add seen name ();
          result := (name, unescape value) :: !result
        end)) headers;
  List.rev !result

let parse_header header = parse_headers [header]
let find name cookies = List.assoc_opt name cookies

let http_date time =
  let ((year, month, day), ((hour, minute, second), _)) = Ptime.to_date_time time in
  let days = [|"Sun"; "Mon"; "Tue"; "Wed"; "Thu"; "Fri"; "Sat"|] in
  let months = [|"Jan"; "Feb"; "Mar"; "Apr"; "May"; "Jun"; "Jul"; "Aug"; "Sep"; "Oct"; "Nov"; "Dec"|] in
  let weekday = Ptime.weekday_num time in
  Printf.sprintf "%s, %02d %s %04d %02d:%02d:%02d GMT"
    days.(weekday) day months.(month - 1) year hour minute second

let same_site_attribute = function
  | None -> ""
  | Some Lax -> "; samesite=lax"
  | Some Strict -> "; samesite=strict"
  | Some None_site -> "; samesite=none"

let set_cookie_header name c =
  let b = Buffer.create 100 in
  Buffer.add_string b (name ^ "=" ^ escape c.value);
  Option.iter (fun domain -> Buffer.add_string b ("; domain=" ^ domain)) c.domain;
  Buffer.add_string b ("; path=" ^ c.path);
  Option.iter (fun date -> Buffer.add_string b ("; expires=" ^ http_date date)) c.expires;
  if c.secure then Buffer.add_string b "; secure";
  if c.httponly then Buffer.add_string b "; httponly";
  Buffer.add_string b (same_site_attribute c.same_site);
  if c.partitioned then Buffer.add_string b "; partitioned";
  Buffer.contents b

let delete_cookie_header name options =
  let domain = match options.domain with None -> "" | Some value -> "; domain=" ^ value in
  name ^ "=" ^ domain ^ "; path=" ^ options.path ^
  "; max-age=0; expires=Thu, 01 Jan 1970 00:00:00 GMT" ^
  same_site_attribute options.same_site

let permanent_expiry now =
  let ((year, month, day), time) = Ptime.to_date_time now in
  let target_year = year + 20 in
  let target_is_leap =
    target_year mod 4 = 0 &&
    (target_year mod 100 <> 0 || target_year mod 400 = 0) in
  let day = if month = 2 && day = 29 && not target_is_leap then 28 else day in
  match Ptime.of_date_time ((target_year, month, day), time) with
  | Some value -> value | None -> invalid_arg "permanent cookie expiry out of range"

type t = {
  mutable current : (string * string) list;
  mutable writes : (string * cookie) list;
  mutable deletes : (string * delete_options) list;
  now : Ptime.t;
}

let create ~headers ~now = { current = parse_headers headers; writes = []; deletes = []; now }
let get jar name = find name jar.current
let contains jar name = Option.is_some (get jar name)
let is_deleted jar name = List.mem_assoc name jar.deletes

let upsert name value pairs =
  if List.mem_assoc name pairs then List.map (fun (key, old) -> key, if key = name then value else old) pairs
  else pairs @ [name, value]

let resolve_expiry jar c = if c.permanent then { c with expires = Some (permanent_expiry jar.now) } else c

let set jar name c =
  let c = resolve_expiry jar c in
  if get jar name <> Some c.value || Option.is_some c.expires then begin
    jar.current <- upsert name c.value jar.current;
    jar.writes <- upsert name c jar.writes;
    jar.deletes <- List.remove_assoc name jar.deletes
  end

let check_overflow name value =
  let size = String.length name + String.length value in
  if size > max_cookie_size then Error (Printf.sprintf "%s cookie overflowed with size %d bytes" name size)
  else Ok ()

let set_signed jar ~secret_key_base name c =
  let c = resolve_expiry jar c in
  let expires_at = Option.map (fun t -> Ptime.to_rfc3339 ~frac_s:3 ~tz_offset_s:0 t) c.expires in
  let value = Signed_cookie.generate ~secret_key_base ~name ~value:c.value ~expires_at in
  match check_overflow name value with
  | Error _ as error -> error
  | Ok () -> set jar name { c with value; permanent = false }; Ok ()

let set_encrypted jar ~secret_key_base name value c =
  let c = resolve_expiry jar c in
  let expires_at = Option.map (fun t -> Ptime.to_rfc3339 ~frac_s:3 ~tz_offset_s:0 t) c.expires in
  let value = Encrypted_cookie.encrypt ~secret_key_base ~name ~value ~expires_at in
  match check_overflow name value with
  | Error _ as error -> error
  | Ok () -> set jar name { c with value; permanent = false }; Ok ()

let delete_with jar name options =
  if contains jar name then begin
    jar.current <- List.remove_assoc name jar.current;
    jar.deletes <- upsert name options jar.deletes
  end

let delete jar name = delete_with jar name default_delete_options

let set_cookie_headers jar ~ssl ~host =
  let writes = List.filter_map (fun (name, c) ->
    if ssl || not c.secure || String.ends_with ~suffix:".onion" host then
      Some (set_cookie_header name c) else None) jar.writes in
  writes @ List.map (fun (name, options) -> delete_cookie_header name options) jar.deletes

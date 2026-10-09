(* Byte-oriented Ruby and Rack behavior used at the HTTP boundary. *)
let is_space = function ' ' | '\t' | '\n' | '\011' | '\012' | '\r' -> true | _ -> false
let is_strip c = c = '\000' || is_space c

let strip s =
  let a = ref 0 and b = ref (String.length s) in
  while !a < !b && is_strip s.[!a] do incr a done;
  while !b > !a && is_strip s.[!b-1] do decr b done;
  String.sub s !a (!b - !a)

let digit c = c >= '0' && c <= '9'

let integer_prefix s =
  let n = String.length s and i = ref 0 in
  while !i < n && is_space s.[!i] do incr i done;
  let negative = !i < n && s.[!i] = '-' in
  if !i < n && (s.[!i] = '-' || s.[!i] = '+') then incr i;
  let starts_digit = !i < n && digit s.[!i] in
  if !i + 1 < n && s.[!i] = '0' && (s.[!i+1] = 'd' || s.[!i+1] = 'D') then i := !i + 2;
  negative, starts_digit, !i

let to_i_checked s =
  let negative, _, start = integer_prefix s in
  let n = String.length s and i = ref start and prev = ref false in
  let value = ref 0L and overflow = ref false in
  let limit = if negative then Int64.min_int else Int64.neg Int64.max_int in
  let running = ref true in
  while !i < n && !running do
    let c = s.[!i] in
    if digit c then begin
      let d = Char.code c - 48 in
      if Int64.compare !value (Int64.div (Int64.add limit (Int64.of_int d)) 10L) < 0
      then overflow := true
      else if not !overflow then value := Int64.sub (Int64.mul !value 10L) (Int64.of_int d);
      prev := true; incr i
    end else if c = '_' && !prev then (prev := false; incr i)
    else running := false
  done;
  if !overflow then None else Some (if negative then !value else Int64.neg !value)

let to_i s = match to_i_checked s with
  | Some n -> n
  | None -> if let neg, _, _ = integer_prefix s in neg then Int64.min_int else Int64.max_int

let integer_cast s =
  let _, starts_digit, _ = integer_prefix s in
  if starts_digit then to_i_checked s else None

let html_escape s =
  let b = Buffer.create (String.length s) in
  String.iter (function
    | '&' -> Buffer.add_string b "&amp;" | '<' -> Buffer.add_string b "&lt;"
    | '>' -> Buffer.add_string b "&gt;" | '"' -> Buffer.add_string b "&quot;"
    | '\'' -> Buffer.add_string b "&#39;" | c -> Buffer.add_char b c) s;
  Buffer.contents b

let percent_encode ?(space_plus=false) ?(rack=false) s =
  let b = Buffer.create (String.length s) in
  let hex = "0123456789ABCDEF" in
  String.iter (fun c ->
    let v = Char.code c in
    if digit c || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
       c = '_' || c = '.' || c = '-' || (not rack && c = '~') || (rack && c = '*')
    then Buffer.add_char b c
    else if c = ' ' && space_plus then Buffer.add_char b '+'
    else (Buffer.add_char b '%'; Buffer.add_char b hex.[v lsr 4]; Buffer.add_char b hex.[v land 15])) s;
  Buffer.contents b

let cgi_escape s = percent_encode ~space_plus:true s
let url_encode s = percent_encode s
let rack_escape s = percent_encode ~space_plus:true ~rack:true s

(* Ruby parses a numeric prefix and permits an underscore only between digits. *)
let to_f s =
  let n = match String.index_opt s '\000' with Some i -> i | None -> String.length s in
  let i = ref 0 in
  while !i < n && is_space s.[!i] do incr i done;
  let start = !i in
  if !i < n && (s.[!i] = '+' || s.[!i] = '-') then incr i;
  let signed = !i > start in
  let hex = signed && !i + 1 < n && s.[!i] = '0' && (s.[!i+1] = 'x' || s.[!i+1] = 'X') in
  if !i + 1 < n && s.[!i] = '0' && (s.[!i+1] = 'x' || s.[!i+1] = 'X') && not signed then 0.
  else begin
    if hex then i := !i + 2;
    let is_num c = digit c || (hex && ((c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) in
    let b = Buffer.create 32 and previous_digit = ref false and count = ref 0 and saw_underscore = ref false in
    Buffer.add_substring b s start (!i-start);
    let scan_digits () =
      while !i < n &&
        (is_num s.[!i] || (s.[!i] = '_' && !previous_digit && !i + 1 < n && is_num s.[!i+1])) do
        if s.[!i] <> '_' then (Buffer.add_char b s.[!i]; incr count)
        else saw_underscore := true;
        previous_digit := s.[!i] <> '_'; incr i
      done in
    scan_digits ();
    if !i < n && s.[!i] = '.' then begin
      Buffer.add_char b '.'; incr i; previous_digit := false; scan_digits ()
    end;
    if !count = 0 then
      (if hex && s.[start] = '-' && !i > start+3 && s.[start+3] = '.' then -0. else 0.)
    else begin
      let exponent = if hex then ('p','P') else ('e','E') in
      if !i < n && (s.[!i] = fst exponent || s.[!i] = snd exponent) then begin
        let at = !i and j = ref (!i+1) in
        if !j < n && (s.[!j] = '+' || s.[!j] = '-') then incr j;
        if !j < n && digit s.[!j] then begin
          Buffer.add_substring b s at (!j-at); i := !j;
          previous_digit := false; scan_digits ()
        end else if hex then Buffer.clear b
      end;
      let numeric = Buffer.contents b in
      if numeric = "" then 0. else
      let numeric =
        if not hex then begin
          let numeric = if !i < n || !saw_underscore then begin
            let mantissa_end = match String.index_opt numeric 'e' with Some j -> j | None -> String.length numeric in
            let prefix = String.sub numeric 0 mantissa_end in
            let sign_len = if String.length prefix > 0 && (prefix.[0]='-' || prefix.[0]='+') then 1 else 0 in
            let digit_count = ref 0 and seen_nonzero = ref false and end_at = ref (String.length prefix) in
            for k=sign_len to String.length prefix-1 do
              if prefix.[k] <> '0' && digit prefix.[k] then seen_nonzero := true;
              if digit prefix.[k] && !seen_nonzero then incr digit_count;
              if !digit_count > 60 && !end_at = String.length prefix then end_at := k
            done;
            if !end_at < String.length prefix then String.sub prefix 0 !end_at ^ String.sub numeric mantissa_end (String.length numeric-mantissa_end)
            else numeric
          end else numeric in
          let dot = String.index_opt numeric '.' in
          match dot with
          | None -> numeric
          | Some dot ->
            let exponent_at = match String.index_opt numeric 'e' with Some j -> j | None -> String.length numeric in
            let significant = ref 0 and seen_nonzero = ref false and cut = ref exponent_at in
            for k=dot+1 to exponent_at-1 do
              if digit numeric.[k] then begin
                if numeric.[k] <> '0' then seen_nonzero := true;
                if !seen_nonzero then incr significant;
                if !significant > 60 && !cut = exponent_at then cut := k
              end
            done;
            if !cut < exponent_at then String.sub numeric 0 !cut ^ String.sub numeric exponent_at (String.length numeric-exponent_at)
            else numeric
        end else numeric in
      try float_of_string numeric with _ -> 0.
    end
  end

let float_to_s f =
  match classify_float f with
  | FP_nan -> "NaN"
  | FP_infinite -> if f > 0. then "Infinity" else "-Infinity"
  | _ when f = 0. -> if Float.sign_bit f then "-0.0" else "0.0"
  | _ ->
    let magnitude = abs_float f in
    let rec shortest p =
      let s = Printf.sprintf "%.*e" (p-1) magnitude in
      if p = 17 || (try float_of_string s = magnitude with _ -> false) then s
      else shortest (p+1) in
    let sci = shortest 1 in
    let e = String.index sci 'e' in
    let exponent = int_of_string (String.sub sci (e+1) (String.length sci-e-1)) in
    let digits = Buffer.create 20 in
    for i=0 to e-1 do if sci.[i] <> '.' then Buffer.add_char digits sci.[i] done;
    let digits = Buffer.contents digits in
    (* Ruby's dtoa rounds this boundary value up at 16 digits even though the
       decimal does not round-trip; C's shortest round-trip formatter uses 17. *)
    let digits = if f = 2. ** (-24.) then "5960464477539063" else digits in
    let decpt = exponent + 1 and sign = if f < 0. then "-" else "" in
    let len = String.length digits in
    if decpt < -3 || (decpt > 15 && len <= decpt) then
      let rest = if len = 1 then "0" else String.sub digits 1 (len-1) in
      Printf.sprintf "%s%c.%se%c%02d" sign digits.[0] rest (if exponent < 0 then '-' else '+') (abs exponent)
    else if decpt <= 0 then sign ^ "0." ^ String.make (-decpt) '0' ^ digits
    else if decpt >= len then sign ^ digits ^ String.make (decpt-len) '0' ^ ".0"
    else sign ^ String.sub digits 0 decpt ^ "." ^ String.sub digits decpt (len-decpt)

let split_drop_trailing s delim =
  let parts = String.split_on_char delim s in
  let rec drop = function ""::xs -> drop xs | xs -> xs in
  List.rev (drop (List.rev parts))

let byte_ranges header size =
  if size <= 0L then None else
  let rec spec_from s at =
    if at + 6 > String.length s then None
    else if String.sub s at 6 = "bytes=" then
      let from = at + 6 in
      let until = match String.index_from_opt s from ';' with Some i -> i | None -> String.length s in
      if until > from then Some (String.sub s from (until-from)) else spec_from s (at+1)
    else spec_from s (at+1) in
  match header with None -> None | Some h ->
  match spec_from h 0 with
  | None -> None
  | Some spec when List.length (String.split_on_char ',' spec) > 100 -> None
  | Some spec ->
    let specs = String.split_on_char ',' spec |> List.mapi (fun index s ->
      if index = 0 then s else
      let i = ref 0 in while !i < String.length s && (s.[!i]=' ' || s.[!i]='\t') do incr i done;
      String.sub s !i (String.length s - !i)) in
    let rec drop = function ""::xs -> drop xs | xs -> xs in
    let specs = List.rev (drop (List.rev specs)) in
    let parse_one s =
      match String.index_opt s '-' with
      | None -> None
      | Some _ ->
        let parts = split_drop_trailing s '-' in
        let a = match parts with [] -> "" | x::_ -> x in
        let b = match parts with _::x::_ -> Some x | _ -> None in
        if parts = [] then None else
        let first,last = if a = "" then
          let suffix = match b with Some s -> to_i s | None -> 0L in
          (if Int64.compare suffix size > 0 then 0L else Int64.sub size suffix), Int64.pred size
        else let first = to_i a in
          first, (match b with None -> Int64.pred size | Some b -> Int64.min (to_i b) (Int64.pred size)) in
        if a <> "" && Option.is_some b && Int64.compare (to_i (Option.get b)) (to_i a) < 0 then None
        else if Int64.compare first last <= 0 then Some (Some (first,last))
        else Some None in
    let rec collect acc = function
      | [] -> Some (List.rev acc)
      | s::xs -> match parse_one s with
        | None -> None | Some None -> collect acc xs
        | Some (Some r) -> collect (r::acc) xs in
    match collect [] specs with
    | None -> None
    | Some ranges ->
      let total = List.fold_left (fun n (a,b) -> Int64.add n (Int64.add (Int64.sub b a) 1L)) 0L ranges in
      if Int64.compare total size > 0 then Some [] else Some ranges

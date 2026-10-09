(* UserAgent 0.16.11 / platform_agent 1.0.1 behavior used by the pinned Rails app.
   Ruby's malformed-input exceptions are represented explicitly. *)
module Version = struct
  type segment = Int of string | Str of string
  type t = string
  let create s = s
  let is_nil s = String.for_all (function
    | ' ' | '\t' | '\n' | '\011' | '\012' | '\r' -> true
    | _ -> false) s
  let is_present s = not (Unicode_lower.blank s)
  let digit c = c >= '0' && c <= '9'
  let alpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
  let run s i pred = let n=String.length s in let j=ref i in while !j<n && pred s.[!j] do incr j done; !j
  let normalize_digits s =
    let i=run s 0 ((=) '0') in if i=String.length s then "0" else String.sub s i (String.length s-i)
  let comparable s = let n=String.length s in let i=run s 0 digit in
    not (is_nil s) && i>0 && (i=n || s.[i]='.')
  let to_a s =
    if is_nil s then [] else if not (comparable s) then [Str s] else
    let n=String.length s in
    let rec scan i acc = if i>=n then List.rev acc else
      if digit s.[i] then let j=run s i digit in
        scan j (Int (normalize_digits (String.sub s i (j-i)))::acc)
      else if alpha s.[i] then let j=run s (i+1) (fun c -> alpha c || digit c || c='-') in
        if j=n then scan j (Str (String.sub s i (j-i))::acc) else scan (i+1) acc
      else scan (i+1) acc in scan 0 []
  let compare_segment a b = match a,b with
    | Int x, Int y -> let c=Int.compare (String.length x) (String.length y) in if c<>0 then c else String.compare x y
    | Str x, Str y -> String.compare x y
    | Int _, Str _ -> 1 | Str _, Int _ -> -1
  let compare a b =
    if not (comparable a) then if a=b then 0 else -1 else
    let xs=Array.of_list (to_a a) and ys=Array.of_list (to_a b) in
    let rec loop i = if i=6 then 0 else
      let x=if i<Array.length xs then xs.(i) else Int "0"
      and y=if i<Array.length ys then ys.(i) else Int "0" in
      let c=compare_segment x y in if c<>0 then c else loop (i+1) in loop 0
end

type error = No_method | Argument
let ( let* ) r f = match r with Ok x -> f x | Error e -> Error e
let opt_map f = function None -> None | Some x -> Some (f x)
let opt_bind x f = match x with None -> None | Some y -> f y
let opt_exists f = function None -> false | Some x -> f x
let first = function [] -> None | x::_ -> Some x
let last xs = first (List.rev xs)
let nth xs n = List.nth_opt xs n
let contains s sub =
  let n=String.length sub and m=String.length s in
  let rec search i = i+n<=m && (String.sub s i n=sub || search (i+1)) in search 0
let starts s sub = String.starts_with ~prefix:sub s
let lower = Unicode_lower.lowercase
let ci_equal a b = lower a=lower b
let ci_contains a b = contains (lower a) (lower b)
let ruby_space = function ' '| '\t'|'\n'|'\011'|'\012'|'\r' -> true | _ -> false
let run s i pred = let n=String.length s in let j=ref i in while !j<n && pred s.[!j] do incr j done; !j
let sub s i j = String.sub s i (j-i)
let strip s = let n=String.length s in let trim c = ruby_space c || c='\000' in let a=run s 0 trim in
  let b=ref n in while !b>a && trim s.[!b-1] do decr b done; sub s a !b
let ruby_split s sep =
  let n=String.length s and k=String.length sep in
  let rec loop i acc =
    let rec find j = if j+k>n then None else if String.sub s j k=sep then Some j else find (j+1) in
    match find i with None -> List.rev (sub s i n::acc)
    | Some j -> loop (j+k) (sub s i j::acc) in
  let rec drop = function ""::xs -> drop xs | xs -> xs in List.rev (drop (List.rev (loop 0 [])))
let capture_after s prefix pred =
  let n=String.length s and k=String.length prefix in
  let rec find i = if i+k>n then None else if String.sub s i k=prefix then
    let j=run s (i+k) pred in if j>i+k then Some (sub s (i+k) j) else find (i+1)
    else find (i+1) in find 0
let version_char c = Version.digit c || c='.'
let webkit_comment_version s =
  match String.index_opt s '/' with None -> None | Some slash ->
    let name=String.sub s 0 slash in
    if not (ci_equal name "AppleWebKit") then None else
    let j=run s (slash+1) version_char in
    if j>slash+1 then Some (sub s (slash+1) j) else None
let trident_rv s =
  let rec check i = if i+7>String.length s then false else if String.sub s i 7="Trident" then
    let stop=match String.index_from_opt s (i+7) '\n' with None -> String.length s | Some j -> j in
    let rec rv j = j+3<=stop && (j>i+7 && String.sub s j 3="rv:" || rv (j+1)) in rv (i+7)
    else check (i+1) in check 0
let ie_version s =
  let n=String.length s in let rec loop i = if i>=n then None else
    let start = if i+4<n && String.sub s i 4="MSIE" && ruby_space s.[i+4] then Some (i+5)
      else if i+3<=n && String.sub s i 3="rv:" then Some (i+3) else None in
    match start with None -> loop (i+1) | Some j -> let e=run s j version_char in
      if e>j then Some (sub s j e) else loop (i+1) in loop 0

type product = { name:string; version:Version.t; comment:string list option }
type kind = Base | Edge | Ie | Opera | Wechat | Vivaldi | Chrome | Itunes | PlayStation
          | PodcastAddict | Webkit | Gecko | Wmp | AppleCoreMedia | Libavformat
type t = { kind:kind; products:product list }
let match_product s =
  let n=String.length s in let quotes=run s 0 (fun c -> c='\'' || c='"') in
  let prodchar c = c<>'/' && not (ruby_space c) in
  let start = if quotes<n && prodchar s.[quotes] then Some quotes
    else if quotes>0 then Some (quotes-1) else None in
  match start with None -> None | Some a ->
    let b=run s (a+1) prodchar in let vstart=if b<n && s.[b]='/' then b+1 else b in
    let vend=run s vstart (fun c -> not (ruby_space c) && c<>',') in
    let cend,comment =
      if vend+1<n && ruby_space s.[vend] && s.[vend+1]='(' then
        (match String.index_from_opt s (vend+2) ')' with
        | Some close -> close+1,Some (ruby_split (sub s (vend+2) close) "; ")
        | None -> vend,None)
      else if vend+10<=n && String.sub s vend 10=",gzip(gfe)" then vend+10,None
      else vend,None in
    Some (cend,{name=sub s a b;version=sub s vstart vend;comment})
let joined p = opt_map (String.concat "; ") p.comment
let comments p = Option.value p.comment ~default:[]
let comments_of ps = List.concat_map comments ps
let comment_at p i = opt_bind p.comment (fun c -> nth c i)
let detect ps name = List.find_opt (fun p -> ci_equal p.name name) ps
let any ps name = List.exists (fun p -> p.name=name) ps
let kind ps =
  let f=first ps and l=last ps in
  let fv=opt_map (fun p -> p.version) f in
  let fc i=opt_bind f (fun p -> comment_at p i) in
  if opt_exists (fun p -> p.name="Edge") l then Edge
  else if opt_exists (fun p -> p.comment<>None &&
      (opt_exists (fun c -> contains c "MSIE") (comment_at p 1) || opt_exists trident_rv (joined p))) f then Ie
  else if opt_exists (fun p -> p.name="Opera") f || opt_exists (fun p -> p.name="OPR") l then Opera
  else if List.exists (fun p -> ci_contains p.name "micromessenger") ps then Wechat
  else if any ps "Vivaldi" then Vivaldi
  else if any ps "Chrome" || any ps "CriOS" then Chrome
  else if any ps "iTunes" then Itunes
  else if opt_exists (fun c -> contains c "PLAYSTATION 3" || contains c "PlayStation Vita" || contains c "PlayStation 4") (fc 0) then PlayStation
  else if List.length ps>=3 && (List.nth ps 0).name="Podcast" && (List.nth ps 1).name="Addict" && (List.nth ps 2).name="-" then PodcastAddict
  else if List.exists (fun p -> ci_equal p.name "applewebkit" || List.exists (fun c -> webkit_comment_version c<>None) (comments p)) ps then Webkit
  else if opt_exists (fun p -> p.name="Mozilla") f then Gecko
  else if List.exists (fun p -> List.mem p.name ["NSPlayer";"Windows-Media-Player";"WMFSDK"] && not (List.mem fv [Some "4.1.0.3856";Some "7.10.0.3059";Some "7.0.0.1956"])) ps then Wmp
  else if any ps "AppleCoreMedia" then AppleCoreMedia
  else if List.exists (fun p -> p.name="Lavf" || (p.name="NSPlayer" && fv=Some "4.1.0.3856")) ps then Libavformat
  else Base
let parse s =
  let s=if strip s="" then "Mozilla/4.0 (compatible)" else s in
  let rec loop s acc = match match_product s with
    | None -> List.rev acc | Some (len,p) -> loop (strip (String.sub s len (String.length s-len))) (p::acc) in
  let products=loop s [] in {kind=kind products;products}
let application a = match a.kind with
  | Chrome | Vivaldi | Webkit | Itunes | AppleCoreMedia ->
    List.find_opt (fun p -> opt_exists ((<>) []) p.comment) a.products
  | _ -> first a.products
let application_comment a = opt_bind (application a) (fun p -> p.comment)
let base_version a = opt_map (fun p -> p.version) (application a)
let bot a = match application a with None -> true | Some app ->
  List.exists (fun c -> ci_contains c "bot") (comments_of a.products)
  || detect a.products "Chrome-Lighthouse"<>None || contains app.name "bot"
let find_capture s prefix pred = capture_after s prefix pred
let mac_os_x_version s =
  let rec seek i = if i>=String.length s then None else
    let tail=String.sub s i (String.length s-i) in
    let prefix=if starts tail "Intel Mac OS X" then Some "Intel Mac OS X"
      else if starts tail "PPC Mac OS X" then Some "PPC Mac OS X" else None in
    match prefix with None -> seek (i+1) | Some p ->
      let j=run s (i+String.length p) ruby_space in
      let e=run s j (fun c -> Version.digit c || c='_' || c='.') in
      Some (if e>j then Some (sub s j e) else None) in seek 0
let ios_version s =
  let rec seek i = if i+4>String.length s then None else if String.sub s i 4<>"CPU " then seek (i+1) else
    let j=i+4 in let j=if j+7<=String.length s && String.sub s j 7="iPhone " then j+7
      else if j+5<=String.length s && String.sub s j 5="iPod " then j+5 else j in
    if j+3>String.length s || String.sub s j 3<>"OS " then seek (i+1)
    else let a=j+3 in let b=run s a (fun c -> Version.digit c || c='_') in
      if b>a && b+14<=String.length s && String.sub s b 14=" like Mac OS X" then Some (sub s a b)
      else seek (i+1) in seek 0
let chrome_os_version s =
  let rec seek i = if i+4>String.length s then None else if String.sub s i 4<>"CrOS" then seek (i+1) else
    let a=i+4 in if a>=String.length s || not (ruby_space s.[a]) then seek (i+1) else
    let b=run s (a+1) (fun c -> not (ruby_space c)) in
    if b=a+1 || b>=String.length s || not (ruby_space s.[b]) then seek (i+1)
    else let c=b+1 in let d=run s c Version.digit in if d=c then seek (i+1)
    else let rec more j = if j+1<String.length s && s.[j]='.' && Version.digit s.[j+1]
      then more (run s (j+1) Version.digit) else j in Some (sub s c (more d)) in seek 0
let windows_os s =
  let rec seek i = if i>=String.length s then None else
    let tail=String.sub s i (String.length s-i) in
    let prefix=if starts tail "Windows NT " then Some "Windows NT "
      else if starts tail "Windows Phone OS " then Some "Windows Phone OS "
      else if starts tail "Windows Phone " then Some "Windows Phone " else None in
    match prefix with None -> seek (i+1) | Some p ->
      let j=i+String.length p in let k=run s j version_char in
      if k>j then Some (sub s i k) else seek (i+1) in seek 0
let normalize_os s =
  let windows=["Windows NT 10.0","Windows 10";"Windows NT 6.3","Windows 8.1";
    "Windows NT 6.2","Windows 8";"Windows NT 6.1","Windows 7";
    "Windows NT 6.0","Windows Vista";"Windows NT 5.2","Windows XP x64 Edition";
    "Windows NT 5.1","Windows XP";"Windows NT 5.01","Windows 2000, Service Pack 1 (SP1)";
    "Windows NT 5.0","Windows 2000";"Windows NT 4.0","Windows NT 4.0";
    "Windows 98","Windows 98";"Windows 95","Windows 95";"Windows CE","Windows CE"] in
  match List.assoc_opt s windows with Some x -> x | None ->
  match mac_os_x_version s with Some (Some v) -> "OS X " ^ String.map (function '_' -> '.' | c -> c) v
  | Some None -> "OS X" | None ->
  match ios_version s with Some v -> "iOS " ^ String.map (function '_' -> '.' | c -> c) v
  | None -> match chrome_os_version s with Some v -> "ChromeOS " ^ v | None -> s
let pick_chrome_os cs =
  let c0=nth cs 0 and c1=nth cs 1 and c2=nth cs 2 in
  let x=if opt_exists (fun x -> contains x "Windows NT") c0 then c0
    else if c2=None || opt_exists (fun x -> contains x "Android") c1 then c1 else c2 in
  opt_map normalize_os x
let webkit_platform a = match application_comment a with None -> None | Some cs ->
  let c0=first cs in
  if opt_exists (fun x -> contains x "Windows") c0 then Some "Windows"
  else if c0=Some "BB10" then Some "BlackBerry"
  else if List.exists (fun x -> contains x "Android") cs then Some "Android"
  else c0
let webkit_os a = match application_comment a with None -> None | Some cs ->
  let c0=nth cs 0 and c1=nth cs 1 and c2=nth cs 2 in
  if opt_exists (fun x -> contains x "Windows NT") c0 then opt_map normalize_os c0
  else if c2=None || opt_exists (fun x -> contains x "Android") c1 then opt_map normalize_os c1
  else match List.find_opt (fun x -> ios_version x<>None) cs with
    | Some x -> Some (normalize_os x) | None -> opt_map normalize_os c2
let playstation_os a = opt_map (String.concat " ") (application_comment a)
let playstation_platform a = match playstation_os a with None -> None | Some os ->
  if contains os "PLAYSTATION 3" then Some "PlayStation 3"
  else if contains os "PlayStation 4" then Some "PlayStation 4"
  else if contains os "PlayStation Vita" then Some "PlayStation Vita" else None
let playstation_browser a =
  match opt_bind (application_comment a) first with None -> None | Some c ->
  if contains c "PLAYSTATION 3" then Some "PS3 Internet Browser"
  else if opt_exists (fun p -> p.name="Silk") (last a.products) then Some "Silk"
  else if contains c "PlayStation 4" then Some "PS4 Internet Browser" else None
let podcast_addict_os a =
  match nth a.products 3 with None -> Ok None | Some p ->
    if p.name<>"Dalvik" && p.name<>"Mozilla" then Ok None else
    match p.comment with None -> Error No_method | Some cs ->
      Ok (if List.length cs>3 then nth cs 2 else if List.length cs=3 then Some "Android" else None)
let gecko_os a = match application_comment a with None -> None | Some cs ->
  let c0=first cs in let i=if nth cs 1=Some "U" then 2
    else if opt_exists (fun x -> starts x "Windows " || starts x "Android") c0 then 0
    else if c0=Some "Mobile" then -1 else 1 in
  if i<0 then None else opt_map normalize_os (nth cs i)
let wmp_os a =
  let segments=Option.value (opt_map Version.to_a (base_version a)) ~default:[] in
  let number i=match nth segments i with Some (Version.Int s) -> Int64.of_string_opt s | _ -> None in
  match number 0 with None -> Error (if segments=[] then No_method else Argument)
  | Some major ->
    let m=Int64.to_int major and p2=opt_map Int64.to_int (number 2) and p3=opt_map Int64.to_int (number 3) in
    let result=if m<=4 then (match p3 with Some (3564|3925) -> "Windows 98" | Some 3857 -> "Windows 9x"
        | Some 3936 -> "Windows XP" | Some 3938 -> "Windows 2000" | _ -> "Windows")
      else if m=7 then (if p3=Some 3055 then "Windows 98" else "Windows")
      else if m=8 then "Windows XP"
      else if m=9 || m=10 then (match p3 with Some 2980 -> "Windows 98/2000"
        | Some (3268|3367|3270) -> "Windows 2000" | Some (3802|4503) -> "Windows XP" | _ -> "Windows")
      else if m=11 || m=12 then (match p2 with Some (9841|9858|9860|9879) -> "Windows 10"
        | Some 9651 -> "Windows Phone 8.1" | Some 9600 -> "Windows 8.1" | Some 9200 -> "Windows 8"
        | Some (7600|7601) -> "Windows 7" | Some (6000|6001|6002) -> "Windows Vista"
        | Some 5721 -> "Windows XP" | _ -> "Windows") else "Windows" in Ok result
let itunes_os a =
  let cs=application_comment a in
  if not (opt_exists (fun x -> contains x "Windows") (opt_bind cs first)) then webkit_os a
  else let full=Option.value (opt_bind cs (fun cs -> nth cs 1)) ~default:"" in
  Some (match List.find_opt (contains full) ["Windows 8.1";"Windows 8";"Windows 7";"Windows Vista";"Windows XP"] with
    Some x -> x | None -> "Windows")
let webkit_browser a =
  if opt_exists (fun x -> contains x "Android") (webkit_os a) then "Android"
  else if webkit_platform a=Some "BlackBerry" then "BlackBerry" else "Safari"
let gecko_browser a =
  match List.find_opt (fun n -> detect a.products n<>None) ["PaleMoon";"Firefox";"Camino";"Iceweasel";"Seamonkey"] with
  | Some x -> x | None -> Option.value (opt_map (fun p -> p.name) (first a.products)) ~default:""
let try_browser a =
  let b=match a.kind with
    | Base -> opt_map (fun p -> p.name) (application a)
    | Edge -> Some "Edge" | Ie -> Some "Internet Explorer" | Opera -> Some "Opera"
    | Wechat -> Some "Wechat Browser" | Vivaldi -> Some "Vivaldi"
    | Chrome -> Some (if detect a.products "Iron"<>None then "Iron" else "Chrome")
    | Itunes -> Some "iTunes" | PlayStation -> playstation_browser a
    | PodcastAddict -> Some "Podcast Addict" | Webkit -> Some (webkit_browser a)
    | Gecko -> Some (gecko_browser a) | Wmp -> Some "Windows Media Player"
    | AppleCoreMedia -> Some "AppleCoreMedia" | Libavformat -> Some "libavformat" in Ok b
let browser a = match try_browser a with Ok (Some s) -> s | _ -> ""
let webkit_build_version = function
  | "85.7" -> Some "1.0" | "85.8.5" | "85.8.2" -> Some "1.0.3"
  | "124" -> Some "1.2" | "125.2" -> Some "1.2.2" | "125.4" -> Some "1.2.3"
  | "125.5.5" | "125.5.6" | "125.5.7" -> Some "1.2.4"
  | "312.1.1" | "312.1" -> Some "1.3"
  | "312.5" | "312.5.1" | "312.5.2" -> Some "1.3.1"
  | "312.8" | "312.8.1" -> Some "1.3.2"
  | "412" | "412.6" | "412.6.2" -> Some "2.0"
  | "412.7" -> Some "2.0.1" | "416.11" | "416.12" -> Some "2.0.2"
  | "417.9" | "418" -> Some "2.0.3"
  | "418.8" | "418.9" | "418.9.1" | "419" -> Some "2.0.4"
  | "425.13" -> Some "2.2" | "534.52.7" -> Some "5.1.2" | _ -> None
let webkit_version a = match detect a.products "Version" with Some p -> p.version | None ->
  let os=webkit_os a in
  match opt_bind os (fun os -> capture_after os "iOS " (fun c -> Version.digit c || c='.')) with
  | Some ios when webkit_browser a="Safari" -> String.map (function '_' -> '.' | c -> c) ios
  | _ ->
    let build=match List.find_opt (fun p -> ci_equal p.name "applewebkit") a.products with
      | Some p -> Some p.version | None ->
        let rec find = function [] -> None | c::rest ->
          match webkit_comment_version c with None -> find rest | Some _ as x -> x in find (comments_of a.products) in
    Option.value (opt_bind build webkit_build_version) ~default:""
let opera_mini a = opt_exists (fun c -> contains c "Opera Mini") (opt_bind (first a.products) joined)
let opera_version a =
  if opera_mini a then let cs=Option.value (application_comment a) ~default:[] in
    let c=List.find_opt (fun c -> contains c "Opera Mini") cs in
    Some (Option.value (opt_bind c (fun c -> capture_after c "Opera Mini/" (fun x -> Version.digit x || x='.'))) ~default:"")
  else match detect a.products "Version" with Some p -> Some p.version | None ->
    match detect a.products "OPR" with Some p -> Some p.version | None -> base_version a
let playstation_version a =
  match playstation_os a with None -> None | Some os ->
    if playstation_browser a=Some "Silk" then opt_map (fun p -> p.version) (last a.products)
    else let marker=match playstation_platform a with Some "PlayStation 3" -> Some "PLAYSTATION 3 "
      | Some "PlayStation 4" -> Some "PlayStation 4 "
      | Some "PlayStation Vita" -> Some "PlayStation Vita " | _ -> None in
    opt_map (fun marker -> Option.value (last (ruby_split os marker)) ~default:"") marker
let try_version a = match a.kind with
  | Base | Wmp | AppleCoreMedia -> Ok (base_version a)
  | Edge | Vivaldi -> Ok (opt_map (fun p -> p.version) (last a.products))
  | Ie -> let joined=Option.value (opt_bind (application a) joined) ~default:"" in
    Ok (Some (Option.value (ie_version joined) ~default:""))
  | Opera -> Ok (opera_version a)
  | Wechat -> (match detect a.products "MicroMessenger" with None -> Error No_method | Some p -> Ok (Some p.version))
  | Chrome -> (match detect a.products "CriOs" with Some p -> Ok (Some p.version) | None ->
      match detect a.products "chrome" with Some p -> Ok (Some p.version) | None -> Error No_method)
  | Itunes -> (match detect a.products "iTunes" with None -> Error No_method | Some p -> Ok (Some p.version))
  | PlayStation -> Ok (playstation_version a)
  | PodcastAddict -> Ok None
  | Webkit -> Ok (Some (webkit_version a))
  | Gecko -> (match detect a.products (gecko_browser a) with None -> Error No_method | Some p ->
      Ok (if Version.is_nil p.version then base_version a else Some p.version))
  | Libavformat -> Ok (if detect a.products "NSPlayer"<>None then None else base_version a)
let version a = match try_version a with Ok (Some v) -> v | _ -> ""
let try_platform a =
  let cs=application_comment a in let c0=opt_bind cs first in
  let any s=opt_exists (fun cs -> List.exists (fun c -> contains c s) cs) cs in
  match a.kind with
  | Base | Libavformat -> Ok None | Edge | Ie | Wmp -> Ok (Some "Windows")
  | Opera | AppleCoreMedia -> Ok (if cs=None then None else if opt_exists (fun c -> contains c "Windows") c0 then Some "Windows" else c0)
  | Wechat -> Ok (if cs=None then None else if opt_exists (fun c -> contains c "iPhone") c0 then Some "iPhone"
      else if any "Android" then Some "Android" else c0)
  | Chrome | Vivaldi -> Ok (if cs=None then None else if opt_exists (fun c -> contains c "Windows") c0 then Some "Windows"
      else if any "CrOS" then Some "ChromeOS" else if any "Android" then Some "Android" else c0)
  | Webkit | Itunes -> Ok (webkit_platform a)
  | PlayStation -> Ok (playstation_platform a)
  | PodcastAddict -> let* os=podcast_addict_os a in
      (match os with None -> Error No_method | Some os -> Ok (if contains os "Android" then Some "Android" else None))
  | Gecko -> Ok (if cs=None then None else match c0 with Some ("compatible" | "Mobile") -> None
      | Some c when starts c "Windows " -> Some "Windows" | _ -> c0)
let platform a = match try_platform a with Ok x -> x | Error _ -> None
let try_os a = match a.kind with
  | Base | Libavformat -> Ok None
  | Edge -> let matched=List.find_map windows_os (comments_of a.products) in
      Ok (Some (normalize_os (Option.value matched ~default:"")))
  | Ie -> let c=Option.value (opt_bind (application a) joined) ~default:"" in
      Ok (Some (normalize_os (Option.value (windows_os c) ~default:"")))
  | Opera -> (match application_comment a with None -> Ok None | Some cs ->
      match first cs with Some c when contains c "Windows" -> Ok (Some (normalize_os c))
        | _ -> Ok (nth cs 1))
  | Wechat | Chrome | Vivaldi | AppleCoreMedia -> Ok (opt_bind (application_comment a) pick_chrome_os)
  | Webkit -> Ok (webkit_os a)
  | Itunes -> Ok (itunes_os a)
  | PlayStation -> Ok (playstation_os a)
  | PodcastAddict -> podcast_addict_os a
  | Gecko -> Ok (gecko_os a)
  | Wmp -> let* os=wmp_os a in Ok (Some os)
let os a = match try_os a with Ok x -> x | Error _ -> None
let try_mobile a = match a.kind with
  | Opera -> Ok (opera_mini a)
  | PlayStation -> Ok (playstation_platform a=Some "PlayStation Vita")
  | PodcastAddict -> Ok true
  | Wmp -> let* os=wmp_os a in Ok (os="Windows Phone 8" || os="Windows Phone 8.1")
  | _ -> let* os=try_os a in Ok (
      detect a.products "Mobile"<>None || List.exists ((=) "Mobile") (comments_of a.products)
      || opt_exists (fun os -> contains os "Android") os
      || opt_exists (fun cs -> List.exists (fun c -> starts c "IEMobile") cs) (application_comment a))

type view = { ios:bool; android:bool; mac:bool; chrome:bool; firefox:bool;
  safari:bool; edge:bool; apple_messages:bool; mobile:bool; desktop:bool;
  windows:bool; operating_system:string; browser:string }
type application_platform = { raw:string; agent:t }
let application_platform raw = let raw=Option.value raw ~default:"" in {raw;agent=parse raw}
let flag p s = contains p.raw s
let app_ios p = flag p "iPhone" || flag p "iPad"
let app_android p = flag p "Android"
let app_mac p = flag p "Macintosh"
let app_mobile p = app_ios p || app_android p
let app_apple_messages p = ci_contains p.raw "facebookexternalhit" && ci_contains p.raw "twitterbot"
let try_operating_system p =
  let* platform=try_platform p.agent in
  let platform=Option.value platform ~default:"" in
  match List.find_opt (fun (needle,_) -> contains platform needle)
      ["Android","Android";"iPad","iPad";"iPhone","iPhone";
       "Macintosh","macOS";"Windows","Windows";"CrOS","ChromeOS"] with
  | Some (_,os) -> Ok (Some os) | None ->
    let* os=try_os p.agent in Ok (opt_map (fun os -> if contains os "Linux" then "Linux" else os) os)
let browser_matches result names =
  let* b=result in match b with None -> Error No_method | Some b ->
    Ok (List.exists (contains b) names)
let to_view p =
  let b=try_browser p.agent and os=try_operating_system p in
  let bf names=match browser_matches b names with Ok x -> x | Error _ -> false in
  let string_or_empty = function Ok (Some s) -> s | _ -> "" in
  {ios=app_ios p;android=app_android p;mac=app_mac p;
   chrome=bf ["Chrome"];firefox=bf ["Firefox";"FxiOS"];
   safari=bf ["Safari"];edge=bf ["Edg"];
   apple_messages=app_apple_messages p;mobile=app_mobile p;desktop=not (app_mobile p);
   windows=(os=Ok (Some "Windows"));operating_system=string_or_empty os;browser=string_or_empty b}
let try_browser_blocked p =
  if Unicode_lower.blank p.raw then Ok false else
  let* v=try_version p.agent in
  match v with None -> Ok false | Some v when not (Version.is_present v) -> Ok false
  | Some v ->
    let* b=try_browser p.agent in
    let* b=match b with None -> Error No_method | Some b -> Ok (lower b) in
    let minimum=match b with "safari" -> Some (Some "17.2")
      | "chrome" -> Some (Some "120") | "firefox" -> Some (Some "121")
      | "opera" -> Some (Some "104") | "internet explorer" -> Some None | _ -> None in
    match minimum with None -> Ok false | Some minimum ->
      let below=match minimum with None -> true | Some x -> Version.compare v x<0 in
      Ok (below && not (bot p.agent))
let browser_blocked p = match try_browser_blocked p with Ok x -> x | Error _ -> false

type page_request = { platform:application_platform; view:view; checked:bool; blocked:bool }
let page_request raw =
  let platform=application_platform raw in
  let checked=match raw with Some s -> not (Unicode_lower.blank s) | None -> false in
  let blocked=checked && browser_blocked platform in
  {platform;view=to_view platform;checked;blocked}

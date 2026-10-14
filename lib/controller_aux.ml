(** PWA, QR, health, Turbo, Action Mailbox, and Active Storage route policy.
    M5 supplies OpenGraph fetching and M6 registers storage actions. *)

open Lwt.Infix
module H = Http_app

external qr_library_matrix : string -> int -> (int * string) option = "campfire_qr_matrix"

(* libqrencode rejects an empty segment. RQRCode's empty numeric segment is a
   fixed version-one code, recorded here from its pinned compatibility vector. *)
let empty_qr_matrix = String.concat "" [
  "111111100111101111111";"100000101000101000001";
  "101110101010101011101";"101110101101001011101";
  "101110101101001011101";"100000101011001000001";
  "111111101010101111111";"000000000101000000000";
  "001001111000110111110";"100101011100001101100";
  "110001100011101111011";"110101010000011101100";
  "101111111101010111111";"000000001000101000000";
  "111111101011010000111";"100000101100100010000";
  "101110100100111000111";"101110100111101101100";
  "101110101100000111011";"100000100010100101110";
  "111111100110101111111"]

let qr_capacity_h = [|
  72;128;208;288;368;480;528;688;800;976;
  1120;1264;1440;1576;1784;2024;2264;2504;2728;3080;
  3248;3536;3712;4112;4304;4768;5024;5288;5608;5960;
  6344;6760;7208;7688;7888;8432;8768;9136;9776;10208|]

(* RQRCode picks the first version whose H-level capacity is strictly greater
   than the one-segment bit length. libqrencode accepts equality, so its
   automatic version choice is too small at exact boundaries. *)
let qr_mode input =
  if String.for_all (function '0'..'9' -> true | _ -> false) input then `Numeric
  else if String.for_all (fun c -> String.contains
    "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:" c) input then `Alphanumeric
  else `Byte

let qr_segment_bits mode version length =
  let macro = if version<=9 then 0 else if version<=26 then 1 else 2 in
  let length_bits = match mode with
    | `Numeric -> [|10;12;14|].(macro)
    | `Alphanumeric -> [|9;11;13|].(macro)
    | `Byte -> [|8;16;16|].(macro) in
  let content_bits = match mode with
    | `Numeric -> length/3*10 + [|0;4;7|].(length mod 3)
    | `Alphanumeric -> length/2*11 + (if length mod 2=0 then 0 else 6)
    | `Byte -> length*8 in
  4 + length_bits + content_bits

let qr_minimum_version input =
  let length=String.length input and mode=qr_mode input in
  let rec choose version =
    if version>40 then None
    else if qr_segment_bits mode version length < qr_capacity_h.(version-1)
    then Some version else choose (version+1) in
  choose 1

let qr_matrix input = if input="" then Some (21,empty_qr_matrix)
  else Option.bind (qr_minimum_version input) (qr_library_matrix input)

let response value = Lwt.return value
let head status = H.respond ~status ~content_type:"text/html" ""
let available c formats = Option.is_some (Http_format.negotiate c.H.format formats)
let public ?(csrf=true) action =
  Some { H.action; before_action=H.before ~access:H.Public ~csrf () }
let standalone action = Some { H.action; before_action=(fun _ -> Lwt.return (Ok ())) }
let user action = Some { H.action; before_action=H.default_before_action }

let service_worker_js = {|self.addEventListener("push", async (event) => {
  const data = await event.data.json()
  event.waitUntil(Promise.all([ showNotification(data), updateBadgeCount(data.options) ]))
})

async function showNotification({ title, options }) {
  return self.registration.showNotification(title, options)
}

async function updateBadgeCount({ data: { badge } }) {
  return self.navigator.setAppBadge?.(badge || 0)
}

self.addEventListener("notificationclick", (event) => {
  event.notification.close()

  const url = new URL(event.notification.data.path, self.location.origin).href
  event.waitUntil(openURL(url))
})

async function openURL(url) {
  const clients = await self.clients.matchAll({ type: "window" })
  const focused = clients.find((client) => client.focused)

  if (focused) {
    await focused.navigate(url)
  } else {
    await self.clients.openWindow(url)
  }
}
|}

let service_worker c =
  if not (available c [Http_format.Js]) then response (H.error ~status:406)
  else response (H.respond ~status:200 ~content_type:"text/javascript; charset=utf-8"
    service_worker_js)

let manifest_json c account =
  let context = View_presenter.context c account in
  let context = { context with Views.account_name =
    Option.fold ~none:"Campfire"
      ~some:(fun row -> row.Db_accounts.Account.name) account } in
  let version = Option.map (fun (row : Db_accounts.Account.t) ->
    View_presenter.timestamp_number row.updated_at) account in
  let logo_url_small = Route_helpers.fresh_account_logo
    ?v:version ~size:"small" () in
  Views.pwa_manifest_json ~context ~logo_url_small

let manifest c =
  if not (available c [Http_format.Json]) then response (H.error ~status:406)
  else Db_runtime.read_async c.H.runtime Db_accounts.Account.first >|= fun account ->
    H.respond ~status:200 ~content_type:"application/json; charset=utf-8"
      (manifest_json c account)

(* libqrencode supplies the single-segment data and ECC; its mask scoring
   differs from RQRCode. Re-score its matrix with RQRCode's lost-points rule. *)
let qr_mask pattern row col = match pattern with
  | 0 -> (row+col) mod 2 = 0
  | 1 -> row mod 2 = 0
  | 2 -> col mod 3 = 0
  | 3 -> (row+col) mod 3 = 0
  | 4 -> (row/2+col/3) mod 2 = 0
  | 5 -> (row*col) mod 2 + (row*col) mod 3 = 0
  | 6 -> ((row*col) mod 2 + (row*col) mod 3) mod 2 = 0
  | 7 -> ((row*col) mod 3 + (row+col) mod 2) mod 2 = 0
  | _ -> assert false

let qr_format_info pattern =
  let data = (2 lsl 3) lor pattern in
  let generator = (1 lsl 10) lor (1 lsl 8) lor (1 lsl 5) lor
    (1 lsl 4) lor (1 lsl 2) lor (1 lsl 1) lor 1 in
  let bit_length n = let rec loop n count =
    if n=0 then count else loop (n lsr 1) (count+1) in loop n 0 in
  let rec divide value =
    let shift = bit_length value - bit_length generator in
    if shift < 0 then value else divide (value lxor (generator lsl shift)) in
  ((data lsl 10) lor divide (data lsl 10)) lxor
    ((1 lsl 14) lor (1 lsl 12) lor (1 lsl 10) lor (1 lsl 4) lor (1 lsl 1))

let qr_format_row size i = if i<6 then i else if i<8 then i+1 else size-15+i
let qr_format_col size i = if i<8 then size-i-1 else if i<9 then 15-i else 14-i
let qr_bit matrix size row col = Bytes.get matrix (row*size+col) = '1'
let qr_set matrix size row col value =
  Bytes.set matrix (row*size+col) (if value then '1' else '0')

let qr_current_mask size matrix =
  let bits = ref 0 in
  for i=0 to 14 do
    if qr_bit matrix size (qr_format_row size i) 8 then
      bits := !bits lor (1 lsl i)
  done;
  let rec search candidate =
    if candidate=8 then None
    else if qr_format_info candidate = !bits then Some candidate
    else search (candidate+1) in
  search 0

let qr_reserved size =
  let reserved = Array.make (size*size) false in
  let mark row col = if row>=0 && row<size && col>=0 && col<size then
    reserved.(row*size+col) <- true in
  List.iter (fun (base_row,base_col) ->
    for row=(-1) to 7 do for col=(-1) to 7 do
      mark (base_row+row) (base_col+col)
    done done)
    [0,0;0,size-7;size-7,0];
  let version=(size-17)/4 in
  if version>=2 then (
    let count=version/7+2 in
    let step=if version=32 then 26 else
      ((version*4+count*2+1)/(count*2-2))*2 in
    let centers=Array.init count (fun i ->
      if i=0 then 6 else size-7-(count-1-i)*step) in
    Array.iter (fun row -> Array.iter (fun col ->
      if not reserved.(row*size+col) then
        for dr=(-2) to 2 do for dc=(-2) to 2 do
          mark (row+dr) (col+dc)
        done done) centers) centers);
  for i=8 to size-9 do mark i 6; mark 6 i done;
  for i=0 to 14 do
    mark (qr_format_row size i) 8;
    mark 8 (qr_format_col size i)
  done;
  mark (size-8) 8;
  if version>=7 then for i=0 to 17 do
    mark (i/3) (i mod 3+size-11);
    mark (i mod 3+size-11) (i/3)
  done;
  reserved

let qr_lost_points size matrix =
  let cell row col = qr_bit matrix size row col in
  let points=ref 0 in
  for row=0 to size-1 do for col=0 to size-1 do
    let dark=cell row col in
    let same=ref 0 in
    for dr=(-1) to 1 do for dc=(-1) to 1 do
      if (dr<>0 || dc<>0) && row+dr>=0 && row+dr<size &&
         col+dc>=0 && col+dc<size && cell (row+dr) (col+dc)=dark
      then incr same
    done done;
    if !same>5 then points := !points+3+ !same-5
  done done;
  for row=0 to size-2 do for col=0 to size-2 do
    let dark=cell row col in
    if cell (row+1) col=dark && cell row (col+1)=dark &&
       cell (row+1) (col+1)=dark then points := !points+3
  done done;
  for start=0 to size-7 do for line=0 to size-1 do
    let finder get = get 0 && not (get 1) && get 2 && get 3 &&
      get 4 && not (get 5) && get 6 in
    if finder (fun k -> cell line (start+k)) then points := !points+40;
    if finder (fun k -> cell (start+k) line) then points := !points+40
  done done;
  let dark=ref 0 in Bytes.iter (fun c -> if c='1' then incr dark) matrix;
  let ratio=float !dark /. float (size*size) in
  float !points +. (abs_float (100. *. ratio -. 50.) /. 5.) *. 10.

let qr_reformat matrix size ~pattern ~test =
  let bits=qr_format_info pattern in
  for i=0 to 14 do
    let dark=not test && bits land (1 lsl i) <> 0 in
    qr_set matrix size (qr_format_row size i) 8 dark;
    qr_set matrix size 8 (qr_format_col size i) dark
  done;
  qr_set matrix size (size-8) 8 (not test);
  if test && size>=45 then for i=0 to 17 do
    qr_set matrix size (i/3) (i mod 3+size-11) false;
    qr_set matrix size (i mod 3+size-11) (i/3) false
  done

let qr_compatible_matrix ((size,raw) as source) =
  match qr_current_mask size (Bytes.of_string raw) with
  | None -> source
  | Some old_mask ->
      let reserved=qr_reserved size in
      let candidate pattern ~test =
        let matrix=Bytes.of_string raw in
        for row=0 to size-1 do for col=0 to size-1 do
          if not reserved.(row*size+col) &&
             qr_mask old_mask row col <> qr_mask pattern row col then
            qr_set matrix size row col (not (qr_bit matrix size row col))
        done done;
        qr_reformat matrix size ~pattern ~test;
        matrix in
      let best=ref 0 and best_score=ref max_float in
      for pattern=0 to 7 do
        let score=qr_lost_points size (candidate pattern ~test:true) in
        if score < !best_score then (best:=pattern;best_score:=score)
      done;
      size,Bytes.to_string (candidate !best ~test:false)

let qr_svg (width, matrix) =
  let dimension = width * 11 in
  let out = Buffer.create (width * width * 35) in
  Buffer.add_string out "<?xml version=\"1.0\" standalone=\"yes\"?>";
  Buffer.add_string out (Printf.sprintf
    "<svg version=\"1.1\" xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" xmlns:ev=\"http://www.w3.org/2001/xml-events\" viewBox=\"0 0 %d %d\" shape-rendering=\"crispEdges\">"
    dimension dimension);
  Buffer.add_string out (Printf.sprintf
    "<rect width=\"%d\" height=\"%d\" x=\"0\" y=\"0\" fill=\"white\"/>"
    dimension dimension);
  for row=0 to width-1 do
    for col=0 to width-1 do
      if matrix.[row*width+col] = '1' then
        Buffer.add_string out (Printf.sprintf
          "<rect width=\"11\" height=\"11\" x=\"%d\" y=\"%d\" fill=\"black\"/>"
          (col*11) (row*11))
    done
  done;
  Buffer.add_string out "</svg>"; Buffer.contents out

let qr_show c =
  match Option.bind (H.param_string c "id") Rails_format.urlsafe_decode with
  | None -> response (H.error ~status:500)
  | Some data ->
      (match qr_matrix data with
       | None -> response (head 422)
       | Some matrix ->
           let headers = ["cache-control","max-age=31556952, public"] in
           response (H.respond ~headers ~status:200
             ~content_type:"image/svg+xml; charset=utf-8"
             (qr_svg (qr_compatible_matrix matrix))))

let health c =
  if available c [Http_format.Html] then
    response (H.html ~status:200
      H.health_html)
  else if available c [Http_format.Json] then
    let time = Authentication.now_time c.H.now in
    let timestamp = Authentication.utc_rfc3339 ~frac_s:0 time in
    response (H.json ~status:200 (`Assoc ["status",`String "up";
      "timestamp",`String timestamp]))
  else response (H.error ~status:406)

let turbo body _ = response (H.html ~status:200 body)
let ingress _ = response (head 404)
let conductor_before c = Lwt.return (H.csrf_check c)
let conductor _ = response (head 403)

(* M5 registers its bounded, SSRF-guarded OpenGraph implementation here.
   A missing integration returns no content for syntactically present URLs. *)
let unfurl_adapter : (string -> string option Lwt.t) option ref = ref None
let register_unfurl f = unfurl_adapter := Some f
let missing_unfurl_url () =
  H.respond ~status:400 ~content_type:"text/html; charset=UTF-8"
    ~headers:["x-campfire-public-exception","1";"content-length","0"] ""
let unfurl c =
  match H.param c "url" with
  | None | Some Http_params.Nil | Some (Http_params.Text "") ->
      response (missing_unfurl_url ())
  | Some (Http_params.Text url) ->
      (match !unfurl_adapter with
       | None -> response (head 204)
       | Some f -> f url >|= function
           | None -> head 204
           | Some json -> H.respond ~status:200
               ~content_type:"application/json; charset=utf-8" json)
  | Some _ -> response (head 204)

(* Active Storage has separate authentication and forgery policies. The disk
   PUT only looks up a session; direct-upload POST verifies CSRF first. *)
let storage_before ~write ~csrf c =
  match (if csrf then H.csrf_check c else Ok ()) with
  | Error _ as rejection -> Lwt.return rejection
  | Ok () when not write -> Lwt.return (Ok ())
  | Ok () ->
      (* Active Storage's own authentication concern only looks up the signed
         database session. It does not resume it or run the app's banned-IP
         before action. In particular, invalid disk tokens stay 404 and
         missing direct-upload parameters stay 400 for a banned address. *)
      let headers = Cohttp.Header.get_multi (Cohttp.Request.headers c.H.request) "cookie" in
      let token = Option.bind (Authentication.cookie headers "session_token")
        (fun raw -> Signed_cookie.verify ~secret_key_base:c.H.secret_key_base
          ~name:"session_token" ~raw ~now:c.H.now) in
      (match token with
       | None -> Lwt.return_false
       | Some token -> Db_runtime.read_async c.H.runtime (fun db ->
           Option.is_some (Db_accounts.Session.find_by_token db token)))
      >|= fun found -> if found then Ok () else Error (head 401)

let storage_adapter : (string -> H.handler option) ref = ref (fun _ -> None)
let register_storage f = storage_adapter := f
let storage_action name c = match (!storage_adapter) name with
  | Some action -> action c
  | None -> response (head 501)
let storage_endpoint name =
  let owned = String.starts_with ~prefix:"active_storage/" name in
  if not owned then None else
  let write = name="active_storage/disk#update" ||
    name="active_storage/direct_uploads#create" in
  let csrf = name<>"active_storage/disk#update" in
  Some { H.action=storage_action name; before_action=storage_before ~write ~csrf }

let endpoint name : H.endpoint option =
  match name with
  | "pwa#manifest" -> public ~csrf:false manifest
  | "pwa#service_worker" -> public ~csrf:false service_worker
  | "qr_code#show" -> public qr_show
  | "unfurl_links#create" -> user unfurl
  | "rails/health#show" -> standalone health
  | "turbo/native/navigation#recede" -> standalone (turbo "Going back…")
  | "turbo/native/navigation#resume" -> standalone (turbo "Staying put…")
  | "turbo/native/navigation#refresh" -> standalone (turbo "Refreshing…")
  | name when String.starts_with ~prefix:"action_mailbox/ingresses/" name ->
      standalone ingress
  | name when String.starts_with ~prefix:"rails/conductor/action_mailbox/" name ->
      Some {H.action=conductor;before_action=conductor_before}
  | name -> storage_endpoint name

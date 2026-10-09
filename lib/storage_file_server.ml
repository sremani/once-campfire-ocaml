(** Rack::Files-style disk serving. Each file part is read in bounded chunks. *)

type part = Text of string | File of string * int64 * int64
type served = { status:int; headers:(string * string) list; body:part list }
open Lwt.Infix

let boundary = "AaB03x"

let httpdate seconds =
  let time = Unix.gmtime seconds in
  let days = [|"Sun";"Mon";"Tue";"Wed";"Thu";"Fri";"Sat"|]
  and months = [|"Jan";"Feb";"Mar";"Apr";"May";"Jun";
                "Jul";"Aug";"Sep";"Oct";"Nov";"Dec"|] in
  Printf.sprintf "%s, %02d %s %04d %02d:%02d:%02d GMT"
    days.(time.Unix.tm_wday) time.tm_mday months.(time.tm_mon)
    (time.tm_year+1900) time.tm_hour time.tm_min time.tm_sec

let parse_range size raw =
  if not (String.starts_with ~prefix:"bytes=" raw) then None else
  let rest=String.sub raw 6 (String.length raw-6) in
  let pieces=String.split_on_char ',' rest in
  let parse piece =
    let piece=String.trim piece in
    match String.index_opt piece '-' with
    | None -> None
    | Some dash ->
        let first=String.sub piece 0 dash in
        let last=String.sub piece (dash+1) (String.length piece-dash-1) in
        if first="" then
          (match Int64.of_string_opt last with
           | Some n when n>0L && size>0L ->
               Some (max 0L (Int64.sub size n), Int64.pred size)
           | _ -> None)
        else match Int64.of_string_opt first with
          | None -> None
          | Some start when start<0L || start>=size -> None
          | Some start ->
              if last="" then Some (start,Int64.pred size)
              else match Int64.of_string_opt last with
                | Some finish when finish>=start ->
                    Some (start,min finish (Int64.pred size))
                | _ -> None in
  let ranges=List.filter_map parse pieces in
  Some ranges

let body_length = List.fold_left (fun total -> function
  | Text s -> Int64.add total (Int64.of_int (String.length s))
  | File (_,start,finish) -> Int64.add total (Int64.succ (Int64.sub finish start))) 0L

let serve ~method_ ?range ?if_modified_since ~path ~content_type ~disposition () =
  if method_="OPTIONS" then
    { status=200;headers=["allow","GET, HEAD, OPTIONS";
       "content-length","0";"content-type",content_type;
       "content-disposition",disposition];body=[] }
  else
  let stat=Unix.stat path in
  let size=Int64.of_int stat.Unix.st_size in
  let modified=httpdate stat.Unix.st_mtime in
  if if_modified_since=Some modified then
    {status=304;headers=["content-type",content_type;
      "content-disposition",disposition];body=[]}
  else
  let status,headers,parts = match Option.bind range (parse_range size) with
    | Some [] -> 416,["content-range", "bytes */" ^ Int64.to_string size],
        [Text "Byte range unsatisfiable\n"]
    | Some [(start,finish)] ->
        206,["content-range",Printf.sprintf "bytes %Ld-%Ld/%Ld" start finish size],
        [File (path,start,finish)]
    | Some ranges ->
        let parts=List.concat_map (fun (start,finish) -> [
          Text (Printf.sprintf
            "\r\n--%s\r\ncontent-type: text/plain\r\ncontent-range: bytes %Ld-%Ld/%Ld\r\n\r\n"
            boundary start finish size);
          File (path,start,finish)]) ranges @
          [Text ("\r\n--" ^ boundary ^ "--\r\n")] in
        206,["content-type","multipart/byteranges; boundary=" ^ boundary],parts
    | None -> 200,[],if size=0L then [] else [File (path,0L,Int64.pred size)] in
  let length=body_length parts in
  let content_type=match List.assoc_opt "content-type" headers with
    | Some value when status<>416 -> value
    | _ -> content_type in
  let headers=List.remove_assoc "content-type" headers in
  let modified_header=if status=416 then [] else ["last-modified",modified] in
  {status;headers=modified_header @ [
    "content-type",content_type;
    "content-disposition",disposition;
    "content-length",Int64.to_string length] @ headers;
   body=(if method_="HEAD" then [] else parts)}

let stream parts =
  let pending=ref parts in
  let active : (in_channel * int64) option ref = ref None in
  let close () = match !active with
    | None -> () | Some (channel,_) -> close_in_noerr channel; active:=None in
  Gc.finalise (fun _ -> close ()) pending;
  let rec next () =
    match !active with
    | Some (channel,remaining) when remaining>0L ->
        let count=min 65536 (Int64.to_int remaining) in
        Lwt_preemptive.detach (fun () ->
          let bytes=Bytes.create count in
          let got=input channel bytes 0 count in
          Bytes.sub_string bytes 0 got) () >>= fun chunk ->
        if chunk="" then (close (); Lwt.return_none)
        else (active:=Some (channel,Int64.sub remaining
          (Int64.of_int (String.length chunk))); Lwt.return_some chunk)
    | Some _ -> close (); next ()
    | None -> match !pending with
      | [] -> Lwt.return_none
      | Text s :: rest -> pending:=rest; Lwt.return_some s
      | File (path,start,finish)::rest ->
          pending:=rest;
          let channel=open_in_bin path in
          seek_in channel (Int64.to_int start);
          active:=Some (channel,Int64.succ (Int64.sub finish start));
          next () in
  Cohttp_lwt.Body.of_stream (Lwt_stream.from next)

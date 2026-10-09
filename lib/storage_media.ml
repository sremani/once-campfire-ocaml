(** Active Storage audio/video analyzers and video previewer. The external
    codecs are ffprobe and ffmpeg, as in the pinned Rails and Rust versions. *)

module Blob = Db_remaining.Blob
module Attachment = Db_remaining.Attachment
module V = Storage_variation

exception Process_error of string
exception Process_timeout of string

let ffprobe_timeout = 30.
let ffmpeg_timeout = 60.
let video_preview_arguments =
  ["-vf"; "select=eq(n\\,0)+eq(key\\,1)+gt(scene\\,0.015),loop=loop=-1:size=2,trim=start_frame=1";
   "-frames:v"; "1"; "-f"; "image2"]

let rec retry_eintr f =
  try f () with Unix.Unix_error (Unix.EINTR,_,_) -> retry_eintr f

let rec select_until ?(select=Unix.select) read_fds deadline =
  let remaining=deadline -. Unix.gettimeofday () in
  if remaining<=0. then ([],[],[])
  else try select read_fds [] [] remaining with
    Unix.Unix_error (Unix.EINTR,_,_) ->
      select_until ~select read_fds deadline

let run ?(stdout_limit=64 * 1024 * 1024) ?(stderr_limit=1024 * 1024)
    ~timeout program args =
  let out_r,out_w=Unix.pipe () and err_r,err_w=Unix.pipe () in
  let null=Unix.openfile "/dev/null" [Unix.O_RDONLY] 0 in
  let close fd = try Unix.close fd with _ -> () in
  let pid = try
      let pid=Unix.create_process program
        (Array.of_list (program::args)) null out_w err_w in
      close null;close out_w;close err_w;pid
    with exn ->
      List.iter close [null;out_r;out_w;err_r;err_w];raise exn in
  let waited=ref false in
  let reap () = if not !waited then begin
    ignore (retry_eintr (fun () -> Unix.waitpid [] pid));waited:=true end in
  let stop () =
    (try Unix.kill pid Sys.sigkill with _ -> ());
    (try reap () with _ -> ()) in
  Fun.protect ~finally:(fun () ->
    List.iter close [out_r;err_r];if not !waited then stop ()) (fun () ->
    Unix.set_nonblock out_r;Unix.set_nonblock err_r;
    let out=Buffer.create 4096 and err=Buffer.create 512 in
    let streams=ref [out_r,out,stdout_limit;err_r,err,stderr_limit] in
    let started=Unix.gettimeofday () in
    while !streams<>[] do
      let remain=timeout -. (Unix.gettimeofday () -. started) in
      if remain <= 0. then raise (Process_timeout program);
      let ready,_,_=select_until
        (List.map (fun (fd,_,_) -> fd) !streams)
        (Unix.gettimeofday () +. min 0.05 remain) in
      List.iter (fun fd ->
        match List.find_opt (fun (candidate,_,_) -> candidate=fd) !streams with
        | None -> ()
        | Some (_,buffer,limit) ->
            let chunk=Bytes.create 65536 in
            (try
               let n=retry_eintr (fun () ->
                 Unix.read fd chunk 0 (Bytes.length chunk)) in
               if n=0 then (close fd;streams:=List.filter
                 (fun (candidate,_,_) -> candidate<>fd) !streams)
               else if Buffer.length buffer+n>limit then
                 raise (Process_error (program ^ " output limit exceeded"))
               else Buffer.add_subbytes buffer chunk 0 n
             with Unix.Unix_error ((Unix.EAGAIN|Unix.EWOULDBLOCK),_,_) -> ())) ready
    done;
    let rec await_exit () =
      let observed,status=retry_eintr (fun () ->
        Unix.waitpid [Unix.WNOHANG] pid) in
      if observed<>0 then (waited:=true;status)
      else if Unix.gettimeofday () -. started >= timeout then
        raise (Process_timeout program)
      else (ignore (select_until [] (Unix.gettimeofday () +. 0.005));
        await_exit ()) in
    let status=await_exit () in
    (match status with Unix.WEXITED 0 -> ()
      | Unix.WEXITED n -> raise (Process_error
          (Printf.sprintf "%s failed (status %d): %s" program n
            (String.trim (Buffer.contents err))))
      | Unix.WSIGNALED n | Unix.WSTOPPED n -> raise (Process_error
          (Printf.sprintf "%s ended with signal %d" program n)));
    Buffer.contents out)

let probe ?(program="ffprobe") ?(timeout=ffprobe_timeout) path =
  try
    let output=run ~stdout_limit:(8 * 1024 * 1024) ~timeout program
      ["-print_format";"json";"-show_streams";"-show_format";"-v";"error";path] in
    Yojson.Basic.from_string output
  with Unix.Unix_error (Unix.ENOENT,_,_) -> `Assoc []

let field name = function `Assoc entries -> List.assoc_opt name entries | _ -> None
let nonnull name json = match field name json with Some `Null | None -> None | value -> value
let stream kind probe = match field "streams" probe with
  | Some (`List streams) -> List.find_opt (fun item ->
      field "codec_type" item=Some (`String kind)) streams
  | _ -> None
let present = function Some (`Assoc (_::_)) -> true | _ -> false
let float = function
  | `Int n -> float_of_int n | `Float n -> n
  | `String s -> (try float_of_string (String.trim s)
      with _ -> invalid_arg ("invalid Float: " ^ s))
  | _ -> invalid_arg "invalid Float"
let integer = function
  | `Int n -> n | `Float n -> int_of_float n
  | `String s -> (try int_of_string (String.trim s)
      with _ -> invalid_arg ("invalid Integer: " ^ s))
  | _ -> invalid_arg "invalid Integer"

let video_metadata probe =
  let video=stream "video" probe and audio=stream "audio" probe in
  let get name=Option.bind video (nonnull name) in
  let tags=Option.bind video (field "tags") in
  let angle=match Option.bind tags (nonnull "rotate") with
    | Some value -> Some (integer value)
    | None -> (match get "side_data_list" with
      | Some (`List items) ->
          let matrix=List.find_opt (fun item ->
            field "side_data_type" item=Some (`String "Display Matrix")) items in
          Option.bind matrix (nonnull "rotation") |> Option.map integer
      | _ -> None) in
  let ratio=match get "display_aspect_ratio" with
    | None -> None
    | Some (`String s) -> (match String.split_on_char ':' s with
        | [n;d] -> let n=integer (`String n) and d=integer (`String d) in
            if n=0 then None else Some (n,d)
        | _ -> invalid_arg "display_aspect_ratio")
    | _ -> invalid_arg "display_aspect_ratio" in
  let width=Option.map float (get "width")
  and encoded_height=Option.map float (get "height") in
  let computed_height=match width,ratio with
    | Some width,Some (n,d) -> Some (width *. float_of_int d /. float_of_int n)
    | _ -> None in
  let height=Option.value computed_height ~default:(Option.value encoded_height ~default:nan) in
  let height=if Float.is_nan height then None else Some height in
  let rotated=List.mem angle [Some 90;Some 270;Some (-90);Some (-270)] in
  let width,height=if rotated then height,width else width,height in
  let duration=match get "duration" with
    | Some value -> Some (float value)
    | None -> Option.bind (field "format" probe) (nonnull "duration")
        |> Option.map float in
  let optional key encode = function None -> [] | Some value -> [key,encode value] in
  `Assoc (optional "width" (fun n -> `Float n) width @
    optional "height" (fun n -> `Float n) height @
    optional "duration" (fun n -> `Float n) duration @
    optional "angle" (fun n -> `Int n) angle @
    optional "display_aspect_ratio" (fun (n,d) -> `List [`Int n;`Int d]) ratio @
    ["audio",`Bool (present audio);"video",`Bool (present video)])

let audio_metadata probe =
  let audio=stream "audio" probe in
  let get name=Option.bind audio (nonnull name) in
  let add key convert = function None -> [] | Some value -> [key,convert value] in
  `Assoc (add "duration" (fun v -> `Float (float v)) (get "duration") @
    add "bit_rate" (fun v -> `Int (integer v)) (get "bit_rate") @
    add "sample_rate" (fun v -> `Int (integer v)) (get "sample_rate") @
    add "tags" Fun.id (get "tags"))

let metadata_for_path ?program ?timeout ~content_type path =
  if String.starts_with ~prefix:"video" content_type then
    video_metadata (probe ?program ?timeout path)
  else if String.starts_with ~prefix:"audio" content_type then
    audio_metadata (probe ?program ?timeout path)
  else `Assoc []

let analyze ?program ?timeout runtime service blob =
  let content_type=Option.value blob.Blob.content_type ~default:"" in
  if String.starts_with ~prefix:"image" content_type then
    Storage_image.analyze runtime service blob else
  let extracted=if String.starts_with ~prefix:"video" content_type ||
    String.starts_with ~prefix:"audio" content_type then
      Storage_blob.open_verified service blob
        (metadata_for_path ?program ?timeout ~content_type)
    else `Assoc [] in
  let existing=Storage_image.metadata_json blob in
  let merged=match extracted with
    | `Assoc entries -> List.fold_left (fun values (key,value) ->
        Storage_image.put values key value) existing entries
    | _ -> existing in
  let metadata=Rails_format.encode (Yojson.Safe.from_string
    (Yojson.Basic.to_string (`Assoc (Storage_image.put merged "analyzed" (`Bool true))))) in
  Db_runtime.write runtime (fun tx ->
    ignore (Db_runtime.execute (Db_runtime.conn tx)
      "UPDATE active_storage_blobs SET metadata=? WHERE id=?"
      [Sqlite3.Data.TEXT metadata;Sqlite3.Data.INT blob.id]);
    {blob with metadata=Some metadata})

let video_preview ?(program="ffmpeg") ?(timeout=ffmpeg_timeout) path =
  run ~timeout program (["-i";path] @ video_preview_arguments @ ["-"])

let existing_preview runtime blob =
  Db_runtime.read runtime (fun db ->
    match Attachment.find_for db ~record_type:"ActiveStorage::Blob"
        ~record_id:blob.Blob.id ~name:"preview_image" with
    | None -> None | Some attachment -> Some (Attachment.blob db attachment))

let preview_image ?program ?timeout runtime service blob ~now =
  let content_type=Option.value blob.Blob.content_type ~default:"" in
  if not (String.starts_with ~prefix:"video" content_type)
  then invalid_arg ("unpreviewable blob: " ^ content_type);
  match existing_preview runtime blob with
  | Some image -> image
  | None ->
      let output=Filename.temp_file "ActiveStorage-" ".jpg" in
      Fun.protect ~finally:(fun () -> if Sys.file_exists output then Sys.remove output)
        (fun () ->
          let frame=Storage_blob.open_verified service blob
            (video_preview ?program ?timeout) in
          let oc=open_out_bin output in
          Fun.protect ~finally:(fun () -> close_out_noerr oc)
            (fun () -> output_string oc frame);
          let filename=Storage_marcel.base_without_extension blob.filename ^ ".jpg" in
          Storage_blob.stage_file service ~source:output ~filename
            ~content_type:(Some "image/jpeg") (fun prepared staged ->
              let dimensions=Storage_vips.analyze output in
              let prepared={prepared with Storage_blob.metadata=
                Storage_image.analyzed_metadata
                  (match Yojson.Basic.from_string prepared.metadata with
                   | `Assoc entries -> entries | _ -> []) dimensions} in
              let image,created=Db_runtime.write runtime (fun tx ->
                let db=Db_runtime.conn tx in
                match Attachment.find_for db ~record_type:"ActiveStorage::Blob"
                    ~record_id:blob.id ~name:"preview_image" with
                | Some attachment -> Attachment.blob db attachment,false
                | None ->
                    let image=Storage_blob.insert tx ~now prepared in
                    ignore (Attachment.create tx ~now
                      ~record_type:"ActiveStorage::Blob" ~record_id:blob.id
                      ~name:"preview_image" ~blob_id:image.id);
                    image,true) in
              if created then Storage_disk.keep staged;
              image))

let process_preview runtime service blob variation ~now =
  let image=preview_image runtime service blob ~now in
  if variation=[] then image
  else Storage_image.process_variant runtime service image variation ~now

let process_representation runtime service blob variation ~now =
  let content_type=Option.value blob.Blob.content_type ~default:"" in
  if String.starts_with ~prefix:"video" content_type then
    Some (process_preview runtime service blob variation ~now)
  else if Storage_image.is_variable blob then
    Some (Storage_image.process_variant runtime service blob variation ~now)
  else None

(** Opt-in aggregate timings for disposable performance runs. The normal
    request path calls through without reading a clock or updating counters. *)

let enabled = Sys.getenv_opt "CAMPFIRE_PROFILE" = Some "1"

type sample = { mutable count:int; mutable total:float; mutable maximum:float }
let mutex = Mutex.create ()
let samples : (string, sample) Hashtbl.t = Hashtbl.create 32
let events = ref 0

let dump () = match Sys.getenv_opt "CAMPFIRE_PROFILE_PATH" with
  | None -> ()
  | Some path ->
      Mutex.lock mutex;
      let rows = Hashtbl.to_seq samples |> List.of_seq
        |> List.map (fun (name,sample) ->
          name,sample.count,sample.total,sample.maximum) in
      Mutex.unlock mutex;
      let buffer = Buffer.create 2048 in
      Buffer.add_string buffer
        (Printf.sprintf "snapshot\t%.3f\t%d\n"
          (Unix.gettimeofday ()) !events);
      List.iter (fun (name,count,total,maximum) ->
        Buffer.add_string buffer
          (Printf.sprintf "stage\t%s\t%d\t%.3f\t%.3f\n"
            name count (total *. 1000.) (maximum *. 1000.))) rows;
      let data = Buffer.contents buffer in
      let fd = Unix.openfile path [Unix.O_WRONLY;Unix.O_CREAT;Unix.O_APPEND] 0o600 in
      Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
        let rec write offset =
          if offset < String.length data then
            let written = Unix.write_substring fd data offset
              (String.length data - offset) in
            write (offset + written) in
        write 0)

let record name elapsed =
  Mutex.lock mutex;
  let sample = match Hashtbl.find_opt samples name with
    | Some sample -> sample
    | None ->
        let sample = {count=0;total=0.;maximum=0.} in
        Hashtbl.add samples name sample;
        sample in
  sample.count <- sample.count + 1;
  sample.total <- sample.total +. elapsed;
  sample.maximum <- max sample.maximum elapsed;
  incr events;
  let flush = !events mod 10000 = 0 in
  Mutex.unlock mutex;
  if flush then (try dump () with _ -> ())

let bump name = if enabled then record name 0.

let time name f =
  if not enabled then f () else
  let started = Unix.gettimeofday () in
  Fun.protect ~finally:(fun () ->
    record name (Unix.gettimeofday () -. started)) f

let time_lwt name f =
  if not enabled then f () else
  let started = Unix.gettimeofday () in
  Lwt.finalize f (fun () ->
    record name (Unix.gettimeofday () -. started);
    Lwt.return_unit)

let () = if enabled then at_exit (fun () -> try dump () with _ -> ())

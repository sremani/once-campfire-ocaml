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
      let gc = Gc.quick_stat () and cpu = Unix.times () in
      Buffer.add_string buffer
        (Printf.sprintf "runtime\t%.3f\t%.3f\t%.0f\t%.0f\t%.0f\t%d\t%d\t%d\n"
          cpu.Unix.tms_utime cpu.Unix.tms_stime
          gc.Gc.minor_words gc.Gc.major_words gc.Gc.promoted_words
          gc.Gc.minor_collections gc.Gc.major_collections gc.Gc.heap_words);
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

(* Allocation sampling is diagnostic and stays off in release runs. Keep raw
   stacks in the callback; symbolization and grouping happen after sampling
   stops, so the request path does not format backtraces. *)
let memprof_path = Sys.getenv_opt "CAMPFIRE_MEMPROF_PATH"
let memprof_mutex = Mutex.create ()
let memprof_samples : (Printexc.raw_backtrace * int) list ref = ref []
let memprof_record allocation =
  Mutex.lock memprof_mutex;
  memprof_samples := (allocation.Gc.Memprof.callstack,
    allocation.Gc.Memprof.n_samples) :: !memprof_samples;
  Mutex.unlock memprof_mutex;
  None

let dump_memprof path =
  Mutex.lock memprof_mutex;
  let samples = !memprof_samples in
  Mutex.unlock memprof_mutex;
  let groups = Hashtbl.create 1024 in
  List.iter (fun (stack, count) ->
    let trace = Printexc.raw_backtrace_to_string stack in
    let name = match String.index_opt trace '\n' with
      | None -> trace
      | Some at -> String.sub trace 0 at in
    Hashtbl.replace groups name
      (count + Option.value (Hashtbl.find_opt groups name) ~default:0))
    samples;
  let rows = Hashtbl.to_seq groups |> List.of_seq
    |> List.sort (fun (_,a) (_,b) -> Int.compare b a) in
  let temporary = path ^ ".tmp" in
  let output = open_out temporary in
  Fun.protect ~finally:(fun () -> close_out output) (fun () ->
    Printf.fprintf output "samples=%d stacks=%d\n"
      (List.length samples) (List.length rows);
    List.iteri (fun index (stack,count) ->
      if index < 120 then Printf.fprintf output
        "%d\t%d\t%s\n" (index+1) count stack) rows);
  Sys.rename temporary path

let () = match memprof_path with
  | None -> ()
  | Some path ->
      Printexc.record_backtrace true;
      ignore (Gc.Memprof.start ~sampling_rate:0.00001 ~callstack_size:24
        {Gc.Memprof.null_tracker with
          alloc_minor=memprof_record;alloc_major=memprof_record});
      ignore (Thread.create (fun () ->
        while true do
          Unix.sleepf 2.;
          (try dump_memprof path with _ -> ())
        done) ());
      at_exit (fun () ->
        Gc.Memprof.stop ();
        try dump_memprof path with _ -> ())

let () = if enabled then at_exit (fun () -> try dump () with _ -> ())

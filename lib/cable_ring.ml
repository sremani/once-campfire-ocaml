(** A bounded in-process Action Cable hub. Each broadcasting has one shared
    256-entry ring and each subscriber has its own read cursor. *)

type entry = { sequence : int; order : int; payload : string }
type stream = {
  name : string;
  frames : entry option array;
  mutable next : int;
  mutable readers : int;
}
type subscriber = { stream : stream; identifier : string;
  mutable next : int; mutable active : bool }
type t = {
  mutex : Mutex.t;
  streams : (string, stream) Hashtbl.t;
  mutable order : int;
}

type delivery = [ `Frames of (string * string) list
                | `Lagged of (string * string) list ]

let capacity = 256
let max_write_batch = 64

let create () = {mutex=Mutex.create ();streams=Hashtbl.create 32;order=0}
let with_lock t f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

let subscribe t ~stream:name ~identifier = with_lock t (fun () ->
  let stream = match Hashtbl.find_opt t.streams name with
    | Some stream -> stream
    | None ->
        let stream = {name;frames=Array.make capacity None;next=0;readers=0} in
        Hashtbl.add t.streams name stream;
        stream in
  stream.readers <- stream.readers + 1;
  {stream;identifier;next=stream.next;active=true})

let unsubscribe t sub = with_lock t (fun () ->
  if sub.active then begin
    sub.active <- false;
    sub.stream.readers <- sub.stream.readers - 1;
    if sub.stream.readers = 0 then Hashtbl.remove t.streams sub.stream.name
  end)

let broadcast t ~stream:name ~payload = with_lock t (fun () ->
  match Hashtbl.find_opt t.streams name with
  | None -> 0
  | Some stream ->
      let sequence = stream.next in
      stream.frames.(sequence mod capacity) <- Some {sequence;order=t.order;payload};
      stream.next <- sequence + 1;
      t.order <- t.order + 1;
      stream.readers)

let stream_count t = with_lock t (fun () -> Hashtbl.length t.streams)

let take_many t subscribers ~limit =
  if limit < 0 || limit > max_write_batch then invalid_arg "Cable_ring.take_many limit";
  with_lock t (fun () ->
    let rec collect n acc =
      if n = limit then `Frames (List.rev acc) else
      let lagged = List.exists (fun sub ->
        sub.active && sub.stream.next - sub.next > capacity) subscribers in
      if lagged then `Lagged (List.rev acc) else
      let ready = List.filter_map (fun sub ->
        if not sub.active || sub.next >= sub.stream.next then None
        else match sub.stream.frames.(sub.next mod capacity) with
          | Some entry when entry.sequence = sub.next -> Some (sub,entry)
          | _ -> None) subscribers in
      match List.sort (fun (_,(a:entry)) (_,(b:entry)) -> Int.compare a.order b.order) ready with
      | [] -> `Frames (List.rev acc)
      | (sub,entry)::_ ->
          sub.next <- sub.next + 1;
          collect (n+1) ((sub.identifier,entry.payload)::acc) in
    collect 0 [])

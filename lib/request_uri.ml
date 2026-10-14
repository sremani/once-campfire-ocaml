(** Cohttp.Request.uri reconstructs and parses the URI on every call. Keep the
    parsed result while a request is active; entries are bounded and released
    as newer requests arrive. Physical identity avoids conflating requests
    with the same target but different Host or scheme headers. *)

type entry = Cohttp.Request.t * Uri.t
type cache = { entries: entry option array; mutable next: int }

let capacity = 64
let enabled = Sys.getenv_opt "CAMPFIRE_URI_CACHE" <> Some "0"
let local = Domain.DLS.new_key (fun () ->
  {entries=Array.make capacity None;next=0})

let get request =
  if not enabled then Cohttp.Request.uri request else
  let cache = Domain.DLS.get local in
  let rec lookup offset =
    if offset = capacity then None else
    let index = (cache.next - 1 - offset + capacity) mod capacity in
    match cache.entries.(index) with
    | Some (key, uri) when key == request -> Some uri
    | _ -> lookup (offset + 1) in
  match lookup 0 with
  | Some uri -> uri
  | None ->
      let uri = Cohttp.Request.uri request in
      cache.entries.(cache.next) <- Some (request, uri);
      cache.next <- (cache.next + 1) mod capacity;
      uri

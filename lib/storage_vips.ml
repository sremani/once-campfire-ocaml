(** The libvips operations selected by ruby-vips 2.2.5 and image_processing
    1.14.0 for Campfire. The C binding loads the shared library on first use. *)

external version : unit -> string = "caml_storage_vips_version"
external raw_analyze : string -> (int * int * string option) option =
  "caml_storage_vips_analyze"
external raw_transform : string -> string -> (int option * int option) list -> unit =
  "caml_storage_vips_transform"

let analyze path =
  match raw_analyze path with
  | None -> None
  | Some (width,height,orientation) ->
      let rotated=match orientation with
        | None -> false
        | Some value -> List.exists (fun direction ->
            let n=String.length direction in
            let rec search i =
              i+n<=String.length value &&
              (String.sub value i n=direction || search (i+1)) in
            search 0)
          ["Right-top";"Left-bottom";"Top-right";"Bottom-left"] in
      Some (if rotated then height,width else width,height)

let transform ~source ~target ~operations =
  let validate = function
    | None,None -> invalid_arg "either width or height must be specified"
    | width,height ->
        List.iter (function
          | None -> ()
          | Some n when n>=Int32.to_int Int32.min_int &&
                        n<=Int32.to_int Int32.max_int -> ()
          | Some _ -> invalid_arg "resize_to_limit dimension out of range")
          [width;height] in
  List.iter validate operations;
  raw_transform source target operations

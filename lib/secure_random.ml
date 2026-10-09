let bytes length =
  if length < 0 then invalid_arg "Secure_random.bytes";
  let input = Unix.openfile "/dev/urandom" [Unix.O_RDONLY] 0 in
  Fun.protect ~finally:(fun () -> Unix.close input) (fun () ->
    let output=Bytes.create length in
    let rec fill offset =
      if offset<length then
        match Unix.read input output offset (length-offset) with
        | 0 -> failwith "/dev/urandom returned EOF"
        | count -> fill (offset+count) in
    fill 0;Bytes.to_string output)

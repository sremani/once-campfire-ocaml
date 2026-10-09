let bytes length =
  let input = open_in_bin "/dev/urandom" in
  Fun.protect ~finally:(fun () -> close_in input)
    (fun () -> really_input_string input length)

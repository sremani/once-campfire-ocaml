let ensure_directory path =
  let rec make path =
    if path <> "" && path <> "." && not (Sys.file_exists path) then (
      make (Filename.dirname path);
      Unix.mkdir path 0o700)
  in make path

let write_config path contents =
  ensure_directory (Filename.dirname path);
  let temp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
  let fd = Unix.openfile temp [Unix.O_WRONLY;Unix.O_CREAT;Unix.O_EXCL] 0o600 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
    let bytes = Bytes.of_string contents in
    let rec write offset =
      if offset < Bytes.length bytes then
        let n = Unix.write fd bytes offset (Bytes.length bytes - offset) in
        write (offset + n) in
    write 0;
    Unix.fsync fd);
  Unix.rename temp path

let read_file path =
  let input = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in input) (fun () ->
    really_input_string input (in_channel_length input))

let pem_blocks contents =
  let lines = String.split_on_char '\n' contents in
  let rec collect blocks current label = function
    | [] -> if label <> None then invalid_arg "incomplete legacy PEM"
        else List.rev blocks
    | line :: rest ->
        if String.starts_with ~prefix:"-----BEGIN " line then
          if label <> None then invalid_arg "nested legacy PEM" else
          let name = String.sub line 11 (String.length line - 16) in
          collect blocks [line] (Some name) rest
        else match label with
        | None -> collect blocks current None rest
        | Some name ->
            let current = line :: current in
            if line = "-----END " ^ name ^ "-----" then
              collect ((name,String.concat "\n" (List.rev current) ^ "\n") :: blocks)
                [] None rest
            else collect blocks current label rest in
  collect [] [] None lines

let capture command args =
  let input = Unix.open_process_args_in command (Array.of_list (command :: args)) in
  let output = Buffer.create 256 in
  (try while true do Buffer.add_channel output input 1024 done
   with End_of_file -> ());
  match Unix.close_process_in input with
  | Unix.WEXITED 0 -> Buffer.contents output
  | _ -> invalid_arg ("certificate validation failed: " ^ command)

let migrate_certificate config raw_domain =
  let domain = Campfire.Front_config.domain raw_domain in
  let legacy = Filename.concat config.Campfire.Front_config.storage_path domain in
  if not (Sys.file_exists legacy) then false else
  let issuer = Campfire.Front_config.acme_issuer_key config in
  let parent = Filename.concat config.storage_path
    ("caddy/certificates/" ^ issuer) in
  let destination = Filename.concat parent domain in
  if Sys.file_exists destination then false else (
    let blocks = pem_blocks (read_file legacy) in
    let private_key = List.find_opt (fun (label,_) ->
      label = "EC PRIVATE KEY" || label = "PRIVATE KEY" ||
      label = "RSA PRIVATE KEY") blocks in
    let certificates = List.filter (fun (label,_) -> label = "CERTIFICATE") blocks in
    let key = match private_key with Some (_,key) -> key
      | None -> invalid_arg ("legacy certificate has no private key: " ^ domain) in
    if certificates = [] then invalid_arg ("legacy certificate has no chain: " ^ domain);
    ensure_directory parent;
    let temporary = destination ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
    Unix.mkdir temporary 0o700;
    let key_path = Filename.concat temporary (domain ^ ".key") in
    let crt_path = Filename.concat temporary (domain ^ ".crt") in
    let json_path = Filename.concat temporary (domain ^ ".json") in
    Fun.protect
      ~finally:(fun () ->
        if Sys.file_exists temporary then (
          List.iter (fun path -> if Sys.file_exists path then Sys.remove path)
            [key_path;crt_path;json_path];
          Unix.rmdir temporary))
      (fun () ->
        write_config key_path key;
        write_config crt_path (String.concat "" (List.map snd certificates));
        ignore (capture "openssl" ["x509";"-in";crt_path;"-noout";
          "-checkhost";domain;"-checkend";"0"]);
        let key_pub = capture "openssl" ["pkey";"-in";key_path;"-pubout"] in
        let cert_pub = capture "openssl" ["x509";"-in";crt_path;"-pubkey";"-noout"] in
        if key_pub <> cert_pub then
          invalid_arg ("legacy certificate key mismatch: " ^ domain);
        write_config json_path
          (Printf.sprintf "{\"sans\":[\"%s\"]}\n" domain);
        Unix.rename temporary destination);
    true)

let migrate config =
  List.fold_left (fun count domain ->
    try if migrate_certificate config domain then count + 1 else count
    with Invalid_argument message ->
      prerr_endline ("Campfire front: " ^ message);
      count) 0 config.Campfire.Front_config.tls_domains

let () =
  let config = Campfire.Front_config.from_env () in
  let contents = Campfire.Front_config.caddyfile config in
  match Array.to_list Sys.argv with
  | [_; "config"] -> print_string contents
  | [_; "migrate"] -> Printf.printf "Imported %d legacy certificate(s)\n" (migrate config)
  | [_; "run"] ->
      ignore (migrate config);
      let path = Filename.concat config.storage_path "caddy/Caddyfile" in
      write_config path contents;
      let caddy = Option.value (Sys.getenv_opt "CAMPFIRE_CADDY_BIN") ~default:"caddy" in
      Unix.execvp caddy [|caddy;"run";"--config";path;"--adapter";"caddyfile"|]
  | _ ->
      prerr_endline "usage: campfire-front {config|migrate|run}";
      exit 2

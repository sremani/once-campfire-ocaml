let inspect database =
  match Campfire.Database.inspect database with
  | Error message -> prerr_endline message; `Error (false, message)
  | Ok inspection ->
      let open Yojson.Basic in
      let report = `Assoc [
        "database", `String database;
        "sqlite_version", `String inspection.sqlite_version;
        "account_count", `Int inspection.account_count;
        "missing_tables", `List (List.map (fun s -> `String s) inspection.missing_tables);
        "required_tables_present", `Bool (inspection.missing_tables = []);
      ] in
      print_endline (pretty_to_string report);
      if inspection.missing_tables = [] then `Ok ()
      else `Error (false, "Required Campfire tables are missing")

let database =
  let open Cmdliner in
  let doc = "Path to the existing Campfire SQLite database." in
  Arg.(required & opt (some string) None & info ["database"] ~docv:"PATH" ~doc)

let check_cmd =
  let open Cmdliner in
  let info = Cmd.info "check" ~doc:"Inspect an existing Campfire database without writing to it." in
  Cmd.v info Term.(ret (const inspect $ database))

let () =
  let open Cmdliner in
  let info = Cmd.info "campfire" ~doc:"OCaml port of ONCE Campfire (in progress)." in
  exit (Cmd.eval (Cmd.group info [check_cmd]))

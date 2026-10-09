(** Environment and storage paths matching the Rust port's [config.rs]. *)

type storage = {
  database : string;
  files : string;
  backups : string;
}

type t = {
  secret_key_base : string;
  environment : string;
  storage : storage;
  db_readers : int;
  job_concurrency : int;
  disable_ssl : bool;
  app_version : string;
  git_revision : string option;
}

let nonblank = function
  | Some value when String.trim value <> "" -> Some value
  | _ -> None

let dummy_secret () =
  let bytes = Secure_random.bytes 64 in
  let buffer = Buffer.create 128 in
  String.iter (fun c -> Buffer.add_string buffer (Printf.sprintf "%02x" (Char.code c))) bytes;
  Buffer.contents buffer

let storage_paths ?database ?files ?backups root environment =
  let default path = Filename.concat root path in
  {
    database = Option.value database ~default:(default (Filename.concat "db" (environment ^ ".sqlite3")));
    files = Option.value files ~default:(default "files");
    backups = Option.value backups ~default:(default "backups");
  }

let from_lookup get =
  let present name = nonblank (get name) in
  let number name default =
    match present name with
    | None -> Ok default
    | Some value ->
        (match int_of_string_opt (String.trim value) with
         | Some n when n >= 0 -> Ok (max 1 n)
         | _ -> Error (Printf.sprintf "%s=%S is not a nonnegative integer" name value))
  in
  let secret =
    match present "SECRET_KEY_BASE" with
    | Some value -> Ok value
    | None when present "SECRET_KEY_BASE_DUMMY" <> None -> Ok (dummy_secret ())
    | None -> Error "Missing SECRET_KEY_BASE (or SECRET_KEY_BASE_DUMMY for development)"
  in
  match secret, number "RAILS_MAX_THREADS" 5, number "JOB_CONCURRENCY" 2 with
  | Error message, _, _ | _, Error message, _ | _, _, Error message -> Error message
  | Ok secret_key_base, Ok db_readers, Ok job_concurrency ->
      let environment = Option.value (present "RAILS_ENV") ~default:"production" in
      let root = Option.value (present "CAMPFIRE_STORAGE_PATH") ~default:"storage" in
      let storage = storage_paths
          ?database:(present "CAMPFIRE_DATABASE_PATH")
          ?files:(present "CAMPFIRE_FILES_PATH")
          ?backups:(present "CAMPFIRE_BACKUPS_PATH") root environment
      in
      let git_revision = get "GIT_REVISION" in
      let app_version =
        match present "APP_VERSION", present "GIT_REVISION" with
        | Some version, _ -> version
        | None, Some revision -> revision
        | None, None -> "0"
      in
      Ok { secret_key_base; environment; storage; db_readers; job_concurrency;
           disable_ssl = present "DISABLE_SSL" <> None; app_version; git_revision }

let from_env () = from_lookup Sys.getenv_opt

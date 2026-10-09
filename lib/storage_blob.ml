(** Blob rows and staged files. The service never holds SQLite's writer while
    copying or checksumming bytes. *)

type new_blob = {
  key : string; filename : string; content_type : string option;
  metadata : string; service_name : string; byte_size : int64;
  checksum : string;
}

let signed_id ~secret_key_base id =
  Storage_disk.signed ~secret_key_base ~purpose:"blob_id"
    (`Int (Int64.to_int id))

let verify_signed_id ~secret_key_base ~now raw =
  match Storage_disk.verify ~secret_key_base ~purpose:"blob_id" ~now raw with
  | Some (`Int id) -> Some (Int64.of_int id)
  | _ -> None

let metadata_identified = "{\"identified\":true}"

let prepare service ~key ~source ~filename ~content_type =
  let stat = Unix.stat source in
  let checksum = Storage_disk.checksum_file source in
  let identified = Storage_marcel.identify_file source
    ~name:(Some (Storage_disk.sanitize_filename filename))
    ~declared:content_type in
  { key; filename; content_type = Some identified; metadata = metadata_identified;
    service_name = service.Storage_disk.name;
    byte_size = Int64.of_int stat.Unix.st_size; checksum }

let row blob : Db_remaining.Blob.t = {
  id = 0L; key = blob.key; filename = blob.filename;
  content_type = blob.content_type; metadata = Some blob.metadata;
  service_name = blob.service_name; byte_size = blob.byte_size;
  checksum = Some blob.checksum; created_at = "";
}

let insert tx ~now blob = Db_remaining.Blob.create tx ~now (row blob)

let stage_file service ~source ~filename ~content_type f =
  let key = Storage_disk.generate_key () in
  Storage_disk.with_staged service ~key ~source (fun staged ->
    let prepared = prepare service ~key
      ~source:(Storage_disk.path_for service key) ~filename ~content_type in
    f prepared staged)

let create_and_upload runtime service ~source ~filename ~content_type ~now =
  stage_file service ~source ~filename ~content_type (fun blob staged ->
    let saved = Db_runtime.write runtime (fun tx -> insert tx ~now blob) in
    Storage_disk.keep staged;
    saved)

let create_direct runtime service ~filename ~content_type ~metadata
    ~byte_size ~checksum ~now =
  let key = Storage_disk.generate_key () in
  let new_blob = { key; filename; content_type; metadata;
    service_name = service.Storage_disk.name; byte_size; checksum } in
  Db_runtime.write runtime (fun tx -> insert tx ~now new_blob)

let open_verified service blob f =
  let suffix=Storage_marcel.extension_with_delimiter
    blob.Db_remaining.Blob.filename in
  Storage_disk.open_verified service ~key:blob.Db_remaining.Blob.key
    ~checksum:blob.checksum
    ~prefix:("ActiveStorage-" ^ Int64.to_string blob.id ^ "-") ~suffix f

let rec purge runtime service blob =
  let dependents=Db_runtime.write runtime (fun tx ->
    let db=Db_runtime.conn tx in
    if Db_remaining.Blob.attachments db blob <> [] then None else begin
      let dependents=ref [] in
      let remove_attachment ~record_type ~record_id ~name =
        match Db_remaining.Attachment.find_for db ~record_type ~record_id ~name with
        | None -> ()
        | Some attachment ->
            dependents:=attachment.blob_id::!dependents;
            Db_remaining.Attachment.delete tx attachment in
      List.iter (fun record_id ->
        remove_attachment ~record_type:"ActiveStorage::VariantRecord"
          ~record_id ~name:"image";
        Db_remaining.Variant_record.delete tx
          (Db_remaining.Variant_record.find db record_id))
        (Db_remaining.Blob.variant_records db blob);
      remove_attachment ~record_type:"ActiveStorage::Blob"
        ~record_id:blob.id ~name:"preview_image";
      ignore (Db_runtime.execute db
        "DELETE FROM active_storage_blobs WHERE id=?"
        [Sqlite3.Data.INT blob.id]);
      Some !dependents
    end) in
  match dependents with
  | None -> ()
  | Some ids ->
      Storage_disk.delete service blob.key;
      if Option.value blob.content_type ~default:"" |> String.starts_with ~prefix:"image"
      then Storage_disk.delete_legacy_variants service blob.key;
      List.iter (fun id ->
        match Db_runtime.read runtime (fun db ->
          Db_runtime.query_one db
            (Db_remaining.Blob.select ^ " WHERE id=? LIMIT 1")
            [Sqlite3.Data.INT id] Db_remaining.Blob.decode) with
        | None -> () | Some dependent -> purge runtime service dependent) ids

let blob_path kind ~secret_key_base blob ?disposition () =
  let filename = Storage_disk.sanitize_filename blob.Db_remaining.Blob.filename in
  let path = "/rails/active_storage/blobs/" ^ kind ^ "/" ^
    Storage_disk.escape_segment
      (signed_id ~secret_key_base blob.id) ^ "/" ^
    Storage_disk.escape_path filename in
  match disposition with
  | None -> path
  | Some kind -> path ^ "?disposition=" ^
      Storage_disk.escape (function
        | 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' | '-' | '.' | '*' -> true
        | _ -> false) kind

let representation_path kind ~secret_key_base blob variation =
  "/rails/active_storage/representations/" ^ kind ^ "/" ^
  Storage_disk.escape_segment (signed_id ~secret_key_base blob.Db_remaining.Blob.id) ^
  "/" ^ Storage_disk.escape_segment
    (Storage_variation.key ~secret_key_base variation) ^
  "/" ^ Storage_disk.escape_path (Storage_disk.sanitize_filename blob.filename)

let forced_disposition content_type =
  let allowed = ["image/webp";"image/avif";"image/png";"image/gif";
    "image/jpeg";"image/tiff";"image/bmp";
    "image/vnd.adobe.photoshop";"image/vnd.microsoft.icon";
    "application/pdf"] in
  if List.mem content_type allowed then None else Some "attachment"

let serving_type content_type =
  if List.mem content_type ["text/html";"image/svg+xml";
    "application/postscript";"application/x-shockwave-flash";
    "text/xml";"application/xml";"application/xhtml+xml";
    "application/mathml+xml";"text/cache-manifest"]
  then "application/octet-stream" else content_type

let service_url_path service ~secret_key_base blob ~disposition ~expires_at =
  let content_type = Option.value blob.Db_remaining.Blob.content_type ~default:"" in
  let disposition = Option.value (forced_disposition content_type) ~default:disposition in
  Storage_disk.disk_url_path service ~secret_key_base ~key:blob.key
    ~filename:blob.filename ~content_type:(Some (serving_type content_type))
    ~disposition ~expires_at ()

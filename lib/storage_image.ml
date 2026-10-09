(** Image analysis and tracked variants. File work runs outside the SQLite
    writer; the short record transaction admits one winner for each digest. *)

module Blob = Db_remaining.Blob
module Attachment = Db_remaining.Attachment
module Variant = Db_remaining.Variant_record
module V = Storage_variation

let variable_types = ["image/png";"image/gif";"image/jpeg";"image/tiff";
  "image/webp";"image/avif";"image/heic";"image/heif"]
let web_types = ["image/png";"image/jpeg";"image/gif";"image/webp"]

let content_type blob = Option.value blob.Blob.content_type ~default:""
let is_variable blob = List.mem (content_type blob) variable_types

let default_format blob =
  let content_type=content_type blob in
  if not (List.mem content_type web_types) then "png" else
  let ext=Storage_marcel.extension blob.Blob.filename in
  if ext<>"" && Storage_marcel.for_extension ext=content_type
  then ext else
  match List.assoc_opt content_type
      (Lazy.force Storage_marcel.tables).type_exts with
  | Some (first::_) -> first
  | _ -> "png"

let variation_for blob variation =
  if not (is_variable blob) then invalid_arg ("invariable blob: " ^ content_type blob);
  V.default_to variation ["format",V.Str (default_format blob)]

let metadata_json blob =
  match blob.Blob.metadata with
  | None -> []
  | Some raw -> (try match Yojson.Basic.from_string raw with
      | `Assoc entries -> entries | _ -> [] with _ -> [])

let put entries key value =
  if List.mem_assoc key entries then
    List.map (fun (name,prior) -> name,if name=key then value else prior) entries
  else entries@[key,value]

let analyzed_metadata entries dimensions =
  let entries=match dimensions with
    | None -> entries
    | Some (width,height) ->
        put (put entries "width" (`Int width)) "height" (`Int height) in
  let json = `Assoc (put entries "analyzed" (`Bool true)) in
  Rails_format.encode (Yojson.Safe.from_string (Yojson.Basic.to_string json))

let analyze runtime service blob =
  let dimensions=Storage_blob.open_verified service blob Storage_vips.analyze in
  let metadata=analyzed_metadata (metadata_json blob) dimensions in
  Db_runtime.write runtime (fun tx ->
    ignore (Db_runtime.execute (Db_runtime.conn tx)
      "UPDATE active_storage_blobs SET metadata=? WHERE id=?"
      [Sqlite3.Data.TEXT metadata;Sqlite3.Data.INT blob.id]);
    {blob with metadata=Some metadata})

let attached_variant db record_id =
  match Attachment.find_for db ~record_type:"ActiveStorage::VariantRecord"
      ~record_id ~name:"image" with
  | None -> None
  | Some attachment -> Some (Attachment.blob db attachment)

let existing_variant runtime blob variation =
  Db_runtime.read runtime (fun db ->
    match Variant.find_for db ~blob_id:blob.Blob.id
        ~variation_digest:(V.digest variation) with
    | None -> None
    | Some record -> attached_variant db record.id)

let process_variant runtime service blob variation ~now =
  let variation=variation_for blob variation in
  match existing_variant runtime blob variation with
  | Some winner -> winner
  | None ->
      let format=V.format variation in
      let operations=V.operations variation in
      let filename=Storage_marcel.base_without_extension blob.Blob.filename ^
        "." ^ String.lowercase_ascii format in
      let output=Filename.temp_file "image_processing" ("." ^ format) in
      Fun.protect ~finally:(fun () -> if Sys.file_exists output then Sys.remove output)
        (fun () ->
          Storage_blob.open_verified service blob (fun source ->
            Storage_vips.transform ~source ~target:output ~operations);
          Storage_blob.stage_file service ~source:output ~filename
            ~content_type:(Some (V.content_type variation))
            (fun prepared staged ->
              let dimensions=Storage_vips.analyze output in
              let prepared={prepared with
                Storage_blob.metadata=analyzed_metadata
                  (match Yojson.Basic.from_string prepared.metadata with
                   | `Assoc entries -> entries | _ -> []) dimensions} in
              let winner,created=Db_runtime.write runtime (fun tx ->
                let db=Db_runtime.conn tx in
                match Variant.find_for db ~blob_id:blob.Blob.id
                    ~variation_digest:(V.digest variation) with
                | Some record ->
                    (match attached_variant db record.id with
                     | Some image -> image,false
                     | None -> failwith "variant record has no image")
                | None ->
                    let record=Variant.create tx ~blob_id:blob.id
                      ~variation_digest:(V.digest variation) in
                    let image=Storage_blob.insert tx ~now prepared in
                    ignore (Attachment.create tx ~now
                      ~record_type:"ActiveStorage::VariantRecord"
                      ~record_id:record.id ~name:"image" ~blob_id:image.id);
                    image,true) in
              if created then Storage_disk.keep staged;
              winner))

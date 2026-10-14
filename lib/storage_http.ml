(** Active Storage HTTP actions for local blobs and direct uploads. *)

open Lwt.Infix
module H = Http_app
module D = Storage_disk
module B = Storage_blob

let head ?(content_type="text/html") status =
  let headers=if List.mem status [204;205;304] then Cohttp.Header.init ()
    else Cohttp.Header.init_with "content-type" content_type in
  Cohttp.Response.make ~status:(Cohttp.Code.status_of_code status)
    ~headers (),Cohttp_lwt.Body.empty
let now_plus c seconds =
  let now = Authentication.now_time c.H.now in
  match Ptime.add_span now (Ptime.Span.of_int_s seconds) with
  | None -> invalid_arg "Active Storage URL expiry"
  | Some value -> Authentication.utc_rfc3339 ~frac_s:3 value

let fetch_blob c id =
  Db_runtime.read_async c.H.runtime (fun db ->
    Db_runtime.query_one db
      (Db_remaining.Blob.select ^ " WHERE id=? LIMIT 1")
      [Sqlite3.Data.INT id] Db_remaining.Blob.decode)

let set_blob c =
  let raw = match H.param_string c "signed_blob_id" with
    | Some _ as value -> value | None -> H.param_string c "signed_id" in
  match Option.bind raw (B.verify_signed_id
    ~secret_key_base:c.H.secret_key_base ~now:c.H.now) with
  | None -> Lwt.return `Invalid_signature
  | Some id -> fetch_blob c id >|= function
      | None -> `Missing_blob
      | Some blob -> `Blob blob

let absolute c path = H.base_url c ^ path

let fullpath c =
  let uri=Request_uri.get c.H.request in
  Uri.path uri ^ (match Uri.verbatim_query uri with
    | None -> "" | Some query -> "?" ^ query)

let with_headers (response,body) f =
  let headers=f (Cohttp.Response.headers response) in
  {response with headers},body

let proxy_validator_headers c =
  let etag=Http_cache.combined_etag (Some (fullpath c)) in
  Cohttp.Header.of_list [
    "etag",etag;
    "last-modified","Sat, 01 Jan 2011 00:00:00 GMT";
    "cache-control","max-age=3155695200, public, immutable"]

let proxy_fresh_headers ?(accept_ranges=true) c response =
  let headers=Cohttp.Response.headers response in
  let headers=Cohttp.Header.fold (fun name value headers ->
    Cohttp.Header.replace headers name value)
    (proxy_validator_headers c) headers in
  let headers=if accept_ranges then Cohttp.Header.replace headers
    "accept-ranges" "bytes" else headers in
  {response with headers}

let blob_redirect service c blob =
  let disposition=Option.value (H.param_string c "disposition") ~default:"inline" in
  let path=B.service_url_path service ~secret_key_base:c.H.secret_key_base
    blob ~disposition ~expires_at:(now_plus c 300) in
  H.respond ~status:302 ~content_type:"text/html; charset=utf-8"
    ~headers:["location",absolute c path;"cache-control","max-age=300, private"] ""

let serve_disk_file ?(use_range=true) service c ~key ~content_type ~disposition ~cache =
  let path=D.path_for service key in
  if not (Sys.file_exists path) then Lwt.return (head 404) else
  let method_=c.H.original_method in
  let served=Storage_file_server.serve ~method_
    ?range:(if use_range then H.header c "range" else None)
    ?if_modified_since:(H.header c "if-modified-since")
    ~path ~content_type ~disposition () in
  let headers=if cache then
    ("cache-control","max-age=3600, public")::served.headers
    else served.headers in
  let response=Cohttp.Response.make
    ~status:(Cohttp.Code.status_of_code served.status)
    ~headers:(Cohttp.Header.of_list headers) () in
  Lwt.return (response, Storage_file_server.stream served.body)

let disk_show service c =
  let missing_content_type=match c.H.format with
    | format::_ when format<>Http_format.All -> Http_format.mime format
    | _ -> "text/html" in
  let not_found () =
    head ~content_type:missing_content_type 404 in
  let encoded=Option.value (H.param_string c "encoded_key") ~default:"" in
  (match D.decode_key service ~secret_key_base:c.H.secret_key_base
    ~now:c.H.now encoded with
  | None -> Lwt.return (not_found ())
  | Some key ->
      Lwt.catch (fun () ->
        serve_disk_file service c ~key:key.key
          ~content_type:(Option.value key.content_type
            ~default:"application/octet-stream")
          ~disposition:key.disposition ~cache:true)
        (function Unix.Unix_error (Unix.ENOENT,_,_) -> Lwt.return (not_found ())
                | exn -> Lwt.fail exn)) >|= fun ((response,_) as result) ->
  with_headers result (fun headers ->
    let headers=if Cohttp.Code.code_of_status (Cohttp.Response.status response)=404
      then Cohttp.Header.replace headers "content-type" missing_content_type
      else headers in
    Cohttp.Header.replace headers "cache-control" "max-age=3600, public")

let blob_proxy service c =
  set_blob c >>= function
  | `Invalid_signature -> Lwt.return (head 404)
  | `Missing_blob -> Lwt.return (H.error ~status:404)
  | `Blob blob ->
      let content_type=Option.value blob.Db_remaining.Blob.content_type ~default:"" in
      let range=match H.header c "range" with
        | Some value when String.trim value<>"" -> Some value
        | _ -> None in
      let invalid_range=match range with
        | None -> false
        | Some raw -> Storage_file_server.parse_range blob.byte_size raw=Some [] in
      if invalid_range then Lwt.return
        (H.respond ~status:416 ~content_type:(B.serving_type content_type) "") else
      if range=None && Http_cache.is_fresh c.H.request (proxy_validator_headers c)
      then Lwt.return (Cohttp.Response.make ~status:`Not_modified
        ~headers:(proxy_validator_headers c) (),Cohttp_lwt.Body.empty) else
      let disposition=Option.value (B.forced_disposition content_type)
        ~default:(if Option.is_some range then "inline" else
          Option.value (H.param_string c "disposition") ~default:"inline") in
      let formatted=D.disposition disposition blob.filename in
      serve_disk_file service c ~key:blob.key
        ~content_type:(B.serving_type content_type)
        ~disposition:formatted ~cache:false >|= fun (response,body) ->
      if Option.is_some range then
        with_headers (response,body) (fun headers ->
          Cohttp.Header.remove headers "last-modified"
          |> fun h -> Cohttp.Header.replace h "cache-control" "no-cache"
          |> fun h -> Cohttp.Header.replace h "accept-ranges" "bytes")
      else proxy_fresh_headers c response,body

let blob_redirect_handler service c =
  set_blob c >|= function
  | `Invalid_signature -> head 404
  | `Missing_blob -> H.error ~status:404
  | `Blob blob -> blob_redirect service c blob

let media_type c = Routes.media_type (H.header c "content-type")

let disk_update service c =
  let encoded=Option.value (H.param_string c "encoded_token") ~default:"" in
  match D.decode_token service ~secret_key_base:c.H.secret_key_base
    ~now:c.H.now encoded with
  | None -> Lwt.return (head 404)
  | Some token ->
      let length=Option.bind (H.header c "content-length")
        (fun s -> Int64.of_string_opt (String.trim s)) in
      let declared=Option.map String.lowercase_ascii token.content_type in
      let actual_type=Option.map String.lowercase_ascii (media_type c) in
      if declared<>actual_type || length<>Some token.content_length ||
         Int64.of_int (String.length c.H.body)<>token.content_length
      then Lwt.return (head 422)
      else Lwt.catch
        (fun () -> Lwt_preemptive.detach (fun () ->
          D.upload_bytes service ~key:token.key ~bytes:c.H.body
            ~checksum:token.checksum ()) () >|= fun () -> head 204)
        (function D.Integrity -> Lwt.return (head 422)
                | exn -> Lwt.fail exn)

let param_text = function
  | Some (Http_params.Text text) -> Some text
  | Some (Http_params.Json_scalar (`Int n)) -> Some (string_of_int n)
  | Some (Http_params.Json_scalar (`Float n)) -> Some (string_of_float n)
  | _ -> None

let parameter_missing c =
  (* This is ActionController::ParameterMissing, rendered by PublicExceptions
     outside the controller response pipeline. Its empty page has no app
     security headers or Rack cache default. *)
  c.H.skip_cookie_commit <- true;
  H.respond ~status:400 ~content_type:"text/html; charset=UTF-8"
    ~headers:["x-campfire-public-exception","1";"content-length","0"] ""

let direct_upload_create service c =
  let fields=match H.param c "blob" with
    | Some (Http_params.Object map) -> Some map
    | _ -> None in
  match fields with
  | None -> Lwt.return (parameter_missing c)
  | Some fields ->
      let get key=param_text (Http_params.get key fields) in
      let filename=get "filename" and checksum=get "checksum" in
      let byte_size=Option.bind (get "byte_size") Int64.of_string_opt in
      (match filename,checksum,byte_size with
       | Some filename,Some checksum,Some byte_size
         when filename<>"" && checksum<>"" ->
           if byte_size<0L || byte_size>16_777_216L then Lwt.return (head 413)
           else
             let content_type=get "content_type" in
             let metadata=match Http_params.get "metadata" fields with
               | Some (Http_params.Object map) ->
                   Rails_format.encode (Yojson.Safe.from_string
                     (Yojson.Basic.to_string (Http_params.to_json map)))
               | _ -> "{}" in
             let key=D.generate_key () in
             let new_blob : B.new_blob = {
               key;filename;content_type;metadata;
               service_name=service.D.name;byte_size;checksum } in
             Db_runtime.write_async c.H.runtime (fun tx ->
               B.insert tx ~now:(Authentication.now_time c.H.now) new_blob)
             >|= fun blob ->
               let signed_id=B.signed_id ~secret_key_base:c.H.secret_key_base blob.id in
               let url=D.direct_upload_path service
                 ~secret_key_base:c.H.secret_key_base ~key:blob.key
                 ~content_type ~content_length:byte_size ~checksum
                 ~expires_at:(now_plus c 300) |> absolute c in
               let optional = function None -> `Null | Some value -> `String value in
               let created=Authentication.parse_time blob.created_at
                 |> Option.map (Authentication.utc_rfc3339 ~frac_s:3)
                 |> Option.value ~default:blob.created_at in
               let payload=`Assoc [
                 "id",`Int (Int64.to_int blob.id);"key",`String blob.key;
                 "filename",`String blob.filename;
                 "content_type",optional blob.content_type;
                 "metadata",Yojson.Basic.from_string metadata;
                 "service_name",`String blob.service_name;
                 "byte_size",`Int (Int64.to_int blob.byte_size);
                 "checksum",optional blob.checksum;
                 "created_at",`String created;
                 "signed_id",`String signed_id;
                 "direct_upload",`Assoc ["url",`String url;
                   "headers",`Assoc ["Content-Type",optional content_type]]] in
               H.respond ~status:200 ~content_type:"application/json; charset=utf-8"
                 (Rails_format.encode
                   (Yojson.Safe.from_string (Yojson.Basic.to_string payload)))
       | _ -> Lwt.return (head 422))

type representation = H.context -> Db_remaining.Blob.t -> Yojson.Basic.t ->
  Db_remaining.Blob.t option Lwt.t
let representation_adapter : representation option ref = ref None
let register_representation f = representation_adapter := Some f

let representation service ~redirect c =
  set_blob c >>= function
  | `Invalid_signature -> Lwt.return (head 404)
  | `Missing_blob -> Lwt.return (H.error ~status:404)
  | `Blob blob ->
      let raw=Option.value (H.param_string c "variation_key") ~default:"" in
      match D.verify ~secret_key_base:c.H.secret_key_base
        ~purpose:"variation" ~now:c.H.now raw with
      | None -> Lwt.return (head 404)
      | Some variation -> match !representation_adapter with
        | None -> Lwt.return (head 501)
        | Some process -> process c blob variation >>= function
          | None -> Lwt.return (head 404)
          | Some image -> if redirect then Lwt.return (blob_redirect service c image)
            else if Http_cache.is_fresh c.H.request (proxy_validator_headers c)
            then Lwt.return (Cohttp.Response.make ~status:`Not_modified
              ~headers:(proxy_validator_headers c) (),Cohttp_lwt.Body.empty)
            else
              let content_type=Option.value image.Db_remaining.Blob.content_type ~default:"" in
              let disposition=Option.value (B.forced_disposition content_type) ~default:"inline" in
              let formatted=D.disposition disposition image.filename in
              serve_disk_file ~use_range:false service c ~key:image.key
                ~content_type:(B.serving_type content_type)
                ~disposition:formatted ~cache:false
              >|= fun (response,body) ->
              proxy_fresh_headers ~accept_ranges:false c response,body

let register service =
  Controller_aux.register_storage (function
    | "active_storage/blobs/redirect#show" -> Some (blob_redirect_handler service)
    | "active_storage/blobs/proxy#show" -> Some (blob_proxy service)
    | "active_storage/representations/redirect#show" ->
        Some (representation service ~redirect:true)
    | "active_storage/representations/proxy#show" ->
        Some (representation service ~redirect:false)
    | "active_storage/disk#show" -> Some (disk_show service)
    | "active_storage/disk#update" -> Some (disk_update service)
    | "active_storage/direct_uploads#create" -> Some (direct_upload_create service)
    | _ -> None)

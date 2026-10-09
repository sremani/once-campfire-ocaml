(** Bot webhook reply policy from Rails Webhook#deliver. Bot URLs are configured
    by administrators and deliberately may reach internal services. *)

type attachment = { data:string; filename:string; content_type:string }
type reply = None_reply | Text of string | Attachment of attachment
type delivery = { status:int option; reply:reply }
type error = Invalid_url of string | Network of string | Invalid_mime_type of string |
  Reply_too_large

let max_reply_size = 100 * 1024 * 1024

let mime_lookup = [
  "text/html","html","text/html";
  "application/xhtml+xml","html","text/html";
  "text/plain","text","text/plain";
  "text/javascript","js","text/javascript";
  "application/javascript","js","text/javascript";
  "application/x-javascript","js","text/javascript";
  "text/css","css","text/css";
  "text/calendar","ics","text/calendar";
  "text/csv","csv","text/csv";
  "text/vcard","vcf","text/vcard";
  "text/vtt","vtt","text/vtt";
  "vtt","vtt","text/vtt";
  "text/markdown","md","text/markdown";
  "image/png","png","image/png";
  "image/jpeg","jpeg","image/jpeg";
  "image/gif","gif","image/gif";
  "image/bmp","bmp","image/bmp";
  "image/tiff","tiff","image/tiff";
  "image/svg+xml","svg","image/svg+xml";
  "image/webp","webp","image/webp";
  "video/mpeg","mpeg","video/mpeg";
  "audio/mpeg","mp3","audio/mpeg";
  "audio/ogg","ogg","audio/ogg";
  "audio/aac","m4a","audio/aac";
  "audio/mp4","m4a","audio/aac";
  "video/webm","webm","video/webm";
  "video/mp4","mp4","video/mp4";
  "font/otf","otf","font/otf";
  "font/ttf","ttf","font/ttf";
  "font/woff","woff","font/woff";
  "font/woff2","woff2","font/woff2";
  "application/xml","xml","application/xml";
  "text/xml","xml","application/xml";
  "application/x-xml","xml","application/xml";
  "application/rss+xml","rss","application/rss+xml";
  "application/atom+xml","atom","application/atom+xml";
  "application/x-yaml","yaml","application/x-yaml";
  "text/yaml","yaml","application/x-yaml";
  "multipart/form-data","multipart_form","multipart/form-data";
  "application/x-www-form-urlencoded","url_encoded_form","application/x-www-form-urlencoded";
  "application/json","json","application/json";
  "text/x-json","json","application/json";
  "application/jsonrequest","json","application/json";
  "application/problem+json","json","application/json";
  "application/pdf","pdf","application/pdf";
  "application/zip","zip","application/zip";
  "application/gzip","gzip","application/gzip";
  "application/x-gzip","gzip","application/gzip";
  "text/vnd.turbo-stream.html","turbo_stream","text/vnd.turbo-stream.html"]

let valid_mime mime =
  let atom c = match c with
    | 'a'..'z' | 'A'..'Z' | '0'..'9' | '!' | '#' | '$' | '&'
    | '-' | '^' | '_' | '.' | '+' -> true | _ -> false in
  let parts = String.split_on_char '/' mime in
  match parts with
  | [main;sub] ->
    let valid part = String.length part > 0 && String.length part <= 127 &&
      String.for_all atom part in
    (main="*" && sub="*") || (valid main && (sub="*" || valid sub))
  | _ -> false

let mime_symbol mime =
  let lookup value = List.find_opt (fun (key,_,_) -> key=value) mime_lookup in
  match lookup mime with
  | Some (_,symbol,canonical) -> Ok (symbol,canonical)
  | None ->
    let bare = String.split_on_char ';' mime |> List.hd |> String.trim in
    (match lookup bare with
     | Some (_,symbol,canonical) -> Ok (symbol,canonical)
     | None when valid_mime bare -> Ok ("",bare)
     | None -> Error (Invalid_mime_type bare))

let reply ~status ~content_type body =
  match content_type with
  | None -> Ok None_reply
  | Some ("text/html" | "text/plain") when status=200 -> Ok (Text body)
  | Some mime ->
    Result.map (fun (symbol,canonical) -> Attachment {
      data=body;filename="attachment."^symbol;content_type=canonical})
      (mime_symbol mime)

let invalid_url url =
  match try Some (Uri.of_string url) with _ -> None with
  | None -> Error (Invalid_url "bad URI")
  | Some uri when Uri.scheme uri <> Some "http" && Uri.scheme uri <> Some "https" ->
    Error (Invalid_url "not an HTTP URI")
  | Some uri when Uri.host uri=None || Uri.host uri=Some "" ->
    Error (Invalid_url "no host component for URI")
  | Some uri when (match Uri.port uri with Some p -> p<1 || p>65535 | None -> false) ->
    Error (Invalid_url "invalid port")
  | Some _ -> Ok ()

let deliver_with ?(perform=Webhook_transport.perform) ?(deadline=60.) url payload =
  match invalid_url url with
  | Error _ as error -> Lwt.return error
  | Ok () ->
    let uri = Uri.of_string url in
    let host = Option.get (Uri.host uri) in
    let scheme = Option.get (Uri.scheme uri) in
    let port = Option.value ~default:(if scheme="https" then 443 else 80) (Uri.port uri) in
    let host_header = if port=(if scheme="https" then 443 else 80)
      then host else host^":"^string_of_int port in
    let request = {Outbound_http.url; meth="POST";pinned_ip=None;
      headers=Outbound_http.net_http_headers ~connection_close:true
        ~host:(Some host_header) ["Content-Type","application/json"] @
        ["Content-Length",string_of_int (String.length payload)];
      body=payload;connect_timeout=7.;read_timeout=7.;
      deadline=Unix.gettimeofday ()+.deadline;max_body=max_reply_size;
      ca_bundle=None} in
    Lwt.map (function
      | Error "body too large" -> Error Reply_too_large
      | Error "whole-call timeout" ->
        Ok {status=None;reply=Text (Printf.sprintf
          "Failed to respond within %d seconds" (int_of_float deadline))}
      | Error ("timeout" | "open timeout" | "read timeout" | "deadline exceeded") ->
        let seconds = if deadline >= 60. then 7 else int_of_float deadline in
        Ok {status=None;reply=Text (Printf.sprintf
          "Failed to respond within %d seconds" seconds)}
      | Error message -> Error (Network message)
      | Ok response ->
        Result.map (fun reply -> {status=Some response.Outbound_http.status;reply})
          (reply ~status:response.status
            ~content_type:(Outbound_http.content_type response) response.body))
      (perform request)

let deliver url payload = deliver_with url payload

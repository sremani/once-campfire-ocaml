(** Request rejection and failure reports preserve the parser or exception
    detail. This mirrors the pinned kit's diagnostic messages. *)

let source = Logs.Src.create "campfire.http.request"
module Log = (val Logs.src_log source : Logs.LOG)

let error_detail = function
  | Http_params.Invalid reason -> "bad request: " ^ reason
  | Http_params.Type reason -> "bad request: " ^ reason
  | Http_params.Too_deep -> "bad request: parameters nested too deeply"
  | Http_params.Limit reason -> "bad request: " ^ reason
  | Http_params.Too_large -> "request entity too large"
  | Http_params.Parse -> "bad request: invalid request body"

let rejected error =
  Log.warn (fun m -> m "request rejected error=%s" (error_detail error))

let exception_detail = function
  | Failure reason | Invalid_argument reason -> reason
  | error -> Printexc.to_string error

let failed ~path error =
  Log.err (fun m -> m "request failed error=%s path=%S"
    (exception_detail error) path)

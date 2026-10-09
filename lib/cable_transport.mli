type config = {
  disable_request_forgery_protection : bool;
  allowed_request_origins : string list;
  allow_same_origin_as_host : bool;
  assume_ssl : bool;
}

val default_config : config

type incoming = Text of string | Binary | Closed
type connection

val protocol : connection -> string option
val compression : connection -> bool
val read : connection -> incoming Lwt.t
val send_text : connection -> string -> unit Lwt.t
(* Write at most 64 ordered text frames in one socket write. *)
val send_texts : connection -> string list -> unit Lwt.t
val send_close : ?code:int -> connection -> unit Lwt.t

(** Return Rails' plain 404 for non-upgrades, bad handshakes, and forbidden origins.
    The supplied [run] owns the accepted socket after HTTP 101. *)
val handle :
  ?config:config -> Cohttp.Request.t ->
  run:(connection -> unit Lwt.t) ->
  Cohttp_lwt_unix.Server.response_action Lwt.t

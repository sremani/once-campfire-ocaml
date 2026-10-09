(** Action Text fragments parsed with the pinned Nokogiri Gumbo HTML5 fork.
    Every public conversion returns an error when the input exceeds its
    resource limits. HTML returned by [render] and [sanitize] is safe for
    [Views.trusted_html_of_sanitized]. *)
type error = string

type mention = {
  id : int64;
  name : string;
  title : string;
  attachable_sgid : string;
  user_path : string;
  avatar_path : string;
}

type resolver = string -> mention option
type gid_resolver = string -> mention option

val parse : string -> (unit, error) result
val sanitize : string -> (string, error) result
val render : ?resolve_sgid:resolver -> ?resolve_gid:gid_resolver -> ?request_host:string -> string -> (string, error) result
(* Rails message presentation rescue: conversion errors render an empty body. *)
val present_message : ?resolve_sgid:resolver -> ?resolve_gid:gid_resolver -> ?request_host:string -> string -> string
val to_plain_text : ?resolve_sgid:resolver -> ?resolve_gid:gid_resolver -> string -> (string, error) result
val editable_value : ?resolve_sgid:resolver -> ?resolve_gid:gid_resolver -> ?request_host:string -> string -> (string option, error) result
val mentioned_user_ids : resolve_sgid:resolver -> string -> (int64 list, error) result
val without_recipient_mentions : string -> recipient_name:string -> string

(** Adapter for message writes, FTS, and mention callbacks. Conversion errors
    raise [Invalid_argument], so the database transaction rolls back. *)
val db_adapter : resolve_sgid:(Sqlite3.db -> resolver) -> Db_messages.rich_text

(** Pass [resolve_gid] to let the plain-text converter resolve expired or
    tampered user SGIDs through their decoded GlobalID. *)
val db_adapter_with_gid : resolve_gid:(Sqlite3.db -> gid_resolver) -> resolve_sgid:(Sqlite3.db -> resolver) -> Db_messages.rich_text

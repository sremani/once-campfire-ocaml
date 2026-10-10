(* A fixed 21,267-byte response, matching the measured cached room body size.
   Both servers use this module and perform no application or database work. *)
let up = "OK\n"
let prefix = "<!doctype html><html><body>"
let suffix = "</body></html>"
let room = prefix ^ String.make (21_267 - String.length prefix - String.length suffix) 'x' ^ suffix

let response path =
  if path = "/up" then
    `OK, Cohttp.Header.init_with "content-type" "text/plain; charset=utf-8", up
  else if path = "/rooms/1" then
    `OK, Cohttp.Header.init_with "content-type" "text/html; charset=utf-8", room
  else
    `Not_found, Cohttp.Header.init_with "content-type" "text/plain; charset=utf-8", "not found\n"

let port () =
  if Array.length Sys.argv <> 2 then invalid_arg "usage: server PORT";
  int_of_string Sys.argv.(1)

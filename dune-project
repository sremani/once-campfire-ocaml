(lang dune 3.14)
(name once_campfire_ocaml)
(generate_opam_files true)

(package
 (name once_campfire_ocaml)
 (synopsis "An OCaml port of ONCE Campfire")
 (description "OCaml implementation of the ONCE Campfire application and its Rails-compatible storage formats")
 (license MIT)
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.14))
  sqlite3
  uri
  yojson
  base64
  cstruct
  mirage-crypto
  pbkdf
  eqaf
  ptime
  cohttp
  cohttp-lwt
  lwt
  cmdliner
  alcotest))

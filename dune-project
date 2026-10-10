(lang dune 3.14)
(name once_campfire_ocaml)
(generate_opam_files true)

(package
 (name once_campfire_ocaml)
 (synopsis "An OCaml port of ONCE Campfire")
 (description "OCaml implementation of the ONCE Campfire application and its Rails-compatible storage formats")
 (license MIT)
 (depends
  (ocaml (= 5.5.1))
  (dune (>= 3.14))
  sqlite3
  uri
  ipaddr
  yojson
  base64
  astring
  ocplib-endian
  conduit
  mirage-crypto-rng
  cstruct
  mirage-crypto
  pbkdf
  eqaf
  ptime
  uutf
  cohttp
  cohttp-lwt
  cohttp-lwt-unix
  conduit-lwt-unix
  ssl
  conf-libcurl
  lwt
  logs
  fmt
  cmdliner
  tyxml
  alcotest))

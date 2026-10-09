# Campfire in OCaml

An OCaml port of [basecamp/once-campfire-rust](https://github.com/basecamp/once-campfire-rust).
The compatibility and authenticated-session milestone is complete. This is **not yet a full
Campfire server**.

The port targets compatibility with existing Campfire installations: the SQLite schema, storage
layout, and signed and encrypted cookies. The Rust source is pinned at
`9872c1d9541551c0889a60e3d49a14488bd1e403` for initial comparisons.
The route, Rails compatibility, and schema fixtures under `test/fixtures/` come from that commit.

## Current status

- Dune project and an OCaml library.
- Environment and storage path parsing based on Rust `crates/campfire/src/config.rs`.
- Read-only inspection of an existing SQLite database for required Campfire tables.
- Complete route catalog recognition and path helpers against the pinned route vectors.
- Rails and Ruby format primitives, signed identifiers, signed/encrypted cookies, CSRF decisions,
  and Rack cookie behavior against the upstream vectors.
- Session authentication against a copy of the pinned Rails seed, including expiry, revocation,
  user status, IP bans, and activity refresh.
- An in-process Cohttp request boundary for authenticated access and CSRF rejection. The
  listening server and application controllers remain in later milestones.

Build and test with OCaml 4.14 or newer, Dune, and the packages in
[`dune-project`](dune-project):

```sh
dune build
dune runtest
dune exec bin/main.exe -- check --database /path/to/storage/db/production.sqlite3
```

`check` never creates or modifies the database. It checks table presence, not every column or
index. A complete server still requires database models, controllers, views, Action Cable,
storage, integrations, and front-server work.
See [the porting map](docs/porting-map.md) for each upstream subsystem and its current status.
The [milestones and tickets](docs/milestones.md) and [verification gates](docs/verification-gates.md)
track the full port.

To regenerate the checked-in route catalog after updating the fixture:

```sh
python3 tools/generate_route_catalog.py test/fixtures/routes.json lib/route_catalog.ml
```

## Library choices

Use established OCaml libraries for protocol and infrastructure work. SQLite is accessed through
`sqlite3`; JSON uses `yojson`; CLI parsing uses `cmdliner`. Cryptography uses `mirage-crypto`,
`pbkdf`, `base64`, and `eqaf`; expiry parsing uses `ptime`. The HTTP boundary uses
`cohttp-lwt-unix` and `lwt`. Use existing HTML parsing and media bindings where they preserve the
Rails formats; verify each against the upstream `vectors/` corpus.

## Port sequence

M1 compatibility and sessions is complete. M2 ports the database models and transactions; M3
builds the listening HTTP application and controllers. Later milestones cover the browser,
realtime, media, operations, and release gates in [the ticket plan](docs/milestones.md).

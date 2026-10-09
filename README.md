# Campfire in OCaml

An OCaml port of [basecamp/once-campfire-rust](https://github.com/basecamp/once-campfire-rust).
The compatibility, authenticated-session, and database-model milestones are complete.
Realtime, media, and local deployment checks have passed their milestone gates. Full
HTTP, browser, differential, and external deployment/release verification is in progress.

The port targets compatibility with existing Campfire installations: the SQLite schema, storage
layout, and signed and encrypted cookies. The Rust source is pinned at
`9872c1d9541551c0889a60e3d49a14488bd1e403` for initial comparisons.
The route, Rails compatibility, and schema fixtures under `test/fixtures/` come from that commit.

## Current status

- Dune project and an OCaml library.
- Environment and storage path parsing based on Rust `crates/campfire/src/config.rs`.
- Existing-schema SQLite access with asynchronous reader and writer queues, transactions,
  WAL checkpoints, and consistent backup snapshots.
- Typed database models for accounts, users, sessions, rooms, memberships, messages,
  boosts, search, Active Storage records, push subscriptions, bans, and webhooks.
- Complete route catalog recognition and path helpers against the pinned route vectors.
- Rails and Ruby format primitives, signed identifiers, signed/encrypted cookies, CSRF decisions,
  and Rack cookie behavior against the upstream vectors.
- Session authentication against a copy of the pinned Rails seed, including expiry, revocation,
  user status, IP bans, and activity refresh.
- A Cohttp/Lwt application listener with the 177-route dispatcher, authenticated controllers,
  cache handling, streamed multipart uploads, packaged assets, and a same-listener Cable upgrade.
- Tyxml views, Action Text parsing, signed Active Storage responses, libvips/ffmpeg derivatives,
  jobs, Web Push, guarded outbound integrations, and a Caddy front configuration. These have
  focused and seeded tests; the complete cross-implementation and browser gates remain open.

Build and test with OCaml 4.14 or newer, Dune, and the packages in
[`dune-project`](dune-project):

```sh
dune build
dune runtest
dune exec bin/main.exe -- check --database /path/to/storage/db/production.sqlite3
```

`check` never creates or modifies the database. It checks table presence, not every column or
index. `dune exec bin/main.exe -- serve` starts the application listener after configuration;
set `SECRET_KEY_BASE` and `CAMPFIRE_STORAGE_PATH` for a disposable installation, or use the
existing installation's secret and storage paths for compatibility checks. The listener and
deployment configuration are still under differential verification, so use a copied installation
for testing.
See [the porting map](docs/porting-map.md) for each upstream subsystem and its current status.
The [milestones and tickets](docs/milestones.md) and [verification gates](docs/verification-gates.md)
track the full port.
The [agent ledger](docs/agent-ledger.md) records milestone managers and ticket agents as they start.
The [deployment guide](docs/deployment.md) describes the ONCE image contract, hooks, and
copied-install upgrade check.

To regenerate the checked-in route catalog after updating the fixture:

```sh
python3 tools/generate_route_catalog.py test/fixtures/routes.json lib/route_catalog.ml
```

## Library choices

Use established OCaml libraries for protocol and infrastructure work. SQLite is accessed through
`sqlite3`; JSON uses `yojson`; CLI parsing uses `cmdliner`. Cryptography uses `mirage-crypto`,
`pbkdf`, `base64`, and `eqaf`; expiry parsing uses `ptime`. HTTP uses `cohttp-lwt-unix` and `lwt`,
views use `tyxml`, and Cable uses a pinned vendored OCaml WebSocket library. The media path calls
libvips and ffmpeg; the front server uses Caddy. Each compatibility boundary is checked against
the pinned upstream vectors and live fixtures.

Rails password digests use bcrypt. The installed OCaml package set has no bcrypt binding, so
`lib/bcrypt_stubs.c` calls the system `libcrypt` implementation through its reentrant `crypt_r`
interface. This keeps password handling in process and uses a maintained system crypto library;
the binding copies OCaml strings before releasing the runtime lock and clears its temporary
password buffer after each call. The database model tests verify Rails-issued `$2a$` digests.

## Port sequence

M1 compatibility and sessions, M2 database models and transactions, and the local M5 realtime,
M6 media, and M7 operations checks are complete. M3 HTTP, M4 browser, and M8 release checks
remain open; external M7 publication and ONCE deployment have not been run. See the
[ticket plan](docs/milestones.md) for exact gates and evidence.

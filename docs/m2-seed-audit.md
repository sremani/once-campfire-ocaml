# Pinned Rails database seed audit

The M2 tests copy the pinned `once-campfire-rust/parity/.seed/*/db/production.sqlite3`
databases before any write. The default seed has one **pre-existing** foreign-key violation:
`messages.id = 933434637` has `creator_id = 999999`, and there is no user with that ID.
`PRAGMA foreign_key_check` reports exactly `messages, 933434637, users, 0` on the
unmodified seed. This row is part of the Rails/Rust parity fixture and must remain intact.

SQLite foreign-key enforcement is enabled on every OCaml connection, as in Rust and Rails.
Enabling it does not repair or delete an existing orphan; it rejects new invalid writes. The
database runtime test compares the seed's foreign-key findings before and after opening the
database. It also compares all existing table rows and verifies that only Rust's two additive
message indexes appear. A clean `foreign_key_check` on this seed would mean fixture data was
changed, so it is not an acceptance condition.

The default seed's `PRAGMA integrity_check` is `ok`. Its fixture counts include one account,
10 users, 11 rooms, 39 memberships, 169 messages, and 169 FTS rows. The `first_run` seed has the
same schema with no application rows and is used for bootstrap tests.

The model differential test uses two additional SQLite fixtures produced by pinned
`reference-tools/db/differential.sh`: `test/fixtures/model_fixtures.sqlite3` is the Rails
`db:fixtures:load` state, and `test/fixtures/model_scenario.sqlite3` is its state after
`crates/db/ruby/scenario.rb`. Their SHA-256 digests are, respectively,
`bd9dd05a007a7422cdc0a3079155f852a29e56a2efd4914940d19482f946e3fb` and
`04300ed90fa12b345c4506fb79cee2ff99ac11c02a5f41bb6bc7006b27030b54`.
`m2_differential_test.ml` copies the first database, performs the same ordered model
mutations, and compares every row in the 13 affected model/FTS tables to the second.
Only clock dependent timestamp precision, random token lengths, bcrypt salt, and the
deactivation UUID are normalized, matching the pinned Rust differential test.

## M2 acceptance evidence

On the shared tree, `dune build @all` and `dune runtest --force` pass. The forced suite
runs 89 cases, including 13 database runtime cases, eight each for accounts, rooms,
messages, and remaining models, and the Rails row differential. Runtime cases cover
writer admission and FIFO scheduling, an event-loop-responsive 300-job Lwt queue,
concurrent readers, rollback and after-commit callbacks, close behavior, backup during
writes, and sustained WAL/checkpoint load. The model cases cover all five pinned seed
variants, first-run bootstrap, Rails bcrypt vectors and unknown-user work, direct-room
concurrency, membership/unread state, rich-text relations, attachment/boost/deletion
effects, FTS permissions and sparse fallback, validated bans, webhooks, push rows, and
typed after-commit event integration. The Rust differential generator's four database
tests passed against its Rails reference; its final host `sqlite3` shell step was
unavailable, and the schema comparison plus Rails rollback on Rust export were repeated
separately.

`Db_runtime.read_async` and `write_async` are the APIs for Lwt request handlers. The
synchronous variants may block the caller. SQLite's OCaml binding does not expose the
Rust WAL hook or a safe backup handle for this fixture, so the runtime measures WAL file
pages, runs passive checkpoints, uses a truncating checkpoint near 10,000 pages, and
uses `VACUUM INTO` for a consistent backup snapshot. SQL calls use prepared statements
but do not retain Rust's statement cache. These choices preserve the tested observable
state and scheduling behavior.

The M2 rich-text adapter stores typed Action Text relations and drives FTS/mention
queries; `basic_rich_text` only handles fixture plain text. M4 supplies production
Action Text parsing and sanitization. M3 controllers must use the async database entry
points and apply route permissions. M5 consumes typed after-commit events for sockets,
push, and webhook delivery. M6 supplies disk-object purge and media processing for the
typed Active Storage rows.

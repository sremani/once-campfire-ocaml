# Porting map

Reference: `basecamp/once-campfire-rust` commit
`9872c1d9541551c0889a60e3d49a14488bd1e403`. The reference app is a full Campfire server;
the current OCaml code covers only the modules marked **started** below.

| Rust crate | OCaml approach | Status and acceptance evidence |
| --- | --- | --- |
| `ruby`, `rails_compat` | `yojson`, `base64`, `pbkdf`, `mirage-crypto`, `ptime`, `eqaf`; add small compatibility functions only where Rails differs | **M1 verified:** Ruby string/number/URL/range vectors, JSON/Marshal/metadata, signed IDs/GlobalIDs/SGIDs/Turbo, cookie wire formats, and CSRF vectors pass. Password/model integration belongs to M2. |
| `routes` | Generated route catalog plus native OCaml recognizer | **M1 verified:** all 177 catalog entries, 111 positive/negative recognitions, 73 path helpers, encoded paths, and method override tests pass. The pinned Rails settings-controller resolution exception is modeled explicitly. |
| `db` | `sqlite3` binding with prepared statements, transactions, and the existing schema; no ORM migration | **M2 verified:** five model tickets cover async reader/writer scheduling, WAL checkpoints, backup snapshots, accounts, rooms, messages, search, storage rows, push, bans, and after-commit event adapters. The Rails mutation scenario matches all 13 affected model/FTS tables. See [seed and differential audit](m2-seed-audit.md). |
| `kit`, `campfire` | `cohttp-lwt-unix` and `lwt` for HTTP and application concurrency; `cmdliner` for operations | **M1 vertical slice:** a Cohttp request boundary accepts a Rails-issued signed cookie against the pinned SQLite seed, and rejects cross-site writes with HTTP 422/no cookie. Full routing, controllers, response formats, caching, jobs, and front-server behavior remain. |
| `richtext` | Existing HTML parser/sanitizer libraries after matching the Action Text vector corpus | Pending. |
| `storage` | OCaml filesystem and crypto libraries; invoke libvips and ffmpeg instead of implementing media codecs | Pending. Active Storage keys, signed IDs, checksums, metadata, and variants need parity tests. |
| `cable` | Established WebSocket library with an Action Cable protocol layer | Pending. Select the library against the frame and subscription vectors before wiring broadcasts. |
| `assets`, `views` | Reuse pinned frontend assets; use an OCaml HTML template or typed HTML library for server-rendered pages | Pending. Preserve URLs, DOM, and escaping behavior in browser comparisons. |

## Next vertical slice

1. Connect the authenticated Cohttp boundary to the full route dispatcher and controllers, using `Db_runtime.read_async` and `write_async` from the Lwt request loop.
2. Add production Action Text parsing and sanitization through the `Db_messages.rich_text` adapter; the M2 test adapter covers fixture plain text and model relation behavior.
3. Add corresponding views and write paths with differential HTTP tests.

The Rust and Rails vector fixtures are copied into `test/fixtures/` so tests do not need a Rust or
Ruby runtime. Update them only from a pinned upstream revision and record the new commit in the
README.

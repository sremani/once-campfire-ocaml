# Porting map

Reference: `basecamp/once-campfire-rust` commit
`9872c1d9541551c0889a60e3d49a14488bd1e403`, including its pinned Rails
reference. The [milestone tracker](milestones.md) records ticket acceptance and the
[verification gates](verification-gates.md) distinguish local checks from release checks.

| Rust subsystem | OCaml implementation and reused libraries | Current gate |
| --- | --- | --- |
| `ruby`, `rails_compat`, `routes` | `yojson`, `base64`, `pbkdf`, `mirage-crypto`, `ptime`, `eqaf`, plus small Rails compatibility functions and a generated route catalog | **M1 complete:** format, cookie, signed ID, CSRF, route, and authentication vectors pass. |
| `db` | `sqlite3` with prepared statements, transactions, reader/writer queues, WAL checkpoints, and backups against the existing schema | **M2 complete:** model, search, concurrency, and copied Rails seed checks pass. |
| `kit`, `campfire` | `cohttp-lwt-unix`, `lwt`, and `cmdliner` for the listener, controllers, background work, and CLI | **M3 gate complete on `2a511ac`:** all 177 catalog routes are dispatched; 3,186/3,186 eligible five-seed route/state cases and 30/30 positive writes match Rust exactly. The 354 unavailable first-run signed/denied roles have no fixture session. |
| `richtext` | Gumbo HTML parser binding with existing `yojson` and `tyxml` rendering; compatibility code handles Action Text behavior | **M4-T3 complete:** pinned parsing, sanitization, mention, and rendering corpus passes. |
| `storage` | OCaml filesystem and crypto libraries with system libvips and ffmpeg for image/video work | **M6 complete:** Active Storage rows, signed delivery, metadata, variants, previews, and live Rails/OCaml media checks pass their local gates. |
| `cable` | A pinned OCaml WebSocket library with the Action Cable protocol, `lwt` channels, and typed Turbo broadcasts | **M5 complete:** frame, channel, multi-client, and same-listener tests pass locally. |
| `assets`, `views` | Pinned frontend assets and `tyxml` views with Rails-compatible HTML boundaries | **M4 complete:** 321 packaged assets, all 123 view files, final-source shared Chromium flows, and five-seed browser parity are verified. |
| operations and deployment | Caddy, Docker, ACME, backup hooks, and `cmdliner` operations | **M7 complete:** copied-install upgrade, restart, backup/restore, rollback, and local TLS/HTTP2/ACME checks pass on both architectures. The published `v0.1.0` image is deployed through ONCE on luigi with persistent storage, restart, health, and backup checks. |
| comparative verification | Pinned Rust/Rails vectors and the shared HTTP, browser, Cable, media, and performance harnesses | **M8 complete:** vectors, HTTP/state differential, 5,890 exact final browser cells, performance/resilience, published image audits, and actual ONCE deployment are evidenced with documented differences. |

The Rust and Rails vector fixtures under `test/fixtures/` are pinned inputs. Update them
only from a recorded upstream revision; do not alter fixture bytes to make a comparison
pass. The completed browser evidence and remaining release gate are tracked in
[M4 browser evidence](m4-t4-browser.md), [M8 browser evidence](m8-t3-browser.md),
and the [release audit](m8-t5-release-audit.md).

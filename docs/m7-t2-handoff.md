# M7-T2 runtime operations handoff

Pinned contract: Rust `crates/campfire/src/app.rs`, `config.rs`,
`crates/kit/src/server.rs`, and the Rails `config/puma.rb` boot hook.

## Implementation

- `campfire` and `campfire server` now boot the app; `campfire backup` writes
  `storage/backups/<database basename>`; `campfire serve` and `check` remain
  available for development and inspection. The backup command uses the
  configured storage paths and Rails environment.
- `Runtime_ops.backup` copies through `Db_runtime.backup_to` into a new temporary
  file in the backup directory, verifies SQLite integrity and all required
  tables, syncs the file, atomically renames it, syncs the directory, and
  removes a failed partial. It never opens a missing source as a new database.
  The existing runtime uses `VACUUM INTO` because the installed OCaml SQLite
  backup binding crashed on the pinned fixture; that yields a consistent
  snapshot including committed WAL pages.
- Boot creates database/file directories, checks the connected schema, and
  applies Rails' `Membership.disconnect_all` before accepting traffic.
  `/up` is the existing public health route.
- `RAILS_LOG_LEVEL` defaults to `info`, and `CAMPFIRE_LOG` can override the
  process level. The process uses installed `logs`/`logs.fmt`; both are pinned
  as dependencies. Worker failures are logged while the worker remains alive.
- SIGTERM/SIGINT stop the listener, send Action Cable's
  `server_restart`/`reconnect:true` disconnect and close frames, and allow
  active requests ten seconds to finish. Jobs then drain for ten seconds
  while the Lwt loop continues running for webhook HTTP work. The job queue
  waits for all workers and follow-on jobs to quiesce before it stops; a
  running banned-content cleanup can still enqueue a `PurgeBlob` job.
- Rust/Rails production sets both `assume_ssl` and `force_ssl`; a plain direct
  request to TARGET_PORT is therefore treated as HTTPS. The OCaml target
  now matches that behavior and sends HSTS. A request explicitly marked HTTP
  by the trusted front gets a 301 for GET/HEAD or 308 for other methods.

## Verification

- Exact local commands from the OCaml repository root:

  ```sh
  dune build
  dune exec test/m7_t1_test.exe
  dune exec test/m7_t2_test.exe
  dune exec test/m5_t3_test.exe
  python3 scripts/m7_live_ops_check.py
  ```

  The last command needs permission to bind localhost sockets. It reads the
  pinned test seed, session cookie fixture, and test secret from the adjacent
  Rust repository, creates disposable copies, and prints no credentials.
- `dune build` passes.
- `dune exec test/m7_t2_test.exe`: 8/8. It covers config and redirects,
  committed WAL backup and restore, failed backup cleanup and retention of
  the prior good snapshot, presence reset, follow-on purge, and an Lwt
  event-loop-dependent job drain, and a bounded deadline on stalled work.
- `dune exec test/m7_t1_test.exe`: 7/7, and
  `dune exec test/m5_t3_test.exe`: 8/8 after the shared changes.
- Live copied Rails `default` seed: `campfire backup` wrote an integrity-clean
  snapshot and a restored copy preserved all 169 messages. The production
  target returned `/up` 200 with the expected HSTS header and exited 0 on
  SIGTERM. With `DISABLE_SSL=1`, `/up` returned 200 and SIGINT exited 0.
  A trusted front marker with forwarded `http` returned 301 and the expected
  HTTPS location. A WebSocket authenticated with the pinned test fixture
  returned `welcome`, then `server_restart` with `reconnect:true` on SIGTERM;
  the process exited 0. These live checks used only disposable copies and
  pinned test credentials.

## Scope of remaining M7 verification

The ten-second timeout was tested as a bounded queue deadline at the unit
level; there is no live ten-second stalled request or stalled Web Push test in
this ticket. When a deadline expires, the process exits without closing its
database handle over still-running work. Web Push pool worker supervision
remains its existing M5 implementation; this ticket supervises the job queue
workers and coordinates their drain. Only a single backup invocation and a
failed replacement were exercised here; simultaneous backup invocations were
not compared against Rust. The full M7 gate should include these stress cases.

M7-T1 owns external HTTP/2, ACME renewal, and long-lived WebSocket proxy
checks. M7-T3 owns both container architectures, ONCE hooks, and image
upgrade/rollback. Full milestone and release gates remain open until those
checks pass.

# M8 ticket dispatch briefs

These briefs are ready for dedicated ticket agents when capacity is available. All three
tickets remain open. Pinned inputs are Rust `9872c1d9541551c0889a60e3d49a14488bd1e403`,
Rails submodule `90b330024dec3e757c79b6a7e6568f93da8e3148`, and shared verification
`6f71d70b5e1f17507404ad06cac134aa453a04a6`. Record any deliberate source change
to a shared harness with its new revision. Coordinate application fixes with M4, M3, M5 and
M8-T2 owners; do not count an inventory or a focused smoke as the full ticket gate.

## M8-T3: browser parity

**Dispatch:** Run the pinned Rust browser parity inventory against the OCaml app on
disposable, independent seed copies. Start with `once-campfire-rust/parity/bin/check-inventory`
and `parity/bin/compare --matrix lean`, then the `--matrix full` release sweep. Cover the
222 `parity/screens.yml` states (48 mutating) and all five seed variants used by the inventory, including
Chromium, Firefox and WebKit, desktop/laptop/tablet/phone and light/dark where specified.
Compare server HTML, live DOM, ARIA, network response shapes and normalized bytes, Cable
frames and pixels. Include mutating and multi-actor interaction states. Preserve the pinned
clock, fresh-seed `--reset-host` isolation for `mutates: true`, and the harness's narrow masks;
do not widen allowlists to hide unknown differences.

The pinned `parity/bin/check-inventory` assumes Rails inserts a hidden
`authenticity_token` in the sign-in form. The pinned Rust port omits it and
uses `Sec-Fetch-Site` forgery protection; the OCaml port follows that behavior.
Run the original script on Rails to establish its reference result, then use
`scripts/m8_check_inventory.rb` for Rust and OCaml. That local copy only makes
the login token optional and has been checked against the original on a fresh
Rails default seed. It does not alter the pinned browser capture harness.

**Setup/resources:** `once-campfire-rust/parity/SCREENS.md`, `parity/screens.yml`,
`parity/bin/compare`, `parity/bin/candidate`, and `parity/docker/candidate/Dockerfile` define
the matrix, reset hook and frozen-clock candidate wrapper. Build the wrapper separately with
`BASE_IMAGE=<final OCaml image>` and point its run path at that image; the candidate `build`
subcommand otherwise builds Rust. Make the expected server the pinned Rust app, not the Rails
reference. Run the unmodified shared `once-campfire-verification/bin/browser` on a fresh OCaml
install as a separate functional gate; M4-T4's earlier Chromium smoke already passed but needs
a final-revision rerun. `docs/m4-t4-browser.md` records a strict sign-in cell with matching
server/live/ARIA/pixels but network differences, and a room cell with substantial markup and
pixel differences; start triage there after M4-T2's view work lands.
M4-T4 also produced a 40-cell default-seed parity artifact with two desktop/light room cells
exact in pixels and ARIA; use its final report and wait for M8-T2's Docker reset loop to end
before a fresh browser capture. The final functional smoke's browser console check is under
M4-T4 triage after `ERR_NETWORK_CHANGED` during that reset loop.

**Acceptance:** A reproducible command log and report paths for every seed/matrix run, with
passing cell counts and exact remaining failures or a narrowly reviewed intentional-difference
list. Capture full artifacts in ignored output. Treat skipped cells, failed readiness and missing
engines as not run. Do not mark M8-T3 complete for the shared Chromium smoke alone.

## M8-T4: performance and resilience

**Dispatch:** Add an `ocaml` app adapter to the independent shared
`once-campfire-verification/bench/compare.rb` and its tests, preserving generic image/env
selection (`OCAML_IMAGE`, `OCAML_BENCH_ENV`), source-revision and image-ID checks, isolated seed
copies, topology attribution and raw-output exclusion from git. The current allowed app list
omits `ocaml`; verify the release image's `/rails/storage` mounts and boot contract before
running. Follow the shared `AGENTS.md`: invalid decoded responses, incomplete Cable fanout,
or unaudited acknowledged writes never become throughput. Run shared `bin/check` after edits
and format the load generator with `cargo fmt --manifest-path loadgen/Cargo.toml` if touched.

**Prerequisites:** The shared checkout currently lacks generated `fixtures/default` and
`loadgen/target/release/loadgen`. Build the fixture with `bin/seed` from its pinned Rails
revision `90b330024dec3e757c79b6a7e6568f93da8e3148`, preferably using an already built
reference image whose `GIT_REVISION` environment matches; the builder refuses to overwrite
an existing seed. Keep its generated credentials and raw seed ignored and do not print them.
Build the client with `cargo build --release --locked --manifest-path loadgen/Cargo.toml` in
the pinned Rust 1.98.1 toolchain image described by OCaml `tools/m8_verification.Dockerfile`;
the host Cargo is older and `mise` is unavailable. Record fixture DB SHA-256, reference image
ID and loadgen binary SHA-256. Both operations can be prepared offline before timed Docker
measurement, subject to a narrow Docker approval. The host reports 32 CPUs; benchmark defaults
to server CPUs 8–11 and client CPUs 12–15. Defer timed network measurements until M8-T2's
177-row Docker reset loop finishes.

**Measurement:** Run `bin/benchmark --apps rust,ocaml` in alternating order for at least two
rounds (the default is three), with the same CPUs, 16-client workload, image digests and seed
SHA-256. Exercise all eight shared routes (`room_show`, `messages_page`, `sidebar`, `search`,
`avatar`, `static_css`, `up`, `post_message`), retaining decoded response contracts and exact
acknowledged-write/Action Text/FTS/SQLite-integrity audits. The M8-T2 preflight already passes
all eight `BenchmarkContracts` and one acknowledged write on both Rust and OCaml; the timed
benchmark and its adapter are still missing. Report throughput and latency only from validated
samples, with raw result paths and image/source/topology metadata.

**Resilience:** Use disposable storage and record bounded concurrent reads/writes across rooms,
two-client Cable fanout, slow or disconnected clients, oversized/malformed bodies and security
limits, sustained service memory and queue growth, process crash/restart, and backup/restore.
Define duration, load, resource readings and pass/fail criteria before each run. Investigate any
lost acknowledged write or SQLite integrity failure. Separate observations from throughput
claims and state the test host and runtime constraints.

## M8-T5: release audit

**Dispatch:** Produce a reviewable release candidate and provenance manifest from the final
source and image digests. Audit top-level 37signals MIT attribution, vendored Cable WebSocket
ISC source/commit (`vendor/cable_websocket/`), vendored Nokogiri Gumbo source archive, SHA-256,
per-file hashes, patches and notices (`vendor/gumbo/provenance.json`), packaged static assets,
C stubs and linked libraries. Inventory exact OCaml/opam, apt and transitive package versions,
licenses, base image digests, built image IDs and architecture manifests; identify mutable
repositories or downloads that prevent a repeatable rebuild. M7's Dockerfile pins Ubuntu
24.04/Debian trixie base digests and direct apt versions, while transitive apt resolution still
needs an exact captured inventory.

**Release checks:** Reverify local amd64 and arm64 image boot, upgrade from copied Rails seed,
169-message and 14-blob checksums, backup/restore, OCaml restart and Rails rollback from M7's
handoff. Recheck image entrypoint, `/rails/storage`, media/Caddy TLS and HTTP/2, health and
shutdown. Run clean `dune build`, `dune runtest`, all 123 view goldens, final M8-T2 route/state
matrix, shared `bin/check`, final browser lean/full matrix and validated performance/resilience
results against pinned release images. Keep a table of exact commands, revisions, pass/fail and
artifact locations; document only evidence-backed intentional differences and upgrade/rollback
instructions in the release notes. A fresh GHCR multiarchitecture manifest and actual ONCE
deployment are outstanding external checks; prepare their exact reviewable commands and
credential requirements before requesting any publication or deployment approval.

**Acceptance:** No checked release gate rests on a prior source revision or on a local module
test standing in for live behavior. Keep M8-T5 open until complete local verification and
required external artifact/deployment checks have real evidence.

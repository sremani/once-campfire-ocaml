# M8 differential and release coverage audit

Audit input: Rust `9872c1d9541551c0889a60e3d49a14488bd1e403`, its Rails submodule
`90b330024dec3e757c79b6a7e6568f93da8e3148`, and shared verification
`6f71d70b5e1f17507404ad06cac134aa453a04a6`. This is an inventory and
worklist, not a release pass. **Pass (focused)** below means a previous milestone
recorded a passing local test for the stated subset; **partial** means the full
source corpus or application path is still unmatched. M8-T1's dedicated agent
has delivered its missing top-level vectors. Direct pinned Rust comparison now
passes the 658-case Action Text corpus and the 26-step Cable plus 47-step
channel goldens. The 123 view source files are now accounted for with 121
rendered checks and two input-metadata checks. **M8-T1 remains open** for the
kit/front live HTTP family and final clean-revision rerun. Other M8 tickets
remain open.

## Golden corpus coverage (M8-T1)

| Pinned source | OCaml evidence now | Status and missing artifact |
| --- | --- | --- |
| `vectors/ruby_core.json`: 427 string, 555 float, 200 byte-range cases plus versions | `test/m1_t1_test.ml`, byte-identical copied fixture | Pass (focused); rerun in the final clean build. |
| `vectors/rails_compat.json`: key generator, cookies, sessions, CSRF, signed IDs, GlobalID, SGID, Turbo streams, app verifiers, bcrypt | `test/core_test.ml`, `m1_t2_test.ml`, `m1_t3_test.ml`, `m1_t4_test.ml`, `m8_t1_user_agent_test.ml`; byte-identical fixture | Pass (focused) for M1 vectors and all 40 pinned bcrypt checks, including tampering/rejection; final full-suite rerun pending. |
| `vectors/campfire_routes.json`: 177 routes, 111 recognitions | `test/m1_t5_test.ml`, byte-identical fixture | Pass (focused) catalog recognition/helpers; live route responses remain M8-T2. |
| `vectors/campfire_sessions.json`: sessions, blobs and two forged cases | `test/m1_t3_test.ml`, Rails seed cookie comparison; byte-identical fixture | Pass (focused); live request/session matrix remains M8-T2. |
| `vectors/campfire_user_agents.json`: 385 agents, 44 versions, 352 comparisons, including `crates/campfire/src/concerns/{user_agent,platform}.rs` | `lib/user_agent.ml`, `lib/unicode_lower.ml`, `lib/views_browser.ml`, `test/m8_t1_user_agent_test.ml`; fixture byte-identical (SHA-256 `2eea58cd75ef6112d1d468d1904787e04411317dc20a90ece54b58486c314522`) | **Pass (focused)**: all agent fields, 13 application-platform fields, view nil/error fallbacks, blocking, malformed/default cases, 44 versions and 352 comparisons. HTTP before-action blocking, request-header platform population for view context, and focused in-process request checks pass; full template parity and live HTTP differential remain open. |
| `vectors/storage.json` and 11 derivative files; `crates/storage/tests/vectors.rs` | M6-T1–T4 strict tests; JSON fixture byte-identical; all eight originals and eleven derivatives checked in both pinned Rails and packaged OCaml media images | **Pass (M6 gate)**: T4 strict 3/3 in both images and 256 disposable live Rails/OCaml storage comparisons with zero mismatches, including signed media HTTP, direct upload, malformed signatures and concurrent transforms. See `m6-t4-differential.md`. Release architecture checks remain M8-T5. |
| `crates/kit/tests/params_vectors.json`, `rails_vectors.rs`, `http.rs`, `front.rs`, `logging.rs` | Copied params fixture; M1/M3/M7 tests, M8-T1 request-ID, error-log and four seeded flash/session action-chain tests; bounded live H2C and raw-query probes prepared in `scripts/m8_t1_wire_probe.py` (see `m8-t1-vector-inventory.md`) | Partial. The h2c plus two-second idle Caddyfile is asserted, but the timed live HTTP/2 idle close, live streamed-cache/Vary and raw-wire malformed query probes have not yet run. |
| `crates/db/src/tests/{account,user,first_run,room,membership,message,push,callbacks,columns,fixtures,differential}_test.rs` plus Rails fixture SQL | `m2_t1`–`m2_t5` and `m2_differential_test.ml`; pinned model fixture databases | Pass (focused) for accepted M2 model gate. Repeat against fresh seed copies; integrate HTTP write/state audit. |
| `crates/richtext/tests/{corpus,reference_tests,hardening}.rs` and `corpus/{inputs.yml,expected.json}` | `m4_t3_test.ml`, `test/m4_t3_compare.py --direct-rust`, byte-identical 658-case Rails fixture | **Pass (M4-T3 gate)**: 658/658 presentation, plain text and editable outputs match pinned Rust byte for byte, including 400 malformed/fuzz cases. Security audit found zero unsafe outputs; nine focused and five seeded HTTP suites pass. Raw Rails differences match the pinned Rust hardening exceptions in `m4-t3-corpus-gaps.md`. |
| `crates/assets/tests/reference.rs` and six reference files | `m4_t1_test.ml` and copied assets reference fixtures | Pass (focused) for 314 hashes/332 static responses; packaged image and live headers still pending. |
| `crates/views/tests/` (123 golden files; full pages, fragments, JSON, SVG) | `m4_t2_test.ml`, `test/fixtures/view_golden_inventory.json` and `test/view_golden_matrix.py --require-all` account for every source case | **Pass (golden accounting)**: 121 rendered checks pass and two semantic input metadata checks pass, with zero failures or unsupported cases. The live browser and whitespace byte review remain open. |
| `crates/cable/tests/{protocol,golden}.rs` and `golden/reference.json`; `crates/campfire/src/channels/tests/golden/reference.json` | M5-T1/T2 focused and independent live golden replays | **Pass (M5-T1/T2 gate)**: all 26 transport and 47 channel scripted steps match byte for byte on the shared listener, including ordered text/close frames, revocation and bounded ring behavior. |
| `crates/campfire/src/integrations/testdata/{web_push_expected,webhook_cases,webhook_expected,opengraph_cases,opengraph_expected}.json` | M5-T3/T4 focused and seeded integration; copied JSON fixtures | **Pass (M5 local gate)**: 90 OpenGraph and 19 webhook oracle cases, exact ordered live wire, controlled Web Push TLS/crypto and shared HTTP/Cable listener tests. Public provider delivery remains outside local fixture evidence. |
| `crates/campfire/src/controllers/qr_code/testdata/rqrcode.json` | `m3_t4_test.ml` records 39 QR vectors passing | Pass (focused); route-level comparison pending. |

The pinned Rails repository also has 73 `reference/test/**/*_test.rb` tests. Its
`reference-tools/` scripts generate the JSON, view, database, storage and rich-text
oracles above. Running those Rails tests is an oracle-health check; OCaml needs
equivalent behavior and live differential evidence, not a Ruby test count.

### M8-T1 focused verification (2026-10-09)

The pinned six top-level JSON vector files were compared byte-for-byte with their
OCaml copies; all six match. An audit of their top-level sections found the
`rails_compat.json` password matrix had only local bcrypt examples in
`m2_t2_test.ml`. The storage corpus also lacked direct assertions for its
video-preview argv and secret-prefix metadata. `m8_t1_user_agent_test.ml` now
checks all 40 pinned Rails password outcomes, five digest structures, and
those storage fields, alongside the entire user-agent corpus. `dune build` passed. The focused test passed 6/6 cases:
385 complete agents, 44 versions plus 352 comparisons, page defaults/blocking,
40 bcrypt checks, an in-process old-browser HTTP block/modern-browser pass,
and the pinned storage preview argv and secret-prefix metadata.
The M8 manager independently reran `dune build`, the byte comparison, Unicode
generator check, and `dune runtest --force`; all passed with local loopback sockets
enabled. The full run included the 6/6 M8 corpus suite. Under the normal filesystem/network sandbox, the same full suite failed
seven `m5_t4_test.ml` socket cases at `Unix.socket` with `EPERM`; those cases
passed in the loopback-enabled run. This is a source-revision checkpoint while
M4 and later M8 tickets are active, not the final release build.

## Shared and browser gates (M8-T2 through M8-T4)

| Gate | Current result | Completion evidence needed |
| --- | --- | --- |
| `once-campfire-verification/bin/check` | **Pass** in the pinned disposable image from `tools/m8_verification.Dockerfile` after the OCaml adapter: Rust 1.98.1 fmt/Clippy/loadgen 9/9, five Ruby test files, four Node 22.18 syntax checks, zero failures. Local verification HEAD is `c39d51d` atop adapter commit `f5f14f7` and pinned base `6f71d70`. | Rerun from the final source revision; this validates the harness itself, not an OCaml app. |
| Shared `bin/browser --base URL` | **Pass (focused Chromium smoke)** against a fresh disposable OCaml server: install, two-tab live messages, duplicate suppression, edit/search, profile/account, QR, room/bot/styles, transfer, joining and direct ping. See `m4-t4-browser.md`. | Rerun on the final image/revision and complete the pinned Rust browser parity matrix; this smoke does not establish full screen, engine or pixel parity. |
| Shared `bin/benchmark` | The shared harness now has an OCaml image adapter in local verification commit `f5f14f7`. A provisional direct-listener preflight passed the seven GET contracts and POST target setup in four isolated app runs. One acknowledged message write passed both implementations separately. The direct-listener resilience run validated 13,151 writes and 8,875 Cable deliveries before stopping at the header-limit stage. These are **not** packaged-image throughput or resilience results; see `m8-t4-performance.md`. | Run the final packaged image through all eight contracts, acknowledged writes, full resilience and at least two alternating timed Rust/OCaml rounds. Retain raw results outside git. |
| Rust `parity/bin/check-inventory` and `parity/bin/compare --matrix lean` | **Inventory pass, limited browser diagnostics only.** The pinned inventory has 222 states (48 mutating) across five seeds; 220 GET starting points checked and two non-GET fragments skipped. A minimally adapted sign-in checker passed Rails 198/0, then Rust and OCaml on all five seeds (220/0 each). The interim 40-cell Chromium desktop/phone light/dark diagnostic finished 12 pass, 28 fail; the packaged `rc-189d1ed` repeat finished **24 pass, 16 fail, 0 error**, with default-seed inventories 198/0 each. Residuals are room/sidebar network body and `Vary`, the intentional room Lexxy script, and search accessibility spacing/pixels. The packaged image predates newer offline view edits. See `m8-t3-browser.md`. | Build a fresh image and run lean and full browser captures on disposable seed copies; compare server HTML, live DOM, accessibility, network, Cable and pixels, and investigate every diff. Inventory checks only starting route/status. |
| Rust `parity/bin/compare --matrix full` | Not run. | Release matrix across Chromium, Firefox, WebKit, desktop/laptop/tablet/phone and light/dark, including mutation isolation and all seeds. Save report and explicit intentional-difference allowlist, if any. |
| Persisted-state/route differential | M8-T2's latest immutable default-seed matrix covered 177 route rows × four roles = **708 cases: 661 pass, 47 fail, 0 not-run**, up from 186/522, 556/152, 579/129, 620/88 and 657/51. It compares exact status, headers, body bytes and before/after hashes of every SQLite table; see `m8-t2-http-state.md`. Binary SHA-256: `90b091071bdb9e6d39913273b772fd876f2ff7d0aa334ca608a18c360dae5c78`. All 160 `action_not_found` and four missing-controller role-cases pass. There are zero status, state or infrastructure errors; the 47 residual failures are rendered body bytes and derived `Content-Length`/ETag headers across 24 route rows. This binary includes the five controller presenters, the shared Askama page shell, the exact transfer page and the auxiliary/cache fixes; route-specific view byte work remains. Shared `BenchmarkContracts` passes all eight routes on Rust and OCaml; `AcknowledgedWrites` verifies one real POST with exact persisted message, Action Text/FTS body, +1 row and SQLite integrity on both. M6's separate 256-case Rails/OCaml storage comparison passed. | Freeze the integrated source and rerun all 708 cells; cover valid writes, alternate seeds, malformed paths and method overrides. Close every response difference or document an intentional Rust difference. Include assets, Cable, media and error paths; retain shared contract/ack audit. |
| Performance/resilience | A disposable Caddy plus OCaml image passed the complete provisional resilience script: zero invalid responses, 79 exact HTTP writes across two rooms, 358 complete two-subscriber Cable posts, 15,051 validated reads in 60 seconds, peak 108,842,189 bytes/79 PIDs, header/body/slow-client checks, and SIGKILL/restart plus backup/restore with SQLite integrity. The previous direct-listener run separately validated 13,151 writes and 8,875 Cable deliveries before its header-limit stop. Raw provisional full run: `once-campfire-verification/tmp/bench/m8-t4-resilience-1791537692-2473296/`; see `m8-t4-performance.md`. | Repeat the gate on a final clean packaged image and run at least two timed alternating Rust/OCaml rounds. Publish comparison rates only from complete, valid samples and exact write audits. |

For M8-T3, the Rust parity harness's `parity/bin/candidate` accepts
`PARITY_CANDIDATE_IMAGE`. Build `parity/docker/candidate/Dockerfile` on the
final OCaml image with `BASE_IMAGE=...`, then point the harness at the
resulting parity image. This wrapper provides the pinned libfaketime and
fresh-seed reset behavior without altering the OCaml app image. Its `build`
subcommand builds Rust by default, so the OCaml wrapper build is a separate
step. Compare disposable seed copies only.

## Release and dependency provenance plan (M8-T5)

1. Pin a clean source revision and reproducible OCaml dependency solution. M7-T3 has built
   local amd64 and arm64 images from pinned Ubuntu 24.04 and Debian trixie base digests and
   direct apt versions; transitive apt packages still follow repository metadata. Record final
   image digests, exact package inventory and checksums. Release publication remains.
2. Audit the top-level 37signals MIT license; retain source attribution. The vendored
   WebSocket source records commit `133eda58386c43b95fed21ba1921cbc37b629b98` and ISC
   license in `vendor/cable_websocket/`. The vendored Nokogiri Gumbo source records commit,
   archive SHA-256, per-file hashes and local patches in `vendor/gumbo/provenance.json`;
   include its dependency notices. Inventory 321 packaged static files, all fonts/images/JS
   and their notices. Record provenance for C stubs and linked system libraries.
3. M7's local image pins Debian libvips `8.16.1-1+deb13u1`, ffmpeg
   `7:7.1.5-0+deb13u1` and Caddy `2.6.2-12+deb13u1`. Verify their licenses,
   final package versions, media bytes and HTTP/2/TLS/ACME behavior in the release image.
4. M7's local **amd64 and arm64** images passed copied Rails-seed upgrade, OCaml restart,
   backup/restore and Rails rollback while retaining 169 messages and 14 blob SHA-256 hashes.
   The arm64 run used QEMU on an amd64 host. Publish and inspect a multiarchitecture manifest,
   stress the noted Rails worker shutdown sensitivity, and verify actual ONCE deployment when
   the CLI and release credentials are available. Preserve the existing `/rails/storage`
   layout and hooks.
5. Run clean `dune build` and `dune runtest`, the complete vector and differential matrix,
   shared harness gates, browser full matrix and release smoke against the final image
   digests. Publish a concise evidence table and raw-result locations only after checks pass.

No benchmark or browser result is inferred from local module tests. All five M8 tickets and
the milestone gate remain open until their artifacts above exist.

### Harness audit commands and results

At shared verification commit `6f71d70b5e1f17507404ad06cac134aa453a04a6`,
the four Ruby files `bench/test_contracts.rb`, `bench/test_benchmark.rb`,
`bench/test_check_sample.rb`, and `bench/test_validate_acks.rb` passed (2, 1, 2,
and 1 Minitest runs respectively, zero failures/errors/skips) with each file
invoked using this isolated form:

```sh
docker run --rm --network none --read-only --tmpfs /tmp:rw,nosuid,nodev \
  --mount type=bind,src=/home/srikanth/projects/once-campfire-verification,dst=/verify,readonly \
  --workdir /verify --entrypoint ruby campfire-reference:latest bench/test_contracts.rb
```

Substitute each other Ruby test path in the last argument. `cargo fmt
--manifest-path loadgen/Cargo.toml --check` and `node --check` for
`browser/smoke.mjs`, `test/sidebar-reload.mjs`, `test/editor-preservation.mjs`,
and `test/autocomplete-json.mjs` each exited zero on the host. The installed
Cargo is 1.97.1, while the harness README asks for Rust 1.98.1; `mise` is not
installed. The local `sccache` wrapper failed under sandboxing. After clearing
`RUSTC_WRAPPER` and `CARGO_BUILD_RUSTC_WRAPPER` and fetching locked public crates,
`cargo test --locked --manifest-path loadgen/Cargo.toml` passed all nine tests.
`cargo clippy --locked --offline --manifest-path loadgen/Cargo.toml
--all-targets -- -D warnings` also exited zero on the host. The first combined
container run exposed three toolchain-image gaps: missing Rust components
`rustfmt`/`clippy`, missing `ffprobe`, and a non-executable `/tmp` build mount.
The checked-in pinned Dockerfile fixes those. The subsequent complete
`bin/check` run exited **0** using the documented Rust 1.98.1 and Node 22.18.0:

```sh
docker build -t campfire-m8-check:pinned -f tools/m8_verification.Dockerfile tools
docker run --rm --tmpfs /tmp:rw,exec,nosuid,nodev,size=1g \
  --mount type=bind,src=/home/srikanth/projects/once-campfire-verification,dst=/verify,readonly \
  --workdir /verify -e CARGO_TARGET_DIR=/tmp/loadgen-target \
  campfire-m8-check:pinned bin/check
```

The image was rebuilt from the checked-in Dockerfile and resolved to local
image ID `sha256:f9165e45afffa0b1e1086c8aec98c776ca2e26ee5f03c208204705f8f5ab5fd5`.
The Dockerfile pins its Rust and Node base digests. Its apt-installed Ruby,
SQLite and ffmpeg versions depend on the Debian trixie repository snapshot;
record their package inventory for the release audit. This run uses the shared
verification commit named above and read-only source; it does not exercise an
OCaml server, browser, or benchmark.

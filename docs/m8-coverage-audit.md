# M8 differential and release coverage audit

Historical audit input: Rust `9872c1d9541551c0889a60e3d49a14488bd1e403`, its Rails submodule
`90b330024dec3e757c79b6a7e6568f93da8e3148`, and shared verification
`6f71d70b5e1f17507404ad06cac134aa453a04a6`. This is an inventory and
worklist, not a release pass. **Pass (focused)** below means a previous milestone
recorded a passing local test for the stated subset; **partial** means the full
source corpus or application path is still unmatched. M8-T1's golden inventory
finds no unported offline vector case: six top-level JSON fixtures and the
2,755-case kit params fixture match pinned Rust byte for byte; Action Text
passes 658/658, Cable passes 26 transport plus 47 channel scripted goldens,
and the 123 view files have 121 rendered checks plus two linked input-metadata
checks. The clean `d6600ed` view matrix passes all 123 accountings. M8-T1 is
complete on its golden-coverage scope; remaining front wire differences
belong to M8-T2's documented comparison and release review. The clean `d6600ed` packaged image has a
five-seed HTTP/state sweep and passing external Cable, valid signed-media, and
shared-contract gates. Its ordinary route sweep retains 16 explicit Lexxy
room-page differences; packaged asset and raw malformed-path results are
classified below. The clean `d6600ed` image also has complete local M8-T4
benchmark/resilience evidence. M8-T2 is complete as a comparison with its
Lexxy, gzip-wire and Caddy-parser differences retained as failures;
M8-T5 and the release milestone remain open; M8-T3 is complete on the final
source as recorded below.

Current clean executable source `2a511ac` removes the retained Lexxy room-script
difference and matches text, attachment edit, involvement-frame, group-name
and avatar-upload responses. The pinned seeded room bodies match Rust directly
at rows 95/100; the 16 previously failing HTTP/state cells pass exactly
across four populated seeds on `e4b71e6`. Focused
`d223a0f` attachment-edit browser cells pass 4/4 and `7352f48` involvement
cells pass 16/16, and `2a511ac` group-name/avatar-upload cells pass 8/8,
across server, live DOM, accessibility, network, Cable and pixels. The full
`2a511ac` five-seed shared HTTP gate also passes 3,186/3,186 eligible cases
and 30/30 positive writes; 354 first-run roles lack a signed fixture.
The final-source browser matrix passes 5,890/5,890 applicable cells and its
three first-attempt WebKit anomalies pass separate exact recaptures. The
final-image release audit remains open. The
historical `d6600ed` results below retain their original evidence scope.

## Golden corpus coverage (M8-T1)

| Pinned source | OCaml evidence now | Status and missing artifact |
| --- | --- | --- |
| `vectors/ruby_core.json`: 427 string, 555 float, 200 byte-range cases plus versions | `test/m1_t1_test.ml`, byte-identical copied fixture | Pass (focused); rerun in the final clean build. |
| `vectors/rails_compat.json`: key generator, cookies, sessions, CSRF, signed IDs, GlobalID, SGID, Turbo streams, app verifiers, bcrypt | `test/core_test.ml`, `m1_t2_test.ml`, `m1_t3_test.ml`, `m1_t4_test.ml`, `m8_t1_user_agent_test.ml`; byte-identical fixture | Pass (focused) for M1 vectors and all 40 pinned bcrypt checks, including tampering/rejection; final full-suite rerun pending. |
| `vectors/campfire_routes.json`: 177 routes, 111 recognitions | `test/m1_t5_test.ml`, byte-identical fixture | Pass (focused) catalog recognition/helpers; live route responses remain M8-T2. |
| `vectors/campfire_sessions.json`: sessions, blobs and two forged cases | `test/m1_t3_test.ml`, Rails seed cookie comparison; byte-identical fixture | Pass (focused); live request/session matrix remains M8-T2. |
| `vectors/campfire_user_agents.json`: 385 agents, 44 versions, 352 comparisons, including `crates/campfire/src/concerns/{user_agent,platform}.rs` | `lib/user_agent.ml`, `lib/unicode_lower.ml`, `lib/views_browser.ml`, `test/m8_t1_user_agent_test.ml`; fixture byte-identical (SHA-256 `2eea58cd75ef6112d1d468d1904787e04411317dc20a90ece54b58486c314522`) | **Pass (focused)**: all agent fields, 13 application-platform fields, view nil/error fallbacks, blocking, malformed/default cases, 44 versions and 352 comparisons. HTTP before-action blocking, request-header platform population for view context, and focused in-process request checks pass; full template parity and live HTTP differential remain open. |
| `vectors/storage.json` and 11 derivative files; `crates/storage/tests/vectors.rs` | M6-T1–T4 strict tests; JSON fixture byte-identical; all eight originals and eleven derivatives checked in both pinned Rails and packaged OCaml media images | **Pass (M6 gate)**: T4 strict 3/3 in both images and 256 disposable live Rails/OCaml storage comparisons with zero mismatches, including signed media HTTP, direct upload, malformed signatures and concurrent transforms. See `m6-t4-differential.md`. Release architecture checks remain M8-T5. |
| `crates/kit/tests/params_vectors.json`, `rails_vectors.rs`, `http.rs`, `front.rs`, `logging.rs` | Byte-identical 2,755-case params fixture; M1/M3/M7 tests, M8-T1 request-ID/error-log and four seeded flash/session action-chain tests; packaged wire probes in `m8-t1-vector-inventory.md` | **Golden coverage pass; front differential partial.** Clean packaged OCaml H2C GOAWAY/EOF occurred at 3.002 s, raw malformed queries `%`, `%G0`, `%FF` matched Rust 400/empty, and the f099 logo miss/hit/signed/conditional sequence matched Rust 4/4. Caddy `/%ZZ` remains 400 versus Rust/direct OCaml 404; the custom raw-H2 client observed a packaged Rust discrepancy despite its passing Hyper source test. Keep these live questions in M8-T2/M8-T5. |
| `crates/db/src/tests/{account,user,first_run,room,membership,message,push,callbacks,columns,fixtures,differential}_test.rs` plus Rails fixture SQL | `m2_t1`–`m2_t5` and `m2_differential_test.ml`; pinned model fixture databases | Pass (focused) for accepted M2 model gate. Repeat against fresh seed copies; integrate HTTP write/state audit. |
| `crates/richtext/tests/{corpus,reference_tests,hardening}.rs` and `corpus/{inputs.yml,expected.json}` | `m4_t3_test.ml`, `test/m4_t3_compare.py --direct-rust`, byte-identical 658-case Rails fixture | **Pass (M4-T3 gate)**: 658/658 presentation, plain text and editable outputs match pinned Rust byte for byte, including 400 malformed/fuzz cases. Security audit found zero unsafe outputs; nine focused and five seeded HTTP suites pass. Raw Rails differences match the pinned Rust hardening exceptions in `m4-t3-corpus-gaps.md`. |
| `crates/assets/tests/reference.rs` and six reference files | `m4_t1_test.ml`, copied asset fixtures and `/tmp/m8-t2-d6600ed-assets-handoff.md` | Pass (focused) for 314 hashes and 332 static responses. Clean d660 packaged assets match Rust on 1,004/1,015 paired live cases: all 321 GET, 321 HEAD and five conditional cases match; ten gzip wire bodies differ with equal compared status/encoding/stable headers, and Caddy returns 400 for malformed `/assets/%GG` where Rust returns 404. A static-handler-only `/` fixture expects 404 while both full apps return 302; that is not a cross-app difference. |
| `crates/views/tests/` (123 golden files; full pages, fragments, JSON, SVG) | `m4_t2_test.ml` and `test/view_golden_matrix.py --require-all`; clean d660 report `/tmp/m8-d6600ed-view-golden-matrix.json` | **Pass (golden accounting)**: 121 rendered checks and two semantic input-metadata checks pass, zero failures or unsupported. Six large crowd/first-run page bodies also match pinned Rust byte hashes. Many rendered golden cases use structural DOM normalization; broad browser parity remains M8-T3. `test/fixtures/view_golden_inventory.json` retains historical 60/123 counters and should be refreshed or labeled historical. |
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

Since that focused checkpoint, request-ID and rejected-request logging coverage
raised the M8-T1 focused suite to 7/7, and four seeded flash/session/idle-config
action-chain tests pass. The six top-level vectors and 2,755-case kit params
fixture are byte-identical to pinned Rust. A full default-profile Dune suite
passed shortly before the clean bcb commit with the same source changes;
`/tmp/campfire-views-final-runtest.log` records its output. The clean bcb view
matrix `/tmp/m4-t2-goldens-bcb440c.json` exits 0 with 121 rendered passes and
two linked input-metadata cases. A durable clean release-profile build/full-suite
run remains an M8-T5 gate.

## Shared and browser gates (M8-T2 through M8-T4)

| Gate | Current result | Completion evidence needed |
| --- | --- | --- |
| `once-campfire-verification/bin/check` | **Pass** in the pinned disposable image from `tools/m8_verification.Dockerfile` after the OCaml adapter: Rust 1.98.1 fmt/Clippy/loadgen 9/9, five Ruby test files, four Node 22.18 syntax checks, zero failures. Local verification HEAD is `c39d51d` atop adapter commit `f5f14f7` and pinned base `6f71d70`. | Rerun from the final source revision; this validates the harness itself, not an OCaml app. |
| Shared `bin/browser --base URL` | **Pass (focused Chromium smoke)** against a fresh disposable OCaml server: install, two-tab live messages, duplicate suppression, edit/search, profile/account, QR, room/bot/styles, transfer, joining and direct ping. See `m4-t4-browser.md`. | Rerun on the final image/revision and complete the pinned Rust browser parity matrix; this smoke does not establish full screen, engine or pixel parity. |
| Shared `bin/benchmark` | **Pass (clean d660 packaged image)** with the generic OCaml adapter at verification `c39d51d`: two alternating Rust/OCaml preflight and timed rounds, all eight routes, 16 clients, eight seconds per route. Both summaries are `complete: true` and `release_comparable: true`; all 32 timed samples have zero HTTP errors/invalid responses, exact acknowledged writes, Action Text/FTS and SQLite integrity. Raw summaries: shared `tmp/bench/m8-t4-d6600ed-{preflight,timed}/`; see `m8-t4-performance.md`. | Preserve image/source/fixture/loadgen hashes and the material throughput gap in release notes; rerun impacted gates if the final image changes. |
| Rust `parity/bin/check-inventory` and `parity/bin/compare --matrix lean` | **Inventory pass, bounded bcb captures only.** The pinned inventory has 222 states (48 mutating) across five seeds; 220 GET starting points checked and two non-GET fragments skipped. The Rust/OCaml inventory adapter passes all five seeds. Clean bcb captures: default bounded Chromium **32/40**, custom styles lean **25/33**, restricted lean **8/8**, focused Firefox PWA **0/2**, all with zero capture errors. The 18 failed cells in those four slices are room pages with the retained 557-byte Lexxy readiness script and derived document hash; pixels, live DOM, ARIA and Cable agree. The intermittent sign-in readiness stall was traced to superseded-document request tracking in a detached harness worktree; the narrow fix still needs live replay. See `/tmp/m8-t3-browser-bcb440c-notes.md` and `/tmp/m8-t3-css-and-full-browser-plan.md`. | Complete reviewed readiness replay and the remaining all-seed lean/full captures, including mutation isolation and all output layers; decide and document the exact Lexxy script difference. Inventory alone does not exercise interactions. |
| Rust `parity/bin/compare --matrix full` | Not run. | Release matrix across Chromium, Firefox, WebKit, desktop/laptop/tablet/phone and light/dark, including mutation isolation and all seeds. Save report and explicit intentional-difference allowlist, if any. |
| Persisted-state/route differential | **Clean d660 packaged image:** five independently reset ordinary seeds, 177 routes × four roles each: **3,170 pass, 16 fail, 354 explicit not-run / 3,540**. Default, custom_styles, restricted and crowd each pass 704/708; first_run passes every applicable anonymous/bot cell (354/354) and has no matching signed-session fixture for its other 354 cells. Every failure is row 95 or 100 signed/denied: a reviewed 557-byte Lexxy readiness script in OCaml room HTML with derived `Content-Length`/ETag; status, other headers and SQLite effects match. Clean d660 packaged Cable frames/revocation pass literal ordered comparison; valid signed media passes 233/233; pinned shared BenchmarkContracts pass 8/8 and AcknowledgedWrites verifies one HTTP 200 message with +1 row and SQLite `ok` on both apps. Assets match 1,004/1,015, with ten gzip wire and one Caddy malformed-path differences. Handoffs: `/tmp/m8-t2-d6600ed-{full,external-gates,assets}-handoff.md`. | Every differential class has a live result. T2 is accepted as a completed comparison with the three narrow exception classes below recorded explicitly; none of their failing cases is a byte-exact pass. Confirm any later source/image revision with a targeted rerun. First-run signed/denied cells remain not-run, never passes. The full browser/release gates remain M8-T3/T5. |
| Performance/resilience | **Pass (clean d660 packaged image)**: two-round preflight and timed summaries are complete and release comparable; all 32 route samples have zero errors/invalid responses and exact acknowledged writes. Header probe returns 431 for a 66,560-byte front header and keeps the target private. The 60-second run has four validated workers (454 room reads, 533 searches, 368+370 exact writes), two Cable subscribers receiving five paced plus 1,658 saturated posts, 408/400/413/431 slow/malformed/body/header handling, 20 disconnected clients with healthy `/up`, 115,198 validated reads, peak 45,592,084 bytes and 79 PIDs, plus passing restart/backup/SQLite audits. Timed median room show Rust **81,888** versus OCaml **1,889** req/s; POST **4,926** versus **502**. Raw summaries: shared `tmp/bench/m8-t4-d6600ed-{preflight,timed}/` and `tmp/bench/m8-t4-resilience-1791561006-2326118/` and `tmp/bench/m8-t4-resilience-1791561012-2327394/`. | M8-T4 local gate is complete; retain workload bounds and measured gap as release evidence. No throughput target was specified. |

### Clean d660 M8-T2 evidence and proposed acceptance

The ordinary route runner froze both servers and reset separate seed databases
for every case. It compared status, returned headers, body bytes and
before/after hashes of every SQLite table. As in the documented runner,
only current `Date`, six-decimal `X-Runtime`, equivalent encrypted session-cookie
plaintext and validated independently generated write IDs receive narrow
normalization; deterministic values and header presence are not masked.
The image ID is
`sha256:ac006d4c5d5ca83db3ee0cc58c4f9af2d02d5c66161dc201449613bca08565d0`;
its extracted app SHA-256 is
`42a8df769a107df9e1ff6c48a071f861b45576b1684827dfaadefe3aafecd170`.
The pinned Rust commit is `9872c1d9541551c0889a60e3d49a14488bd1e403`.

| Seed | Pass | Fail | Not-run | Report |
| --- | ---: | ---: | ---: | --- |
| default | 704 | 4 | 0 | `/tmp/m8-t2-d6600ed-default-full.json` |
| custom_styles | 704 | 4 | 0 | `/tmp/m8-t2-d6600ed-custom_styles-full.json` |
| restricted | 704 | 4 | 0 | `/tmp/m8-t2-d6600ed-restricted-full.json` |
| crowd | 704 | 4 | 0 | `/tmp/m8-t2-d6600ed-crowd-full.json` |
| first_run | 354 | 0 | 354 | `/tmp/m8-t2-d6600ed-first_run-full.json` |

All 16 failing cells are rows 95 and 100 in signed and denied roles for the
four populated seeds. The OCaml room page includes an additional 557-byte
Lexxy mount-readiness script; only its body, `Content-Length` and ETag differ.
The script supports the repeated-edit browser flow. No status, other-header,
or SQLite-state mismatch remains in those cells. The first_run seed has no
matching signed session; its 354 signed/denied cells are explicitly not-run.
The d660 crowd autocomplete page/query Link, status and JSON probe passes 3/3;
the default public-logo miss, hit, signed hit, conditional 304 and Range
sequence passes 5/5 with no database changes. The logo Range response is
HTTP 200 with a full file on both apps, matching pinned Rust `send_file`.

External d660 packaged gates used independently copied default databases and
the same frozen test clock on Rust and OCaml. Cable's nine ordered non-heartbeat
frame groups match literal Rust bytes, with exact two-peer append delivery,
HTTP write, membership revocation, remote disconnect and rejected resubscribe.
Valid signed blob/disk/representation and presenter media pass 233/233 exact
checks. The shared pinned harness passes eight route contracts and verifies one
acknowledged HTTP write, +1 persisted message and SQLite integrity on both
apps. Reports and SHA-256 values are in
`/tmp/m8-t2-d6600ed-external-gates-handoff.md`. Initial one-off Cable/media
reports differed because the OCaml test launcher omitted `libfaketime` while
Rust was frozen; the corrected identical-clock reruns pass, and both initial
reports remain preserved as harness diagnostics.

The final `2a511ac` amd64 image repeats the live comparison against pinned
Rust: **1,004/1,015 exact**, with zero fixture errors. All 332 applicable
static fixture responses, 321 manifest GETs, 321 HEADs and five conditional
requests match. The eleven edge differences are ten gzip wire bodies on
five files and `/assets/%GG` returning Rust 404 versus Caddy 400. All
non-gzip sampled edges match. Raw malformed-target probes also confirm
Rust 404 versus Caddy 400 for `/assets/%GG`, `/assets/%ZZ` and `/assets/%2`.
The static-handler fixture's `GET /` expects 404, whereas both whole apps
redirect with 302; the live comparator excludes that static-only assertion
while still comparing both app responses. Reports are
`/tmp/m8-t2-2a511ac-assets-live.json` and
`/tmp/m8-t2-2a511ac-assets-malformed-raw.json`.

The final d660 packaged asset sweep compares **1,004/1,015** cases exactly:
all 321 manifest GET, 321 HEAD and five conditional requests pass. Its 11
remaining edge cases are ten gzip wire-body differences on five files and
`/assets/%GG` returning Rust 404 versus Caddy 400. The gzip cases retain
matching status, content encoding and compared stable headers; the identity
GET for every manifest asset is exact. The earlier bcb audit found equal
inflated content for this same gzip class. The current d660 asset report does
not separately store inflated payload hashes, so the ten cases remain wire
failures. A separate raw-socket d660 spot-check confirms Rust 404 versus
Caddy 400 for `/assets/%GG`, `/assets/%ZZ` and `/assets/%2`; Caddy rejects
these targets before OCaml dispatch. Both full apps return 302 for `/`, while
one static-handler-only fixture expects 404; that fixture expectation is not
an app differential. See `/tmp/m8-t2-d6600ed-assets-handoff.md` and its
retained JSON hashes.

**M8 manager acceptance recommendation:** M8-T2 can close as a *completed
comparison and classification* ticket if the owner accepts three narrowly
recorded differences, without counting them as exact passes:

1. Lexxy: the 16 specified row/role/seed cells have one 557-byte readiness
   script and derived `Content-Length`/ETag difference. The script is needed
   for repeated edit; scoped d660 Chromium room pixels, live DOM, ARIA and
   Cable are equal. The all-engine/all-viewport browser matrix remains M8-T3.
2. Compression: ten static gzip wire bodies differ across Rust's and the
   packaged front's compressors; status, encoding, compared stable headers,
   and identity asset responses match. Retain the raw-wire failures and
   verify inflation again if the compressor or asset bytes change.
3. Front parser: malformed raw targets in the recorded class return Caddy
   400 before OCaml routing versus Rust 404. Retain this status/body/header
   difference and the older malformed-matrix Rust-only session effects as
   explicit architecture-boundary findings; do not normalize them to passes.

The 354 first_run signed/denied cells lack a fixture session and remain
not-run, not passed. The earlier 30/30 positive-write and 236/236
method-override suites were on an older image; d660 has its complete ordinary
route/state sweep, exact custom-logo delete effects, focused first-run error paths,
and shared acknowledged-write audit. The older suites are inherited evidence,
not labeled d660 runs. A source or image change touching writes, method
selection, compression or the front must trigger targeted reruns. The broad
browser and release gates remain open under M8-T3 and M8-T5 even if T2 closes.

For M8-T3, the Rust parity harness's `parity/bin/candidate` accepts
`PARITY_CANDIDATE_IMAGE`. Build `parity/docker/candidate/Dockerfile` on the
final OCaml image with `BASE_IMAGE=...`, then point the harness at the
resulting parity image. This wrapper provides the pinned libfaketime and
fresh-seed reset behavior without altering the OCaml app image. Its `build`
subcommand builds Rust by default, so the OCaml wrapper build is a separate
step. Compare disposable seed copies only.

## Release and dependency provenance plan (M8-T5)

1. Clean d660 source `d6600edb94e5e038734786c4f927ec7ff05bcca0` has local
   amd64 image `sha256:ac006d4c5d5ca83db3ee0cc58c4f9af2d02d5c66161dc201449613bca08565d0`
   and arm64 image `sha256:4f2e61e9e6e9c6049042e8d49ebc6a3781d1e4850d02ceb6b30c5fa4263e9161`.
   `/tmp/campfire-image-d6600ed-{amd64,arm64}.json` report zero issues and
   321 assets each, with builder/runtime package and notice inventories. Pinned
   base digests and direct apt versions still leave
   transitive apt resolution mutable; a guaranteed repeatable rebuild remains open.
2. Audit the top-level 37signals MIT license; retain source attribution. The vendored
   WebSocket source records commit `133eda58386c43b95fed21ba1921cbc37b629b98` and ISC
   license in `vendor/cable_websocket/`. The vendored Nokogiri Gumbo source records commit,
   archive SHA-256, per-file hashes and local patches in `vendor/gumbo/provenance.json`;
   include its dependency notices. Inventory 321 packaged static files, all fonts/images/JS
   and their notices. Record provenance for C stubs and linked system libraries.
3. The bcb local images pin Debian libvips `8.16.1-1+deb13u1`, ffmpeg
   `7:7.1.5-0+deb13u1` and Caddy `2.6.2-12+deb13u1`. Verify their licenses,
   final package versions, media bytes and HTTP/2/TLS/ACME behavior in the release image.
4. The clean d660 **amd64 and arm64** images passed copied Rails-seed upgrade, OCaml restart,
   backup/restore and Rails rollback while retaining 169 messages and 14 blob SHA-256 hashes.
   Logs: `/tmp/campfire-lifecycle-d6600ed-{amd64,arm64}.log`. The arm64 run used
   QEMU on an amd64 host. Publish and inspect a multiarchitecture manifest,
   stress the noted Rails worker shutdown sensitivity, and verify actual ONCE deployment when
   the CLI and release credentials are available. Preserve the existing `/rails/storage`
   layout and hooks.
5. Run clean `dune build` and `dune runtest`, the complete vector and differential matrix,
   shared harness gates, browser full matrix and release smoke against the final image
   digests. Publish a concise evidence table and raw-result locations only after checks pass.

No benchmark or browser result is inferred from local module tests. M8-T1's
golden coverage and M8-T4's clean packaged benchmark/resilience tickets are
complete. M8-T2 is accepted as a completed historical comparison with its
scoped differences recorded above; M8-T3, M8-T5 and the milestone gate remain
open.

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

# Verification gates

Pinned inputs:

- Rust source: `9872c1d9541551c0889a60e3d49a14488bd1e403`
- Rails reference submodule: `90b330024dec3e757c79b6a7e6568f93da8e3148`
- Original shared verification harness baseline: `6f71d70b5e1f17507404ad06cac134aa453a04a6`
- Current clean shared verification harness: `b7647b401dcc2c4bcd91d913735b2b376ba0e3af`

The reference and verification checkouts are expected alongside this repository. The table
records completed local gates separately from the final browser and release checks.

| Gate | Required evidence | Status |
| --- | --- | --- |
| OCaml build and unit/integration tests | Clean `dune build --profile release` and `dune runtest --force`, including malformed-input, permission, and persistence cases | **Passed on frozen `2a511ac` code source**: 41 suites, 297 cases, plus the 123-file view inventory (121 rendered passes, two linked input metadata cases) in `/tmp/campfire-2a511ac-view-goldens.json`. Full-suite log: `/tmp/campfire-runtest-group-avatar-escalated.log`. Repeat if the release code changes. |
| Rails/Rust golden vectors | Relevant Rust `vectors/` and crate-local golden/corpus fixtures, including rejection cases | **Passed for M8-T1**: six top-level vectors and the 2,755-case parameters fixture are byte identical; all 123 view files are accounted for (121 rendered checks, two semantic inputs). See [vector inventory](m8-t1-vector-inventory.md). |
| Existing installation | Start against a copy of Rails storage and secrets; verify signed-in users, messages, attachments, memberships, search, writes, and restarts | **Passed locally on both final `2a511ac` images**: copied Rails upgrade/restart, backup/restore and rollback preserve 169 messages and 14 blob hashes; SQLite integrity and clean shutdown pass. See [release audit](m8-t5-release-audit.md). |
| HTTP and persisted-state contracts | Five-seed route/state comparison plus shared route contracts and acknowledged-write audit | **M3/M8-T2 local comparison complete on `2a511ac`:** 3,186/3,186 eligible route/state cases and 30/30 positive writes exact, with 354 first-run roles unavailable for lack of a signed fixture. The final amd64 static-route sweep is 1,004/1,015 exact, with ten gzip wire responses and one malformed Caddy path classified as scoped boundary differences. See [route audit](m3-route-audit.md) and [coverage audit](m8-coverage-audit.md). |
| Browser flows | Shared `bin/browser` against disposable servers: install, live messages, edit, search, permissions, settings, invitation, session transfer | **M4-T4 passed on frozen `2a511ac`**: shared two-tab repeated-edit and full Chromium smoke pass with fresh separate storage and mounted-editor readiness in verification checkout `b7647b4`; the complete five-seed browser parity matrix also passes. See [browser evidence](m4-t4-browser.md). |
| Rust local browser parity | Complete lean and full matrices across seeds, engines, viewports, and schemes; compare HTML, live DOM, accessibility, network, Cable, and pixels | **M8-T3 passed on frozen `2a511ac`**: all ten seed/matrix plans, 40 batches, and 5,890/5,890 final cells are exact on applicable layers (5,858 six-layer pages and 32 server-only fragments). The broad coordinator flagged two WebKit capture retries and a WebKit pixel retry; all three cells passed separate first-pass six-layer and network recaptures with zero retries. See [browser evidence](m8-t3-browser.md). |
| Cable and media | Crate-local frame, channel, storage, and media golden fixtures plus live multi-client and upload flows | **M5/M6 local gates passed**: pinned live Cable transport 26/26 and channel steps 47/47; strict media corpus 3/3 and 256 Rails/OCaml storage comparisons pass, plus streamed uploads and purge checks. Both final `2a511ac` images pass 233/233 signed-media cases. |
| Deployment | amd64 and arm64 image inventory, copied-install upgrade, restart, backup/restore, TLS/HTTP2/ACME, rollback, then published manifest and actual ONCE deployment | **Local and published release gates passed on final `2a511ac`**: `v0.1.0` is published at immutable digest `sha256:3215a11e11ee5cfb1c5b37ce4312a7292b6e5fe85fb5cfe451c556fcd42a7154`; both published architectures pass source inventory, copied-install lifecycle, TLS/HTTP2/ACME/Cable restart, and 233/233 signed-media checks. Uncached rebuild application inventories match but byte-identical images are unproven. M8-T5 remains open for an actual ONCE deployment; the target host and CLI access are missing. |
| Performance and resilience | Shared benchmark with response/write validation, plus memory, concurrency, long-running, and failure-recovery checks | **M8-T4 passed on final `2a511ac` image**: two alternating timed rounds cover 32 validated route samples with zero errors/invalid responses and exact acknowledged writes; header and 60-second resilience probes pass. The material Rust/OCaml throughput gap is retained as a release finding. See [performance evidence](m8-t4-performance.md). |

The shared harness requires a disposable server for browser flows because it mutates account,
room, and message state. The benchmark's route contracts validate full decoded responses and
acknowledged writes; throughput without these checks is not release evidence. The Rust parity
inventory's full matrix covers Chromium, Firefox, WebKit, viewports, and light/dark schemes.

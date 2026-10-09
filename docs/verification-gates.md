# Verification gates

Pinned inputs:

- Rust source: `9872c1d9541551c0889a60e3d49a14488bd1e403`
- Rails reference submodule: `90b330024dec3e757c79b6a7e6568f93da8e3148`
- Shared verification harness: `6f71d70b5e1f17507404ad06cac134aa453a04a6`

The reference and verification checkouts are expected alongside this repository. The table
records completed local gates separately from the final browser and release checks.

| Gate | Required evidence | Status |
| --- | --- | --- |
| OCaml build and unit/integration tests | Clean `dune build --profile release` and `dune runtest --force`, including malformed-input, permission, and persistence cases | **Passed** on clean `d6600ed` source and again on clean `f8f0775` source; the latter full-suite log is `/tmp/campfire-runtest-current-escalated.log`. Repeat on the final release revision. |
| Rails/Rust golden vectors | Relevant Rust `vectors/` and crate-local golden/corpus fixtures, including rejection cases | **Passed for M8-T1**: six top-level vectors and the 2,755-case parameters fixture are byte identical; all 123 view files are accounted for (121 rendered checks, two semantic inputs). See [vector inventory](m8-t1-vector-inventory.md). |
| Existing installation | Start against a copy of Rails storage and secrets; verify signed-in users, messages, attachments, memberships, search, writes, and restarts | **Passed locally on both architectures** for the `bb49e1e` candidate: copied Rails upgrade/restart, backup/restore and rollback preserve 169 messages and 14 blob hashes; SQLite integrity and clean shutdown pass. Repeat on the final image. See [release audit](m8-t5-release-audit.md). |
| HTTP and persisted-state contracts | Five-seed route/state comparison plus shared route contracts and acknowledged-write audit | **M8-T2 complete** on packaged `d6600ed`: 3,170 exact cells, 16 documented Lexxy room-script differences and 354 first-run signed/denied cells without a fixture session. Shared route and write contracts, Cable, and signed media pass. Ten gzip wire responses and one malformed Caddy path differ in the asset sweep. See [coverage audit](m8-coverage-audit.md). |
| Browser flows | Shared `bin/browser` against disposable servers: install, live messages, edit, search, permissions, settings, invitation, session transfer | **Focused Chromium smoke passed**; M4-T4 remains open for the complete supported browser behavior gate. See [browser evidence](m4-t4-browser.md). |
| Rust local browser parity | Complete lean and full matrices across seeds, engines, viewports, and schemes; compare HTML, live DOM, accessibility, network, Cable, and pixels | **M8-T3 open**. The full `bb49e1e` run is in progress. Earlier captures found an intentional Lexxy room-script difference and newly fixed view/upload cases; these results do not clear the final revision. See [browser evidence](m8-t3-browser.md). |
| Cable and media | Crate-local frame, channel, storage, and media golden fixtures plus live multi-client and upload flows | **M5/M6 local gates passed**: pinned live Cable transport 26/26 and channel steps 47/47; strict media corpus 3/3 and 256 Rails/OCaml storage comparisons pass, plus streamed uploads and purge checks. The `bb49e1e` arm64 image passes 233/233 signed-media cases. |
| Deployment | amd64 and arm64 image inventory, copied-install upgrade, restart, backup/restore, TLS/HTTP2/ACME, rollback, then published manifest and actual ONCE deployment | **Local image gates passed on `bb49e1e`**: both architectures have 321 exact assets, zero inventory issues, copied-install lifecycle, Pebble issuance/renewal, HTTP/2 and TLS Cable restart. M8-T5 remains open; no Git remote, registry target, ONCE CLI or host is available for publication and deployment. |
| Performance and resilience | Shared benchmark with response/write validation, plus memory, concurrency, long-running, and failure-recovery checks | **M8-T4 passed** on clean packaged `d6600ed`: two-round benchmark and 60-second resilience run have exact write audits and no invalid responses. The material Rust/OCaml throughput gap is retained as a release finding. See [performance evidence](m8-t4-performance.md). |

The shared harness requires a disposable server for browser flows because it mutates account,
room, and message state. The benchmark's route contracts validate full decoded responses and
acknowledged writes; throughput without these checks is not release evidence. The Rust parity
inventory's full matrix covers Chromium, Firefox, WebKit, viewports, and light/dark schemes.

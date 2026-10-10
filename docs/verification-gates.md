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
| HTTP and persisted-state contracts | Five-seed route/state comparison plus shared route contracts and acknowledged-write audit | **M3 shared HTTP fixture gate complete on `2a511ac`:** 3,186/3,186 eligible route/state cases and 30/30 positive writes exact, with 354 first-run roles unavailable for lack of a signed fixture. M8-T2's earlier packaged `d6600ed` comparison retained 16 Lexxy room-script differences that this source fixes; ten gzip wire responses and one malformed Caddy path remain scoped asset differences. See [route audit](m3-route-audit.md) and [coverage audit](m8-coverage-audit.md). |
| Browser flows | Shared `bin/browser` against disposable servers: install, live messages, edit, search, permissions, settings, invitation, session transfer | **Shared Chromium smoke and two-tab repeated-edit pass** on the script-free `e4b71e6` build with a mounted-editor readiness wait in verification checkout `b7647b4`. M4-T4 remains open for the complete supported browser gate. See [browser evidence](m4-t4-browser.md). |
| Rust local browser parity | Complete lean and full matrices across seeds, engines, viewports, and schemes; compare HTML, live DOM, accessibility, network, Cable, and pixels | **M8-T3 open**. The pinned inventory expands to 5,890 planned cells across ten seed/matrix combinations. The `2a511ac` five-seed lean matrix is 956/956 exact on applicable layers: 940 page cells compare all six, and 16 pinned fragments compare server HTML only. Its first thirteen default full batches are 4,428/4,428 final passes, bringing completed coverage to 5,384/5,890. Rust-side and OCaml-side WebKit captures each crashed once and passed on retry; one WebKit screenshot matched on its second attempt after a 114-pixel avatar-edge difference. All three cells require fresh first-pass exact recaptures. The remaining full matrix is running. See [browser evidence](m8-t3-browser.md). |
| Cable and media | Crate-local frame, channel, storage, and media golden fixtures plus live multi-client and upload flows | **M5/M6 local gates passed**: pinned live Cable transport 26/26 and channel steps 47/47; strict media corpus 3/3 and 256 Rails/OCaml storage comparisons pass, plus streamed uploads and purge checks. Both final `2a511ac` images pass 233/233 signed-media cases. |
| Deployment | amd64 and arm64 image inventory, copied-install upgrade, restart, backup/restore, TLS/HTTP2/ACME, rollback, then published manifest and actual ONCE deployment | **Local image gates passed on final `2a511ac`**: both architectures have 321 exact assets, zero inventory issues, copied-install lifecycle, Pebble issuance/renewal, HTTP/2 and TLS Cable restart. M8-T5 remains open for the final browser gate and external publication/deployment; no Git remote, registry target, ONCE CLI or host is configured. |
| Performance and resilience | Shared benchmark with response/write validation, plus memory, concurrency, long-running, and failure-recovery checks | **M8-T4 passed** on clean packaged `d6600ed`: two-round benchmark and 60-second resilience run have exact write audits and no invalid responses. The material Rust/OCaml throughput gap is retained as a release finding. See [performance evidence](m8-t4-performance.md). |

The shared harness requires a disposable server for browser flows because it mutates account,
room, and message state. The benchmark's route contracts validate full decoded responses and
acknowledged writes; throughput without these checks is not release evidence. The Rust parity
inventory's full matrix covers Chromium, Firefox, WebKit, viewports, and light/dark schemes.

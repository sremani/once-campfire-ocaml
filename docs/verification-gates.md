# Verification gates

Pinned inputs:

- Rust source: `9872c1d9541551c0889a60e3d49a14488bd1e403`
- Rails reference submodule: `90b330024dec3e757c79b6a7e6568f93da8e3148`
- Shared verification harness: `6f71d70b5e1f17507404ad06cac134aa453a04a6`

The reference and verification checkouts are expected alongside this repository. These gates
apply to the finished port; their current absence is a known incomplete state, not a waiver.

| Gate | Required evidence | Status |
| --- | --- | --- |
| OCaml build and unit/integration tests | Clean `dune build` and `dune runtest`, with every subsystem's malformed-input, permission, and persistence cases included | Foundation passes; full suite pending |
| Rails/Rust golden vectors | Every relevant suite in Rust `vectors/` plus crate-local golden/corpus fixtures, including rejection cases | Cookie/route subset passes; remainder pending |
| Existing installation | Start against a copy of Rails storage and secrets; verify users stay signed in and messages, attachments, memberships, and search survive writes/restarts | All five Rails parity seeds built. OCaml checks the default seed's required tables (one account), and M1 authenticates a Rails-issued cookie against a seed copy. Full upgrade/write/restart checks pending |
| HTTP and persisted-state contracts | Shared `once-campfire-verification` route contracts and acknowledged-write audit against a disposable OCaml server | Pending |
| Browser flows | Shared `bin/browser` against a fresh disposable server: install, live messages, edit, search, permissions, settings, invitation, session transfer | Pending |
| Rust local browser parity | `parity/bin/compare` lean matrix during development and full matrix for release; compare HTML, live DOM, accessibility, network, Cable, and pixels | Pending |
| Cable and media | Crate-local frame, channel, storage, and media golden fixtures plus live multi-client and upload flows | M6 storage/media complete: strict corpus 3/3 in both pinned Rails and packaged OCaml media images; 256 live Rails/OCaml storage comparisons with zero mismatches, plus streamed multipart and after-commit purge tests. Complete Cable protocol and multi-client verification remains pending |
| Deployment | amd64 and arm64 Docker/ONCE upgrade, restart, backup/restore, TLS/HTTP2/ACME, and rollback checks | Both local image architectures and copied Rails upgrade/restart/backup/restore/rollback pass; live HTTP/2, long-lived Cable, and ACME initial/second issuance pass. Genuine prior Thruster certificate storage, actual remote ONCE deploy and published manifest remain unverified |
| Performance and resilience | Shared route benchmark with complete response/write validation, plus memory, concurrency, long-running, and failure-recovery checks | Pending |

The shared harness requires a disposable server for browser flows because it mutates account,
room, and message state. The benchmark's route contracts validate full decoded responses and
acknowledged writes; throughput without these checks is not release evidence. The Rust parity
inventory's full matrix covers Chromium, Firefox, WebKit, viewports, and light/dark schemes.

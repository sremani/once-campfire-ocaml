# M7 front server, operations, and deployment audit

Pinned baseline: Rust `9872c1d9541551c0889a60e3d49a14488bd1e403` and Rails
`90b330024dec3e757c79b6a7e6568f93da8e3148`. All three local tickets are verified. The milestone's
remote ONCE deployment gate remains open. The `v0.1.0` GHCR manifest and both
published architecture images have passed the independent release checks in
[M8-T5](m8-t5-release-audit.md).

## T1 review after handoff

The [T1 handoff](m7-t1-handoff.md) records eight focused tests and live local
HTTP/1.1, HTTP/2 TLS, h2c, redirects/421, 413, WebSocket 101, Pebble ACME
TLS-ALPN-01 and EAB HTTP-01, and imported-certificate fingerprint reuse. The
manager reran `dune build bin/main.exe bin/front.exe test/m7_t1_test.exe` and
the live suite with Caddy; all eight pass, including Cable beyond one-second
HTTP deadlines. The saved resilience checks now pass for direct read, idle and
body deadlines, oversized headers, a progressing upload, and graceful stop.
The manager also reran local Pebble ACME renewal: initial and near-expiry
certificates had distinct fingerprints, and Pebble issued a second certificate.
T2 verified the direct target's scheme semantics against Rust production's
`assume_ssl` behavior. T3 pinned Caddy in both image architectures. These close
T1's implementation and local compatibility checks. A genuine prior Thruster
certificate cache was unavailable in the pinned fixtures, so old-install TLS
continuity is supported by an import of a certificate assembled in Thruster's
documented combined PEM layout; a real old-install cache remains a deployment
gate fixture limitation. Natural expiry of a CA-issued short leaf was not
available in Pebble; the renewal check replaced the cached leaf with a
five-minute leaf signed by the same disposable CA before a second ACME order.

## T2 review after handoff

The [T2 handoff](m7-t2-handoff.md) records eight focused tests and the saved
`scripts/m7_live_ops_check.py` run against a disposable pinned Rails seed. The
manager reran `dune build bin/main.exe bin/front.exe test/m7_t2_test.exe` and
`dune exec test/m7_t2_test.exe`; all eight pass. The live check reports an
integrity-clean backup/restore retaining 169 messages, direct production
`/up` 200 with HSTS, trusted-front HTTP redirect, authenticated Cable
`server_restart`, and successful SIGTERM/SIGINT exits. T2 resolved the direct
target behavior against Rust's production `assume_ssl`: direct plain HTTP is
treated as HTTPS, while trusted front requests explicitly marked HTTP are
redirected. A later manager audit exposed and fixed an `EEXIST` race in
`Runtime_ops.ensure_directory` under concurrent backups. Four simultaneous
`campfire backup` invocations against a copied Rails seed all succeeded; the
snapshot retained 169 messages, passed integrity, and left no partial files.
The new four-worker regression passes, raising the T2 focused suite to ten
cases. `scripts/m7_resilience_check.py` verifies an in-flight request finishes
after SIGTERM and a held request is abandoned after 10.03 seconds with exit 0.
The integrated `App_jobs`/Web Push shutdown test blocks an outbound delivery,
checks that a short deadline reports incomplete, releases the transport, and
checks full drain. These close T2's local stress checks. T3 subsequently wired
the image boot and ONCE hooks, as reviewed below.

## T3 review after handoff

The [T3 handoff](m7-t3-handoff.md), [Dockerfile](../Dockerfile), and
[deployment guide](deployment.md) record Debian trixie runtime pins for Caddy
2.6.2-12+deb13u1, libvips 8.16.1-1+deb13u1, and ffmpeg
7:7.1.5-0+deb13u1. The manager inspected the final Docker image IDs:
`sha256:4a4c24c2425bc31c9cc1e5bcf026f88ab7358c7d5fcb57a7ba1fe0dd3cec8500`
for amd64 and
`sha256:d7649972b7143ac106326ec38c32baa715c8f4529b6223823c355c1846f14426`
for arm64. Both report uid/gid `1000:1000`, `/rails`, and `bin/boot`. The
post-restore hook is byte-identical to the pinned Rails hook. `git diff --check`
and Python script compilation pass.

The manager reran `scripts/m7_image_lifecycle.py` independently against each
final image. Both report old Rails, upgrade, restart, and rollback `/up=200`,
OCaml SIGTERM exit 0, 14 unchanged blob SHA256 checksums, 169 unchanged
messages, the two Rust-matching additive indexes, and clean backup/restore
integrity with unchanged table definitions. T3 is complete for the ticket's
local image, deployment configuration, and copied-install upgrade/rollback
requirements. The GHCR workflow and a real remote ONCE deployment have not
run; those remain in the milestone/release gate because registry credentials,
ONCE CLI, and a target host are unavailable in this workspace. The pinned
Rails image's immediate stop after startup caused a disposable fixture failure
in T3's initial check, so the final lifecycle waits for its workers to settle;
extended shutdown stress remains an M8 resilience check.

## M7-T1 — Front server and TLS

Rust `crates/kit/src/front.rs` and `front/{config,conn,handler,tls,acme,cache,compression}.rs`
define the contract. HTTP_PORT defaults to 80, HTTPS_PORT to 443, TARGET_PORT to
3000 on loopback. HTTP mode offers HTTP/1.1, with optional h2c prior knowledge;
TLS_DOMAIN enables ACME, HTTP-01 redirects/challenges on the HTTP port, and
HTTP/1.1 plus HTTP/2 ALPN on the HTTPS port. The front enforces read/write/idle
timeouts, MAX_REQUEST_BODY, forwarded-header trust, request logging, compression,
and a bounded public response cache. `THRUSTER_` variables take precedence over
unprefixed names. Existing autocert keys/certificates live under
`storage/thruster`; preserve valid certificates and renewal continuity.

OCaml uses `cohttp-lwt-unix` 5.3.0 and `conduit` 6.2.1 for its loopback
HTTP/1.1 target (`lib/http_app.ml`, `bin/main.ml`); `lib/http_cache.ml` and
`lib/http_gzip.ml` keep cache/compression in the app. Debian Caddy 2.6.2 is
the established protocol front for HTTP/2 and ACME. `Front_proxy` now applies
a trusted boundary to client IP, host, and scheme, and strips private marker
headers. The host `ocamlfind` exposes no HTTP/2 or ACME package.

The pinned `crates/kit/tests/front.rs` live socket cases are
`caches_public_responses`, `caches_streamed_responses_of_declared_length`,
`bypassed_requests_repeat_vary`, `compresses_what_the_app_left_unencoded`,
`forwards_client_addresses`, `the_app_still_listens_on_the_target_port`,
`the_target_port_is_loopback_only_and_limited`, `limits_request_bodies`,
`closes_idle_and_slow_connections`, `http2_connections_close_after_the_idle_timeout`,
`websockets_pass_through_and_outlive_the_timeouts`, `speaks_h2c_only_when_enabled`,
and `acme_tls_alpn_certificate_cached_and_reused`. Recreate the applicable cases
against the deployed OCaml front, not only a configuration generator.

## M7-T2 — Runtime operations

Rust `crates/campfire/src/app.rs`, `crates/kit/src/server.rs`, and
`crates/campfire/src/config.rs` define boot, logging, graceful SIGTERM/SIGINT,
WebSocket restart notification, a 10-second request/job grace, and `backup`.
`/up` already exists in OCaml (`lib/controller_aux.ml`). `lib/config.ml` has the
Rails storage paths and secret handling, while `Db_runtime.backup_to` uses SQLite
`VACUUM INTO` because the installed OCaml binding's backup API crashed on the
pinned fixture. The ticket needs a `backup` command that writes a consistent
snapshot to `storage/backups/<env>.sqlite3` through a temporary file and atomic
rename, failure cleanup, a restore check, boot-time connected-state reset, signal
handling, and supervised job/Cable shutdown. Logs should use the installed
`logs` 0.7.0 package, pinned in `dune-project`, or another established logger.
Compare the actual Rust env defaults and CLI contract in tests.

## M7-T3 — Container and ONCE

Rust `Dockerfile` is the image compatibility specification: Debian trixie,
`/rails` workdir, uid/gid 1000, storage at `/rails/storage/{db,files,backups}`,
`/rails/storage/thruster`, `bin/boot`, `/hooks/pre-backup`,
`/hooks/post-restore`, `RAILS_ENV=production`, ports 80/443, and APP_VERSION and
GIT_REVISION. It pins libvips 8.16.1-1+deb13u1 and ffmpeg
7:7.1.5-0+deb13u1 source checksums. The Rust release workflow builds separate
amd64/arm64 images and a multi-arch manifest. The Rails post-restore hook copies
the backed-up database over the live database and removes its `-wal` and `-shm`.
An OCaml image must include all runtime OCaml libraries, media tools, CA store,
the proxy selected by T1, and the existing asset corpus, while preserving those
paths and hooks. Test old-image to OCaml-image upgrade, OCaml restart, backup and
restore, and rollback to the Rust/reference image on a copied seed with blob files.
No migration or destructive rewrite of live storage is permitted.

## Current availability and open checks

- The development host has Docker, Podman, and OpenSSL. The production image
  pins Debian Caddy 2.6.2-12+deb13u1; T1 validated Caddy 2.6.2 locally and T3
  validated the Debian package in both final image architectures.
- `opam` is not on PATH. Dune and `ocamlfind` are available, so dependency pins
  should be made in `dune-project`/the generated opam file and confirmed in the
  image build.
- M7's local HTTP/1.1, HTTP/2, initial and second ACME issuance, direct
  phase deadlines, long-lived Cable, restart, copied-install backup/restore
  and rollback, and both final image architectures have passed. The remaining
  gate is a published multiarchitecture manifest and real ONCE deployment on
  preserved storage and secrets; no registry credentials, ONCE CLI, or target
  host are available here. A genuine prior Thruster certificate cache is also
  absent from the pinned fixtures, so this specific import path remains
  unverified beyond the documented-format PEM test.

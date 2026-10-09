# M8-T4 performance and resilience record

Status: **open**. The shared adapter and independent route-contract preflight are
ready. Final throughput and packaged-image resilience require a fresh image from
a stable source snapshot. No provisional rate below is a release comparison.

## Shared benchmark setup

The independent verification checkout now accepts `ocaml` in `bench/compare.rb`.
`OCAML_IMAGE` and `OCAML_BENCH_ENV` select its image and runtime settings. The
adapter retains image-ID and source-revision checks across rounds, copies the
seed for each run, records Caddy/Cohttp topology, and mounts disposable
`/rails/storage/{db,files,logs,thruster}`. Route contracts and acknowledged-write
audits remain the shared validators. Its ignored `tmp/bench` directory holds all
raw outputs. `bin/check` passes in `campfire-m8-check:pinned` (Rust 1.98.1,
Ruby 3.3, Node 22) after the adapter, its tests, and strict UTF-8 response
validation were added.

The fixture came from pinned Rails revision
`90b330024dec3e757c79b6a7e6568f93da8e3148`, reference image
`sha256:6c7b40625835c7c86a428a8d4074614ec56a58e69066669387efbb3401d2dc0a`.
The fixture database SHA-256 is
`03313d985beb5e06d657728591e4526429840cc8f17b299b3058df8134a66d67`;
the release loadgen binary SHA-256 is
`8997721370a9d9fc321ba09ce5f1a7396d9e5527d4694fab8b2ab0a8c4a2b6b3`.
Credentials and generated seed stay in ignored `fixtures/default`.

The provisional two-round `bin/benchmark --apps rust,ocaml --preflight` passed
the seven GET contracts and built the POST target contract in each of four
isolated app runs. The zero-write database audit passed. Rust image ID was
`sha256:c45786de2e6c7169129edd6bc6e0607c99cc768a1c4d19046f208c376d5822a3`;
OCaml image ID was
`sha256:3cb22d67a64a5e226ded7e680b4cd26a5571ebcc13992365b738ad1c631accbe`.
The OCaml source was dirty at HEAD `cbf7bb5412e725a6705a76aa6f24f82bb4f912a8`.
Raw preflight output: `once-campfire-verification/tmp/bench/m8-t4-preflight/`.
This `campfire-candidate:latest` image is a direct app listener with a short
single-process boot script and **does not contain Caddy**. Its preflight is
useful for application contracts only.

The clean packaged `189d1ed` image then passed the shared two-round preflight
at verification commit `c39d51d`: Rust and OCaml each passed all eight route
contracts and the zero-write database audit in both isolated rounds. The OCaml
checkout was clean at the image's `GIT_REVISION`, and the harness marked the
source/image pairing release-comparable. This is a contract preflight, not a
timed throughput result. Raw output and source/image identities are in
`once-campfire-verification/tmp/bench/m8-t4-189d1ed-preflight-0930/`.

## Provisional direct-listener resilience

`scripts/m8_t4_resilience.py` defines bounded criteria before the run: four
concurrent validated loadgen workers with four clients each for eight seconds,
two independent POST rooms and exact acknowledgement audits; two Cable
subscribers with complete fanout; slow/disconnected and malformed/oversized
requests; sixty seconds of resource sampling with a 1 GiB/PID bound; then
SIGKILL/restart and backup/restore with integrity and acknowledged-write checks.
The fixture, audit files, container logs, and results use isolated ignored
storage and port 26380. The image and seed digests are saved in each summary.

The first direct-listener run completed its concurrency and Cable stages before
the header-limit assertion stopped it. It recorded 11,229 validated fixed-window
room reads, 18,437 validated searches, 6,567 acknowledged writes in HQ, and
6,584 acknowledged writes in Watercooler. All four HTTP samples had zero errors
and zero invalid responses; the 13,151 writes matched the two room row deltas
and each acknowledgement's exact Action Text and FTS body. SQLite integrity was
`ok`. Both Cable subscribers connected, and all five paced and 8,875 saturated
posts were delivered to both subscribers and persisted. These are workload
observations for the direct listener, **not** comparative throughput or packaged
release evidence. Raw result:
`once-campfire-verification/tmp/bench/m8-t4-resilience-1791531817-3055/`.
The sustained-resource and recovery stages were not reached, so the ticket
remains open.

The old packaged `campfire-ocaml:m7-t3` image
(`sha256:4a4c24c2425bc31c9cc1e5bcf026f88ab7358c7d5fcb57a7ba1fe0dd3cec8500`,
`GIT_REVISION=local`) boots the two-process Caddy plus OCaml stack. Its full
resilience run stopped at the independent room-show contract: HTTP 406 on a
request that must be HTTP 200. The current source has since received HTTP
negotiation fixes; that old image cannot establish the current release gate.
The raw stopped run is in
`once-campfire-verification/tmp/bench/m8-t4-resilience-1791531966-29576/`.

Separate probes against that old packaged image sent fresh HTTP sockets with
65 KiB and 1 MiB `X-Fill` headers to an application room path. Both the Caddy
front and its direct loopback target returned the ordinary anonymous 302 for
those requests. The target was not reachable via the host's non-loopback
interface. Current `Front_target` source counts a 64 KiB header limit in its
injected Cohttp `read_line`; the old image predates that fix. Raw old-image probes are in
`once-campfire-verification/tmp/bench/m8-t4-resilience-1791532038-43580/`
and `...-1791532048-45515/`.

The clean `189d1ed` packaged image (`sha256:4636f3e8e077786aa1bec9c637dc139d375202caa0c1873c56eb4d6a00df10a0`)
showed why the first 65 KiB header probe still failed: Caddy returned 502
after the target closed, while a 72 KiB header was rejected at Caddy. Its
adapted JSON contained `max_header_bytes: 65536`, but Go's HTTP reader allows
roughly 4 KiB of parser slack above that value. A disposable build with
`max_header_size 60KiB` returned 431 at Caddy, closed the target connection,
returned normal 302s at both listeners, and kept the target private for the
65 KiB probe. The source now uses that tested setting; rebuild a clean image
before treating the result as a release gate. Raw experimental probe:
`once-campfire-verification/tmp/bench/m8-t4-resilience-1791537447-2402214/`.

The same disposable `campfire-ocaml:header-60k` image
(`sha256:73b0b1deeb1cd648ae646dfba9b3bfa887fb7ccb17e67434ed6ac469ebe7a6c7`)
completed the full provisional resilience script. Its four simultaneous
eight-second validated workers returned 43 room reads, 56 searches and 79
acknowledged writes across two rooms, all with zero errors or invalid responses.
Exact Action Text, FTS, room-count and SQLite-integrity audits passed. Two Cable
subscribers received all five paced and 353 saturated posts. Slow, malformed,
oversized-body and 65 KiB-header requests returned 504, 400, 413 and 431;
20 disconnected clients left health at 200. During the 60-second sustained run,
15,051 validated room reads completed with peak memory 108,842,189 bytes and
79 PIDs. SIGKILL/restart, backup/restore, integrity and acknowledged-write
audits passed; the restored database held 606 messages. The raw summary and
supporting artifacts are in
`once-campfire-verification/tmp/bench/m8-t4-resilience-1791537692-2473296/`.
The disposable image is a diagnostic build, so this establishes a complete
provisional workload pass, not a final release or comparative throughput result.

## Validator hardening before the release run

The shared benchmark update at local verification commit `c39d51d` records a SHA-256 manifest of tracked and
non-ignored untracked source files before and after every app round. It rejects
source edits between rounds. For a release-comparable OCaml run, the checkout
must be clean and the packaged image's `GIT_REVISION` must equal its Git HEAD.
`--allow-dirty-source` permits an explicitly provisional check and marks its
summary `release_comparable: false`. Image IDs, fixture SHA-256 and loadgen
SHA-256 remain in the summary. The pinned toolchain's complete `bin/check`
passed after this change, including the new source-identity tests.

The standalone `--header-probe` now passes only when normal anonymous room
requests redirect through both listeners, a header above 64 KiB is rejected
by both listeners, and the target is unreachable through the host's non-loopback
interface. A socket timeout fails the probe. Four focused offline Python tests
pass; the final clean image still needs the live probe.

After the source is committed and the packaged image built with that HEAD as
`GIT_REVISION`, run the checks in this order, during a quiet Docker interval:

```sh
cd /home/srikanth/projects/once-campfire-verification
docker run --rm --tmpfs /tmp:rw,exec,nosuid,nodev,size=1g \
  --mount type=bind,src=/home/srikanth/projects/once-campfire-verification,dst=/verify,readonly \
  --workdir /verify -e CARGO_TARGET_DIR=/tmp/loadgen-target \
  campfire-m8-check:pinned bin/check
benchmark_in_toolchain() {
  docker run --rm --network host \
    --user "$(id -u):$(id -g)" --group-add "$(stat -c '%g' /var/run/docker.sock)" \
    --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
    --mount type=bind,src=/usr/bin/docker,dst=/usr/bin/docker,readonly \
    --mount type=bind,src=/home/srikanth/projects,dst=/home/srikanth/projects \
    --workdir /home/srikanth/projects/once-campfire-verification \
    -e OCAML_IMAGE=campfire-ocaml:m8-rc \
    campfire-m8-check:pinned bin/benchmark "$@"
}
benchmark_in_toolchain --apps rust,ocaml --rounds 2 --preflight --output tmp/bench/m8-t4-rc-preflight
cd /home/srikanth/projects/once-campfire-ocaml
python3 scripts/m8_t4_resilience.py --image campfire-ocaml:m8-rc --header-probe
python3 scripts/m8_t4_resilience.py --image campfire-ocaml:m8-rc --duration 60
cd /home/srikanth/projects/once-campfire-verification
benchmark_in_toolchain --apps rust,ocaml --rounds 2 --duration 8 --concurrencies 16 --output tmp/bench/m8-t4-rc-timed
```

If a source edit is required during exploratory work, add
`--allow-dirty-source` to `bin/benchmark` and keep that run labeled provisional.
Use a unique output directory for each rerun; the benchmark refuses to
overwrite results.

## Clean `ff61768` candidate and body-timeout diagnosis

The clean amd64 image `campfire-ocaml:rc-ff61768-amd64`
(`sha256:0abeb89774d45a8cdd58dbe23d35ddedfd3867c87f7fe1c0960620ca0994051f`)
passed two alternating Rust/OCaml shared preflight rounds. All eight route
contracts and zero-write audits passed in each isolated run. The OCaml source
was clean, its HEAD matched the image's `GIT_REVISION`, and the summary marked
the run `release_comparable: true`. The packaged header probe passed: both
listeners redirected an ordinary anonymous room request, the front rejected a
65 KiB header with 431, the target closed it, and the target was private to
loopback. Raw results are in
`once-campfire-verification/tmp/bench/m8-t4-ff61768-preflight-clean/` and
`m8-t4-resilience-1791543801-680639/`.

The full resilience script reached its slow-body check twice after validated
concurrent reads, searches and exact writes in two rooms, plus complete Cable
fanout. Both runs failed because an incomplete `POST /up` returned **HTTP 200
with an empty body**. A separate raw-wire probe showed the failure was generic:
incomplete POSTs to `/up`, `/session` and `/messages` all received Caddy's
`Server`, `Date`, `Content-Length: 0` and `Connection: close` headers with 200;
the direct OCaml target closed without a response. See
`/tmp/campfire_m8_t4_diag/route-wire.json` and the stopped run at
`once-campfire-verification/tmp/bench/m8-t4-resilience-1791544655-1193770/`.
Caddy 2.6.2 rejected `reverse_proxy request_buffers 1MiB`; a route fallback,
`handle_errors`, `request_body max_size`, and disabling upstream keepalive did
not prevent the empty 200 under the warmed workload. A disposable Caddy with
no front `read_body` deadline avoided the false 200, but the unmodified target
could leave an incomplete request unanswered. The target therefore needs to
send a response on its own per-read timeout.

In an isolated `ff61768` worktree, `Front_target` was changed to return an
empty 408 and close the connection when a body read times out, including
timeouts while draining a body. The Caddy `read_body` deadline was removed;
the target retains the full configured `HTTP_READ_TIMEOUT` for **each** body
read. The experimental image `campfire-ocaml:target408-noread-exp`
(`sha256:228249fed4b77261d44d12ca1385bee790a0777d7f053c30b43be222d9bc6e2a`)
returned 408 through its packaged Caddy and directly on all three incomplete
POST routes. Its header probe and full resilience run passed. The full run
recorded 39 room reads, 57 searches and 39 plus 40 acknowledged writes with
zero errors or invalid responses; both Cable subscribers received all five
paced and 333 saturated posts. Other request probes returned 400 for malformed
JSON, 413 for an oversized body and 431 for a large header. The 60-second
sample completed 11,707 validated reads with peak memory 50,090,476 bytes and
79 PIDs. SIGKILL/restart, backup/restore, SQLite integrity and exact write
audits passed; the restored database held 586 messages. Raw results are in
`once-campfire-verification/tmp/bench/m8-t4-resilience-1791546000-1531405/`
and `m8-t4-resilience-1791546005-1533737/`.

The same experimental image accepted a progressing 135,266,441-byte multipart
body over 25.86 seconds through Caddy and 25.85 seconds directly; both returned
the expected 404 after parsing the complete request. The payload was sent in
129 one-MiB chunks with a 0.2-second interval, under ordinary 60-second idle
and 300-second write settings. With Caddy's old absolute `read_body 2s`, the
front instead broke the transfer at 10 MiB after two seconds and returned the
empty 200. Raw results: `/tmp/campfire_m8_t4_diag/upload129-target408-noread.json`
and `/tmp/campfire_m8_t4_diag/upload129.json`. Under deliberately shortened
two-second idle and five-second write settings, the full body could be sent
but the front closed without a final response; those settings do not establish
the long-upload gate.

Only `lib/front_target.ml` and `lib/front_config.ml` were copied from the
proven worktree into the main checkout. `dune build bin/main.exe bin/front.exe @check`,
eight focused M7-T1 tests, direct stalled-body and progressing-upload
checks, and `git diff --check` passed after integration. The experimental image
was built from an uncommitted worktree and is **not** a release comparison.
The integrated changes still need a clean committed image, repeat preflight
and resilience, then the timed alternating benchmark.

## Remaining gate

Build one fresh packaged OCaml image after M3/M4 source edits settle. Repeat
the eight-route contract preflight and full resilience script on that image,
including the Caddy header cap, sustained memory/PID samples, crash/restart,
and backup/restore. Run at least two alternating timed Rust/OCaml benchmark
rounds with the same 8–11 server and 12–15 client CPUs, 16 clients, seed hash,
and image IDs. Publish rates and latency only from samples with zero invalid
responses, complete response contracts, exact acknowledged-write audits, and
SQLite integrity.

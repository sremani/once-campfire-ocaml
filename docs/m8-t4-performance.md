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
injected Cohttp `read_line`; the discrepancy needs a fresh-image retest before
changing target parser logic. Caddy now explicitly emits
`max_header_size 64KiB` in the current source. Caddy 2.6 accepted that syntax
with a 65,536-byte parsed limit, and the focused M7 configuration test passed
8/8. Raw old-image probes are in
`once-campfire-verification/tmp/bench/m8-t4-resilience-1791532038-43580/`
and `...-1791532048-45515/`.

## Validator hardening before the release run

The pending shared benchmark update records a SHA-256 manifest of tracked and
non-ignored untracked source files before and after every app round. It rejects
source edits between rounds. For a release-comparable OCaml run, the checkout
must be clean and the packaged image's `GIT_REVISION` must equal its Git HEAD.
`--allow-dirty-source` permits an explicitly provisional check and marks its
summary `release_comparable: false`. Image IDs, fixture SHA-256 and loadgen
SHA-256 remain in the summary. This update still needs Ruby checks in the
pinned toolchain before any final benchmark.

The standalone `--header-probe` now passes only when normal anonymous room
requests redirect through both listeners, a header above 64 KiB is rejected
by both listeners, and the target is unreachable through the host's non-loopback
interface. A socket timeout fails the probe. Four focused offline Python tests
pass; the fresh packaged image still needs the live probe.

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

## Remaining gate

Build one fresh packaged OCaml image after M3/M4 source edits settle. Repeat
the eight-route contract preflight and full resilience script on that image,
including the Caddy header cap, sustained memory/PID samples, crash/restart,
and backup/restore. Run at least two alternating timed Rust/OCaml benchmark
rounds with the same 8–11 server and 12–15 client CPUs, 16 clients, seed hash,
and image IDs. Publish rates and latency only from samples with zero invalid
responses, complete response contracts, exact acknowledged-write audits, and
SQLite integrity.

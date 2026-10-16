# Performance escalation plan

The [2026-10-16 HTTP timer and output-buffer measurements](performance-http-timer-buffer-2026-10-16.md)
provide a newer grown-seed, identity-encoded five-route result. The older
numbers below use different images and benchmark windows; use the newer
evidence when assessing the F# comparison.

The [2026-10-13 profile and refactor review](performance-refactor-review-2026-10-13.md)
supersedes this document's baseline and sets the next action: complete CPU,
allocation, GC, and queue profiling, then refactor along the measured hot path.
It also separates product/browser and migration contracts from Rails/Rust
presentation parity. The rungs below remain hypotheses until that profile.

## Goal and decision rule

Reach at least **85% of Go's throughput on each of the four authenticated GET
routes and message POST** in the shared, same-host benchmark. A candidate must
also pass response contracts, exact acknowledged-write audits, Cable behavior,
and resilience checks. Do not trade correctness for requests per second.

The latest validated OCaml 5.5.1 versus Go comparison, at 16 clients and four
server cores, puts OCaml at 8.7% of Go on room show, 5.7% on messages page,
8.5% on sidebar, 6.9% on search, and 14.2% on message POST. Those values are a
starting point, not fixed acceptance thresholds. Raw data:
`once-campfire-verification/tmp/bench/perf-go-ocaml55-committed-20261010/`.

For every rung below, build an immutable candidate and compare it with the
immediately preceding image in alternating A/B/B/A order on a quiet host.
Use the same seed, client and server CPU sets, load generator, route contracts,
and 16-client/four-core setup. Include one-client runs to separate per-request
cost from scaling. Record throughput, p50/p95 latency, app and Caddy CPU,
allocations/GC, RSS, error counts, and image/source hashes. Repeat a promising
result until the gain exceeds observed run-to-run variation. Promote a change
only when all correctness gates pass and the relevant routes improve reliably.
If a rung does not meet its gate, retain its evidence and move to the next
mechanism without carrying an unproven request-path change.

## Rung 0: locate the cost

Profile the released OCaml 5.5.1 image under the shared benchmark. Measure
direct Cohttp and Caddy paths for `/up`, static CSS, room show, messages page,
and POST; collect CPU profiles, allocation samples, and time spent waiting for
SQLite readers and the writer. Compare one and 16 clients. The output is a
ranked cost breakdown for HTTP parsing/writing, authentication, database work,
view construction, compression, and proxying. This gate decides the order of
the next two rungs; it does not claim a performance gain.

## Rung 1: reduce work per request

Make one focused change at a time to the measured hot path. Candidates include
Cohttp response writing and connection handling, repeated header/cookie work,
authentication reads, cache lookups, template allocations, and SQLite query
shape. Prior buffered-listener work improved throughput materially, while a
fresh-session reader experiment was inconclusive; use those results to avoid
repeating an unmeasured optimization. Preserve wire headers, authenticated
cache rules, session revocation, and exact writes.

**Gate:** a repeatable gain beyond the A/B/B/A noise band on the route the
change targets, with no regression on the other required routes or p95 latency.
If the app still saturates one core at 16 clients, proceed to whole-request
parallelism even if this rung helps single-client speed.

## Rung 2: parallelize whole requests with Lwt worker processes

Run two, then four independent OCaml application processes behind Caddy. Each
worker owns its Lwt loop, SQLite connections, and request caches. Use the
existing SQLite WAL database and keep only one background-job owner. Add a
cross-worker Cable bus for broadcasts and user disconnects. Verify that cache
generation changes and session revocations are visible to every worker.
Treat SQLite writer contention, memory per worker, and connection balancing as
measured limits. Existing libraries should provide the IPC or Pub/Sub layer
where practical.

**Gate:** demonstrate increasing validated throughput from one to two to four
workers on the same four cores. In addition to the shared HTTP benchmark, run
two-client Cable fanout across different workers, remote disconnect, session
revocation, cache invalidation, concurrent writes, shutdown, backup/restore,
and a sustained soak. If scaling flattens, use the CPU and SQLite wait data to
choose the next rung.

## Rung 3: address the bottleneck exposed by worker scaling

If GETs scale but POST does not, shorten the measured SQLite writer critical
section, reduce unnecessary writes and indexes, and revisit transaction/query
shape while preserving commit and event ordering. If HTTP parsing or response
writing dominates, replace only the front transport behind the existing
controllers and compare direct-listener and Caddy results. If Caddy dominates,
tune or simplify that hop without changing trusted-proxy semantics.

**Gate:** the same response, write, Cable, and resilience checks as rung 2,
plus a repeatable improvement on the route identified by profiling. Keep the
single-file SQLite storage and ONCE backup contract unless a separate product
decision authorizes a storage change.

## Rung 4: evaluate a domain-native request runtime

Use this rung if whole-request parallelism or per-request cost remains short
of the 85% target after the earlier changes. Prototype a full `/up` and one
authenticated GET request on a runtime with an independent event loop in each
OCaml 5 domain. Evaluate existing Eio/HTTP libraries and Async only after
proving the chosen scheduler actually runs concurrent listeners in separate
domains. Measure a real route, not a fixed-body synthetic server, before
porting the remaining controllers. Migrate route groups incrementally and
retain the shared contract suite as the compatibility gate.

Lwt 6.1.2 rejected concurrent `Lwt_main.run` calls in separate domains, and
offloading only room/message rendering produced no isolated throughput gain.
Those experiments are recorded in [performance-go-target.md](performance-go-target.md).
The domain-native path therefore needs a different request scheduler, not
another rendering pool.

**Gate:** full route and write parity, cross-domain Cable behavior, resilience,
and repeatable same-host throughput toward the 85% target. If the prototype
does not beat the process model after its added complexity is counted, keep the
process model.

## Completion

Stop escalating when every required route reaches at least 85% of Go in a
validated same-host comparison and the Cable, write, backup, and resilience
gates pass on the release image. Publish the exact image digests and raw
summaries so the result can be reproduced.

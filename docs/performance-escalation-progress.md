# Performance escalation progress

## Rung 0: request-path measurements (2026-10-10)

The OCaml 5.5.1 target was instrumented with opt-in `CAMPFIRE_PROFILE=1`
aggregate timings. The shared benchmark validated every timed response and its
exact POST write count. Raw runs are in the verification workspace under
`tmp/bench/ocaml55-profile-up-r0b-20261010/` and
`tmp/bench/ocaml55-profile-room-r0d-20261010/`.

At 16 clients, room show spent approximately 1.1 ms of elapsed time per
request in the before action and 0.5 ms in the action. Its before action queued
one SQLite writer job for authentication and two reader jobs. The writer job
itself took about 0.10 ms while queue plus execution took about 0.65 ms; the
two reader jobs together took about 0.46 ms including queue time. These are
overlapping wall times under load, not additive CPU costs. The `/up` action
took under 1 µs while its route wrapper took about 26 µs. HTTP request-read
timings include idle keep-alive time and cannot be interpreted as CPU time.

The host denies `perf stat` (`perf_event_paranoid=4`), so kernel CPU samples
are unavailable. Direct-listener/Caddy and allocation comparisons remain on
the rung-0 measurement list.

## Rung 1: fresh-session authentication on a SQLite reader

Fresh sessions now verify the session and load the user in one SQLite reader
job for every HTTP method. If the hourly activity update is due, they retry
on the writer and retain the original cookie refresh behavior. Unsafe methods
still check the IP ban on the reader; their action writes still use the writer.
The `CAMPFIRE_AUTH_READ=0` switch compares the old authentication path with
the new one in the same candidate binary. The table below predates the
extension from GET/HEAD to all methods.

The four-run A/B/B/A comparison used the same image digest
`sha256:71a485b66d6fe7d6df5f720e0c40dfcbfb08757c31f635b609677604691c291c`,
seed, pinned load generator, four server cores, 16 clients, two four-second
rounds per run, and Caddy. A is the writer path; B is the reader path. Values
below are the mean of each pair's two run medians in requests per second:

| Route | Writer A | Reader B | Change |
| --- | ---: | ---: | ---: |
| Room show | 4,446 | 4,774 | +7.4% |
| Messages page | 3,204 | 3,383 | +5.6% |
| Sidebar | 5,335 | 6,178 | +15.8% |
| Search | 4,029 | 4,271 | +6.0% |
| Message POST | 928 | 953 | +2.8% |

Both B runs exceeded both A runs on room show and sidebar. Search also
improved, although its A runs varied more. Messages page had one low A sample
(2,757 requests/s), so its quoted gain is not a reliable effect. POST is
effectively unchanged; the code path deliberately remains on the writer. Every
run had zero HTTP errors or invalid responses and passed the exact acknowledged
write audit. The full OCaml 5.5.1 `dune runtest --profile release --force`
suite passed after this change. The first unforced suite invocation had a
transient nonzero exit, and a subsequent unforced and forced invocation passed.

Raw summaries: `once-campfire-verification/tmp/bench/ocaml55-authread-{A1,B1,B2,A2}-20261010/`.

The gain is useful but well short of the 80%-of-Go completion target.

## Rung 2 diagnostic: independent request processes

The disposable `experiments/worker-scale` image runs two or four application
processes behind one Caddy front. This is a scaling probe, **not a deployable
worker design**: each process still owns local Cable subscriptions and job
queues, and process-local rate limits are independent. It is deliberately
kept separate from `deploy/boot`. The two-worker preflight passed. The timed
runs used the same seed, pinned load generator, CPU set and route contracts
as the one-worker run. All responses were valid, and exact POST write audits
passed. Raw summaries are under
`once-campfire-verification/tmp/bench/ocaml55-workers{2,4}-r1-20261010/`.

| Route | 1 worker | 2 workers | 4 workers | 4 workers / Go |
| --- | ---: | ---: | ---: | ---: |
| Room show | 4,823 | 7,139 | 8,822 | 17.1% |
| Messages page | 3,398 | 4,889 | 6,838 | 11.9% |
| Sidebar | 6,133 | 8,234 | 10,744 | 17.0% |
| Search | 4,261 | 6,375 | 6,908 | 11.3% |
| Message POST | 952 | 840 | 791 | 13.3% |

The one-worker numbers in this table are from the second reader-path run
above. A same-image one-worker repeat yielded 4,804 room views/s and 947
POSTs/s; its second round showed host drift on other GETs. The Go denominator
is the committed OCaml 5.5.1/Go comparison. Four workers use the four assigned
server cores but are only 1.6–2.0 times faster than one worker on GETs. The
first four-worker POST run lost 17% as multiple SQLite writers contended.
Messages-page rounds varied substantially. A second, opt-in-profiling
four-worker run yielded 9,560 room views/s and 972 POSTs/s, which shows that
the short POST result is sensitive to host state. Its per-worker snapshots
showed writer jobs around 0.9–1.2 ms each and queue-plus-job time around
3–5.6 ms during mixed room/POST load. Those are elapsed queue times under
contention, not isolated SQLite CPU costs. A repeated profile run showed
writer execution averaging 0.84–0.98 ms per worker and queue-plus-execution
averaging 2.9–3.9 ms. Its eight per-worker raw logs are preserved with the
summary in `tmp/bench/ocaml55-workers4-profile-preserved-20261010/profiles/`.

Same-image public-route runs at one and 16 clients separated a fixed
per-request cost from scaling:

| Route | One worker, one client | One worker, 16 clients | Four workers, one client | Four workers, 16 clients |
| --- | ---: | ---: | ---: | ---: |
| Room show | 4,053 | 4,756 | 3,000 | 9,571 |
| Static CSS | 9,174 | 15,873 | 7,306 | 24,269 |
| `/up` | 6,605 | 11,741 | 5,250 | 18,823 |

Values are two-round averages of validated requests/s; raw samples are under
`tmp/bench/ocaml55-workers{1,4}-public-20261010/`. Four workers reduce
single-client throughput, likely due to extra proxy/upstream handling, and
still leave a large gap on `/up` with no auth or database work. Thus worker
coordination alone cannot meet the completion gate.

An alternating Caddy/direct/direct/Caddy probe on the same disposable
fixture-backed container isolated the `/up` transport boundary. It used the
pinned load generator and CPU sets, gzip, the same OCaml image, and verified
nonempty HTTP 200 responses with zero errors. At one client, Caddy averaged
5,669 requests/s and the direct listener 10,882 (+92%); at 16 clients,
Caddy averaged 8,119 and direct 12,031 (+48%). The Caddy rounds varied
materially, but both direct rounds exceeded both Caddy rounds. Raw samples:
`once-campfire-verification/tmp/bench/ocaml55-direct-caddy-20261010/`.
The direct listener is still far below Go's published `/up` throughput, so
removing the proxy hop cannot close the target gap on its own. The next work
is to shorten the POST writer section and reduce HTTP request cost before
building the cross-worker Cable bus.

## Rung 3 diagnostic: HTTP/af transport

An isolated probe uses the published `httpaf-lwt-unix` 0.7.1 library as the
HTTP parser and writer while calling the same Campfire router. This tests a
real authenticated GET and POST, not a fixed-body handler. The package's
normal server and dependencies are unchanged. The probe has no WebSocket
upgrade, streaming upload, timeout, or graceful-shutdown support, so it
cannot be promoted as a release image. Its pinned preflight passed all route
contracts in `tmp/bench/ocaml55-httpaf-framed-preflight-20261010/`.

The first 16-client timed probe completed with zero errors, zero invalid
responses, and exact POST write counts. Its first round measured 5,796 room
views/s, 3,828 message pages/s, 7,736 sidebars/s, 5,212 searches/s, 936
POSTs/s, 23,535 CSS responses/s, and 14,524 `/up` responses/s. Every route
fell 31–44% in its second round. At that time eight unrelated `cc1` compiler
processes each consumed a full core with affinity covering the benchmark's
CPU set, and host load exceeded 14. That run was inconclusive. Raw samples:
`tmp/bench/ocaml55-httpaf-r1-20261010/`.

On the quieter physical cores described below, the probe was rebuilt from
the same current source as the Cohttp candidate. The paired two-round run
used 16 clients, the same fixture and route order, and passed response
contracts and exact POST write audits. Median requests/s were:

| Route | Cohttp | HTTP/af | Change |
| --- | ---: | ---: | ---: |
| Room show | 6,001 | 7,290 | +21% |
| Messages page | 5,766 | 7,468 | +30% |
| Sidebar | 6,281 | 7,967 | +27% |
| Search | 6,172 | 7,635 | +24% |
| Static CSS | 16,520 | 24,357 | +47% |
| `/up` | 11,458 | 14,911 | +30% |
| Message POST | 618 | 995 | +61% |

The GET and public-route gains are consistent with a substantial HTTP
transport cost. POST is more variable than the table suggests: the same
Cohttp image achieved 921–935 POSTs/s in shorter route selections on the
same CPU sets, so the paired POST difference is **not yet attributable to
HTTP/af**. These are still shared-host, dirty-source development runs.
Raw results: `tmp/bench/ocaml55-{httpaf,cohttp}-current-quietcores-20261010/`.
The next gate is an alternating same-source transport comparison and a
complete Cable, streaming, timeout, and shutdown implementation before any
HTTP/af release candidate.

## Rung 1 follow-up: check the private cache before route reads

The opt-in cache counters in a validated room run showed 10,749 private cache
hits and only nine misses in one round, yet the room action still performed
its membership query before reaching the cache. Raw counters:
`tmp/bench/ocaml55-cache-profile-20261010/profiles/`. The room, messages,
and search actions now ask the existing private cache first. Authentication
still reads the signed session and user on every request; the cached body is
bound to the session and current SQLite data version. On a miss, the original
membership, pagination, and search checks run. A new test removes the current
user's room membership after a cache fill and verifies that neither the room
nor its message page can be served from the cache.

The full OCaml 5.5.1 forced test suite and pinned route preflight passed. In a
profiled candidate run, warm hits reduced room action time to 43–52 µs,
messages action time to 38–40 µs, and search action time to 32–33 µs under
heavy host contention. The reader pool handled approximately one job per
request across those routes, compared with multiple jobs before the change.
Raw counters: `tmp/bench/ocaml55-cache-order-profile-20261010/profiles/`.
The initial run used server CPUs 8–11 and client CPUs 12–15. On HeMan, CPUs
0–15 are separate physical cores and CPUs 16–31 are their SMT siblings. The
unrelated builds mainly occupied physical cores 8–15. We therefore moved the
server to CPUs 2,3,5,6 and the load generator to 0,1,4,7. These are eight
distinct physical cores. Their sibling threads sometimes had competing work,
so the run remains a shared-host measurement, but the new placement is much
less exposed to the builds.

On that placement, two four-second rounds at 16 clients gave the following
median requests/s. The sequence was candidate, released OCaml 5.5.1 image,
candidate repeat; both candidate runs used the same experimental image and
all three runs used the same seed, route contracts, Caddy, and exact POST
write audit. All timed responses were valid with zero HTTP errors.

| Route | Released image | Candidate 1 | Candidate repeat | Candidate mean vs released |
| --- | ---: | ---: | ---: | ---: |
| Room show | 4,080 | 5,442 | 5,464 | +34% |
| Messages page | 3,063 | 5,022 | 5,388 | +70% |
| Sidebar | 4,979 | 5,224 | 5,765 | +10% |
| Search | 3,889 | 5,578 | 5,669 | +45% |
| Message POST | 904 | 921 | 935 | +3% |

The repeat supports a real improvement in the read routes, especially room,
messages, and search. POST is effectively flat. These are combined candidate
changes, so the table does not isolate cache order from reader-path auth.
The image was built from a dirty source tree, making this a development
comparison rather than a release benchmark. Raw summaries are under
`once-campfire-verification/tmp/bench/ocaml55-quietcores-{candidate,baseline,candidate-repeat}-20261010/`.
The candidate is still far below the 80%-of-Go completion target and has not
been deployed.

## Rung 3 follow-up: reuse SQLite statements on the writer (2026-10-13)

The POST writer profile showed roughly 0.94–0.98 ms of execution per message.
Search-index insertion averaged about 0.23 ms, rich-text body insertion 0.14
ms, and unread membership update 0.13 ms. A same-binary A/B/B/A trial that
moved the index and unread updates into the first transaction improved POST
by only about 2%, inside run variation, so that change was removed.

An opt-in bounded prepared-statement cache reduced the writer's measured job
time from about 1.06 to 0.80 ms in an earlier POST-only profile. Caching on
**all** SQLite connections increased POST throughput by 14% but regressed all
four GET routes by 4–10% in the quiet-core five-route A/B/B/A sequence; that
design was rejected. Raw results:
`once-campfire-verification/tmp/bench/ocaml55-sqlcache-all-{A1,B1,B2,A2}-20261013/`.

The cache now applies only to the exclusive writer connection. It keeps at
most 512 compiled statements, falls back to a fresh statement for nested use
of the same SQL, and finalizes statements before closing the connection. The
same-image A/B/B/A comparison used image
`sha256:c014d2ee81a06d9d9d2b4ed35ca55458b6bd11d54b0cef3bda4be9044c4d994b`,
the same pinned fixture, Caddy, server CPUs 2,3,5,6 and client CPUs 0,1,4,7.
Each run had two four-second rounds at 16 clients. Mean requests/s across the
four off or on rounds were:

| Route | Cache off | Writer cache on | Change | Mean p99 latency, off → on |
| --- | ---: | ---: | ---: | ---: |
| Room show | 5,738 | 5,856 | +2.1% | 4.58 → 4.49 ms |
| Messages page | 5,490 | 5,574 | +1.5% | 4.77 → 4.75 ms |
| Sidebar | 6,062 | 6,221 | +2.6% | 4.37 → 4.22 ms |
| Search | 5,842 | 5,810 | −0.5% | 4.57 → 4.47 ms |
| Message POST | 966 | 1,103 | +14.1% | 23.09 → 17.88 ms |

Every run had zero errors and invalid responses, passed route contracts and
the exact acknowledged-write audit. The four GET changes are within observed
variation; the POST gain exceeded both cache-off runs in both cache-on runs.
Raw summaries: `once-campfire-verification/tmp/bench/ocaml55-sqlcache-writer-{A1,B1,B2,A2}-20261013/`.
The full OCaml 5.5.1 forced suite passes with writer caching both enabled and
disabled. A focused test exercises parameter rebinding, nested use of the
same SQL, transaction rollback, recovery after a SQLite constraint error, and
close/reopen. Writer caching is now the default; `CAMPFIRE_SQL_CACHE=0` keeps
an opt-out. This remains a development image, and the 80%-of-Go target and
full release-image resilience gate are open.

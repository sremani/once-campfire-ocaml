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

The gain is useful but well short of the current 85%-of-Go completion target.

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
The candidate is still far below the current 85%-of-Go completion target and has not
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
an opt-out. This remains a development image, and the 85%-of-Go target and
full release-image resilience gate are open.

## Further request-path work (2026-10-13 to 2026-10-14)

The clean, pinned OCaml 5.5.1 release comparison remains the acceptance
baseline: room 5,608, messages 5,393, sidebar 6,124, search 5,735, and POST
1,011 requests/s against Go's 54,104, 57,094, 63,170, 63,169, and 6,027.
These are 9–17% of Go. The 85% gates from that paired comparison are 45,989,
48,530, 53,695, 53,694, and 5,123 requests/s. A new clean paired release
comparison is required after any candidate is promoted.

The request profile found repeated route-pattern splitting, empty-body buffer
allocation, two session/user queries, a fresh observer `PRAGMA data_version`
statement per cached GET, and avoidable message POST reads. Compiled routes,
header-line copying avoidance, one session/user JOIN, a reused observer
statement, and direct construction of known inserted rows passed the full
OCaml 5.5.1 suite. The strongest isolated same-image GET result was the JOIN:
four direct-listener workers gained 12–22% across the four GETs. Direct
`SO_REUSEPORT` increased GET throughput from approximately 6–7k per second
with one worker to 23–27k with four; POST rose only from about 1.1k to 1.4k.
With the row-construction change, POST rose from 1,462 to 1,709/s in a paired
four-worker run. Raw summaries are under
`tmp/bench/ocaml55-{reuseport-w*,authjoin-w4-*,postfast-w4-*}-20261013/` in
the verification checkout. The four-worker boot is a diagnostic only: Cable,
jobs, presence, and rate limits are still process-local.

The next profile identified one SQLite writer job and four reader jobs per
POST, with fresh statement preparation, HTML formatting, and rich-text
conversion prominent in allocation samples. A selective authentication
reader-statement cache, Tyxml's simple streaming printer, post-write reader
fusion, precomputing plain text before the writer for non-markup messages, and
reusing the message body and plain text in the view presenter are now
implemented. The streaming path and reader-statement cache remain opt-in while
their effect is uncertain. The POST code and presenter pass the full suite; the
streaming path also passes all 121 rendered pinned view goldens. A focused
test verifies that precomputed text and the ordinary conversion produce the
same search-index row. In the last bracketed direct four-worker POST runs,
presenter reuse reached 1,506–1,543/s; the adjacent prior-image runs were
1,415–1,526/s. The benefit is small relative to shared-host variation.
Raw summaries are under `tmp/bench/ocaml55-{stream-w4-*,authstmt-w4-*,postmain-w4-*,viewreuse-w4-*}-20261014/`.

The host load climbed from roughly 20 to more than 50 runnable tasks during
these short runs, and the same-image room route varied by over 30% between
rounds. A route-index toggle comparison favored indexing for room and messages
but was flat for search; it cannot establish an absolute throughput advance.
Its raw summaries are under `tmp/bench/ocaml55-routeindex-w4-{A1,B2}-20261014/`.
Keep these runs as directional evidence. The next hard gates are a quiet-host
paired Go comparison, a release-compatible parallel request topology with
cross-worker Cable and jobs, and a shorter serialized POST writer path.

## Release comparison and rejected micro-optimizations (2026-10-14)

The first-wave request-path changes were committed as `5a34416`, passed the
forced suite and 121 rendered view goldens, and were built into a clean release
image. A paired two-round Go/OCaml comparison passed every response contract
and the exact POST write audit. Shared-host load lowered both programs from
their earlier quiet figures. The clean run measured:

| Route | Go requests/s | OCaml requests/s | OCaml / Go |
| --- | ---: | ---: | ---: |
| Room show | 23,202 | 3,378 | 14.6% |
| Messages page | 24,146 | 3,203 | 13.3% |
| Sidebar | 27,393 | 3,581 | 13.1% |
| Search | 26,771 | 3,547 | 13.2% |
| Message POST | 3,159 | 654 | 20.7% |

Raw summary: `once-campfire-verification/tmp/bench/ocaml55-release-5a34416-go-20261014/summary.json`.
The release still runs one application process behind Caddy. Four direct
`SO_REUSEPORT` workers reach roughly 25–35k GETs/s and 1.7–1.9k POSTs/s in
valid development probes, but their Cable, jobs, presence, and rate limit
state is local to each process. They cannot be deployed as the release.

A same-source four-worker HTTP/af probe passed all contracts and exact writes
at 34,353 room, 33,146 messages, 31,459 sidebar, 28,620 search, and 1,894
POST requests/s. Its matched Cohttp probe measured 24,997, 26,857, 31,004,
33,054, and 1,870. HTTP/af helped room and messages, was flat on sidebar and
POST, and regressed search. The first HTTP/af run had one unexplained HTTP 500
and was excluded; the logged repeat was valid. Raw summaries are
`tmp/bench/ocaml55-httpaf-w4-B2-20261014/` and
`tmp/bench/ocaml55-cohttp-w4-A1-20261014/`. HTTP/af still lacks WebSocket,
streaming upload, timeout, and shutdown support in this probe.

The opt-in authenticated session-row cache passed the full suite, including
revocation and membership invalidation tests, but the same-image four-worker
bracket moved routes in different directions under host drift. It was removed.
Moving search-index and unread writes into the message transaction passed the
suite but yielded inconclusive and lower POST rates in a bracketed run, so it
was removed. Checking WAL size every 16 writes, with per-write checks above
9,000 pages, passed the sustained-write WAL test but changed POST by less than
1% in its valid A/B; it was removed. A specialized presenter for freshly
inserted plain messages passed the suite and live response audit but improved
POST only 2% (1,687 to 1,721/s) in the same-image comparison, so it was
removed. Raw summaries are under `tmp/bench/ocaml55-{authrow-safe,inline-index,checkpoint,new-view}-*-20261014/`.

The focused one-worker POST profile after these request-path changes showed
three reader jobs and one writer job per request. Across two rounds, the writer
averaged 0.65–0.75 ms; message-view construction 0.41–0.47 ms; broadcast
recipient lookup 0.21–0.25 ms; broadcast 0.15–0.17 ms; and response rendering
0.13–0.14 ms. The reader jobs averaged 1.03–1.18 ms of execution each under
profiling, with queue delay on top. Minor allocation was about 1.5 MB per
message, with one major collection per roughly five messages. These timings
overlap and include instrumentation contention; they guide changes rather
than add up to a response time. Raw profile:
`tmp/bench/runtime/3892197/ocaml-{1,2}/db/profile.tsv`.

Same-image GC runs tested `OCAMLRUNPARAM=s=1M` and `s=4M` against the default
on four direct workers. The 1M run had one invalid HTTP 500 and was excluded;
its valid repeat improved some reads but regressed search. The 4M run passed
all contracts, generally improved GET rates, and moved POST by only a few
percent. Bracketed default runs varied substantially, so no runtime default
has changed. Raw summaries are under `tmp/bench/ocaml55-gc-*-20261014/`.

A separate OCaml 5.5.1 Flambda switch rebuilt the same dependency set and
passed the full suite from a fresh Dune build directory. In a same-source,
same-runtime-image-shape, single-process release comparison, Flambda changed
room +2.7%, messages -3.4%, sidebar +1.1%, search +1.1%, and POST -4.7%.
The differences are too small and mixed to justify changing the release
compiler. Raw summaries are `tmp/bench/ocaml55-compiler-{vanilla-A1,flambda-B1}-20261014/`.
The separate compiler recipe remains under `experiments/flambda/` for future
reruns.

Fusing message room membership and room lookup into the authentication reader
job passed the full suite and every live POST contract. It removed one reader
job per POST but did not improve throughput. In an A/B/A direct four-worker
bracket, the two off medians were 1,434 and 1,438 POSTs/s; the on median was
1,312. Room and `/up` controls drifted during the comparison, so this is not
an exact regression estimate. The fused path was removed. Raw summaries:
`tmp/bench/ocaml55-post-scope-{A1,B1,A2}-20261014/`.

## Four workers behind the production front (2026-10-14)

A disposable four-process image kept the normal Caddy front and used the same
application binary as a direct-listener image. Both two-round 16-client runs
passed every route contract and the exact acknowledged-write audit on the
same fixture and assigned cores. Median requests/s were:

| Route | Four workers through Caddy | Four direct workers | Direct / Caddy |
| --- | ---: | ---: | ---: |
| Room show | 7,498 | 15,628 | 2.08x |
| Messages page | 7,832 | 14,106 | 1.80x |
| Sidebar | 8,973 | 16,946 | 1.89x |
| Search | 8,420 | 16,653 | 1.98x |
| `/up` | about 11,912 | about 32,164 | 2.70x |
| Message POST | 1,291 | 1,476 | 1.14x |

The host was heavily loaded and the direct messages-page rounds varied, but
the 1.8–2.1x GET gap appeared on all four routes. Caddy is a plain reverse
proxy here; the app already supplies gzip and static responses. A correct
multi-worker Cable bus alone cannot meet the 85%-of-Go read gate through this
front. We need a release-compatible direct HTTP path for the Tailscale-only
deployment or a materially faster front/transport, as well as shared Cable
and lifecycle state. Raw summaries:
`tmp/bench/ocaml55-{caddy-workers-A1,direct-workers-B1}-20261014/`.

## SQLite write ceiling and OCaml 5 domains (2026-10-14)

A standalone write probe uses the pinned SQLite seed and the real message
creation path, including body, room touch, FTS, and unread writes. One process
completed 5,000 writes in 0.401 seconds (12,475/s) on an assigned core. Four
independent processes sharing one copied database completed 20,000 writes in
2.004 seconds (about 10,000/s aggregate), with exactly 20,000 message and
20,000 FTS rows verified. This isolates the database from HTTP, auth, view,
and broadcast work. The database writer can exceed the 5,123 POST/s gate in
this fixture; the full HTTP path remains the bottleneck. The reproducible
probe is in `benchmarks/write-ceiling/`.

The SQLite async worker pool now uses OCaml 5 domains by default: one writer
domain and two reader domains, with the Lwt listener on the main domain.
Worker ownership includes the domain ID so thread IDs from different domains
cannot collide. `CAMPFIRE_DB_DOMAINS=0` restores the earlier thread workers;
`CAMPFIRE_DB_DOMAIN_READERS` sets one to eight reader workers. The default-on
forced test suite passed, including async close and ownership tests.

A same-image, one-process release-style A/B/A comparison behind Caddy used
two three-second rounds per run, 16 clients, assigned cores, exact response
contracts, and acknowledged-write audits. Median requests/s were:

| Route | Threads A1 | Domains B1 | Threads A2 |
| --- | ---: | ---: | ---: |
| Room show | 3,317 | 4,961 | 3,460 |
| Messages page | 3,284 | 4,613 | 3,332 |
| Sidebar | 3,498 | 5,205 | 3,535 |
| Search | 3,270 | 5,274 | 3,523 |
| Message POST | 574 | 1,010 | 627 |

`/up` did not increase, which supports a real database-work parallelism
effect rather than a faster host during B1. These are development images, not
a clean release comparison. Raw summaries:
`tmp/bench/ocaml55-dbdomains-{A1,B1,A2}-20261014/`.

The reader-count runs drifted substantially: a one-reader room/POST sample
was 5,051/1,076 per second, while a two-reader repeat was 3,828/969 as `/up`
fell during the run. There is no reliable count ranking yet; two readers
remains the default.

Four direct diagnostic processes tested the domain option in an A/B/A
sequence on the same image. The first domain run was about 16.8–21.1k GETs/s
and 2,154 POSTs/s. The middle thread run was about 24.9–30.0k GETs/s and
1,778 POSTs/s. The second domain run was about 22.5–24.5k GETs/s and 2,752
POSTs/s. `/up` varied from roughly 31k to 57k and back to 38k across the
runs; GET effects are therefore inconclusive on this loaded host. The POST
gain is directional, not yet a reliable magnitude. Every run passed the
response and write audits. These processes still have local Cable, jobs,
presence, and rate limits, so they cannot replace the release topology.
Raw summaries: `tmp/bench/ocaml55-{domains-direct4-r1,threads-direct4-r1,domains-direct4-r2}-20261014/`.

Next: profile the domain-backed POST path; reduce HTTP and view work; build a
correct multi-process state and Cable topology; then compare a clean release
against Go on a quiet, matched host. The existing 85% gate is not met.

## Paired Go gap and statement-cache gain (2026-10-14)

An alternating OCaml/Go, two-round comparison used the pinned fixture,
identical server/client CPU sets, authenticated route contracts, and exact
acknowledged-write audits. OCaml used four direct diagnostic processes with
one reader domain each. Go used its release image. Median requests/s were:

| Route | OCaml diagnostic | Go | OCaml / Go |
| --- | ---: | ---: | ---: |
| Room show | 22,443 | 52,286 | 42.9% |
| Messages page | 22,075 | 51,382 | 43.0% |
| Sidebar | 22,714 | 60,051 | 37.8% |
| Search | 23,790 | 59,897 | 39.7% |
| Message POST | 2,791 | 6,092 | 45.8% |

Raw summary:
`once-campfire-verification/tmp/bench/ocaml55-domains-direct4-go-paired-20261014/summary.json`.
This topology is not release compatible because Cable, jobs, presence, and
rate limits remain process-local. The clean one-process release remains much
slower. The paired run establishes the size of the request-path gap on the
current host, not a shippable speedup.

The domain-backed POST profile measured about 0.12 ms per complete writer
job, three reader jobs per request, roughly 1.2 ms of writer queue plus work,
and roughly 0.84 ms per reader queue plus work under load. View construction,
broadcast, and Turbo response rendering each consumed about 0.09–0.13 ms per
request. These are overlapping elapsed timings; the write-ceiling probe
confirms the SQLite transaction is not the 5,123/s bottleneck. Raw profile:
`tmp/bench/runtime/733238/ocaml-{1,2}/db/profile.tsv`.

A one-worker room-view allocation profile found 54,484 private-cache hits in
54,493 checks. The room action averaged about 19 µs; the authenticated
session SQL averaged about 12 µs, while its reader job took about 21 µs and
the queue plus job about 310 µs. HTTP parsing through Angstrom dominated the
sampled allocation stacks. Raw profile:
`tmp/bench/runtime/891606/ocaml-2/logs/{profile.tsv,memprof.txt}`.

The existing selective authentication statement cache was retested with
domain workers. It avoids preparing the session lookup on every request and
is now enabled by default; `CAMPFIRE_AUTH_STMT_CACHE=0` remains the comparison
switch. A same-image off/on/off sequence passed all route contracts and write
audits. Median requests/s were:

| Route | Off A1 | On B1 | Off A2 |
| --- | ---: | ---: | ---: |
| Room show | 22,381 | 25,603 | 22,580 |
| Messages page | 21,894 | 25,829 | 21,326 |
| Sidebar | 22,273 | 27,954 | 24,594 |
| Search | 22,045 | 27,580 | 24,153 |
| Message POST | 2,852 | 2,936 | 2,819 |

Every on GET beat both off medians; POST is effectively unchanged. `/up`
rose across the bracket, from about 35.6k to 38.0k to 41.1k/s, so host
conditions do not explain the GET drop on returning to off. The forced
OCaml 5.5.1 suite passes with the cache default on. Raw summaries:
`tmp/bench/ocaml55-{inlineauth-off-A1,authstmt-domains-on-B1,authstmt-domains-off-A2}-20261014/`.

The HTTP/af plus domains diagnostic measured about 21–26k GETs/s and 2,851
POSTs/s, similar to Cohttp plus domains under host drift. It still lacks
production WebSocket and shutdown support, so there is no transport switch.
The opt-in inline session read improved some GETs 4–9%, left room flat, and
slightly lowered POST; it was removed. Reusing one rendered message item for
the POST broadcast and response passed the full suite and exact live audits.
Its on/off bracket was confounded by `/up` drift, so it is retained as an
allocation cleanup without a claimed throughput gain. Raw summaries are
under `tmp/bench/ocaml55-{httpaf-dbdomains-w4,inlineauth-*,postrender-*}-20261014/`.

The Tyxml simple streaming printer was retested for message POST with the
reader domains and auth statement cache enabled. Same-image off/on/off
medians were 2,827 / 3,070 / 2,874 audited POSTs/s, a roughly 7–9% on
advantage. `/up` medians were about 36.3k / 37.8k / 38.4k/s, so the POST
gain did not follow the host control. The printer is now the default;
`CAMPFIRE_STREAM_HTML=0` restores the Format printer. The forced suite,
including rendered view goldens, passes with the new default. Raw summaries:
`tmp/bench/ocaml55-stream-domains-{off-A1,on-B1,off-A2}-20261014/`.

The clean `7897445` release image was then paired with Go on the same four
server cores. It uses the supported one-process application behind Caddy.
Both two-round runs passed all route contracts and the exact POST write
audit; the comparison was marked release comparable. Median requests/s:

| Route | OCaml release | Go | OCaml / Go |
| --- | ---: | ---: | ---: |
| Room show | 9,393 | 54,173 | 17.3% |
| Messages page | 8,988 | 56,483 | 15.9% |
| Sidebar | 10,052 | 58,381 | 17.2% |
| Search | 9,964 | 60,919 | 16.4% |
| Message POST | 2,147 | 5,909 | 36.3% |

Raw summary:
`once-campfire-verification/tmp/bench/ocaml55-release-7897445-go-20261014/summary.json`.
This is a large improvement over the earlier clean release in absolute terms,
but it remains far below the 85% target. The next release-compatible rung is
a direct listener for private HTTP and a coordinated parallel topology.

## Private direct HTTP and the Lwt scheduler boundary (2026-10-14)

The production boot script now accepts `CAMPFIRE_DIRECT_HTTP=1` with
`DISABLE_SSL=1` and no TLS domain. It binds the existing single app process
directly to `HTTP_PORT`, bypassing Caddy for private HTTP deployments. This
keeps Cable, jobs, presence, and rate limiting inside one process. The
direct-mode route preflight passed; an alternating two-round OCaml/Go run
passed all authenticated route contracts and exact POST audits. It measured:

| Route | OCaml direct | Go | OCaml / Go |
| --- | ---: | ---: | ---: |
| Room show | 9,510 | 48,695 | 19.5% |
| Messages page | 9,693 | 52,615 | 18.4% |
| Sidebar | 11,168 | 58,033 | 19.2% |
| Search | 10,371 | 58,157 | 17.8% |
| Message POST | 2,788 | 5,229 | 53.3% |

This development comparison is not a clean release image because the boot
change was uncommitted at build time. The host also slowed during the run.
The direct listener helps POST, but one Lwt event loop still limits GET.
Raw summaries: `tmp/bench/ocaml55-direct-http-{preflight,go}-20261014/`.

An isolated OCaml 5.5.1/Lwt 6.1.2 test started four domains and attempted an
independent `Lwt_main.run` loop in each. One succeeded; three failed with
`Nested calls to Lwt_main.run are not allowed`. The current Lwt scheduler is
process-global, so copying the listener onto domains is not a valid route to
parallel HTTP handling. Database work remains parallel on domains; HTTP
parallelism requires coordinated processes or a domain-aware I/O rewrite.

## Coordinated direct workers and current limits (2026-10-14)

The direct listener now has an opt-in two- or four-worker mode. A Unix-domain
broker carries ordered Cable broadcasts and disconnects between workers. It
tracks confirmed stream subscriptions and avoids forwarding message batches to
workers with no interested WebSocket client. A shared, file-locked login
counter preserves the ten-attempt window across processes. Focused tests cover
framing, subscription transitions, real WebSocket typing and disconnect frames,
and the cross-process login limit. The full 5.5.1 suite passed.

The same fixture and exact POST write audit passed every timed run. An
old/new/old comparison of broker subscription filtering measured POST medians
of 1,372 / 1,662 / 1,540 requests/s. The host was unusually loaded, but the
filtered run exceeded both baselines; `/up` did not follow that pattern. Raw
summaries are `tmp/bench/ocaml55-broker-filter-{old-A1,new-B1,old-A2}-20261014/`.
This mode remains short of the Go target and has not replaced the default.

The four-worker POST profile attributed about 0.36 ms per request to Cable
broadcasting before subscription filtering and roughly 3 ms to SQLite writer
queue time under contention. Raw profile is
`tmp/bench/runtime/1561003/ocaml-{1,2}/logs/profile.tsv`.

Authenticated room GETs mostly hit the private response cache, but each hit
previously queued a database session lookup. A generation-checked local session
cache now skips that lookup while still verifying signed and encrypted cookies
and checking the hourly refresh deadline. It invalidates on SQLite changes.
`CAMPFIRE_AUTH_CACHE=0` is the comparison switch. The same-image off/on/off
room medians were 11,748 / 12,819 / 12,543 requests/s under a heavily loaded
host, so the throughput gain is not yet established. An instrumented run showed
18,329 cache hits and two misses in one worker snapshot; room before-action
time fell from about 0.224 ms to 0.012 ms per request. The CPU reduction is
promising, but a quieter paired Go comparison is still required. Raw summaries
are `tmp/bench/ocaml55-authcache-{off-A1,on-B1,off-A2}-20261014/` and raw
profiles are in `tmp/bench/runtime/{1856866,1872126}/`.

The first complete paired candidate/Go run on the heavily loaded host passed
all route contracts and exact POST write audits. Four coordinated OCaml workers
reached 50.3% of Go on room show, 55.8% on messages, 56.4% on sidebar, 48.8%
on search, and 52.6% on POST. `/up` was only about 27% of Go, exposing the
HTTP parser and response path even without authentication or SQLite. These are
development-image numbers; the 85% completion gate remains unmet. Raw summary:
`tmp/bench/ocaml55-coordinated-go-paired-20261014/summary.json`.

The HTTP handler was also doing a second static-file lookup while finalizing
every dynamic response. The first lookup result now travels with the response,
including public-cache hits. Same-image old/new/old room medians were
21,498 / 24,707 / 23,644 requests/s; `/up` did not show the same direction,
so the room gain is modest and still needs a quieter repeat. Raw summaries:
`tmp/bench/ocaml55-staticreuse-{old-A1,new-B1,old-A2}-20261014/`.

The profiler showed a SQLite observer generation check even on `/up` and POST,
which never use the private response cache. A lazy single-check refactor passed
the full suite, including cache invalidation tests, but an old/new/old direct
benchmark gave mixed GETs and no convincing POST gain. It was removed. Raw
summaries: `tmp/bench/ocaml55-lazycache-{old-A1,new-B1,old-A2}-20261014/`.

## Clean coordinated-worker checkpoint and URI parsing (2026-10-14)

The clean `c81ca34` image and Go image were compared on the same pinned four
server cores with 16 clients, two three-second rounds, the same fixture, full
route response contracts, and exact POST write audits. All timed requests
passed. OCaml reached 42.7% of Go on room show, 53.1% on messages, 48.6% on
sidebar, 41.8% on search, 43.0% on POST, and 29.4% on `/up`. Raw summary:
`tmp/bench/ocaml55-c81ca34-clean-go-20261014/summary.json`.

A disposable raw Lwt socket server serving only the fixed `/up` response
reached 697k–734k requests/s on four worker cores. That is a transport ceiling,
not an application benchmark. A full raw adapter that called the real app
passed response and write audits but did not improve read throughput; its
initial writer exposed a 40 ms delayed-ACK stall until TCP_NODELAY was set.
The parser itself took about 1 µs per request while the app handler remained
near 100 µs. The adapter is retained under `experiments/raw-http/` and is not
production capable. Raw summary:
`tmp/bench/ocaml55-raw-adapter-nodelay-20261014/summary.json`.

On the production Cohttp listener, an allocation sample of 8,644 allocations
on room traffic attributed 3,515 (40.7%) to `Uri.of_string` stacks. Cohttp's
`Request.uri` reconstructs the URI every time it is called, and the app called
it from several middleware and controller modules. A bounded, per-domain cache
now parses each physically distinct request once while retaining Cohttp's
exact URI interpretation. `CAMPFIRE_URI_CACHE=0` is the comparison switch.
The full forced test suite, including different Host headers and cache eviction,
passed. Raw allocation sample:
`tmp/bench/runtime/2556108/ocaml-2/logs/memprof-85.txt`.

The same-image A/B/A/B comparison used the four pinned server cores and exact
response/write audits. A disabled the URI cache; B enabled it. The mean of the
two run medians was:

| Route | URI cache off | URI cache on | Change |
| --- | ---: | ---: | ---: |
| Room show | 29,078 | 57,505 | +97.8% |
| `/up` | 41,700 | 91,945 | +120.5% |
| Message POST | 2,697 | 2,824 | +4.7% |

Every timed response was valid, and exact POST write counts passed. These are
dirty-source development images, not yet a clean paired Go result. Raw
summaries: `tmp/bench/ocaml55-uricache-{A1,B1,A2,B2}-20261014/`.

Other small experiments: a shared `/dev/urandom` descriptor eliminated repeated
open/close calls but had no measurable same-image throughput effect. Skipping
static-file and public-cache checks on known dynamic paths increased room
throughput by roughly 11% in alternating runs, with no reliable `/up` or POST
gain. Both changes remain individually switchable while the clean paired
comparison determines whether to retain them. Raw summaries:
`tmp/bench/ocaml55-randomfd-{A1,B1,A2}-20261014/` and
`tmp/bench/ocaml55-pathfast-{A1,B1,A2retry,B2}-20261014/`.

## Clean URI-cache result and remaining POST/health gaps (2026-10-14)

The clean, revision-stamped `5ec12c6` image was paired with the pinned Go
image on the same four server cores. Both images and their source trees were
clean. The same fixture, 16 clients, two three-second rounds, response
contracts, and exact POST write audit passed. Median throughput was:

| Route | OCaml requests/s | Go requests/s | OCaml / Go |
| --- | ---: | ---: | ---: |
| Room show | 55,884 | 55,845 | 100.1% |
| Messages page | 60,705 | 58,087 | 104.5% |
| Sidebar | 74,626 | 63,847 | 116.9% |
| Search | 66,918 | 62,352 | 107.3% |
| Message POST | 2,628 | 6,074 | 43.3% |
| `/up` | 79,664 | 139,514 | 57.1% |

Raw summary: `tmp/bench/ocaml55-5ec12c6-clean-go-20261014/summary.json`.
All four authenticated read routes clear the 85% target. The overall target
remains unmet because writes and `/up` do not.

An isolated POST test on the same image measured 3,594 requests/s with one
worker, 3,296 with two, and about 2,628 with four. A one-worker profile showed
about 0.10 ms of actual writer work per message and no significant wait at
`BEGIN IMMEDIATE`; the four-worker profile showed roughly 0.55–0.9 ms per
writer job, including 0.3–0.6 ms waiting to begin, plus 1.9–2.6 ms in the
writer queue. Cross-process SQLite lock contention is a major part of the
four-worker loss. Raw runs:
`tmp/bench/ocaml55-post-workers{1,2}-20261014/` and
`tmp/bench/ocaml55-post-profile-5ec12c6-20261014/`.

Two write experiments were removed after comparison. Moving FTS and unread
updates into the message transaction changed four-worker POST from 2,831 to
2,866 requests/s (+1.2%); it also changed the visible in-transaction FTS
behavior. An extra cross-process file lock around writes fell from 2,742 to
2,523 requests/s. Neither justified its cost. Raw summaries:
`tmp/bench/ocaml55-postatomic-{A1,B1}-20261014/` and
`tmp/bench/ocaml55-writerlock-{A1,B1}-20261014/`.

The `/up` stage profile after URI caching showed a roughly 8 µs route handler,
2.3 µs SQLite observer check, 3–4 µs gzip step, and 4 µs response finalizer.
The observer check is now lazy and runs only when private response caching is
used; an initial same-image throughput comparison was tied on the busy host.
The allocation sample also found repeated `Printf.sprintf` calls for the
request ID hex encoding and a substring allocation at each position of the
HTML stylesheet check. Direct byte conversion and a character scan passed the
full suite. A cached gzip health response template for ordinary `GET /up`
requests uses the same HTML, ETag, gzip, and final response-header path while
other formats and conditional requests use the general handler. Two alternating
off/on pairs measured 60,919/77,782 and 60,421/81,057 requests/s, a mean
gain of 30.9%. The host was heavily occupied by unrelated Java jobs, so a
clean paired Go run is still needed. Raw summaries:
`tmp/bench/ocaml55-healthtemplate-{A1,B1,A2,B2}-20261014/`.

## POST allocation profile and idle Cable work (2026-10-14)

The clean `e287572` one-worker POST allocation sample found two repeated costs:
the URL scanner built every scheme prefix and copied substrings at each text
character, and message creation encoded Cable JSON even when the local hub had
no subscribers. The clean sample is at
`tmp/bench/runtime/3687572/ocaml-2/logs/memprof-1.txt`. URL prefix comparison
now reads characters directly and prepares scheme prefixes once per body.
`CAMPFIRE_FAST_AUTOLINK=0` selects the old scanner. The full forced test suite,
including pinned rich-text output, passed. Same-image POST comparisons were
interrupted by Java jobs starting and stopping across runs, so this change has
no isolated throughput claim yet. Raw summaries:
`tmp/bench/ocaml55-autolink-{A1,B1,A2,B2}-20261014/`.

When there is no cross-process bus and no local Cable stream, message creation
now avoids the member-ID query and the unused broadcast. It checks stream
presence after commit; a new subscription after that check can fetch the
persisted message. With a bus, the broadcast remains enabled. The switch
`CAMPFIRE_SKIP_IDLE_BROADCAST=0` restores the old path. The full forced test
suite passed, including Cable integration cases. On one worker, the same-image
alternating pairs at 16 clients yielded:

| Pair | Broadcast always | Skip idle broadcast | Change |
| --- | ---: | ---: | ---: |
| 1 | 3,332 | 4,307 | +29.2% |
| 2 | 3,184 | 4,505 | +41.5% |

Both candidate runs exceeded both baselines. Every timed response was valid,
and both exact acknowledged-write audits passed. The host acquired new Java
jobs during these runs, so a clean revision-stamped Go comparison remains
necessary. Raw summaries:
`tmp/bench/ocaml55-skipidle-{A1,B1,A2,B2}-20261014/`.

Several smaller POST probes were removed after testing. Reusing a zlib stream
passed the full suite but did not improve paired throughput. zlib level 1
showed only about 3% in one pair. A short SQLite `BEGIN IMMEDIATE` retry first
caused HTTP 500s when it also disabled busy waiting for post-commit callbacks;
after that was fixed, a second pair tied the baseline. Pre-sizing Turbo stream
render buffers fell from 4,613 to 4,405 requests/s in a same-image pair. A
plain-message presenter shortcut moved work from the reader domain to the HTTP
domain and regressed one-worker throughput; it was removed. Raw summaries are
under `tmp/bench/ocaml55-{gzipfast,gzipreuse,fastbusy,turbocap,post-offload}-*`.

The read routes still require several HTTP workers to reach the Go target,
while POST is fastest with one writer process. A worker and Cable routing
design that preserves real-time delivery is the next architectural gate.

For messages made solely of ASCII letters, digits, and internal spaces,
rich-text rendering, search text, and editable text now take the equivalent
plain-text path. This excludes markup, entities, URLs, email addresses,
punctuation, Unicode, and leading or trailing spaces. A focused byte check and
the full forced suite pass; `CAMPFIRE_PLAIN_ASCII_FAST=0` selects the old path.
For 25,000 isolated benchmark bodies, process CPU time for those three
functions fell from 243.4 ms to 3.7 ms, about 9.6 µs saved per message. In
the live one-worker fixture, two alternating pairs measured 2,520/2,831 and
2,998/2,923 requests/s (old/new); Java load changed across runs, so there
is no end-to-end gain claim. All live responses and exact write audits passed.
Raw summaries: `tmp/bench/ocaml55-plainascii-{A1,B1,A2,B2}-20261014/`.

The existing cross-process Cable broker already tracks subscriptions but
previously required every POST worker to build and publish a message batch.
Workers now ask the broker for current remote interest when their local hub is
empty. The broker answers conservatively while any peer has not registered
interest tracking. The query is serialized with subscribe acknowledgements;
when no peer is interested, the POST skips the member lookup and broadcast.
Cross-worker subscription and delivery tests plus the full forced suite pass.

On the same four-worker image, two alternating pairs under heavy shared-host
load gave 2,011/2,417 and 1,893/2,320 POSTs/s (always broadcast/interest
query), gains of 20.2% and 22.6%. Every timed response was valid and each
exact acknowledged-write audit passed. These are development comparisons;
the clean Go ratio still needs an uncontended run. Raw summaries:
`tmp/bench/ocaml55-brokerinterest-{A1,B1,A2,B2}-20261014/`.

## Direct health and central POST writer (2026-10-14)

The direct listener now serves the ordinary gzip `GET /up` request from a
validated raw HTTP fast path. Its fallback retains Cohttp for conditional and
other health requests. A repeated request on one persistent connection,
plain fallback, and conditional `304` were checked live; the full forced
suite passed. Same-image health A/B measurements under concurrent host load
rose from 59,767/69,500 to 145,462/165,040 requests/s. The clean paired
Go/OCaml run at `05a3434` measured about 205,000 OCaml versus 72,600 Go
health requests/s, while shared Java load heavily depressed Go's earlier
139,514/s quiet result. The source is `lib/front_target.ml`; the switch is
`CAMPFIRE_RAW_HEALTH=0`.

An opt-in central POST writer now batches ordinary plain messages from four
HTTP workers through a Unix socket. It preserves exact acknowledged writes,
FTS visibility, and isolation when one item in a batch fails. The full forced
suite and the new integration test pass. `CAMPFIRE_CENTRAL_POST_WRITER=1`
enables it in coordinated direct mode. Under the same heavy host load it
raised four-worker POST from about 2,231 to 2,445 requests/s. Quieter local
runs reached about 3,900/s. The clean, audited all-route paired run under
heavy Java load measured 2,721 OCaml versus 3,725 Go POSTs/s (73%); the
quiet paired POST-only run measured 3,736/3,077 OCaml versus 5,643/5,360 Go.
These are not an 85% pass. Raw summaries are under
`tmp/bench/ocaml55-61b203c-clean-go-20261014/` and
`tmp/bench/ocaml55-05a3434-post-quiet-go-20261014/`.

The POST profile now shows three reader jobs plus one writer or writer RPC
per request. In the four-worker central-writer profile, one writer batch
averaged 314 µs for about 1.8 messages, and each HTTP worker still spent
roughly 350–580 µs awaiting each reader job. Per-process CPU and overlapping
stage times do not identify a single saturated writer: it used roughly
2.2 seconds of CPU while writing about 17,450 messages in the sampled round.
Profiles are at `tmp/bench/runtime/1427076/ocaml-2/db/stages-*.txt`.
Increasing reader domains from two to four lowered one-worker POST to
2,795/s under load. Disabling DB domains halved one-worker POST to about
1,482/s. Lwt 6.1.2 also rejects concurrent `Lwt_main.run` across domains,
so a direct multicore HTTP loop needs a different runtime or process design.

The central writer now offers `CAMPFIRE_POST_BATCH_CALLBACKS=1`, grouping
post-commit FTS and unread updates from a batch in one second transaction.
Two same-image A/B/A/B pairs measured 2,699/2,848/2,770/2,871 POSTs/s
under shifting host load, a small and consistent gain. The grouped path is
opt-in pending a clean comparison. It marks the primary commit before running
callbacks to avoid replaying a committed message if the second transaction
fails. Both callback modes pass the writer integration test and the full
forced suite. Raw summaries: `tmp/bench/ocaml55-callbackbatch-{A1,B1,A2,B2}-20261014/`.

`CAMPFIRE_GZIP_LEVEL=1` is an opt-in response compression tradeoff: paired
POST runs at level 6/1/6/1 measured 2,755/2,873/2,812/2,971 requests/s.
The typical response grew from about 1,981 to 2,250 bytes, so level 6 stays
the default. Exact response contracts and write audits passed. A direct
plain-message presenter showed only a marginal, inconsistent gain and was
removed. Caching static reaction HTML passed the rendered goldens but was
flat in its first paired POST run and was removed. Checking WAL size every
16 writes also failed to improve throughput and was removed. Raw summaries:
`tmp/bench/ocaml55-{gzip1,plainpresent,staticreaction,checkpointstat}-*-20261014/`.

## Route-aware HTTP dispatch and Cable interest flag (2026-10-14)

An adjacent quiet POST-only anchor measured 6,136 Go requests/s. The best
four-worker central-writer setting, with 250 µs of batch coalescing, measured
4,254 OCaml requests/s (69%). A one-worker OCaml process on the same four
assigned cores then reached 5,546 requests/s, over 90% of that Go anchor.
This isolated the multi-worker coordination cost. The 250 µs batch setting
improved central POST against its zero-delay baseline in repeated audited
runs; 500 µs regressed. Raw summaries are under
`tmp/bench/ocaml55-batchdelay-*-20261014/`,
`tmp/bench/go-post-anchor-20261014/`, and
`tmp/bench/ocaml55-cpugzip-A1-20261014/`.

The opt-in `CAMPFIRE_HTTP_DISPATCH=1` mode now transfers accepted TCP sockets
over Unix datagrams to four HTTP workers. Connections beginning with `POST `
go to the worker with a local SQLite writer; other connections rotate among
all four. The initial bytes remain unread for the existing timed Cohttp
listener. A connection that switches methods later retains normal route
behavior, with the central writer available on reader workers. The pinned
fixture preflight and exact POST write audits passed. Dispatch alone remained
near 4,200 POSTs/s: the router correctly sent all profiled POSTs to the
writer worker, but each POST still synchronously queried the Cable broker
for subscription interest. The profile is
`tmp/bench/runtime/1958208/ocaml-2/db/stages-17.txt`.

`CAMPFIRE_SHARED_INTERESTS=1` replaces that per-POST broker round trip with
a one-byte shared mapping. The broker writes its conservative global interest
flag before acknowledging a subscription. A stale true value only causes an
extra broadcast. The full forced suite passes with the flag both enabled
and disabled, including cross-worker Cable fanout tests. On the same image,
the audited POST medians moved from 4,190 with synchronous queries to 5,439
with the shared flag; a subsequent flagged run measured 4,878 during renewed
host drift. The change is a strong local gain, while an 85% release claim
still requires a clean paired Go comparison with all routes and checks.
Raw summaries are `tmp/bench/ocaml55-sharedinterest-{B1,A1,B2}-20261014/`.

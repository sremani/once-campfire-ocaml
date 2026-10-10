# Performance target: approach the Go port

The target is to run the OCaml port slightly below the Go implementation on
the shared, contract-validated benchmark. Interpret "slightly" provisionally
as **at least 80% of Go's measured throughput on each of the four authenticated
GET routes and the message POST route**. Keep zero invalid responses and exact
acknowledged-write audits. A faster response that fails a route contract does
not count.

The published Go reference reports 16 clients and four server cores on an AMD
Ryzen AI MAX+ 395. Its rates are 53,060 room views/s, 54,800 message pages/s,
59,144 sidebars/s, 60,509 searches/s, and 9,021 message posts/s. An 80% floor
against those numbers would be 42,448, 43,840, 47,315, 48,407, and 7,217
requests/s respectively. These are planning numbers, not a final acceptance
comparison: the current OCaml image and published Go image were measured at
different times. A first same-host comparison follows; repeat it on a quiet
host before using its rates for release acceptance.

The released OCaml `2a511ac` image, measured against Rust in two alternating
eight-second rounds, achieved 1,947 room views/s, 1,454 message pages/s,
1,987 sidebars/s, 1,513 searches/s, and 448 message posts/s. The shared
`tmp/bench/m8-t4-2a511ac-timed/summary.json` records image, seed, loadgen,
validation, and exact write audits. This is roughly 3–5% of the published Go
GET rates and 5% of its POST rate; the current architecture misses the target
by more than an ordinary tuning margin.

On 2026-10-10, the official Go source at `c4ab53d` was built as a production
image with its pinned Rust/Rails submodules. The shared harness then ran
Go/OCaml/OCaml/Go, with 16 clients, four server cores, eight seconds per route,
one disposable seed copy per app round, response-contract validation, and
exact write audits. Both apps passed every route and write audit. The current
host was much busier than the published Go run, so these are same-host
comparison rates, not replacements for the published rates:

| Route | Go median req/s | OCaml median req/s | Go/OCaml |
| --- | ---: | ---: | ---: |
| Room show | 19,251 | 1,075 | 17.9× |
| Messages page | 20,978 | 884 | 23.7× |
| Sidebar | 23,012 | 1,294 | 17.8× |
| Search | 16,565 | 962 | 17.2× |
| Message POST | 2,083 | 285 | 7.3× |

The raw summary and all samples are in the shared verification checkout at
`tmp/bench/perf-go-ocaml-20261010/`. The OCaml source checkout held only this
documentation edit; `--allow-dirty-source` marked the experiment provisional.
The images were pinned throughout. Go room throughput fell from 24,314 to
14,189 requests/s between its rounds, so do not attribute small percentage
changes to the implementation on this host.

A second validated Go/OCaml/OCaml/Go run selected only public static CSS and
`/up`, at 16 clients for four seconds per route. Go served 67,359 static CSS
responses/s and 27,885 health responses/s; OCaml served 2,915 and 2,909.
All eight samples had zero errors and invalid responses. The raw samples are
under `tmp/bench/perf-go-ocaml-public-20261010/`. The 23.1× static and 9.6×
health gaps occur before session restoration and page rendering, so those
features cannot be the sole explanation. This experiment points first to the
HTTP/front/server path and multicore execution, while still requiring a
function-level profile before assigning exact costs.

A disposable status-only `/up` probe against one released OCaml container used
the same 16-client load generator and pinned CPU sets for eight seconds at
each listener. Caddy on port 25400 served 3,737 responses/s; the private
Cohttp listener on port 25401 served 6,675 responses/s, both with zero errors.
This isolates a substantial proxy/transport cost on that route, while the
direct listener still falls well below Go's paired public-route result. The
probe used an isolated fixture copy and removed its container and storage.

## What the first experiment established

Safe authenticated GETs currently queue session restoration on the one SQLite
writer and then queue a second read for the full user record. A disposable
change moved fresh GET/HEAD session restoration to the reader pool and merged
the user read into that job, while stale sessions still refreshed on the writer.
The focused stale/fresh/revoked-session test passed. Three short, validated
two-round runs on 2026-10-10, in optimized/baseline/optimized order, reported:

| Run | Room views/s | Message pages/s | Sidebars/s | Searches/s | Posts/s |
| --- | ---: | ---: | ---: | ---: | ---: |
| Optimized 1 | 2,362 | 1,821 | 2,801 | 1,905 | 559 |
| Released baseline | 1,695 | 1,378 | 1,895 | 1,525 | 457 |
| Optimized 2 | 1,670 | 1,327 | 1,716 | 1,310 | 354 |

All route and write audits passed. Round-to-round variation and high host load
swamp any reliable gain from this change, so it was reverted. The raw summaries
are in the shared verification checkout under `tmp/bench/perf-authread-20261010`,
`perf-authread-baseline-20261010`, and `perf-authread-repeat-20261010`.

## Architecture facts and next measurements

The released image uses OCaml 4.14, one Cohttp/Lwt application process, and a
separate Caddy reverse proxy. The app has multiple SQLite reader threads, but
OCaml 4.14 executes OCaml code on one runtime domain. Earlier warmed GET CPU
samples put the app near one core, with Caddy around 5% of a core; they are
not a function-level profile. The Go port uses one native `net/http` process
with Go's multicore scheduler and a pooled SQLite reader path. Both ports have
authenticated response caches, so the mere presence of a cache does not
explain the gap.

The next comparison needs at least three alternating rounds on a quiet host
with per-process CPU samples. Then measure front versus direct-listener cost and the warmed authenticated
request stages before changing the HTTP runtime or process model. Any
multi-process design must preserve cross-worker Cable delivery, live session
revocation, cache invalidation, and exact writes; benchmark those behaviors
alongside throughput.

Sources: `once-campfire-rust/README.md` performance table,
`once-campfire-go/README.md` benchmark table,
`docs/m8-t4-performance.md`, and the shared verification summaries above.

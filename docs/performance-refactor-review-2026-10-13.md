# Performance profile and refactor review (2026-10-13)

## Verdict

We have **route benchmarks and partial stage profiles**, not a complete CPU,
allocation, and GC profile of the current release image. The existing
[escalation plan](performance-escalation-plan.md) is a useful experiment ladder,
but it is not yet a code-level refactor plan. This review supplies that plan.
The clean-source, pinned-image OCaml/Go run after the writer statement cache is
the baseline; none of the probe results should be substituted for it.

| Route, 16 clients | OCaml requests/s | Go requests/s | OCaml / Go |
| --- | ---: | ---: | ---: |
| Room show | 5,608 | 54,104 | 10.4% |
| Messages page | 5,393 | 57,094 | 9.4% |
| Sidebar | 6,124 | 63,170 | 9.7% |
| Search | 5,735 | 63,169 | 9.1% |
| Message POST | 1,011 | 6,027 | 16.8% |

Source: `once-campfire-verification/tmp/bench/ocaml55-writer-cache-go-clean-20261013/summary.json`,
OCaml `cde14f5`, Go `c4ab53d`, both clean, same fixture, host, CPU assignment,
load generator, Caddy path, and route checks. The topology differs: OCaml uses
Caddy plus one application process; Go uses one application process. It is a
valid end-to-end product comparison and must be decomposed before attributing
the full gap to OCaml code.

## What the measurements establish

- `Perf_probe` times request stages, SQLite jobs, cache actions, and POST
  substeps. These are **elapsed times under load**; overlapping stages and
  queue waits must not be added as CPU costs. The available data lacks a
  function-level CPU profile, per-route allocation profile, and GC pause
  breakdown. `perf stat` was denied on HeMan (`perf_event_paranoid=4`).
- Warm authenticated reads still execute session restoration and at least one
  SQLite reader job on a cache hit. Moving the private cache lookup before
  controller queries helped reads, but four GET routes remain near 9–10% of
  Go in the clean comparison.
- On a disposable `/up` probe, direct Cohttp served 48% more requests than
  Caddy at 16 clients; a same-source HTTP/af bridge improved authenticated
  GETs by 21–30%. These are diagnostic runs, not additive gains or release
  results. The bridge lacks WebSocket upgrade, streaming uploads, timeouts,
  and graceful shutdown.
- A four-process probe improved GET throughput 1.6–2.0 times over one worker,
  while POST fell in its first run because SQLite writers contended. The
  probe has no cross-worker Cable bus or shared job ownership, so it cannot
  be shipped. Lwt's single scheduler in one process is a scaling limit, but
  processes or domains alone do not remove per-request cost.
- The POST writer job was about 0.94–0.98 ms in the measured profile. FTS
  insertion, rich-text insertion, and unread updates took roughly 0.23,
  0.14, and 0.13 ms respectively. Writer-only prepared statement reuse gave
  a repeatable 14% POST gain without measured GET regression. The SQLite
  writer and its queue remain a separate bottleneck.

## Code review: where work and coupling concentrate

1. **Request transport and policy are entangled.** `lib/front_target.ml`
   implements a custom timed Cohttp listener, including line buffering,
   response framing, and upgrade handling. `lib/http_app.ml` (917 lines)
   owns transport types, body parsing, route resolution, cookies, Rails
   session behavior, authorization, caches, headers, compression, and the
   listener callback. Its context has more than 40 fields. This makes a
   transport replacement a router rewrite and makes attribution difficult.
   The `/up` and HTTP/af probes show this boundary is worth measuring first.
2. **The read fast path is still a full request path.** `lib/http_app.ml`
   authenticates before private cache lookup; `lib/controller_rooms.ml`
   reaches the cache early on room, message, and search actions, but session
   restoration still queries SQLite. `lib/views.ml` is 4,225 lines of mixed
   Tyxml and hand-built legacy HTML. The cache avoids most view work when
   warm, so a whole-template rewrite has no measured justification yet.
3. **Writes cross several layers.** `lib/controller_rooms.ml` creates the
   message, then performs a reader query to build the response and find
   subscribers. `lib/db_messages.ml` and hooks update multiple tables;
   `lib/db_runtime.ml` serializes writes on one SQLite connection and runs
   after-commit callbacks. Transactional durability, FTS visibility, and
   broadcast order are real invariants. The writer queue and post-commit
   reader/render work need separate cost accounting.
4. **Compatibility logic is in the production path.** `lib/http_app.ml`
   contains a hard-coded Rust `ActionNotFound` table and path-specific header
   rewrites, including `x-runtime`/`x-rev`. `lib/authentication.ml` restores
   Rails cookie formats; `lib/views.ml` has many `legacy_*` renderers. Some
   preserve existing users and the shipped browser; some only reproduce
   reference implementation details. Their costs and necessity are currently
   mixed.

## Contract reset

Classify each check by its consumer before removing it. The benchmark should
prove the same useful work, not force the OCaml app to emit Rust/Rails bytes.

| Disposition | Contract | Reason |
| --- | --- | --- |
| Keep | Auth, authorization, CSRF, revocation, room visibility, message order/content, exact acknowledged writes, FTS visibility, Cable delivery, uploads, backup/restore, security headers, zero errors | User data, safety, and observable product behavior. |
| Keep while current browser uses it | Turbo Stream content type, append target, stable DOM identities, Action Cable protocol | These are browser integration points, even though Rails introduced them. Replace only alongside a frontend change and equivalent browser tests. |
| Keep as migration tests, remove from hot-path acceptance | Rails cookie decoding, signed IDs, Action Text schema, old attachment records | Needed to read existing ONCE data or sessions; no reason for new OCaml objects to keep every old serialization detail forever. Define a documented migration window before retiring. |
| Replace in shared performance preflight | `/up` body containing literal `background-color: green`; CSS and avatar byte equality to each app's own preflight body | Check health status/readiness and valid CSS/image content. Exact static bytes are not needed to prove useful work per request. |
| Move out of performance acceptance | Rails/Rust HTML and JSON golden bytes, incidental response header parity | Test old-data migration and supported client behavior separately; keep relevant security and cache headers. |
| Retire after a route inventory | Rust `ActionNotFound` table, Rails exception body/header quirks, `x-runtime`/`x-rev` parity | Keep HTTP status and product error behavior; remove special cases only when no supported client consumes them. |

The shared `bench/contracts.rb` already derives message IDs and room names
from seed SQL; preserve that strong semantic check. It also requires the
literal green CSS health body, captures each app's CSS/avatar bytes for
equality during its timed run, and requires specific Turbo DOM strings.
Replace the literal health check and consider a content validity check for
static assets; use a browser-level test to decide the smallest Turbo/DOM
contract.
Do not loosen the suite during a performance comparison: version the
semantic contract, run old and new checks side by side once, then use the
same new version for both OCaml and Go. Keep the old goldens in a separate
migration/compatibility suite rather than running all of them as the
performance acceptance gate.

## Refactor sequence and decision gates

1. **Establish a real profile on the current image.** On quiet distinct
   physical cores, run one- and 16-client direct and Caddy tests for `/up`,
   CSS, four GETs, and POST. Capture per-process user/system CPU and RSS,
   request stage histograms, SQLite queue versus execution, writer lock wait,
   response bytes, allocation words/request (`Gc.quick_stat` deltas in a
   sampled or isolated run), major collections and pause times. Use OCaml
   Memprof or Memtrace for allocation call sites if available; test the
   profiler's overhead with an A/B run. If kernel sampling stays restricted,
   use userspace sampling and state that function-level CPU attribution is
   unavailable. Deliver a ranked time/allocation table with uncertainty.
2. **Extract transport-neutral request and response types.** Split
   `http_app.ml` into a thin Cohttp adapter and policy/router core. Keep
   request body streaming and `/cable` upgrade explicit in the adapter.
   Eliminate repeated conversion between Cohttp headers, cookies, and app
   fields on the measured path. Existing libraries should handle HTTP
   framing and WebSocket protocol; do not grow the custom listener further.
   Gate on all product contracts and an A/B/B/A Cohttp baseline with no
   material regression before changing transport.
3. **Remove reference-only work from the hot path.** After contract inventory,
   delete `ActionNotFound` and header/body special cases that serve only Rust
   parity; retain or isolate legacy decode paths for stored data and existing
   sessions. Replace exact view goldens with semantic/browser tests for new
   behavior. Gate on old-data login, live browser flows, and the new shared
   semantic suite. Measure each request-path deletion separately.
4. **Optimize the measured per-request cost.** First target the larger of
   HTTP parse/write/proxy and auth/cache/database work shown by step 1.
   Evaluate a complete HTTP/af adapter if transport dominates, including
   Cable, streaming upload, deadlines, and shutdown. If auth dominates,
   reduce repeated cookie/session work without weakening revocation. If
   allocations dominate, reduce header/HTML construction only at sampled
   sites. Gate each focused change with same-image or pinned A/B/B/A runs;
   reject gains inside variance or regressions on other routes.
5. **Split read scaling from write scaling.** For GETs, compare one, two,
   and four correct worker processes with a shared Cable event bus,
   cross-worker invalidation, one job owner, and common rate-limit behavior.
   For POST, profile writer occupancy and post-commit read/render separately;
   shorten the serialized section only where profiling shows a gain. Do not
   multiply SQLite writers as the primary POST strategy. Verify exact writes,
   event order, multi-worker fanout, restart, and backup/restore.
6. **Escalate to OCaml 5 domains only with a real route win.** Lwt 6.1.2
   rejected concurrent `Lwt_main.run` in separate domains; Async by itself
   also does not supply multicore request execution. Prototype an existing
   domain-ready scheduler/HTTP stack (Eio is a candidate) with `/up` and one
   authenticated route, checking library and SQLite domain safety, Cable,
   uploads, and shutdown. Compare it against the correct process design on
   the same cores. Port more code only if it shows a repeatable advantage.

The current target is at least 85% of Go on **each** of the five routes, with
correctness and resilience intact. That is a release gate, not a predicted
gain from any one refactor. Review the profile table after step 1 and change
the order of steps 4–6 if it points to a different dominant cost.

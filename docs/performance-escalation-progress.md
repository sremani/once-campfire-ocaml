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

Safe GET and HEAD requests now verify the session and load the user in one
SQLite reader job. If the hourly activity update is due, they retry on the
writer and retain the original cookie refresh behavior. Mutating methods stay
on the writer. The `CAMPFIRE_AUTH_READ=0` switch was used only to compare the
old path with the new path in the same candidate binary.

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

The gain is useful but well short of the 80%-of-Go completion target. The next
escalation is independent application workers for whole-request parallelism,
with cross-worker Cable delivery and session/cache invalidation gates.

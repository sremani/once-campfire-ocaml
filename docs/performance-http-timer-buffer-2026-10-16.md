# HTTP timer and output buffer tuning (2026-10-16)

The OCaml 5.5.1 direct HTTP listener now completes all five grown-seed,
identity-encoded RP-X workloads under the 1 GiB server limit. The final image
`sha256:65ad60069d31d0134ef675f8d49d4873c554daa9657423b4d1c8fe6980a222db`
(`campfire-ocaml:perf-http-20261016`) passed every response validator and the
message POST's exact persisted-write audit. Its final single-run throughput
exceeded the accepted pinned F# medians recorded in the sibling checkout at
`once-campfire-fsharp/docs/evidence/rpx-fg-benchmark.md`
on every route. These are direct HTTP/1.1 results; they do not measure Caddy,
TLS, or public deployment throughput.

| Route | OCaml final RPS | OCaml p95 ms | OCaml peak MiB | F# pinned median RPS | OCaml / F# |
| --- | ---: | ---: | ---: | ---: | ---: |
| Watercooler room | 16,407 | 2.58 | 155 | 8,408 | 1.95× |
| Messages page | 20,693 | 2.26 | 151 | 8,304 | 2.49× |
| Sidebar | 41,808 | 1.69 | 131 | 30,877 | 1.35× |
| Search | 33,010 | 1.79 | 134 | 14,398 | 2.29× |
| Successful HQ message POST | 5,460 | 7.28 | 206 | 1,671 | 3.27× |

The 64 KiB buffer candidate's earlier independent rows measured 18,596,
24,044, 47,701, 30,717, and 3,705 RPS in the same route order. The final
image contains the same executable changes plus source comments, but host
variation is visible between rows. A fresh run of the pinned F# room image
measured 8,465 RPS with the same protocol and zero invalid responses. The
historical F# medians are two accepted rows per route; the OCaml values above
are one final row per route. The large directional lead is supported by those
rows, while a narrow confidence interval or production-path claim is not.

## Mechanism and evidence

The original listener created a 300-second Lwt sleeper for every timed read
and write, including operations that completed immediately. Lwt's select
engine leaves canceled sleepers in its timer heap until earlier deadlines are
processed. The original sidebar warmup grew to 1 GiB and was OOM-killed after
about nine seconds. Disabling all HTTP deadlines for diagnosis completed at
31.5k RPS and about 124 MB peak, which localized the memory problem to timer
handling. The fix returns already-resolved operations directly and checks
pending operations against the same absolute deadline in intervals of at most
0.5 seconds. A state-only experiment reached 39.4k sidebar RPS but memory
still grew; bounded intervals completed the warmup and measurement at about
132 MB peak. The new deadline regression test verifies immediate completion
and expiry of a pending operation.

The remaining room profile recorded about 370 microseconds of response-write
wall time per request versus 54 microseconds in application route handling.
Room responses are roughly 416 KiB and the installed Lwt output channel's
default buffer is 4 KiB. Using a 64 KiB output buffer on each accepted worker
socket cut copies and writes in this measured path. Before that buffer change,
the bounded-timer image measured 7,940 room, 9,630 messages, 32,659 sidebar,
16,369 search, and 2,834 POST RPS in one row each. Buffer sizes of 128 and
256 KiB produced 19,230 and 18,681 room RPS in single trials, a small and
inconsistent gain for more memory per connection; 64 KiB was retained.

All runs used the F# RP-X shared adapter and its pinned grown seed, semantic
contracts, and load generator: four server cores 8–11, four client cores
12–15, 16 measured clients, 1 GiB server memory, identity encoding, 20-second
read warmups or exactly 12,000 acknowledged write warmups, and 10-second
measurements. OCaml used four HTTP workers, its central POST writer, and a
64 MiB response cache. The exact final row artifacts are in the local F#
checkout at `tmp/ocaml-tune-final_{room,messages_page,sidebar,search,message_write}1/`;
the first buffer rows are `tmp/ocaml-tune-buf64_{room,messages,sidebar,search,write}1/`.
The profiler row is `tmp/ocaml-tune-half_room_profile1/`, and the fresh F#
room row is `tmp/ocaml-tune-fsharp-room-fresh1/`.

The focused front-server test and the full `dune runtest` suite passed in the
pinned OCaml 5.5.1 test image. Every final RP-X row had zero errors and zero
invalid responses; the read rows had no product-state mutation, and the POST
row's acknowledged message, rich-text, and search-index effects matched its
database audit. A future production-path comparison should run Caddy/TLS and
repeat alternating F#/OCaml/Go rows on a controlled host.

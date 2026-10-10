# Performance escalation handoff (paused 2026-10-10)

## Goal and acceptance gate

The active goal is to execute [the performance escalation plan](performance-escalation-plan.md): reach at least 80% of Go's throughput on **each** of room show, messages page, sidebar, search, and message POST in the shared same-host benchmark. The final release image must also pass response contracts, exact acknowledged-write audits, Cable behavior, backup/restore, and resilience checks. Do not mark the goal complete from a local speedup or a disposable transport probe.

## Stable checkpoint before this pause

Commit `39719f8` contains the verified cache-order and fresh-session reader-path work, plus disposable worker and HTTP/af probes. [The progress log](performance-escalation-progress.md) records raw run paths and limits. On HeMan's quieter physical cores, the combined Cohttp candidate beat the released OCaml image by about 34% on room show, 70% on messages page, 10% on sidebar, and 45% on search; POST was effectively flat. The HTTP/af probe showed a 21–30% read-route gain over matching current-source Cohttp, but lacks Cable, streaming uploads, timeouts, and graceful shutdown. Neither is near the 80%-of-Go gate.

The reproducible core layout used server CPUs `2,3,5,6` and client CPUs `0,1,4,7`, eight distinct physical cores on a 16-core/32-thread machine. The host's unrelated builds later occupied those cores and many sibling threads too. Re-sample `/proc/stat` and SMT topology before trusting a throughput comparison; the physical-core assignment may need to change.

## Work in progress at pause

`lib/db_messages.ml` has opt-in POST stage timings (`post_insert_message`, `post_insert_body`, `post_touch_room`, `post_find_message`, `post_insert_index`, `post_receive_room`). The timed profile put a POST writer job near 0.94–0.98 ms, with search-index insertion around 0.23 ms, body insertion around 0.14 ms, and unread membership update around 0.13 ms. The writer queue dominated end-to-end latency under 16-client load.

A trial moving search-index and unread updates into the main message transaction (`CAMPFIRE_POST_BATCH=1`) was discarded. Same-image A/B/B/A POST medians were A=`974,914`, B=`989,937` requests/s: about 2% mean gain with overlapping run variation. Raw summaries: `once-campfire-verification/tmp/bench/ocaml55-postbatch-{A1,B1,B2,A2}-20261010/`. No batching branch remains in source.

`lib/db_runtime.ml` now has an **experimental, off-by-default** `CAMPFIRE_SQL_CACHE=1` switch. It keeps at most 512 prepared SQL statements per runtime-managed SQLite connection, reuses idle statements, and finalizes them before closing the connection. The registry uses an atomic snapshot; each writer or pooled reader connection has exclusive use during a query. Statements used recursively fall back to a fresh prepare. This version caches both reader and writer connections and has not passed its full comparative benchmark yet. The disposable image is `campfire-ocaml:sqlcache-all-exp`, digest `sha256:1a073fbf6030a507f4179464d7395feaac2d70dc9add24d1e3fcfa8026c4c62b`.

The prior writer-only version (`campfire-ocaml:sqlcache-exp`) passed the full OCaml 5.5.1 suite with the cache both off and on. In an exact-audited same-image A/B/B/A POST run, cache-off medians were `756,751` and cache-on medians were `831,797` requests/s, an 8% mean gain. Profiled writer execution fell from roughly 1.06 to 0.80 ms; a cache-on round recorded about 37,600 hits and 10 misses. Raw summaries and copied profile TSVs: `once-campfire-verification/tmp/bench/ocaml55-sqlcache-{A1,B1,B2,A2}-20261010/`. The absolute rates were below earlier quiet-core runs, so this remains a development result. The writer-only implementation was superseded by the current lock-free, all-connection candidate.

The current all-connection candidate builds and the full OCaml 5.5.1 `dune runtest --profile release --force` suite passed with `CAMPFIRE_SQL_CACHE=1`. Its first same-image five-route cache-off run at `once-campfire-verification/tmp/bench/ocaml55-sqlcache-all-A1-20261010/` **exited 1**: writing this handoff changed the source manifest during round 2, and the benchmark correctly rejected the run. Do not use its partial route rates as a comparison. No cache-on run for this exact image has started. Do not compare it with the earlier writer-only image as though they were the same binary.

## Resume sequence

1. Inspect `git status`, the aborted run metadata, and current per-core/SMT utilization. Read the current source and benchmark metadata rather than assuming this handoff still matches the worktree.
2. When the server and client sets have low competing load, rerun a valid **same-image** A/B/B/A sequence with `sqlcache-all-exp`: `CAMPFIRE_SQL_CACHE=0` for A1/A2 and `1` for B1/B2. Use the same pinned seed, `--routes room_show,messages_page,sidebar,search,post_message`, `--rounds 2 --duration 4 --concurrencies 16`, core sets, and `--allow-dirty-source`. Do not edit the OCaml source tree during a run; the runner rejects a changed source manifest. The pinned runner is `campfire-m8-check:pinned` in `once-campfire-verification`; its benchmark records image digest, zero-error route contracts, exact POST writes, and latency samples. Repeat if host drift is material. Check p95 latency and every route, not only POST RPS.
3. If the all-connection cache reliably improves the required routes without correctness or p95 regressions, add focused lifecycle/reentrant-statement tests, run the complete suite with cache off and on, and run Cable and resilience gates. Then decide whether to enable it by default. If the gain is within noise or a route regresses, remove the experimental cache. Keep the POST profiling data.
4. Continue the remaining plan: optimize measured POST/HTTP costs, finish a production-compatible HTTP/af transport only if its same-source gain repeats, and build a correct cross-worker Cable/event design or a domain-native request runtime. A disposable probe does not satisfy the 80% completion gate.

The benchmark's disposable authentication uses only pinned test fixture credentials. No production deployment or release image has been changed by this work.

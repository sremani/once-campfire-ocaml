# M8-T1 source-vector and kit audit

Audit against Rust `9872c1d9541551c0889a60e3d49a14488bd1e403` and Rails
`90b330024dec3e757c79b6a7e6568f93da8e3148`, using the current OCaml
source tree on 2026-10-09. This records source coverage; it is not a release or
live differential pass.

## Copied top-level vector files

All six JSON files under pinned Rust `vectors/` are byte-identical to the
same-name files under `test/fixtures/`:

| File | Pinned cases and OCaml assertion |
| --- | --- |
| `ruby_core.json` | 427 strings, 555 floats, 200 byte ranges in `m1_t1_test.ml`. Its four version strings are fixture provenance. |
| `rails_compat.json` | Key derivation, cookies, session, CSRF, IDs, SGIDs and verifiers in `core_test.ml` and M1 tests; all 40 password outcomes and five digest structures in `m8_t1_user_agent_test.ml`. |
| `campfire_routes.json` | 177 routes and 111 recognitions in `m1_t5_test.ml`. |
| `campfire_sessions.json` | Seed session, blob link and forged token in M1 and M6 tests. |
| `campfire_user_agents.json` | 385 complete agents, 44 versions, 352 comparisons, every application-platform field and error/default result in `m8_t1_user_agent_test.ml`. |
| `storage.json` | Media, Marcel, URL, variation and file cases in M6 tests; previously uncovered exact ffmpeg preview argv and secret prefix in `m8_t1_user_agent_test.ml`. `generated_by` is provenance metadata. |

The direct user-agent implementation includes the Ruby product matcher, version
comparison, browser/platform/OS/mobile/bot classification, platform view flags,
and browser minimums. The pinned 385 cases include nil, blank, malformed,
Unicode, raised `NoMethodError`/`ArgumentError`, versioned nil-browser, bot,
and blocked-browser cases. The generated Unicode lowercase table is reproducible
with `python3 tools/generate_unicode_lower.py --check` (Unicode 15.0.0).

## Other pinned suites

The M8 coverage audit tracks DB, rich text, assets, 123 view goldens, Cable,
integration JSON and QR fixtures. Its current evidence reports 658/658 direct
Rust Action Text comparisons; 121 rendered and two input-metadata view golden
checks; 26 transport plus 47 channel golden steps; 90 OpenGraph and 19 webhook
cases; and 39 QR vectors. These are focused suite results. The complete browser,
HTTP, persisted-state and release matrices remain separate M8 gates.

The pinned `crates/kit/tests/` contains 45 Rust tests: one 2,755-case parameter
vector test, two Rails session tests, 28 HTTP tests, 13 front tests and one
logging test. The OCaml 2,755-case parser test passes. M1–M3 cover cookies,
CSRF, sessions, MIME/format, multipart, limits, method override, ETag, HEAD,
cache and much of the HTTP response family. M7-T1's local live evidence covers
HTTP/1.1, HTTP/2, h2c, TLS/ACME, body limits, WebSocket timeout survival and
target socket bounds. This audit added exact generated/sanitized `X-Request-Id`
assertions from Rust `http.rs` to the M8-T1 in-process test. The audit also
added `Http_request_log` with exact rejected-request and failed-action diagnostics
and a focused log capture test. Malformed form and raised action go through the
in-process HTTP boundary. Cohttp's synthetic request constructor normalizes a
malformed `%` in a URI, so the malformed-query diagnostic is exercised by the
parameter parser and logger directly; a raw-wire query check remains useful.

**Concrete coverage still missing:**

- Rust `front.rs::http2_connections_close_after_the_idle_timeout` has no
  equivalent explicit timed HTTP/2 connection test. M7-T1 established HTTP/2
  service and direct HTTP/1.1 idle deadlines, but its handoff does not record
  this combined behavior.
- Rust `front.rs::caches_streamed_responses_of_declared_length` and
  `bypassed_requests_repeat_vary` have focused OCaml cache/stream unit tests,
  but no matching live front exchange was found in the M7 handoff. Final
  Caddy-front validation belongs with M8's live HTTP/release matrix.
- Rust `http.rs::flash_survives_exactly_one_redirect` and
  `session_cookie_is_written_only_when_the_session_changes` have component and
  seeded session tests, but no exact synthetic action-chain reproduction was
  found. A route-level differential can settle their observable behavior.

These are evidence gaps. M8-T1 should remain open until the manager assigns or
accepts precise equivalent
checks; M8-T2's 708-cell route matrix currently has 47 response mismatches and
cannot be treated as a clean HTTP-family pass.

## Local verification

`dune build` exited 0. `dune runtest --force` exited 0 with local loopback
socket access before the logging patch; the focused M8-T1 suite now passes
7/7 cases, including all 385
agents, 44 versions, 352 comparisons, 40 bcrypt checks and the new request
logging check. `dune build bin/main.exe @check` exited 0 after M3/M4 yielded.
No Docker or browser run was performed during this audit.

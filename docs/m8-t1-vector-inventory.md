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

- Rust `front.rs::http2_connections_close_after_the_idle_timeout` now has an
  explicit Caddyfile configuration assertion for h2c plus the distinct two-second
  idle and one-second read deadlines in `m8_t1_session_chain_test.ml`. The timed
  HTTP/2 connection close still needs a live Caddy exchange. The bounded probe
  is prepared in `scripts/m8_t1_wire_probe.py` but has not been run against
  Caddy while M8-T2 owns the Docker interval.
- Rust `front.rs::caches_streamed_responses_of_declared_length` and
  `bypassed_requests_repeat_vary` have focused OCaml cache/stream unit tests,
  but no matching live front exchange was found in the M7 handoff. Final
  Caddy-front validation belongs with M8's live HTTP/release matrix.
- Rust `http.rs::flash_survives_exactly_one_redirect` and
  `session_cookie_is_written_only_when_the_session_changes` now have exact
  synthetic action chains through `Http_app.handle` on a disposable pinned Rails
  seed copy in `m8_t1_session_chain_test.ml`. The four cases cover unchanged
  session writes, 32-character-ID continuity, reset/deletion, malformed encrypted and
  signed cookies, flash crossing one redirect then being consumed, signed
  authentication continuity and database revocation. They pass locally.

## Packaged front wire evidence, 2026-10-09

`python3 scripts/m8_t1_live_wire_check.py --image campfire-ocaml:rc-7bd8a49-amd64
--output /tmp/m8-t1-live-wire-rust-both-env-7bd8a49.json` ran the pinned Rust
image `sha256:c45786de2e6c7169129edd6bc6e0607c99cc768a1c4d19046f208c376d5822a3`
and clean OCaml image
`sha256:1ffb96c88fc92ee90710e27b7f2fcc03b540b3cd7ec8210c7c09c03e21b44c3b`
on separate copied default seeds. Both were configured for h2c and a two-second
idle deadline. The script sent anonymous requests only and removed both
disposable containers. OCaml returned a complete HTTP/2 response and closed
after 3.002 seconds with GOAWAY, within the pinned test's 1.8–3.5-second
window. The packaged Rust image did not close within the probe's five-second
deadline. Its native Hyper-client source test, `cargo test -p campfire_kit
--test front http2_connections_close_after_the_idle_timeout`, passed in 2.03
seconds with `RUSTC_WRAPPER=`. The raw HPACK client versus packaged-image
difference remains unresolved; the OCaml packaged close is proven, but this
probe does not establish exact Rust/OCaml wire equivalence.

The same raw-socket run exposed a real malformed-query gap. For
`/session/new?a=%` and `a=%G0`, Rust returned 400 with an empty body while
OCaml returned a 200 sign-in page. For `a=%FF`, both returned 400, but Rust's
body was empty and OCaml's was a 20-byte HTML error. A literal
`/session/new/%ZZ` gave Rust 404 (4,237-byte HTML) and Caddy 400 (15-byte
plain text), consistent with M8-T2's 708-case malformed-path sweep. Cohttp's
raw request target is available as `Cohttp.Request.resource`; the old app read
the normalized `Cohttp.Request.uri`, so the first two invalid escapes never
reached `Http_params.parse_query` unchanged.

The OCaml source now parses the raw resource query and returns the same empty
PublicExceptions 400 for these three cases. The 17-case M3-T1 suite passes,
including a raw-resource regression. After rebuilding `bin/main.exe`, a
disposable direct-listener raw-socket probe returned 400,
`text/html; charset=UTF-8`, and an empty body for `%`, `%G0`, and `%FF`, exactly
matching the pinned Rust response fields above. A freshly packaged Caddy-front
image still needs the same live check; the 7bd8 image in this section predates
the source fix. The malformed path remains a separate Caddy boundary gap.

These are evidence gaps. M8-T1 should remain open until the manager assigns or
accepts precise equivalent
checks; M8-T2's most recent frozen ordinary 708-cell route matrix has 34
response mismatches and cannot be treated as a clean HTTP-family pass.

## Next quiet-interval wire probes

Run only against disposable loopback listeners and copied default Rails seed.
The script starts no server and sends no credentials. For the timed H2C check,
configure the OCaml front with `THRUSTER_H2C_ENABLED=1`,
`THRUSTER_HTTP_IDLE_TIMEOUT=2`, and `THRUSTER_HTTP_READ_TIMEOUT=1`, with its
plain HTTP port bound to loopback. The pinned Rust `front.rs` uses those values.
First verify `curl --http2-prior-knowledge -sS -o /dev/null -w '%{http_version} %{http_code}\n' http://127.0.0.1:18381/up`
prints `2 200`. Then run:

```sh
python3 scripts/m8_t1_wire_probe.py h2-idle --port 18381
```

The script sends the HTTP/2 prior-knowledge preface, SETTINGS, and a static-HPACK
GET `/up`; it requires response HEADERS and END_STREAM, then waits at most five
seconds for TCP EOF. With the two-second idle deadline, EOF must occur 1.8 to
less than 3.5 seconds after END_STREAM. It records whether GOAWAY preceded EOF.
This mirrors the pinned Rust test's timing window and bounds the probe's wait.
Run it separately against a pinned Rust front port with the same settings if
that listener is available.

For the pinned `logging.rs` malformed-query request, start independent Rust and
OCaml default-seed listeners on loopback ports 3228 and 3230, then run:

```sh
python3 scripts/m8_t1_wire_probe.py malformed-query --rust-port 3228 --ocaml-port 3230
```

This sends raw HTTP/1.1 target bytes for `/session/new?a=%`, `%G0`, and `%FF`
without URI normalization. Both sides must return 400; it compares the status,
content type, body length, and SHA-256, reporting any divergence. For the first
case, the pinned kit log contract is one
`request rejected error=bad request: invalid %-encoding (%)` diagnostic, with
no repeated `bad request:` prefix. Capture each disposable server's logs to
check that line separately; the script only checks the wire response.

## Local verification

`dune build` exited 0. `dune runtest --force` exited 0 with local loopback
socket access before the logging patch; the focused M8-T1 suite now passes
7/7 cases, including all 385
agents, 44 versions, 352 comparisons, 40 bcrypt checks and the new request
logging check. `dune build bin/main.exe @check` exited 0 after M3/M4 yielded.
The additional `m8_t1_session_chain_test.exe` passes 4/4 cases. No Docker or
browser run was performed during this audit.

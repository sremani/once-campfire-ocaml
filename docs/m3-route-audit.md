# M3 route ownership and response audit

The pinned Rust `crates/campfire/src/controllers.rs` declares 177 routes in Rails table order.
The OCaml `Route_catalog.routes` has the same 177 rows. This inventory assigns every row to an
M3 ticket so that a recognized path does not get mistaken for an implemented action.

| Ticket | Controller families | Route rows | Rust `action_not_found` rows | Other missing controller rows |
| --- | --- | ---: | ---: | ---: |
| M3-T2 | `welcome`, `first_runs`, `sessions`, `accounts`, `users` | 73 | 27 | 0 |
| M3-T3 | `rooms`, `messages`, `searches`, `autocompletable` | 73 | 13 | 1 |
| M3-T4 | `pwa`, `qr_code`, `unfurl_links`, `rails`, `turbo`, `action_mailbox`, `active_storage` | 31 | 0 | 0 |
| **Total** | | **177** | **40** | **1** |

M3-T1 owns parsing, request context, policy, response primitives, and dispatcher wiring. M3-T5
owns cache and conditional response behavior across all controller families. The 40 actions
explicitly mapped to `action_not_found` in Rust must retain that response behavior. The
`rooms/settings#show` row is declared but mapped to `missing_controller` in Rust. Its catalog
entry is intentional, while Rails route recognition fails because the controller is absent.

The pinned `concerns.rs` orders the default application callbacks as version headers, current
request, banned-IP check on writes, session/bot authentication, bot denial, CSRF unless bot-key
authenticated, and browser allowance. Actions can opt into unauthenticated access, require an
unauthenticated user, allow bot keys, or skip forgery protection. Controller tests must exercise
the applicable variants, not just the default authenticated path. `Db_runtime.read_async` and
`write_async` are the nonblocking entry points for Cohttp handlers.

For the M3 gate, compare each route's status, redirect, headers, authorization, and response shape
against the shared fixture suite. Distinguish exercised action behavior from catalog/vector
coverage: the M1 route vectors prove recognition and path generation only.

The complete HTTP gate also needs M4 HTML and asset output, M5 event/integration effects, and M6
Active Storage/media behavior. The M3 controller tickets may finish their action logic before
those components, but the M3 milestone remains open until integrated responses satisfy the gate.

## Integrated reassessment, 2026-10-09

| Ticket | Focused evidence now available | Every-route gate still open |
| --- | --- | --- |
| M3-T1 | 16/16 HTTP foundation tests, 2,755 Rails params vectors, 129 MiB streamed multipart, request temp cleanup through cancellation, real TCP listener and 64 KiB header bound | **Accepted:** clean 674-case-pass matrix matches all 100 affected `Vary` role cells; packaged 65 KiB and 1 MiB front/target header probes reject oversized requests while normal requests pass. |
| M3-T2 | 73 owned catalog rows dispatched; seeded permissions, first-run, transfer, logo purge, avatar, account and bot tests; positive account/session writes | **Accepted:** d6600ed passes 1,314/1,314 eligible five-seed route/role cells, including first-run's 146 anonymous/bot cells. |
| M3-T3 | 73 owned rows dispatched; seeded room/message/search/attachment tests and live Cable broadcast checks | **Accepted controller scope:** d6600ed passes 1,298/1,314 eligible five-seed cells; the other 16 are four seeds × signed/denied room-show rows 95/100, differing only in M4 Lexxy view bytes and derived length/ETag. |
| M3-T4 | 31 owned rows dispatched, 9/9 focused tests, 39 pinned QR matrices and 18 capacity vectors, M6's 256-case live storage corpus, M5's guarded integration tests | **Accepted:** latest immutable default-seed matrix passes all 124/124 assigned route/role cases; positive manifest, service-worker and unfurl checks pass 3/3 exact on the same binary. |
| M3-T5 | Public and private cache admission, authorization, invalidation and limits; live identity/gzip/HEAD/conditional and frozen-Date checks | **Accepted cache semantics:** d6600ed public logo miss/hit/signed/304/Range passes 5/5 exact; rows 75/95/100 pass their own bounded cache, HEAD, ETag, no-store and write-invalidation checks. Room validators derive from M4 view bytes; libz and Rust zlib-rs produce different valid gzip wire bytes. |

M8-T2 ran the 177-row, four-role live Rust/OCaml response and SQLite-state
matrix. Its four isolated `GET /` role cases pass after the shared 404, header,
cookie and session fixes. No M3 ticket is accepted from the focused suites alone.

## Current ticket acceptance, 2026-10-09

### Current source correction at `e4b71e6`

The extra room Lexxy script is removed. The pinned seeded byte test now
checks rows 95 and 100 directly against the 416,349-byte Rust SHA-256,
without stripping content. A fresh isolated live rerun of the original
16 failing cases (rows 95/100, signed/denied roles across `default`, `crowd`,
`restricted`, and `custom_styles`) passes **16/16 exact** on status, all
response headers including Content-Length and ETag, body bytes and SHA-256,
and all-table SQLite effects. The tested OCaml binary SHA-256 is
`809a3d3b4143c7aa856473c217879edc92d02fb1a3cc2fa69b32a0169fa34fc5`.
Credential-free reports and their hashes are in
`/tmp/m3-route-gate-e4b71e6-summary.md`; per-seed safe JSON and Markdown
reports use `/tmp/m3-route-gate-e4b71e6-wire-{default,crowd,restricted,custom_styles}`.

This closed the observed room-response difference. The source-impact map at
`/tmp/m3-route-impact-e4b71e6.md` identified 112 additional ordinary
route/role/seed cases changed after the earlier `d6600ed` sweep. The current
full five-seed check below covers those cases; the older results remain
immutable historical evidence.
Source `d223a0f` changes only the attachment edit-frame serializer after
this rerun; its four focused Rust/OCaml attachment browser cells are exact.
Source `7352f48` additionally changes room involvement `Turbo-Frame` layout.
Its 16 focused browser cells are exact on raw network response, including
headers and body hashes. Current source `2a511ac` also fixes the group
direct-room sentence and profile avatar upload; its eight focused browser
cells are exact. The 2a511ac ordinary sweep completed all 177 route rows under
four roles across five independent seeds: **3,186 eligible cases pass exactly,
zero fail**, with 354 first-run signed/denied cases explicitly unavailable
because that seed has no signed session. Each populated seed passes 708/708;
first run passes all 354 available cases. The same pinned executable passes
the separate default-seed positive-write comparison **30/30 exact**. The
shared HTTP fixture gate for M3 is complete at this revision. The independent
five-seed aggregation and report hashes are in
`/tmp/m3-2a511ac-five-seed-audit.md`; the positive-write report is
`/tmp/m3-2a511ac-positive-writes.json`. The original wrapper's last aggregate
assertion used the historical 3,170 pass count and failed after all five
per-seed gates passed; its expected total was corrected to 3,186 without
rerunning cases. The reported application comparisons have no failure.

The final clean packaged d6600ed sweep compared all 177 routes under four
roles on fresh independent copies of `default`, `crowd`, `restricted`, and
`custom_styles`, plus the available anonymous/bot roles on `first_run`.
The executable SHA-256 is
`42a8df769a107df9e1ff6c48a071f861b45576b1684827dfaadefe3aafecd170`;
the pinned Rust source is `9872c1d9541551c0889a60e3d49a14488bd1e403`.
Each populated seed passes **704/708**; `first_run` passes **354/354** eligible
cells, with **354 signed/denied cells not run** because that seed has no
account or signed fixture. In total, **3,170 pass, 16 fail, 354 not run**.
Every failure is signed/denied row 95 or 100 on one of the four populated
seeds: both responses are 200 with equal authorization, independent headers,
and persisted state, while the OCaml room page includes an extra 557-byte
Lexxy readiness script. Body bytes and their derived Content-Length/ETag
therefore differ. M4 owns that remaining rendered-view difference; the M3
every-route milestone remains open until it is resolved and reverified.

T2's **1,314/1,314** eligible cells have no difference; T3's **1,298/1,314**
include only those 16 M4 room-view cells. The d6600ed focused run separately
passed **22/22** first-run cases, including missing-account join 500 and bare
transfer 400 responses; custom-styles logo deletion row 38 passed **2/2** with
exact SQLite attachment, account-touch, blob and variant purge effects.
The crowd autocomplete JSON bodies, counts, and next-page Link headers pass
**3/3** live. Restricted Kevin's open/closed room GET and POST paths all
return 403, an empty body and unchanged rooms on both servers. A separate
bcb440c direct two-port probe saw only OCaml's front-generated `Server: Caddy`
header there;
the isolated route comparator attributes no controller/header difference.

T5's packaged public-logo cache sequence passes **5/5** exact Rust comparisons:
miss, repeat hit, signed hit, conditional 304, and Range bypass. The
conditional hit retains the same frozen Date, and neither server changes
SQLite. Its bounded rows 75/95/100 probe passes identity/gzip GET, HEAD,
own-validator 304, cache miss/hit, no-store and write invalidation on both
servers. Row 75's identity body and ETag are byte-identical; rows 95/100
inherit the M4 room-body residual. OCaml libz and Rust zlib-rs encode different
gzip wire bytes, while both decode to their own exact identity bodies and
expose matching cache/HEAD semantics. This documented compressor difference
does not reopen T5's semantic cache ticket.

Safe immutable reports are `/tmp/m8-t2-d6600ed-{default,crowd,restricted,custom_styles,first_run}-full.json`,
`/tmp/m8-t2-d6600ed-logo-cache-summary.md`, and
`/tmp/m8-t2-d6600ed-head-gzip.json`. The earlier f099059 checkpoint below is
retained as historical evidence. M3-T2, T3, and T5 are accepted on the d6600ed
ticket scope; the M3 milestone is not yet accepted.

### Earlier f099059 checkpoint

The clean packaged f099059 candidate (executable SHA-256
`1d5228d39f659c092b1881b8f6d50263178a9d08f8fff0cca22b604714753384`)
passes **704/708** ordinary default-seed role cases. T2 owns 73 rows and
passes **292/292**; T3 passes **288/292**; T4 passes **124/124**. The four
remaining failures are signed/denied room-show rows 95/100, with identical
status and SQLite state; the OCaml room page contains an extra 557-byte
Lexxy readiness script, so body bytes and derived Content-Length/ETag differ.
The same f099059 binary passes **30/30** isolated valid writes, including
**14/14** T2 and **16/16** T3 cases, and all **236/236** applicable method
override role cases. T2's 12-case seeded permission/first-run suite and exact
assigned role matrix satisfy its ticket. T1, T2 and T4 are checked; T3 and
T5 remain open, as does the M3 every-route gate. Safe report hashes and paths
are in `/tmp/m8-t2-f099-handoff.md`.

T3's narrow remaining response gate is exact identity room HTML on rows
95/100 after M4 removes the extra script, then a fresh shared role comparison.
T5's live row 75 identity body, page-part ETag and conditional `Vary` match,
and its offline suite passes 15/15. Its recorded PageParts gzip still differs
in compressed bytes because the OCaml libz output differs from pinned Rust's
`zlib-rs`; room validators also depend on the same M4 room body fix.

### Earlier 674-case checkpoint

The clean checkpoint `7bd8a4964603e3de3800c1edf45674be08dd3a9f`
passes **674/708** default-seed route/role cases. All 34 failures are rendered
body bytes and derived Content-Length/ETag values; status, independent headers,
and SQLite state match in all 708. T1's 25 affected `Vary` route rows pass
**100/100** role cells. The same source's packaged image passed 66,560-byte
and 1,048,576-byte front and target header probes with normal 302 responses,
front 431 rejection, no oversized target response, and no nonloopback target
reachability. With its streamed multipart, parser, request/session and startup
tests, T1 satisfies its foundation ticket. T1 and T4 boxes are checked; T2,
T3, T5 and the M3 every-route milestone remain open.

T5's newer offline suite passes 13/13 after flash-aware private-cache bypass,
bounded finite-body hashing, and a page-part ETag helper. Room page-part
validators still need view fragment offsets and live conditional/HEAD/gzip
parity. These later cache changes are not claimed by the clean 674-case matrix.

### Earlier 661-case checkpoint

The earlier pinned, isolated default-seed matrix archived at
`/tmp/m8-t2-default-661.json`
passes **661/708** route/role cases. It reports no status, persisted-state,
or independent header difference. The remaining 47 cases are page body bytes
and derived Content-Length/ETag values across 24 rows. T4 owns row 51 and rows 147–176;
all **124/124** of its route/role cases pass. The same OCaml binary passed
the positive `.json` manifest, `.js` service-worker and signed missing-URL
unfurl comparisons **3/3**, including exact headers, body, and SQLite state.
Together with focused QR/capacity, M5 integration and M6 storage/media
evidence, this satisfied T4's assigned HTTP controller scope. At that
checkpoint, the M3 milestone remained open for T1/T2/T3/T5.

T1's public-exception `Vary` correction then awaited an integrated rerun; the
current 674-case-pass checkpoint above closed it. T2 had 18 residual page cells in nine rows;
T3 has 29 in 15 rows. Their controller presenters have pinned structural
coverage, but the full byte gate and positive mutation/alternate-seed suite
remain open. T5's remaining M3-specific work is room page-part validators,
flash-aware private-cache bypass, bounded large finite bodies, and live
conditional/gzip/HEAD route checks. Its 10/10 suite proves focused cache
semantics but not the whole contract.

## Earlier 579-case baseline reconciliation, 2026-10-09

The earlier **immutable full default-seed matrix** archived at
`/tmp/m8-t2-default-579.json`
is **579/708 exact**, with 129 failures. It checks all 177 route rows in four
roles, exact response bytes/headers, and persisted SQLite state. The later
focused T2 run newly passed 16 formerly failing cells, T3 newly passed 56,
and T4 fixed row 147 signed in source and its offline test. Those 73 cells
are disjoint members of the 129 baseline failures. They imply 56 baseline
cells outside those focused closure sets, but **do not establish a 652/708
integrated result**: the T4 change and all cross-ticket edits need one fresh
immutable full run. M6 separately reran invalid disk-key row 174 at 4/4;
that row already passed in the 579 baseline.

The 56 cells outside the focused closure sets are precisely: row 8 in all
four roles; rows 28, 30, 31, 39, 43, 56, 59, 65, 73–75, 92, 95, 100,
106–107, 114–115, 122, 128, 130 and 145 in signed and denied roles; row
49 in anonymous and bot roles; and rows 54, 55, 60, 61, 66 and 137 in
signed role. Most are full-page HTML with derived length/ETag differences.
T2's focused HTML rows 28, 30, 31, 39, 43 and 49 had identical structural
DOM tokens but different serialization. T3's boost rows 128/130 still need
M4 page bytes. Rows 60/61/66 have source-level PublicExceptions changes
since the baseline. Rust ban actions call `find_user`, which raises
RecordNotFound for the missing user at rows 54/55; the OCaml controller now
returns the same public 404 path, with signed seeded assertions for body and
cookie suppression. The full rerun must validate all of these claims.

This manager pass also connected `Controller_rooms.render_room_form` to
M4's six pinned full-page `Views.room_form_page` variants and connected
search index to `Views.search_index_with`. The adapters supply active and
selected users, recent searches, raw and sanitized query values, and a
membership-checked last-room fallback. `dune build @check` passes; seeded
M3-T2 passes 10/10 and M3-T3 passes 8/8, including a new HTTP assertion for
the room form and search presenter inputs. M4's golden view tests cover the
renderer itself. Direct-room message links still require the computed room
display name in `View_presenter.message`, and the room direct/edit and
involvement view adapters remain to be audited.

The interim 40-cell browser comparison found admin/bot pages differing only
in `content-transfer-encoding` on three 200 user-avatar resources. Pinned
Rust `kit/src/response.rs::send` adds `binary`; OCaml account-controller
`stock_file` and `variant_file` omitted it at that checkpoint. M3-T2 then
fixed both paths and matched all three resource responses exactly in a focused
live comparison; the browser sweep still needs a rerun. Browser
room refresh/sidebar `Vary: accept` and view body differences remain with
M3-T5/M4 for source tracing. T1's direct-listener header bound must also be
checked in the packaged Caddy image. This paragraph records the earlier
checkpoint; T4 was accepted on the newer 661-case matrix above.

Next full-route gate: build one source snapshot after the M3-T2 avatar and
M4 presenter changes, reset Rust and OCaml default seeds independently per
case, rerun all 708 route/role cells, and compare exact response and SQLite
state. Then rerun the affected browser 40-cell set on that same snapshot,
followed by alternate-seed, cache conditional/HEAD/gzip, multipart limits,
and packaged listener checks. Keep focused closures as evidence for diagnosis,
not a substitute for that integrated result.

## Earlier live checkpoints

The first completed matrix covered 708 isolated requests: 186 passed and 522 failed.
The M3 controller status differences identified with high confidence were denied-IP
Action Mailbox ingress (Rust 404, OCaml 429) and denied-IP Active Storage writes
(Rust 404/400, OCaml 429). `Controller_aux` now follows the separate pinned Rust
ingress and storage concerns, and the M3-T4 focused suite verifies a banned IP
still reaches those responses while a storage session lookup does not refresh
activity. A rebuilt live rerun is required before counting those rows as passing.
The standalone Rails health and Turbo native actions also now skip the app's
version before action, as in the pinned Rust source.
After Cohttp fixed-length response framing was corrected, M8-T2's fresh live
rerun passed all 16 `/up` and Turbo native role cells exactly.
The subsequent focused 80-cell rerun passed 73: Action Mailbox rows 154–160
and disk PUT row 175 matched all four roles. Row 38's denied response lost
version headers because the OCaml cookie-commit guard also skipped response
headers; the shared HTTP layer now retains headers while suppressing cookies.
Row 176's missing-blob error now uses PublicExceptions response semantics.
A rebuilt pinned Rust/OCaml rerun passed all eight row 38 and row 176 role
cells with exact status, headers, body, and persisted state. M6 owns disk GET
row 174's cache/MIME gap.

The shared BenchmarkContracts run later found `/users/me/sidebar` returned a
frame fragment for an ordinary signed GET. The M3 controller now chooses
M4's pinned full-page sidebar renderer unless a nonblank `Turbo-Frame` header
is present. Seeded M3-T2 page/frame tests pass 6/6 and M3-T5 cache tests 8/8;
the rebuilt signed gzip shared contract passes. M8-T2 reports all eight pinned
BenchmarkContracts route cases passed, plus the acknowledged message-write body,
FTS, persisted delta, and SQLite integrity checks.
The transfer, user-deactivation, and join-code changed-row differences in that
matrix are confined to newly generated random token, UUID, and join code values;
both ports use the same documented value shapes. M8-T2 is validating narrow
canonicalization for those values while retaining all other row comparisons.

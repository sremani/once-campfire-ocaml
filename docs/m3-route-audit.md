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
| M3-T1 | 16/16 HTTP foundation tests, 2,755 Rails params vectors, 129 MiB streamed multipart, request temp cleanup through cancellation, real TCP listener and 64 KiB header bound | Verify shared headers, cookies, malformed methods and body limits over the live Rust/OCaml route matrix and packaged listener. |
| M3-T2 | 73 owned catalog rows dispatched, seeded controller suite 10/10, avatar/logo live corpus passed under M4/M6, scoped push-subscription subset lookup | Complete session/onboarding/account/profile/push response and state comparison for anonymous, signed, denied and bot roles; full HTML and file-header parity remain open. |
| M3-T3 | 73 owned rows dispatched, seeded controller suite 8/8 including disk-backed browser and bot attachments, live Cable broadcast checks | Compare all room/message/search status, headers, HTML/JSON/Turbo bodies and persisted effects; page-part/cache response parity depends on the M4 view corpus. |
| M3-T4 | 31 owned rows dispatched, 39 pinned QR matrices and exact included SVGs, M6's 256-case live storage corpus, M5's guarded integration tests | Verify every auxiliary route in the shared HTTP matrix, including request role and error shape; view/asset variants and uncommon QR payloads remain open. |
| M3-T5 | 8/8 focused cache tests, public QR route, authenticated room and sidebar private-cache hits with SQLite invalidation and revoked-session bypass | Compare exact conditional, gzip, HEAD, fresh_when, page-part and cache headers/bodies on live routes; flash bypass and large finite body behavior need review. |

M8-T2 ran the 177-row, four-role live Rust/OCaml response and SQLite-state
matrix. Its four isolated `GET /` role cases pass after the shared 404, header,
cookie and session fixes. No M3 ticket is accepted from the focused suites alone.

## Latest offline reconciliation, 2026-10-09

The latest **immutable full default-seed matrix** in `docs/m8-t2-http-state.json`
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
`stock_file` and `variant_file` omit it. This is assigned to M3-T2's file
response adapter, with a fresh browser network check after its fix. Browser
room refresh/sidebar `Vary: accept` and view body differences remain with
M3-T5/M4 for source tracing. T1's direct-listener header bound must also be
checked in the packaged Caddy image. No M3 ticket box is checked yet.

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

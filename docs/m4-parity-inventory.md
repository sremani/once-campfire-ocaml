# M4 browser and rendering parity inventory

Pinned source: Rust `9872c1d9541551c0889a60e3d49a14488bd1e403` and its Rails
submodule `90b330024dec3e757c79b6a7e6568f93da8e3148`.

| Ticket | Source and executable evidence | Integration seam |
| --- | --- | --- |
| M4-T1 assets | `crates/assets/tests/reference.rs` and six reference files; preserve the Rails application assets, vendored assets, and Rust overrides by logical path. | `Assets.serve` is wired before route dispatch; the Dockerfile copies assets and sets their root. Verify the final packaged image and live static response/network layer. |
| M4-T2 views | `crates/views/templates/` has 80 templates; `crates/views/tests/golden/` has 123 source files across full pages, fragments, JSON and SVG. | The Tyxml renderer passes the corpus accounting matrix. Finish live controller adapters, raw body review, and browser screen parity. |
| M4-T3 rich text | `crates/richtext/tests/reference_tests.rs`, `corpus/expected.json`, and `hardening.rs` cover parsing limits, safe attributes, attachments, mentions, autolinks, plain text, and editable values. | Production message writes, FTS, and presentation use `Rich_text` with signed/GID resolvers and request Host; direct pinned Rust corpus parity passes. |
| M4-T4 browser | Shared `once-campfire-verification/browser/smoke.mjs` and Rust `parity/` browser matrix. | Needs complete views/assets plus M5 Cable and M6 media for the full gate. The smoke test checks first run, two-tab live messages, editing, search, settings, QR, and more. |

M4-T3 is verified. M4-T1, T2, and T4 remain open until their packaged,
live-page, and browser matrix gates pass.

## M4-T1 handoff

The asset agent delivered `Assets.serve ~method_ ~path ?accept_encoding ?range
?if_modified_since () : Assets.response option`. `None` means route fallthrough;
`response` contains integer status, headers, and body. It also delivered logical asset
path helpers, stylesheet tags with a preload Link header, and import map tags.

The packaged tree has 321 pinned static files and 315 manifest entries. The pinned Rust
asset reference suite passed 8/8. The manager reran the OCaml fixture suite at 5/5;
it checks 314 compiled asset hashes, 332 static response vectors, manifest/head tags,
path traversal, ranges, `HEAD`, and conditional 304. M3 connected `Assets.serve`
before route dispatch. The Dockerfile copies the corpus to `/rails/assets` and sets
`CAMPFIRE_ASSETS_DIR=/rails/assets`, but the final release image and its live asset
headers/network fetches have not been verified against the pinned Rails response.
The four JavaScript overrides have intentionally different digests from Rails and
must remain tied to the pinned Rust override bytes. M4-T1 stays open.

## M4-T2 audit

`Views` uses Tyxml for dynamic text/attribute encoding and a typed `trusted_html`
boundary for sanitized Action Text. Message links remain relative for fragment cache
safety. The manager reran the executable `test/view_golden_matrix.py --require-all`:
121 rendered golden cases pass, zero fail or unsupported, and the remaining two source
files have explicit semantic input-linkage checks. Of the rendered cases, 110 use
structural DOM comparison and 11 compare exact bytes. The structural comparator
ignores whitespace-only text and normalizes Rails CSRF fields, relative Copy-link
URLs, and an OCaml Lexxy mount shim. Six focused view tests pass. This closes the
pinned view corpus accounting, not live page byte or browser parity. M3's account,
bot, join, and profile routes have matching structural tokens in focused live
checks, but Askama/Tyxml whitespace and derived response headers still differ.
M4-T2 stays open pending route-scoped byte review and the fresh browser matrix.

## Request and media integration checkpoint

The request presenter now uses `Rich_text.present_message` with a verified SGID resolver,
and maps attached images, video, and files to signed Active Storage blob and
representation paths. Message fragments keep relative links, matching the detached Cable
presenter. Message create/update and bot paths pass `Rich_text.db_adapter` to the database
so FTS and mention queries use Action Text plain text. The account logo and user avatar
routes now serve stock assets or M6 processed PNG/WebP variants; avatar tokens are checked
for purpose and invalid tokens return 404. Both routes emit public cache validators and
answer matching conditional GETs with 304.

`test/m4_integration_test.ml` covers rich-text HTML preservation and unsafe attribute
removal through HTTP, FTS search, attachment markup and signed URLs, stock media, invalid
avatar tokens, conditional requests, and processed media. Its latest five seeded HTTP
tests pass. The disposable pinned Rails/OCaml live recheck passed 256 comparisons with zero
mismatches, including stock logos at both sizes, stored WebP avatar, and initials SVG:
status, body bytes, MIME, disposition, cache control, ETag, and Last-Modified match.
`dune runtest --force` passed at an earlier loopback-permitted checkpoint; the
ordinary sandbox's M5-T4 socket fixtures fail at `Unix.socket` with `EPERM`.

At that integration checkpoint, full page DOM, all view goldens, the remaining
rich-text corpus differences, and shared browser flows were still open. The
Action Text corpus differences have since been resolved as recorded below.

## M4-T3 verified

The direct pinned Rust comparison now matches all 658 Action Text cases in presentation,
plain text, and editable values. The 658-output security audit found no violations; nine
focused tests and five seeded HTTP integration tests pass. The fixture SHA matches the
pinned Rust corpus. M4-T3 is complete; the larger M4 browser and view gate remains open.

## M4-T4 browser handoff

The shared Chromium smoke and focused two-tab repeated-edit regression passed on
disposable OCaml servers. The latter verifies two successive edits broadcast to the
opposite tab while retaining the Turbo replacement target. The earlier strict
default-seed 40-cell capture failed all cells, mostly because every network layer
included intentional Rust JavaScript override and Rails response-metadata differences.
M8-T3's newer interim 40-cell Chromium diagnostic reports 12 pass, 28 fail, zero
errors: sign-in, join, and profile pass in all sampled desktop/phone light/dark
cells; the Designers room has exact pixels, live DOM, accessibility, and Cable,
with an extra server-side Lexxy readiness script. The direct room still misses
three message room-link text nodes. The open-room form and search page used legacy
controller adapters despite complete `Views.room_form_page` and
`Views.search_index_with` renderers; M3 has now wired their data and the focused
M3 presenter suite passes 8/8. The welcome page
was missing the sidebar body class and frame actions; M4 corrected those
attributes offline and the 123-golden matrix still passes. A fresh M8 browser
capture must confirm these live results. M4-T4 stays open for stable final smoke,
all seeds, engines, breakpoints, and the full browser parity matrix. See
[the browser log](m4-t4-browser.md) for the recorded captures and residuals.

# M4-T2 view implementation status

`lib/views.ml` / `lib/views.mli` provide the standalone view layer. Tyxml encodes
all dynamic text and attributes. `trusted_html_of_sanitized` marks rich text
supplied by the Action Text presenter. Message fragments use relative links
and contain no request Host, preserving cache safety.

## Pinned golden evidence

`test/view_golden_matrix.py` enumerates every file in the pinned
`crates/views/tests/golden/{a,b}` corpus and runs a real OCaml renderer for each
supported case. Its machine-readable result is
`docs/m4-t2-golden-matrix.json`: **121 rendered passes, 0 failures, 0
unsupported, and 2 input metadata files**, out of 123 files. The executable
gate runs with `python3 test/view_golden_matrix.py --output
docs/m4-t2-golden-matrix.json --require-all` and exits 0. The metadata files
are not counted as rendered views: `a/facts.json` checks the account,
manifest, and asset inputs used by passing pages; `a/og_embeds.json` checks
all three inputs used by passing OG fragments.

The passing cases cover exact avatar SVG, user/bot-message/bot-boost JSON,
Turbo destroy bytes, service-worker JavaScript, mailer HTML, and the PWA
manifest after the same Rails entity decoding used by Rust. They also cover
30 PWA partials; full sign-in, first-run, account, bot, profile, user,
sidebar, room, direct Ping, and search pages; room forms; message edit/show,
boost, involvement, and refresh fragments; mention, Action Text, and OG
fragments. `test/view_dom_compare.py`
compares every element, attribute, and nonempty text token. It normalizes
pinned CSRF fields and Rust's relative Copy-link rule. It also documents a
narrow OCaml Lexxy mount shim: the extra head script and the hidden
`lexxy-editor` marker are excluded from structural comparisons. That shim
waits for a mounted editor root before revealing the edit field; the browser
regression covers its behavior.

The room member full-page fixture matches all 611 structural tokens after
that operational script normalization. M4-T4's latest shared full browser
smoke and two-tab repeated-edit regression pass after the Ping and Lexxy
fixes. Its default-seed 40-cell report finds exact Designers and direct-room
pixels and ARIA across desktop/phone/light/dark on its recorded snapshot;
the report and residuals are in `docs/m4-t4-browser.md`.

## Session response bytes

Failed `POST /session` now renders the complete sign-in page. The specialized
session serializer follows the pinned Askama literal whitespace, void-tag
format, attribute order, and `&trade;` spelling while using Tyxml for dynamic
values. Its rejected Rails fixture matches all 350 structural DOM tokens.
`test/view_session_bytes.py` compares the full rejected sign-in body byte for
byte against the pinned Rails fixture after explicit CSRF and Askama block
whitespace adaptations (25,184 fixture bytes). A disposable pinned Rust/OCaml
HTTP rerun confirmed **all 25,156 body bytes equal** for row 17 in anonymous,
signed, denied, and bot roles. M8-T2 also fixed the shared stylesheet preload
header, yielding full status/header/body/state parity in all four cells.

## Current gaps

The golden corpus checks DOM/content equivalence at the same levels as Rust's
`assert_dom` and `assert_content`. It does not assert byte-identical HTML for
every full page. M3's focused live capture found all eight account/join/bot/
profile page rows structurally exact (524, 339, 357, 279, 558, 426, 730,
and 262 tokens), while Askama's whitespace and Tyxml's compact serialization
initially differed from byte 15. The shared application shell now preserves
Askama's layout whitespace, but each page's content template still needs a
fresh raw-byte comparison. The scoped sign-in serializer closes that route.
Broad page byte parity and M4-T4's remaining browser matrix remain open.

Private row 28 bot-index and row 43 account-edit captures establish the
serializer scope without exposing signed fixture values:

| Row | Rust/OCaml bytes | Rust/OCaml lines | Rust/OCaml whitespace-only nodes | Rust/OCaml whitespace-only characters | Rust/OCaml start-tag characters |
| --- | ---: | ---: | ---: | ---: | ---: |
| 28 bot index | 38,500 / 36,390 | 541 / 213 | 396 / 120 | 2,130 / 120 | 26,217 / 26,121 |
| 43 account edit | 37,630 / 36,029 | 518 / 213 | 367 / 120 | 1,579 / 120 | 26,598 / 26,493 |

Both pages have identical start-tag counts and normalized DOM, but their
whitespace deficits differ by 551 characters. A shared layout adjustment
would restore only the common shell; the remaining spacing comes from each
Askama template and helper. Exact raw bodies require per-template literal
formatting like the sign-in serializer. Any M8 allowance should be limited to
these reviewed routes after their pixel/ARIA checks, with status, headers
unrelated to the body, DOM, and state still asserted. No broad body masking
is represented as a pass here.

`Views.account_edit_page`, `account_users_page_stream`, `user_show_page`,
`profile_show_page`, `join_new_with`, `bot_form_page`, `search_index_with`,
`room_form_page`, and `direct_edit_page` are additive richer APIs; legacy
wrappers remain for controller migration. M3 has wired the account, join,
and bot APIs. `Views.pwa_manifest_json` is an exact pinned builder but
production `Controller_aux.manifest_json` still awaits M3-T4 wiring.

`dune build @check test/m4_t2_test.exe` and the 123-file `--require-all`
matrix pass locally. The broad `dune runtest test --force` command previously
exited 1 in this sandbox because M5 socket-based tests receive `Unix.EPERM`;
a loopback-permitted run is needed for that suite gate.

## M8-T3 interim browser follow-up

The default-seed direct-room browser capture omitted three live
`David and Jason` text nodes in message permalink room labels. The message
presenter had passed an empty database room name for direct rooms.
`View_presenter.message_room_name` now derives the member names from the
room's memberships and applies `Views.room_display_name` with no current-user
filter, matching pinned Rust `presenters::room_display_name(room, None)`.
The pinned seed regression checks the David/Jason direct, a four-member
direct, and a named room. The 8 focused view tests, `dune build @check`, and
the 123-file golden matrix pass after this change. A fresh browser capture
is still needed to verify the three previously missing live text nodes.

The interim Designers desktop/light normalized server diff has one extra
three-line insertion at actual lines 146–148: a closing `</script>`, an
opening `<script>`, and the `lexxy:initialize` listener with its
`requestAnimationFrame(revealWhenMounted)` retry. It comes from
`Views.lexxy_ready_head` in the room page head. The listener removes
`data-wait-for-mount` and reveals the edit field only after Lexxy mounts its
root. An earlier two-tab edit regression failed when the room page lacked
this script; the subsequent full smoke and repeated-edit runs passed with it.
It remains an intentional runtime addition. Before any narrow server-layer
allowance, the fresh browser image must again show equal pixels, live DOM,
ARIA, and Cable behavior for Designers and the direct room. The interim
image showed equality in those four layers, but predates this presenter fix.

## Shared application layout byte work

`Views.page` now uses the pinned Askama `layouts/application.html` literal
shell around Tyxml-rendered page fragments. The shared head, body, nav,
main, footer, sidebar, lightbox, and app-logo separators retain the source
whitespace and void-tag spelling. Empty head/nav/footer/sidebar blocks
follow live pinned Rust's trimmed Askama output. `Views.session_new` shares
this shell and its existing full-body byte fixture remains exact. A focused
test compares ten common shell whitespace anchors against pinned
`a/sessions_transfer.html`; Rails golden empty-block whitespace differs from
the live Rust response, so the live row 8 capture controls those four blocks.
`Views.session_transfer` now emits pinned Rust form attribute order,
hidden-input spelling, and content-block newlines; its redacted main-content
slice matches the saved row 8 Rust capture character for character (121/121).

The first fresh 16-cell live run on snapshot SHA-256 `7510d1af95e2` had
8 exact passes: row 17 all four roles, and row 8/28/49 still differed by
+28/-1,818/-494 OCaml body bytes respectively in their applicable roles.
The row 8 difference comprised precisely four extra empty Askama block
whitespace runs of 5, 7, 9, and 7 bytes. After removing those runs, a second
immutable snapshot SHA-256 `90b091071bdb` passed row 8 in **all four roles**
with exact status, headers, all 20,624 body bytes, and SQLite state. The
Rust and OCaml app containers used for this check were stopped; the shared
test proxy/network remained available for M8.

The next offline pass rendered the same frozen default seed and request data
through `test/m4_t2_probe.exe`, then compared each complete body byte for byte
with private pinned Rust captures. Source-aligned Askama whitespace and helper
attribute order now match row 28 bots index (38,500 bytes), row 49 join
(27,281), row 74 user autocomplete (8,846), row 92 involvement (21,144),
row 128 boost index (22,691), row 130 new boost (22,146), and row 137
deleted-room message (20,647). Each comparison is exact. Dynamic text and
attributes still pass through Tyxml encoders; the scoped literal strings
hold only template markup. The special-character message ID fixture in the
golden matrix caught and verified the ID attribute encoding.

The offline pass also preserved row 17's 25,184-byte sign-in fixture, `dune
build bin/main.exe @check`, 8/8 focused view tests, and the 123-file golden
accounting (121 rendered pass, two input metadata links, zero fail). The
integrated M8 matrix and fresh browser capture are still needed because the
offline probe does not exercise Caddy, full wire headers, or browser state.

The packaged `189d1ed` browser diagnostic found one search-result room-link
spacing difference: the compact message heading had `→All Talk` in its
accessible name, while the pinned template's whitespace yields `→ All Talk`.
`Views.message_item` now emits a single text-space before the room link, with
a focused assertion. The saved browser response has exactly one such heading.
After this change the 123-file golden matrix, 8 focused tests, and the eight
offline exact-body probes above still pass. Fresh browser capture must verify
the accessible name and pixels. The same prior browser report shows
`welcome/no_rooms` has exact normalized server HTML, live DOM, ARIA, pixels,
and Cable; its sidebar XHR differs in the raw response body hash and `Vary`
header. The sidebar fragment uses compact Tyxml serialization, so this
remaining body hash is a scoped serialization difference pending integrated
capture; M3-T5 owns the `Vary` header.

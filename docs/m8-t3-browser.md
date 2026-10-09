# M8-T3 browser parity evidence

Status: inventory passed on all five seeds. Current code source `2a511ac`
passes focused recaptures for the earlier attachment-edit, involvement-frame,
group-name, and avatar-upload differences across all six browser layers.
The final lean/full five-seed matrix is running against the immutable source
at `/tmp/m8-t3-harness-wt/parity/out/m8-t3-2a511ac-final-all/summary.json`.
All five lean seed matrices have completed: **956/956 exact** across the six
comparison layers, with zero errors or retries (default 874, crowd 25,
custom styles 33, first run 16, restricted 8). The first four default-seed
full batches also pass 1,801/1,801 exact (416, 496, 432, and 457 cells),
with zero flaky cases, retries, or errors; their reports are under the same
run directory at `default-full-shared-{01,02,03,04}/report.json`. The fifth
full batch passes 344/344 exact with zero final flaky cases, failures, or
errors, bringing completed full coverage to 2,145/2,145. Its Rust-side
WebKit capture retried once after `page.evaluate: Target crashed` during a
notification-help readiness wait; OCaml had no retry. A fresh one-cell
recapture is required after the broad run to clear that operational retry.
The rest of the full matrix is running.
The earlier diagnostics below are historical checkpoints.

## Pinned sources and local images

- Rust: `9872c1d9541551c0889a60e3d49a14488bd1e403`, Rails submodule
  `90b330024dec3e757c79b6a7e6568f93da8e3148`.
- Rust application image `campfire-rust:app` ID
  `sha256:c45786de2e6c7169129edd6bc6e0607c99cc768a1c4d19046f208c376d5822a3`;
  expected candidate wrapper `campfire-candidate:latest` ID
  `sha256:3cb22d67a64a5e226ded7e680b4cd26a5571ebcc13992365b738ad1c631accbe`.
- Pinned browser image `campfire-parity-playwright:1c7609be336e` ID
  `sha256:fff344db13000d5f675c6f881ef1dec007ee6106ad17b407cc757c682af9d785`.
- Rust `parity/screens.yml`: 222 states, including 48 `mutates: true` states.
  Seed distribution: default 200, custom_styles 9, first_run 4,
  restricted 2, crowd 7. Two default non-GET fragments are deliberately
  skipped by `check-inventory`, leaving 220 starting points.
- OCaml browser snapshot image `campfire-ocaml:browser-app` has local image ID
  `sha256:d0daa8971d26c60331d0118b57a6d748bb1121b2255757b9b6ff27d6d0e761f3`.
  Its parity wrapper `campfire-ocaml:browser-parity` has image ID
  `sha256:18f378c3430171aaf17d6568a574cadbcc5156c99de11ed324d4f688d4f7ef39`.
  The snapshot includes uncommitted ongoing M3/M4/M8 work and is **not** the
  final release image. Git HEAD at build was
  `cbf7bb5412e725a6705a76aa6f24f82bb4f912a8`, but the source tree was
  dirty; use the immutable image ID for this diagnostic, not that Git SHA as
  a complete source identifier.

## Inventory contract

The original pinned `parity/bin/check-inventory` extracts a hidden Rails
`authenticity_token` from `/session/new`. The pinned Rust sign-in response is
HTTP 200, `text/html`, 24,681 bytes, and has form fields `email_address` and
`password`, without a hidden token or CSRF meta field. Rust
`crates/views/src/helpers/forms.rs` and `crates/kit/src/ctx.rs` explicitly
document its `Sec-Fetch-Site` tokenless behavior. A live pinned fixture sign-in
without the token reached `/rooms/...` and returned a `session_token` cookie.
The OCaml sign-in form follows the Rust shape. The original script therefore
reports 176 default signed-state login errors against either port; this is a
tool assumption, not a candidate application failure.

`scripts/m8_check_inventory.rb` is a local copy of that pinned script with
only the Rust source root changed and login's hidden field made optional.
All route interpolation, request/status checks, redirect handling and seed
selection remain unchanged. Against fresh Rails default seed copies, the
original and the adapter each returned `198 states checked ... 0 failed`.

`scripts/m8_browser_parity.sh` starts independent disposable seed copies
through the pinned Rust candidate wrapper. It selects the Rust image for
`expected`, the OCaml image for `actual`, freezes both clocks at each seed's
`clock.now`, runs the local inventory adapter in the pinned Ruby image, and
uses the pinned reset hook for every mutating browser cell. It invokes the
pinned `parity/bin/compare` with `--no-allowlist`. Browser artifacts go to
the ignored Rust `parity/out/` directory. The script removes its test
containers and seed copies on exit.

Inventory commands, from the OCaml root, with Ruby supplied by
`campfire-m8-check:pinned`:

```sh
scripts/m8_browser_parity.sh inventory --seed default --ports 4511,4512
scripts/m8_browser_parity.sh inventory --seed custom_styles --ports 4511,4512
scripts/m8_browser_parity.sh inventory --seed first_run --ports 4511,4512
scripts/m8_browser_parity.sh inventory --seed restricted --ports 4511,4512
scripts/m8_browser_parity.sh inventory --seed crowd --ports 4511,4512
```

| Seed | Listed states | Rust checked/fail | OCaml checked/fail |
| --- | ---: | ---: | ---: |
| default | 200 | 198/0 | 198/0 |
| custom_styles | 9 | 9/0 | 9/0 |
| first_run | 4 | 4/0 | 4/0 |
| restricted | 2 | 2/0 | 2/0 |
| crowd | 7 | 7/0 | 7/0 |
| **Total** | **222** | **220/0** | **220/0** |

Private raw logs: `/tmp/m8t3-inventory-{default,custom_styles,first_run,restricted,crowd}.log`.
These checks only establish that starting points resolve with expected status.
They do not exercise the state's browser steps, Cable, rendered layers or
mutating transitions.

## Browser gate still required

An initial full default-seed lean attempt expanded to 874 cells (646 on
shared servers, 228 requiring fresh isolated servers). It was deliberately
interrupted after four failing cells at `--workers 2 --isolated 3` because the
interim image had known view gaps. **No coverage is claimed from that
interrupted run.** Its partial log is `/tmp/m8t3-default-lean.log` and partial
artifacts are under ignored `parity/out/m8-t3-default-lean-interim/`.

A bounded diagnostic instead used the same ten default-seed states as the
earlier M4-T4 report, expanded to Chromium desktop/phone and light/dark. It
used fresh Rust/OCaml default seed copies, the seed's frozen
`2026-03-02T16:00:00Z` clock, the pinned Playwright image, `--no-allowlist`,
and all six output layers. Command from the OCaml root:

```sh
scripts/m8_browser_parity.sh run --seed default --matrix lean \
  --out parity/out/m8-t3-default-40-interim --workers 8 --isolated 6 \
  --only auth/sign_in,auth/join,rooms/show/designers,rooms/show/direct,account/edit/admin,account/bots,rooms/opens/new,users/profile,search/results,welcome/no_rooms \
  --engines chromium --viewports desktop,phone --schemes light,dark \
  --breakpoints exclude
```

The 40-cell report completed in 50.8 seconds: **12 pass, 28 fail, 0 error,
0 allowed, 0 flaky**. Both inventories passed 198/0 immediately beforehand;
the wrapper restarted both servers from fresh seed copies before capture.
There were no mutating states in this subset. Full artifacts:
`/home/srikanth/projects/once-campfire-rust/parity/out/m8-t3-default-40-interim/report.html`
and its sibling `report.json`, normalized layer files and screenshots.

| State | Four cells | Main remaining difference on desktop/light |
| --- | --- | --- |
| `auth/sign_in`, `auth/join`, `users/profile` | 4 pass each | All six layers equal. |
| `rooms/show/designers` | 4 fail | Pixels, live DOM, ARIA and Cable equal. Server has an extra three-line Lexxy mount script; network differs on derived document hash, sidebar/refresh `Vary` and avatar header shape. |
| `rooms/show/direct` | 4 fail | Same server/network gaps; live DOM omits three `David and Jason` text nodes. Pixels, ARIA and Cable equal. |
| `account/edit/admin`, `account/bots` | 4 fail each | Only network differs: avatar responses omit Rust's `content-transfer-encoding` header name. Admin has one affected avatar; bots has two. All rendered and Cable layers equal. |
| `rooms/opens/new` | 4 fail | OCaml still serves the simplified `New room` form instead of Rust's `New chat room` panel, member picker and controls; desktop has 245,120 different pixels, 41 added/223 removed server lines. |
| `search/results` | 4 fail | Recent-search sidebar links and clear control are missing; desktop has 2,705 different pixels and 1 added/49 removed server lines. |
| `welcome/no_rooms` | 4 fail | OCaml lacks the `sidebar` body class and full sidebar-frame action list; desktop has 79,406 different pixels. |

The affected avatar network paths are normalized as
`/users/«signed_id:user/avatar:149087659»/avatar?v=20260125160000`
(admin) and avatar IDs `394959859` and `773523956` (bots). Rust includes
`content-transfer-encoding` in their response header-name set; OCaml does
not. The room refresh and sidebar resource responses also have Rust
`Vary: accept, accept-encoding` versus OCaml `accept-encoding`.

These are findings from the immutable interim image. M3/M4 owners were sent
the exact report and resource paths. Rebuild and rerun after their route and
view integration; do not infer final source behavior from this image.

### Packaged release-candidate diagnostic

A second bounded run used packaged `campfire-ocaml:rc-189d1ed-amd64` (image ID
`sha256:4636f3e8e077786aa1bec9c637dc139d375202caa0c1873c56eb4d6a00df10a0`)
and the pinned parity wrapper built on it (image ID
`sha256:8241bd412963cad37456201c9b6c5360c71bd49a56dddbe27e5f4ede0819d5c7`).
The Rust candidate and Playwright image IDs above remained fixed. This image
predates the latest offline M4 view-byte edits and is a diagnostic, not final
release evidence. Both default-seed inventories again passed 198/0. The same
ten states and Chromium desktop/phone light/dark command above, with output
`parity/out/m8-t3-default-40-rc-189d1ed`, completed 40 cells in 52.4 seconds:
**24 pass, 16 fail, 0 error, 0 allowed, 0 flaky**. None of the ten states
mutates data. The report is
`/home/srikanth/projects/once-campfire-rust/parity/out/m8-t3-default-40-rc-189d1ed/report.html`.

| State family | Four cells | Remaining difference |
| --- | --- | --- |
| Sign-in, join, admin edit, bots, new room, profile | 4 pass each | All six layers equal. This closes the prior avatar header and simplified new-room differences for these cells. |
| Designers and direct rooms | 4 fail each | Pixels, live DOM, ARIA and Cable equal. The server layer has only the intentional three-line Lexxy mount script. The network layer differs on the document and sidebar body hashes and on missing `accept` in the `Vary` value of the room refresh and sidebar responses. The direct-room name now appears in live DOM. |
| Search results | 4 fail | Normalized server HTML, live DOM, network and Cable equal. Compact raw HTML removes a space before the room link: ARIA says `JZ 3:30 PM →All Talk` instead of `JZ 3:30 PM → All Talk`; pixels differ. Recent links and controls now render. |
| Welcome with no rooms | 4 fail | Pixels, server HTML, live DOM, ARIA and Cable equal. The sidebar network response differs in body hash and has `Vary: accept-encoding` rather than `accept, accept-encoding`. |

The packaged image shows that several interim differences were fixed, but the
resource response hashes and `Vary` values remain distinct product behavior.
The search accessibility spacing is also a real remaining difference despite
equal normalized HTML. The final image must be recaptured after current source
changes; no result here is counted toward the 874-cell default lean sweep.

### Clean `ff61768` candidate diagnostic

The next bounded capture used clean source revision
`ff617683b4fa64be34c8c20b454877820a4b8431`, amd64 image
`sha256:0abeb89774d45a8cdd58dbe23d35ddedfd3867c87f7fe1c0960620ca0994051f`,
and a parity wrapper built directly on that image. Both pinned default-seed
inventories passed 198/0. The same ten-state Chromium desktop/phone,
light/dark, six-layer comparison passed **28 of 40** cells, failed 12, and
had zero capture errors. The 40-cell report is in the Rust checkout at
`parity/out/m8-t3-default-40-ff61768/report.json`. Search results now pass
all four cells, including pixels and accessible text. Sign-in, join, admin
edit, bots, new room, and profile remain four-for-four passes each.

The 12 failures are the four cells each for `rooms/show/designers`,
`rooms/show/direct`, and `welcome/no_rooms`. All 12 have equal pixels, live
DOM, accessibility tree, and Cable transcript. Both room states have one
three-line extra Lexxy readiness script in the normalized server document;
the script is retained because the two-tab repeated-edit regression submits
stale editor state without it. Its document body hash differs accordingly.
Room refresh responses, including the empty `\n` body, are exact. The only
other differing network response is `GET /users/me/sidebar`: headers now
match, including `Vary: accept, accept-encoding`, while the normalized body
hash differs for both David and Loner.

The sidebar body cause was traced to Rust's
`layouts/turbo_rails/frame.html` envelope for `Turbo-Frame` requests. OCaml
returned the inner `<turbo-frame>` by itself. A corrected isolated live
fixture capture verified the inner bytes are identical for David and Loner;
Rust adds exactly 63 bytes around them: a 44-byte
`<html><head>…</head><body>` prefix and a 19-byte closing suffix. The
targeted `Views.frame_page`/sidebar controller fix is now in the working
tree and passes M3-T2's seeded 12-test suite, but this clean-image browser
report predates that fix. Rebuild and recapture before claiming closure.

### Full release sweep

The script-free source at `e4b71e6` passed the shared two-tab repeated-edit
regression and the complete shared Chromium smoke on fresh disposable OCaml
storage. The shared verification checkout is `b7647b4`: both flows now wait
for Lexxy's actual editing root before typing, because the visible
contenteditable element can precede the mounted editor by one animation
frame. A diagnostic without that wait showed visible new text while Lexxy's
value still contained the old message; the save therefore sent the old value.

The pinned Rust/OCaml focused comparison first captured ten Chromium
desktop/light cells on the script-free image: eight were exact in all six
layers, including six busy-room pagination states. The two edit cells differed
only in the raw GET edit-frame body hash. Their pixels, server document, live
DOM, accessibility and Cable were exact. The captured edit response showed
compact OCaml HTML versus Rust's multiline Askama output, including Rust's
unclosed no-block delete form. After `Views.message_edit` matched that wire
format, the two edit cells passed **2/2 exact**, zero errors or retries, at
`/tmp/m8-t3-harness-wt/parity/out/m8-t3-exact-edit-focused/report.json`.
The earlier eight exact cells are at
`/tmp/m8-t3-harness-wt/parity/out/m8-t3-lexxy-no-shim-focused/report.json`.
Together they resolve all ten focused states; the full matrix below remains
the M8-T3 gate.

The subsequent `e4b71e6` default lean run completed 178/178 exact cells in
its first two batches. Its third batch completed 78 pass and four fail, with
zero retries/errors: every failure was a network-only raw response hash for
the attachment edit form. Source `d223a0f` gives the attachment branch the
same Rust-exact edit-frame serialization; a fresh four-cell Chromium
desktop/phone, light/dark comparison passed **4/4 exact**, zero retries or
errors, at
`/tmp/m8-t3-harness-wt/parity/out/m8-t3-attachment-edit-focused/report.json`.
The old-image sweep was stopped after the third batch. The clean `d223a0f`
all-seed lean/full run then passed its first five batches **401/401 exact**,
zero retries or errors. Batch six passed 56/72 and found 16 network-only
differences in the four room involvement states across Chromium desktop/phone
light/dark. The server document, live DOM, accessibility, Cable and pixels
were exact. OCaml used the full page layout for a `Turbo-Frame` request,
adding a stylesheet `Link` header and changing the raw frame response body.
That run was stopped after the sixth complete report at
`/tmp/m8-t3-harness-wt/parity/out/m8-t3-d223a0f-all/summary.json`.

Source `7352f48` uses the pinned frame layout for nonempty `Turbo-Frame`
requests to room involvement. Its controller regression and forced Dune suite
pass, and a clean image recapture passes **16/16 exact** cells across all six
layers, with zero retries or errors, at
`/tmp/m8-t3-harness-wt/parity/out/m8-t3-7352-involvement-16/report.json`.
The clean `7352f48` default lean matrix completed all 14 disjoint batches:
**866 pass, eight fail, zero errors or retries** across 874 cells. Four
group direct-room cells differed because OCaml omitted the final “and” in
the room title and heading; four profile avatar-upload cells differed because
the upload was ignored, leaving the old avatar URL and no Delete button.
The run stopped at the default-seed boundary, with no crowd cells, at
`/tmp/m8-t3-harness-wt/parity/out/m8-t3-7352f48-all/summary.json`.

Current clean source `2a511ac` uses the existing Rails-style sentence
formatter for group direct-room names and persists profile avatar uploads,
touching the user cache version and replacing old attachments. The forced
OCaml suite passes 41 suites and 297 cases. A fresh eight-cell Chromium
desktop/phone light/dark recapture passes **8/8 exact** across server, live
DOM, ARIA, network, Cable and pixels, with zero retries or errors, at
`/tmp/m8-t3-harness-wt/parity/out/m8-t3-2a511ac-group-avatar-8/report.json`.
The full all-seed lean/full matrix remains open for this source.

Run each seed in both matrices using the pinned Playwright image and frozen
clock, for example:

```sh
scripts/m8_browser_parity.sh run --seed default --matrix lean \
  --out parity/out/m8-t3-default-lean --workers 2
scripts/m8_browser_parity.sh run --seed default --matrix full \
  --out parity/out/m8-t3-default-full --workers 2
```

Repeat for all five seeds. Capture all six layers (server, live DOM, ARIA,
network, Cable and pixels), including Firefox/WebKit, breakpoint, mutating
and multi-actor states. Report any failed readiness or missing engine as
not run. Rebuild the app/wrapper after M3/M4 finishes and rerun the shared
Chromium functional smoke on the final image.

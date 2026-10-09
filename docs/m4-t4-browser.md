# M4-T4 browser behavior log

Status: in progress. The shared Chromium smoke and a focused two-tab repeated-edit regression pass. A 40-cell pinned Rails comparison still has view and network differences; M8-T3 owns the later full browser matrix.

## Reproduction setup

- OCaml repository: `/home/srikanth/projects/once-campfire-ocaml`
- Pinned Rails repository: `/home/srikanth/projects/once-campfire-rust`
- Shared verification: `/home/srikanth/projects/once-campfire-verification`
- Browser: system Chrome `/usr/bin/google-chrome`, Playwright installed in the shared verification repository with `npm ci --ignore-scripts`.
- Use a new temporary storage directory for each first-run smoke. Example:

```sh
cd /home/srikanth/projects/once-campfire-ocaml
dune build bin/main.exe
storage=$(mktemp -d /tmp/campfire-m4t4-smoke.XXXXXX)
DISABLE_SSL=1 SECRET_KEY_BASE=$(printf 'abcdef0123456789%.0s' {1..8}) \
  CAMPFIRE_STORAGE_PATH="$storage" _build/default/bin/main.exe serve --port 3217
```

From another shell:

```sh
cd /home/srikanth/projects/once-campfire-verification
PLAYWRIGHT_CHROMIUM_EXECUTABLE=/usr/bin/google-chrome \
  node browser/smoke.mjs --base http://127.0.0.1:3217
```

Only pinned fixture credentials are used: `browser@example.test` and `browser test password`. The temporary database, files, and signed session cookies are disposable.

## Live findings

1. First-run stylesheet requests failed in Chrome with `ERR_NETWORK_CHANGED`. A gzip response advertised the uncompressed body length (1218 bytes) but sent 647 bytes. `Http_gzip.apply` now rebuilds the Cohttp response, yielding chunked transfer encoding with the correct on-wire body length. `python3 test/m4_t4_wire.py` passed cold/cache gzip and identity requests through a real listener.
2. A rendered `<div class="lightbox">` covered the first-run form. The page now renders the closed Rails-style `<dialog>`.
3. The room page lacked the current-user meta tag, message template, Lexxy composer, typing indicator targets, and subscribed sidebar. Added those pieces. Two tabs now connect to RoomMessagesChannel and Turbo::StreamsChannel; the shared smoke observed three sends including stored markup, no duplicates, and a correct copied permalink.
4. Message editing lacked a matching Turbo frame. Added the edit frame and Lexxy form. The editor's contenteditable child appears before Lexxy mounts its root on the next animation frame, so Playwright `.fill` could change only the DOM while the form submitted stale Lexxy state. The page now hides the edit control until `lexxy:initialize`; a Chrome check confirmed the submitted HTML and second-tab update. A pinned Rails check established that the same `.fill` call works there, so the shared smoke's editing semantics remain intact.
5. Search results existed but stayed hidden by the pinned CSS. The missing `search-results` Stimulus wrapper, classes, and targets are now rendered. Chrome reported `visibility: visible` and the edited message in the result.
6. The profile route rendered a read-only user view. It now has a PATCH bio form, signed four-hour transfer link, and QR link. The fresh smoke passed profile persistence, transfer URL, and QR image decode.
7. The account settings form posted to a PATCH-only route. Added `_method=patch`; fresh smoke confirmed persistence.
8. Room create/edit form lacked the accessible room-name label and the expected Save control; edit also lacked PATCH override. The room page lacked its settings link. A fresh smoke confirmed room creation, and focused Chrome confirmed room rename and second-tab sidebar update.
9. A fresh smoke passed bot posting and rename and custom style persistence. Room settings navigation initially had an unclickable link because the pinned navbar uses `pointer-events: none` and only `.btn` descendants opt into clicks. Added `.btn` to its links and confirmed the link is the Chrome hit target.
10. The account view lacked an invitation link. Added it, plus complete join and auto-submit transfer forms. A fresh smoke then passed transfer sign-in and invitation join. A focused API-context check found the transfer GET returned 406 under `Accept: */*`; it now serves HTML as Rails does.
11. New Ping initially loaded Turbo's “Content missing” error because `rooms/directs#new` returned a generic page without the expected `direct_rooms_control` frame. Added the pinned frame, autocomplete picker, and selection template, including `data-template-id` on the select. The fresh full smoke passed autocomplete-started direct Ping.
12. A sign-in parity capture showed a small 80px logo, missing translation controls and icons, and missing owner contact/version. The sign-in view now follows the pinned Rails template, including the 300px logo figure, seven-language menus, input and submit icons, owner contact, version badge, reload meta, Cable/VAPID meta, and Rails-shaped form. The Lexxy readiness listener is scoped to editor pages. The sign-in parity cell now has exact server DOM, live DOM, accessibility, and pixel equality.

The first passing full shared-smoke result used fresh OCaml storage on port 3223 after sign-in changes:

```sh
cd /home/srikanth/projects/once-campfire-verification
PLAYWRIGHT_CHROMIUM_EXECUTABLE=/usr/bin/google-chrome \
  node browser/smoke.mjs --base http://127.0.0.1:3223
```

Exit 0: `PASS: setup, two-tab live messaging, duplicate suppression, and stored-markup safety, copying message permalinks, editing, search, profile/account updates, QR codes, live room creation/renaming, bots, custom styles, session transfers, joining, and autocomplete-started direct pings in Chromium.` The previous full run on fresh port 3222 also passed. The shared smoke source retained its original Lexxy `.fill` call; it only gained a system-Chrome executable override and optional debug output.

## Rails comparison and remaining checks

Pinned Rails reference was started with `../once-campfire-rust/parity/bin/reference up --seed first_run --port 3118`. A focused two-tab Chrome check confirmed that Rails Lexxy `.fill` updates the editor value and second tab. A whole shared smoke against the reference stops earlier because its copied permalink omits the forwarded port 3118; this is a reference-proxy URL condition and does not establish an editor mismatch. The shared smoke source has not changed its `.fill` call.

### Pinned Rails parity samples

Pinned default-seed Rails reference: `parity/bin/reference up --seed default --port 3101 --time 2026-03-02T16:00:00Z --freeze`. OCaml used a copied default seed in `/tmp/campfire-m4t4-parity.a8Jn1E`, port 3201, the pinned `parity/.env.reference`, and the same frozen wall clock with libfaketime. The capture command was:

```sh
cd /home/srikanth/projects/once-campfire-rust
parity/bin/compare --expected http://127.0.0.1:3101 --actual http://127.0.0.1:3201 \
  --expected-name rails --actual-name ocaml --out parity/out/m4t4-sign-in-final \
  --only auth/sign_in --engines chromium --viewports desktop --schemes light \
  --breakpoints exclude --workers 1 --no-allowlist
```

The sign-in result is in `parity/out/m4t4-sign-in-final/report.html`: pixel, server DOM, live DOM, ARIA, and Cable layers are equal. The network layer has two differing hunks. Four JS paths are intentionally different because the OCaml build carries the exact pinned Rust overrides from `crates/assets/overrides` for `copy_to_clipboard_controller`, `rooms_list_controller`, `base_autocomplete_handler`, and `file_uploader`; byte hashes match those Rust overrides. The Rails reference manifest and Rails compiled SHA fixture list the older Rails JS bytes and digests. Replacing the overrides would regress browser behavior. Other network differences are Rails-only response headers and session cookie behavior on navigation/logo responses. The cell therefore remains a strict network failure.

The representative authenticated `rooms/show/designers` cell used the same command with `--only rooms/show/designers --out parity/out/m4t4-room-after`. Its report has 174,613 differing pixels at 1440×900, server DOM 167 added/533 removed, live DOM 600/1092, ARIA 60/120, network 43/166, and Cable equal. The capture includes server HTML, live DOM, ARIA, network, Cable, and PNG for each target. Authenticated view markup remains a substantial M4-T2 parity gap.

### Authenticated room parity handoff

The screenshots show the primary visual cause. Rails has a compact fixed room nav, a rich composer pinned at the bottom, and a styled sidebar with Ping avatars and room rows. OCaml has a large plain heading/nav, a bare composer with a text button, and plain sidebar links. The same pinned CSS is loaded; the missing template structure and classes explain the 174,613-pixel difference. Main sources and seams:

| Surface | Pinned Rails source | OCaml seam and observed mismatch | Owner |
| --- | --- | --- | --- |
| Room nav, footer/composer, message area | `reference/app/views/rooms/show/_nav.html.erb`, `_composer.html.erb`, `reference/app/helpers/messages_helper.rb` | `Views.room_show` renders extra account text link, plain h1/settings/notification links, no search/attachment/rich-text controls, plain send button, and fewer Stimulus actions. ARIA has an extra “37signals” link and “Notifications” link where Rails has a button. | M4-T2 views |
| Sidebar | `reference/app/views/users/sidebars/show.html.erb`, `rooms/_direct.html.erb`, `_direct_placeholder.html.erb`, `_shared.html.erb` | `Views.sidebar_frame` lacks avatars, placeholder users, buttons, room badges/order and styling classes. Live ARIA has unnamed direct links and profile link; includes Archive in a different place. | M4-T2 views; `Controller_rooms.user_sidebar` supplies data |
| Boosts | `reference/app/views/messages/boosts/_boost.html.erb`, `_boosts.html.erb` | `Views.boost_item` emits bare `<li>` with text, rather than interactive avatar, content button, delete form and accessible label. This accounts for many repeated ARIA removals and visibly broken emoji pills. | M4-T2 views |
| Message metadata | `reference/app/models/user.rb#title`, `reference/app/helpers/messages_helper.rb#message_tag` | `View_presenter.user` sets `title=name` instead of `name – bio`; `View_presenter.message` fixes `all_emoji=false` even for emoji-only text. Rails applies `message--emoji` and title/bio names. `Views.page` also omits Rails `admin` body class. | M4-T2 presenter/views |
| Sounds and attachments | `reference/app/helpers/messages_helper.rb#message_presentation` and the media/storage partials | `Views.message_presentation` uses native `<audio controls>` instead of Rails sound button. Image/video/text attachments are generic links or fixed 320×240 thumbnails instead of responsive lightbox, poster/video, and download/share controls. ARIA labels differ; network loads two MP3 ranges that Rails does not, and misses attachment icons. | M6 media/presenter and M4-T2 markup |
| Invitation | `reference/app/views/rooms/show/_invitation.html.erb` | OCaml inserts a visible invite link in Designers; Rails only inserts the system welcome card in the original room when messages are not paged. | M4-T2 views/controller |
| Asset and HTTP network | `crates/assets/overrides/*`, Rails `reference/app/javascript/*`; Rails controller/middleware responses | Four JS digest paths differ by design because Rust overrides Rails bytes. Most remaining missing SVG fetches follow absent view controls. Navigation/logo response header and session cookie differences are server HTTP behavior. | Keep Rust overrides; M3 HTTP for headers |

The normalized room server diff starts at `<body class="sidebar admin">` versus `<body class="sidebar">`, then diverges at nav and many message/boost/media sections. The live diff adds extensive sidebar and Lexxy composer structure differences. Cable captures are equal, so this particular matrix failure is rendered UI/network rather than a websocket transcript difference. The comparison artifacts are the reproducible evidence; use `parity/out/m4t4-room-after/{rails,ocaml}/rooms/show/designers/chromium-desktop-light.{server.norm.html,live.norm.html,aria.yml,network.txt,png,cable.txt}`.

The room parity handoff above records the earlier baseline. M4-T2 subsequently fixed the room nav, composer, sidebar, boosts, media presentation, and user metadata; the current matrix below supersedes those baseline room metrics.

### Repeated edits and latest fresh smoke

The focused regression `once-campfire-verification/browser/repeated-edit.mjs` creates a disposable account, opens two Chromium tabs, sends one message, edits it twice from alternating tabs, and checks that the opposite tab receives each update while `#presentation_message_<clientid>` remains in both tabs. It first found that `Cable_broadcasts.message_replace` sent only presentation inner HTML for Turbo `replace`, removing its own target. The broadcast now wraps the inner HTML in the Rails `messages/_presentation` div with the same ID, direction, and Stimulus targets. After M4-T2 restored the room Lexxy readiness listener and pinned edit form markup, a fresh run on port 3223 exited 0: `PASS: two consecutive edits broadcast to the opposite tab and retain both presentation targets`.

M4-T2's new sidebar layout briefly pushed Ping's visible text submit button outside the 1280px viewport (x=1340.84–1453.59). The form was valid and made no POST; the pinned Rails direct-new template uses icon buttons with screen-reader text. M4-T2 ported those controls and its full direct-new golden passed. The next fresh full smoke against candidate snapshot SHA-256 `4adcd9c39da167057a0a9d8172bb8121b0574b876f874b80705babde23fbd979`, port 3224, exited 0 with its original final `PASS` line. Its sidebar draft check preserved the actual input node, typed text, and selected recipient through a subscription refresh. A separate run on port 3227 completed every functional step but failed the final console check with many `net::ERR_NETWORK_CHANGED` messages. M8-T2 confirmed it was restarting two Docker containers before each of 708 requests while that run was active, changing network interfaces. The first failing run did not record URL details; a later debug rerun logged failed request URLs if any and observed none, then passed without weakening the smoke check. A final clean run after the Docker reset interval remains for M8-T3.

### Representative default-seed lean capture

The pinned default seed ran with Rails at 3101 and an OCaml seed copy at 3202, both frozen at `2026-03-02T16:00:00Z`. The OCaml candidate was immutable `/tmp/campfire-m4t4-matrix-main-v2.exe`, SHA-256 `05780f65d71228960569fb06f355f106552e69ba028518e6a38e6db983380bda`. Reproduce the 40 selected cells with:

```sh
cd /home/srikanth/projects/once-campfire-rust
parity/bin/compare --expected http://127.0.0.1:3101 --actual http://127.0.0.1:3202 \
  --expected-name rails --actual-name ocaml --out parity/out/m4t4-matrix-default \
  --seed default --matrix lean \
  --only auth/sign_in,auth/join,rooms/show/designers,rooms/show/direct,account/edit/admin,account/bots,rooms/opens/new,users/profile,search/results,welcome/no_rooms \
  --engines chromium --viewports desktop,phone --schemes light,dark \
  --breakpoints exclude --workers 3 --no-allowlist
```

Result: **40 fail, 0 pass, 0 errors** under strict comparison. This includes 10 representative states × desktop/phone × light/dark. Report and every capture layer: `parity/out/m4t4-matrix-default/report.html` and sibling JSON/capture files. Desktop/light figures below are representative; the report contains all 40 cells.

| State | Pixels different at 1440×900 | Server added/removed | Live added/removed | ARIA added/removed | Leading cause |
| --- | ---: | ---: | ---: | ---: | --- |
| `auth/sign_in` | 0 | 0/0 | 0/0 | 0/0 | Network: four intentional pinned Rust JS overrides, Rails session cookie and preload `Link` header. |
| `rooms/show/designers` | 0 | 3/0 | 0/0 | 0/0 | Server-only Lexxy readiness script; network remains different. |
| `rooms/show/direct` | 0 | 3/3 | 0/3 | 0/0 | Same script plus missing `David and Jason` message room-link text in three live messages. |
| `welcome/no_rooms` | 79,406 | 2/2 | 2/2 | 0/0 | Missing `sidebar` body class and sidebar-frame action attributes. |
| `auth/join` | 172,194 | 24/244 | 23/243 | 11/22 | Simplified join form lacks pinned nav, avatar upload, translation controls, owner footer. |
| `account/edit/admin` | 299,558 | 66/368 | 66/368 | 27/63 | Simplified account form lacks logo upload, invite controls, rich member rows, admin nav. |
| `account/bots` | 397,151 | 61/337 | 60/336 | 10/38 | Missing bot avatars, translation/help copy, attachment curl commands and copy buttons. |
| `rooms/opens/new` | 245,120 | 41/223 | 40/222 | 19/53 | Simplified room picker omits translation, Everyone/private toggle, avatar member list. |
| `users/profile` | 192,545 | 35/571 | 35/571 | 10/77 | Missing avatar upload, translation controls, memberships/notification controls and other profile sections. |
| `search/results` | 241,195 | 195/277 | 197/279 | 6/15 | Missing search nav, exit/clear controls and recent-search sidebar; result heading spacing differs. |

The `auth/join`, account, bot, room-form, profile, search, and welcome markup gaps belong to M4-T2. The four Rust asset overrides should remain. M8-T3 can reuse the artifact to prioritize the full seed/form-factor/browser matrix; this sample did not cover `crowd`, `custom_styles`, `first_run`, or `restricted` seeds.

Still required for M4-T4 closure: a stable smoke after M8-T2's Docker reset interval and M8-T3's full browser matrix across seeds/engines/breakpoints after M4-T2 view parity work.

## Packaged d6600ed room recapture

M8-T3 reran `rooms/show/designers` in Chromium desktop/light on the clean
d6600ed packaged app after repairing the detached Rails submodule used by the
browser harness. The one-cell report has zero retries and zero capture errors.
Pixels (1440×900), live DOM, ARIA, and Cable are exact. The strict result is
still a failure because the OCaml server has three added script lines and the
document network hash differs: this is the 557-byte Lexxy readiness listener
required by the passing two-tab repeated-edit regression. There are no other
server or network differences in this cell. The report is at
`/tmp/m8-t3-harness-wt/parity/out/m8-t3-d6600ed-room-desktop-light-rerun/report.json`.

This fresh packaged sample, the complete five-seed HTTP view sweep, and the
123-file view corpus close M4-T2 with the script documented as an intentional
functional difference. M4-T4 remains open for the full browser matrix across
seeds, engines, viewports, schemes, breakpoints, and interactions. The older
captures above are retained as historical debugging evidence.

## Script-free Lexxy regression, 2026-10-09

The current source `e4b71e6` removes the extra room script and hidden edit
field attributes. The shared verification checkout `b7647b4` waits for
`lexxy-editor.editor.getRootElement()` before entering edit text. This wait
matches the real readiness condition: an earlier diagnostic filled a visible
contenteditable element while Lexxy's value still held the old body. On fresh
disposable storage, both `browser/repeated-edit.mjs` and the complete
`browser/smoke.mjs` pass in Chromium with the script-free OCaml build.

The pinned view inventory passes 121 rendered cases and two input metadata
cases. The strict room response check matches Rust byte for byte for seeded
rows 95 and 100. A ten-state packaged browser diagnostic has eight exact
cells on the first script-free image; its only remaining differences were raw
edit-frame response hashes. The edit serializer was aligned with Rust's
Askama/ERB bytes, and those two cells then passed exactly with no errors or
retries. M4-T4 still awaits the complete all-seed browser matrix.

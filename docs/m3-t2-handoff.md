# M3-T2 controller handoff

M3-T2 is **accepted** on the clean d6600ed five-seed gate described at the end;
the f099059 gate below is historical evidence.
`lib/controller_accounts.ml` maps all 73 pinned Rust route
rows owned by this ticket. The 27 rows mapped by Rust to `action_not_found`
return HTTP 404, including for anonymous requests. Implemented actions use
asynchronous database access; password hashing runs off the Lwt event loop.

## Focused live HTTP and state comparison, 2026-10-09

The disposable default-seed Rust and OCaml servers were reset independently
for each case. The frozen-clock comparison used pinned Rust commit
`9872c1d9541551c0889a60e3d49a14488bd1e403`, 20 selected account,
join, profile, and user route rows, and all four roles. It compares exact
status, headers, body bytes, and SQLite table hashes. The result improved from
48/80 exact passes in `docs/m8-t2-http-state.json` to **64/80 exact passes**, with
no regressions and no request, snapshot, status, or state errors. The focused
report is `/tmp/m3-t2-focused-20261009.md` with sibling JSON.

Sixteen formerly failing cases now pass exactly:

| Rows | Role | Closed difference |
| --- | --- | --- |
| 23, 24, 29, 33, 34, 40, 41, 45, 46 | signed | Public 400 `ParameterMissing` response headers and empty body |
| 26, 27 | signed | Public 404 exception page, headers, and body for missing bot key |
| 49 | signed, denied | Absolute root `Location` on guest-only join GET |
| 50 | signed | Absolute root `Location` on guest-only join POST |
| 50 | anonymous, bot | Public 400 join error headers and empty body |

The remaining 16 failures are rows **28, 30, 31, 39, 43, 49, 59, 73**,
two roles each: signed and denied on every row except join row 49, which is
anonymous and bot. All return matching HTTP 200 and identical structural DOM
tokens when parsed with `test/view_dom_compare.py`'s tokenizer. Token counts
are 524, 339, 357, 279, 558, 426, 730, and 262 respectively. The first
byte difference is layout whitespace after the doctype: Rust emits formatted
HTML, OCaml emits compact Tyxml HTML. Thus body bytes and derived
`Content-Length`/`ETag` differ. M4 owns exact page serialization; no presenter
data mismatch was found in these eight captured responses.

## Controller and view integration

The controller supplies the first administrator contact to the join page;
bot room ordering, webhook and avatar data to the bot pages; role-filtered
members and pagination to the account pages; and transfer, status, avatar, and
membership data to the profile and user pages. It calls M4's additive
`join_new_with`, `bot_form_page`, `account_edit_page`,
`account_users_page_stream`, `profile_show_page`, and `user_show_page` APIs.
Missing account/user/bot records now use the pinned public 404 exception where
Rust raises `RecordNotFound`; missing action parameters use the public 400
exception response. The intentional in-action `head :not_found` join-code
response remains empty.

`dune build bin/main.exe` and `dune exec ./test/m3_t2_test.exe` passed on
2026-10-09. The latter ran **11/11** seed-backed cases covering route inventory,
session/onboarding/account/bot/join/profile/bans/transfer/push action logic,
role visibility, M4 presenter inputs, public exception headers, and the
absolute join redirects. The added avatar case covers stock SVG and uploaded
WebP file responses, a 206 byte range, and the distinct rendered-initials SVG
response. These focused tests support action logic but do not replace a full
live route and state matrix.

### Avatar resource follow-up

M8-T3's 40-cell browser diagnostic found three signed avatar resources whose
Rust `send_file` responses included `content-transfer-encoding: binary` while
OCaml omitted it. The account controller now adds that header to `stock_file`
and `variant_file` responses only, including byte ranges. It leaves generated
initials SVG and shared Active Storage file serving alone. A rebuilt immutable
OCaml binary was compared with the pinned Rust server on independent disposable
default-seed copies. All three identified URLs returned exact matching status,
headers, and body bytes: Jason (`149087659`, 3,364 bytes), Bender Bot
(`394959859`, 884 bytes), and Deploy Bot (`773523956`, 3,364 bytes). Each was
HTTP 200 with `content-transfer-encoding: binary`. This closes the three
resource differences reported by the focused browser diagnostic; a rebuilt
browser sweep remains M8-T3's gate.

## Earlier integration dependencies

| Owner | Response or effect still requiring verification |
| --- | --- |
| M4 views | Exact Rails HTML serialization and derived headers on the eight live page rows above; other account/onboarding page and Turbo variants beyond this focused slice. M4's pinned DOM goldens cover the structural pages. |
| M5 realtime and delivery | Remote disconnect after session destroy or ban, and Web Push test delivery effects under controlled endpoints. |
| M6 attachments and assets | Account logo and user avatar assignment/purge effects in controller actions, beyond the earlier image-serving comparison. |
| M8 live verification | Full account/onboarding route, method override, malformed input, and alternate-seed response/state coverage; positive push subscription creation and duplicate behavior under controlled DNS. |

The historical 64/80 focused matrix above preceded the view-byte fixes and
is superseded for ticket acceptance by the clean f099059 gate. The message-bot
MIME and error cases at rows 83–89 and 135 belong to M3-T3.

## Clean f099059 acceptance gate

The pinned Rust candidate `9872c1d9541551c0889a60e3d49a14488bd1e403`
and clean OCaml checkout `f0990591eb3d0dc232420f034a98085823708abb`
were compared with fresh independent default-seed copies per request. The
packaged OCaml executable SHA-256 is
`1d5228d39f659c092b1881b8f6d50263178a9d08f8fff0cca22b604714753384`.
All **292/292** T2 route/role cells match exact status, headers, body bytes,
and SQLite state; this includes all 73 assigned rows for anonymous, signed,
denied, and bot roles. The positive-write matrix passes **14/14** T2 cases,
covering account roles/deactivation, bot create/rename/key reset, join-code
reset, styles/name/profile, avatar deletion, ban/unban, push subscription
deletion, and logout. The `_method` override matrix passes all **236/236**
applicable role cases across application routes. The seeded T2 suite passes
**12/12**, including first-run setup, permission paths, invalid push endpoint,
transfer, stock logo cache, and signed/public exception handling. The safe
reports are `/tmp/m8-t2-rc-f099-default.json`,
`/tmp/m8-t2-rc-f099-positive.json`, and
`/tmp/m8-t2-rc-f099-override.json`; their SHA-256 digests are recorded in
`/tmp/m8-t2-f099-handoff.md`. Alternate-seed and malformed-path sweeps
remain part of the shared M8/M3 integration gate, while T2's stated
controller scope is complete.

## Final d6600ed five-seed acceptance

The clean packaged d6600ed executable (SHA-256
`42a8df769a107df9e1ff6c48a071f861b45576b1684827dfaadefe3aafecd170`)
was compared with pinned Rust `9872c1d9541551c0889a60e3d49a14488bd1e403`.
The isolated route runner used a fresh copy of each Rails seed per case and
compared exact status, response headers and body bytes plus every SQLite table
before and after. All **1,314/1,314 eligible T2-owned route/role cells pass**:
73 rows × four roles on each of `default`, `crowd`, `restricted` and
`custom_styles`, plus 73 rows × anonymous/bot on `first_run`. That seed has no
account or signed fixture; its 146 T2 signed/denied cells are **not run**, not
counted as passes.

The focused d6600ed first-run run passes **22/22** cases, including transfer
PATCH/PUT invalid-token `head 400` MIME and join GET/POST missing-account
public 500 behavior. The 500 is intentional in the account-free seed: Rails
reads `Current.account.join_code` on nil and pinned Rust raises the matching
internal error. On the `custom_styles` seed, logo DELETE row 38 passes **2/2**
signed/denied cases, including exact transaction state: attachment removal,
account timestamp touch, and source blob plus variant purge after commit.
The seeded controller test also forces an account-touch failure and verifies
rollback leaves the attachment and files intact; repeating a successful
delete is idempotent.

T2's account/onboarding controller scope is complete. Across the whole M3
sweep, the only 16 response failures are M4-rendered signed/denied room-show
rows 95/100 in the four populated seeds; no T2 response or state difference
remains. The M3 milestone remains open for those room-view bytes and derived
Content-Length/ETag. Full safe reports are
`/tmp/m8-t2-d6600ed-{default,crowd,restricted,custom_styles,first_run}-full.json`;
the scoped first-run and custom-styles reports have matching `-focused` names.

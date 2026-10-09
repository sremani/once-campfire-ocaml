# M8-T3 browser parity evidence

Status: inventory passed on all five seeds and a 40-cell interim Chromium
diagnostic completed. Browser lean/full release matrices remain pending.

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

### Full release sweep

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

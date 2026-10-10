# M8-T5 release candidate audit (in progress)

## Current clean source target: `2a511ac`

The current code source is `2a511ac6f74fc3689f72bd039bc11d286e71d1c4`.
`/tmp/campfire-source-2a511ac.json` records a clean checkout, 321 pinned
assets and zero local Gumbo checksum errors. An independent offline audit
at `/tmp/campfire-2a511ac-upstream-provenance.json` verifies the pinned
Nokogiri archive SHA-256 and all 46 Gumbo files present in that archive,
plus the exact clean upstream OCaml WebSocket Git commit and identical ISC
license. `LICENSE-DEPENDENCIES.md` is a local notice, absent from the
Nokogiri archive; three of seven vendored WebSocket files differ from
upstream as the documented local fork. The forced OCaml suite passes
41 suites and 297 cases. Group direct-room naming and avatar uploads pass
eight focused browser cells in all six layers, with zero retries or errors.
The 123-file view matrix on the current checkout reports 121 rendered passes,
two linked input metadata cases, and zero failures or unsupported cases in
`/tmp/campfire-2a511ac-view-goldens.json`; changes since `2a511ac` are
limited to README and documentation files.
The 2a511ac five-seed shared HTTP gate passes 3,186/3,186 eligible cases
with 354 first-run roles unavailable, and positive writes pass 30/30 exact.
The local release runner `/tmp/m8-t5-2a511ac-release-verify.sh all` passed
on both architectures. The image inventories have 321 exact assets and zero
issues: amd64 `sha256:18a4cce33ec9ea7c5120feb4f758c7684e12cb3f658b5220bb38557f4562d9cd`
and arm64 `sha256:deffe1bbb71549c135ea6fc457da3fc6704bd3c6173d0322ea654a1075629194`.
See `/tmp/campfire-image-2a511ac-{amd64,arm64}.json`.
Copied Rails installation upgrade, restart, backup/restore, and rollback
passed on both images, preserving 169 messages and 14 blob checksums;
`/tmp/campfire-lifecycle-2a511ac-{amd64,arm64}.log` records the checks.
TLS, HTTP/2, certificate issuance and renewal, WebSocket restart, and clean
shutdown passed on both architectures in
`/tmp/campfire-2a511ac-protocol-{amd64,arm64}.json`.
Signed media is 233/233 exact per architecture in
`/tmp/m8-t5-2a511ac-{amd64,arm64}-signed-media.json`.
The final all-seed browser matrix is running against the frozen source; all
five lean seeds are 956/956 exact on applicable layers with zero retries or
errors: 940 page cells compare six layers and 16 pinned fragments compare
server HTML only. Its first five default-seed full batches are 2,145/2,145 exact,
with zero final flaky cases, failures, or errors. The fifth batch had one
Rust-side WebKit capture retry after `page.evaluate: Target crashed`; a
fresh one-cell recapture remains pending. The sixth batch passes 416/416
exact with no retries; the seventh passes 467/467, bringing completed full
coverage to 3,028/3,028 across seven batches. One seventh-batch WebKit
search screenshot had 114 differing avatar-edge pixels on its first attempt
and matched on its second, with all other layers already equal. That cell
also requires a fresh exact-cell recapture after the broad run. The eighth
batch passes 378/378 exact with zero retries or flaky cases. The ninth,
first mutating batch passes 194/194 with no final layer differences,
bringing completed full coverage to 3,600/3,600. One OCaml-side WebKit
capture of the rate-limited sign-in cell crashed during page evaluation and
passed on retry; it requires a third first-pass exact recapture. The
remaining full matrix is in progress.
An uncached repeat-build comparison is prepared at
`/tmp/m8-t5-2a511ac-reproducibility.py`; its source and inventory preflight
passes, and the Docker rebuild waits for browser capture to release the
shared environment. A final-image shared contract and resilience probe at
`/tmp/m8-t4-2a511ac-probe/run.sh` also passes its offline source/image
preflight and waits for that Docker interval. M8-T5 remains open for those
gates and external manifest
publication and ONCE deployment; no Git remote, registry destination, or
target host/CLI is configured, and `gh auth status` reports an invalid token.
The [publication handoff](m8-t5-publication-handoff.md) records the exact
source tag, GHCR verification, and ONCE steps once those targets are supplied.

### Earlier involvement-frame source checkpoint: `7352f48`

The earlier code source is `7352f480e79e6aaef52f9044838f23b6ed48b0cb`.
`/tmp/campfire-source-7352f48.json` records a clean checkout, 321 pinned
assets and zero local Gumbo checksum errors. The forced OCaml suite passes
41 suites and 296 cases. Its involvement Turbo-frame fix passes 16/16 focused
browser cells in all six layers, including raw GET response headers and body
hashes, with zero retries or errors. Its default lean browser matrix stopped
after 874 cases, with eight group-name/avatar-upload differences, at
`/tmp/m8-t3-harness-wt/parity/out/m8-t3-7352f48-all/summary.json`.
The offline release runner `/tmp/m8-t5-7352f48-release-verify.sh` passes
preflight for both architectures; current-source release image gates remain
open.

### Earlier attachment-edit source checkpoint: `d223a0f`

The earlier code source is `d223a0f2f778b0d8e033b4d721f9dddcde4a8aad`.
`/tmp/campfire-source-d223a0f.json` records a clean checkout, 321 pinned
assets and zero local Gumbo checksum errors. The full OCaml suite passes
41 suites and 296 cases, and all 123 view files are accounted for. The
attachment edit response fix passes four focused browser cells in all six
layers. Its all-seed lean/full run stopped after the sixth batch found 16
involvement-frame network differences. The reports are under
`/tmp/m8-t3-harness-wt/parity/out/m8-t3-d223a0f-all/summary.json`. No
amd64/arm64 release image inventory, lifecycle, protocol or signed-media
report has yet been produced from this revision. The earlier local source
evidence below remains a historical checkpoint.

### Earlier script-free source checkpoint: `e4b71e6`

The frozen code source is `e4b71e6c922438649df873682884fb1423d9b31b`.
`/tmp/campfire-source-e4b71e6.json` records a clean worktree, 321 pinned
assets, and zero local Gumbo checksum errors. The forced Dune suite passes
41 suites and 296 cases; the 123-file view accounting passes 121 rendered
cases and two input metadata cases. The original 16 room HTTP differences
now pass byte-for-byte across four populated seeds. Ten focused default-seed
browser cells are exact in all six comparison layers. The all-seed lean/full
browser run is active at
`/tmp/m8-t3-harness-wt/parity/out/m8-t3-e4b71e6-all/summary.json`.

The earlier `963e39c` images passed both architecture inventories, copied
installation lifecycle, local Pebble/TLS/HTTP2/Cable checks, and arm64
signed media 233/233. Those image results do not clear `e4b71e6`: no
amd64/arm64 release images, inventories, lifecycle, protocol, or signed-media
reports have yet been produced from this corrected source. Once the browser
run releases Docker, rebuild both architectures from the frozen e4 worktree
with the full revision in `GIT_REVISION` and `APP_VERSION`, then rerun those
local gates. The current main HEAD may include later documentation-only
commits; record the exact build source revision separately. M3 also needs a
current-revision check of other changed routes before its literal gate closes.
External publication and ONCE deployment still need a Git remote, registry
identity/credentials, target host and CLI.

## Earlier local candidate: `bb49e1e`

The frozen source is `bb49e1ed3d318d482a376ae5a12d6def957f7e06`.
`/tmp/campfire-source-bb49e1e.json` records a clean checkout, 321 pinned
assets, and zero local Gumbo checksum errors. The full Dune suite passes.
This revision includes the browser-discovered Turbo frame, empty 204,
message permalink, Lexxy edit-style, and PWA platform fixes after `98ac889`.

| Architecture | Image ID | Inventory |
| --- | --- | --- |
| amd64 | `sha256:09b0fa6bfa5b99ce9dbb0b609827202eecb0e5f5235b81835046f3ca8c080193` | `/tmp/campfire-image-bb49e1e-amd64.json`: 350 runtime packages, 288 builder packages, 321 exact assets, zero issues |
| arm64 | `sha256:70759724e8f4099935e46e371396016e46c55b45182eebf812b26d04a6ae3b98` | `/tmp/campfire-image-bb49e1e-arm64.json`: 347 runtime packages, 287 builder packages, 321 exact assets, zero issues |

Both images passed copied Rails upgrade/restart, backup/restore, rollback,
169-message and 14-blob preservation, and clean shutdown in
`/tmp/campfire-lifecycle-bb49e1e-{amd64,arm64}.log`. Both passed disposable
local Pebble certificate issue and renewal, HTTP/2 `/up=200`, redirect/Host
policy, TLS Cable restart, and SIGTERM exit 0 in
`/tmp/campfire-bb49e1e-protocol-{amd64,arm64}.json`. The arm64 image passed
233/233 pinned Rust signed-media comparisons in
`/tmp/m8-t5-bb49e1e-arm64-signed-media.json`.

Focused default-seed browser recaptures pass for Opera's install instructions
and leave only the documented Lexxy room-script/document-hash difference for
Chrome on iOS notification help. The full five-seed lean/full matrix is
running against the clean detached `bb49e1e` checkout and its exact images at
`/tmp/m8-t3-harness-wt/parity/out/m8-t3-bb49e1e-all/summary.json`.
M8-T5 remains open for its browser gate and release limitations review;
external publication and ONCE deployment still lack a registry and target host.

## Earlier candidate: `98ac889`

Clean source `98ac88910ce3811e0dc4cba6ee87b33606ef8b69` fixes the
browser-discovered duplicate-email join redirect, invalid join-code MIME,
blocked-browser VAPID metadata, and wildcard autocomplete negotiation. The
full Dune suite passes with loopback access for its socket tests; the source
manifest `/tmp/campfire-source-98ac889.json` reports `source_dirty: false` and
zero local Gumbo checksum errors. The committed source was built into these
local images:

| Architecture | Image ID | Inventory |
| --- | --- | --- |
| amd64 | `sha256:f57475e0e019d8f87876f86a4044861f837746f93f4b052ffd36f8c4d483e349` | `/tmp/campfire-image-98ac889-amd64.json`: 350 runtime packages, 288 builder packages, 321 exact assets, zero issues |
| arm64 | `sha256:7ff604b1fb9360bc945e705c1789b83b86241c55eebfb6671c75352166967ba9` | `/tmp/campfire-image-98ac889-arm64.json`: 347 runtime packages, 287 builder packages, 321 exact assets, zero issues |

Both images passed copied Rails upgrade/restart, backup/restore, rollback,
169-message and 14-blob preservation, and clean shutdown in
`/tmp/campfire-lifecycle-98ac889-{amd64,arm64}.log`. Both passed disposable
local Pebble issuance and renewal, HTTP/2 `/up=200`, redirect/Host policy,
TLS Cable restart, and SIGTERM exit 0 in
`/tmp/campfire-98ac889-protocol-{amd64,arm64}.json`. The arm64 image passed
233/233 pinned Rust signed-media comparisons in
`/tmp/m8-t5-98ac889-arm64-signed-media.json`; the prior d660 amd64 image
also passed 233/233, and the signed-media implementation did not change.

The full default-seed HTTP/state matrix on the 98ac889 amd64 binary is
**704 exact, four retained Lexxy room-script differences**. Focused join and
autocomplete rows 49, 50, and 74 are exact on crowd, custom styles, and
restricted seeds (12/12 each); first-run has 6/6 available cases exact and
six signed/denied cases unavailable. Reports are
`/tmp/m8-t2-98ac889-default.md` and
`/tmp/m8-t2-98ac889-{crowd,custom_styles,restricted,first_run}-focused.md`.
The corrected browser run uses a clean detached 98ac889 checkout and exact
image wrapper. Its first 84-cell default-seed batch is **84/84 exact with
zero retries**; the remaining all-seed lean/full batches are in progress
under `/tmp/m8-t3-harness-wt/parity/out/m8-t3-98ac889-all/summary.json`.
M8-T5 stays open for that browser gate, review of the documented Lexxy,
Caddy, gzip-wire and performance limitations, and publication/deployment.

This is a working provenance record, **not release clearance**. Clean local candidate
`bcb440cec2760d0c116f37520585f2f24e663813` now has amd64 and arm64 images,
complete package/license inventories, and passing copied-install upgrade/rollback on both
architectures. At that checkpoint, HTTP/state, full browser, clean release-profile tests,
reproducible rebuild, and external publication/deployment gates remained open.
Do not check M8-T5 yet.

The subsequent clean source `d6600edb94e5e038734786c4f927ec7ff05bcca0`
passed `dune clean`, a release-profile build, the full Dune test suite, and the
123-case view matrix (121 rendered, two semantic inputs, zero failures). Logs
are `/tmp/campfire-d6600ed-clean-release-build.log` and
`/tmp/campfire-d6600ed-clean-runtest.log`; the view report is
`/tmp/campfire-d6600ed-view-goldens.json`. Its source manifest
`/tmp/campfire-source-d6600ed.json` records a clean checkout, 321 assets,
87 application source files, eight C stubs, 11 release files, and zero local
Gumbo checksum errors. The local amd64 image
`campfire-ocaml:rc-d6600ed-amd64` has ID
`sha256:ac006d4c5d5ca83db3ee0cc58c4f9af2d02d5c66161dc201449613bca08565d0`.
Its final image inventory, arm64 image, copied-install lifecycle, broad parity,
and release destination remain pending at this checkpoint.

The d660 follow-up built arm64 image
`sha256:4f2e61e9e6e9c6049042e8d49ebc6a3781d1e4850d02ceb6b30c5fa4263e9161`.
Both d660 image inventories report 321 byte-identical assets, complete
builder/runtime notice coverage and native library links, and zero issues:
`/tmp/campfire-image-d6600ed-{amd64,arm64}.json`. Both copied-install
lifecycles pass old Rails start, OCaml upgrade/restart, backup/restore and
rollback with 169 messages and 14 blob hashes preserved, two additive indexes,
clean SIGTERM, and SQLite integrity; see
`/tmp/campfire-lifecycle-d6600ed-{amd64,arm64}.log`. Packaged Cable and
signed-media gates then passed with the same frozen clock as the route sweep;
full browser parity and deployment/publication remain open.

## Source and notices

| Input | Pinned origin and local evidence | Distribution action |
| --- | --- | --- |
| Application | `LICENSE` is 37signals MIT, SHA-256 `fa0d1454375cbc7701bc13d916c3ae71e613b8ae718321641e678e09409393c4`; byte-identical to pinned Rust `MIT-LICENSE`. | The Dockerfile copies it to `/usr/share/doc/once-campfire-ocaml/LICENSE`; both final `2a511ac` image inventories find the packaged notice. |
| WebSocket | `vendor/cable_websocket/README.md` identifies `vbmithr/ocaml-websocket` commit `133eda58386c43b95fed21ba1921cbc37b629b98`; its ISC license SHA-256 is `e598f1a9f8adc81453a95e665925a110254d5f4b97c1027ba66a11c9ee16e878`. Eight local files include Campfire frame/extension changes. | The Dockerfile now copies `LICENSE.md` to the image. Preserve upstream attribution and local changes in source. |
| HTML parser | `vendor/gumbo/provenance.json` identifies Nokogiri commit `bce9a50af78a9f2ef469761a95b22886a2ab0031` and source archive SHA-256 `362d888e868240977e7c01932c8f2e106487c8d16984f82532d07023e2f1eb12`. The retained archive hash and all 46 upstream source-file hashes now match independently; `LICENSE-DEPENDENCIES.md` is a separate local notice, absent from that archive. Two original patch hashes and four patched local hashes were checked. The OCaml include-path patch, `campfire-ocaml-include.patch`, takes the C port's `util.c` hash `cdc636b38710abbdb5637364238e4cc093a28b18fc4d42abefc456f2ad5cd76f` to `b656af1cfe709bfba2f1669dc403414fcb69bedb9d32ba0ab781ede6ac3ad6c0`; `patch --dry-run` succeeded against that source. The 54-file tree plus new patch has 55 files. | The Dockerfile copies `LICENSE-DEPENDENCIES.md` and `provenance.json`; Apache 2.0 terms for libgumbo and bundled hashmap remain in the notice. See `/tmp/campfire-2a511ac-upstream-provenance.json` for the independent source check and both final image inventories for the packaged notices. |
| Static assets | `assets/README.md` records pinned Rust `9872c1d9541551c0889a60e3d49a14488bd1e403` and Rails `90b330024dec3e757c79b6a7e6568f93da8e3148`; `scripts/export_assets.py` verifies both. `assets/files` contains 321 files; the path/hash tree digest is `b22f9fe3787b4f1f52def29a89befb3503a6cf9f56223248d824a2db2c80e91f`; `assets/manifest.json` SHA-256 is `572180221700940817fbdac20953f81109f5cc161c54275611ec54d2e9cbd069`. JS bundle copyright/license comments remain in the copied files, including Turbo, Stimulus, Trix, Rails UJS, Lexxy, DOMPurify (Apache 2.0/MPL 2.0) and regenerator-runtime. | Both d660 images contain all 321 source assets byte for byte. The final d660 pinned Rust/packaged OCaml live comparison matches **1,004/1,015** paired cases: ten gzip wire responses have equal decoded content but different compressed bytes/framing, and Caddy returns 400 for malformed `/assets/%GG` versus Rust 404. See `/tmp/m8-t2-d6600ed-assets-live.json` and `/tmp/m8-t2-d6600ed-assets-handoff.md`. |
| Native bridge | Eight `lib/*_stubs.c` files cover bcrypt, gzip, QR, Gumbo, Cable zlib, libvips, curl, and webhook inflate. Clean bcb source and both images have per-file/native binary hashes in the manifests below. Gumbo's native allocator is a separate vendored local file. | Both bcb image inventories include linked-library hashes with no missing link and complete builder/runtime package copyright coverage. |

`python3 scripts/release_source_manifest.py --output /tmp/campfire-source-bcb440c.json`
records per-file SHA-256 values, both base image digests, source revision and dirty state. It
fails if the checked-in Gumbo files or patches diverge from their recorded hashes. Its
clean bcb run records `source_dirty: false`, 321 assets, 87 application files, eight C stubs,
11 release files and zero Gumbo mismatches in `/tmp/campfire-source-bcb440c.json`.
Re-run if the release source changes. The script verifies local files and patch metadata; it
does not fetch the upstream Gumbo archive or independently compare the Cable upstream commit.

## Dependency and image inventory

The Dockerfile pins `ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55`
for compilation and
`debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f`
for runtime. Direct build pins include OCaml `4.14.1-1ubuntu1`, Dune `3.14.0-1`, Mirage
Crypto `0.11.2-2build3`, PBKDF `1.2.0-3build7`, Cohttp Lwt Unix `5.3.0-1build6`, and
Conduit `6.2.1-1build3`. The explicit `tyxml` dependency is now in `dune-project`, the
generated opam file, and the build apt list. Direct runtime pins are Caddy
`2.6.2-12+deb13u1`, libvips `8.16.1-1+deb13u1`, and ffmpeg
`7:7.1.5-0+deb13u1`. `lib/dune` also links SQLite, OpenSSL, curl, zlib, crypt,
QR encode, libvips and the OCaml libraries declared there.
The development host is Ubuntu 24.04 with OCaml 4.14.1 and Dune 3.14.0; its
[104 OCaml/Dune package versions](release-inventory/host-ocaml-packages.tsv) are a
provisional compiler inventory, not proof of the final Docker build stage's resolution.

The clean d660 and prior bcb local images have the following checked inventories.
Each image's `GIT_REVISION` and `APP_VERSION` match its clean source; 321 packaged assets,
both hooks, project/vendor licenses, builder copyright notices and all linked
libraries were checked. All four JSON reports have zero `issues` and zero
`missing_package_copyright` entries:

| Architecture | Local image ID | Runtime packages | Builder packages | Inventory |
| --- | --- | ---: | ---: | --- |
| d660 amd64 | `sha256:ac006d4c5d5ca83db3ee0cc58c4f9af2d02d5c66161dc201449613bca08565d0` | 350 | 288 | `/tmp/campfire-image-d6600ed-amd64.json` |
| d660 arm64 | `sha256:4f2e61e9e6e9c6049042e8d49ebc6a3781d1e4850d02ceb6b30c5fa4263e9161` | 347 | 287 | `/tmp/campfire-image-d6600ed-arm64.json` |
| amd64 | `sha256:2044476f5e6c0b8766101dd6f75c627452f4c3209e9b4453c8b9286f51149566` | 350 | 288 | `/tmp/campfire-image-bcb440c-amd64.json` |
| arm64 | `sha256:619c9f6068cc0bfbc3f310abe46298110a577a5db9936c7f5774421eba3d1682` | 347 | 287 | `/tmp/campfire-image-bcb440c-arm64.json` |

The prior M7 local images are historical checks:

| Architecture | Local image ID | Runtime packages | Copyright files | Binary/link inventory |
| --- | --- | --- | --- | --- |
| amd64 | `sha256:4a4c24c2425bc31c9cc1e5bcf026f88ab7358c7d5fcb57a7ba1fe0dd3cec8500` | 350, [TSV](release-inventory/m7-amd64-packages.tsv) | 350/350 present, [hashes](release-inventory/m7-amd64-copyright-hashes.txt) | [ldd and SHA-256](release-inventory/m7-amd64-linked-libs.txt), no missing link |
| arm64 | `sha256:d7649972b7143ac106326ec38c32baa715c8f4529b6223823c355c1846f14426` | 347, [TSV](release-inventory/m7-arm64-packages.tsv) | 347/347 present, [hashes](release-inventory/m7-arm64-copyright-hashes.txt) | [ldd and SHA-256](release-inventory/m7-arm64-linked-libs.txt), no missing link |

The arm64 inventory ran under the already installed QEMU binfmt. Debian package copyright
files were found for every installed package in both bcb images. The `ldd` files are raw process
output and include changing load addresses; their library names and binary SHA-256 values
are the useful evidence. The two architecture images have different transitive package sets
(for example, the amd64 image contains `libdrm-intel1`, `libpciaccess0`, and `libvpl2`).

This is **not yet a reproducible rebuild guarantee**: `apt-get update` resolves transitive
packages against mutable Ubuntu/Debian repositories, and `dune-project`/opam constraints do
not lock every OCaml package version. The Dockerfile now saves its complete builder
`dpkg-query` inventory and copyright notices inside the runtime image;
`release_image_inventory.py` checks their coverage and records hashes alongside the runtime
package set for each final image. With `--revision`, it also requires a clean checkout at
that exact image revision. Retain immutable final
image digests for deployment and rollback. The bcb local images have an empty OCI source
label because `OCI_SOURCE` was unset; the publish workflow supplies it. Inspect
that label on any pushed image rather than inferring it from this local build.

## Current `2a511ac` release command log and outstanding checks

| Check | Current evidence |
| --- | --- |
| Source and native tests | `/tmp/campfire-source-2a511ac.json` records a clean source, 321 exact assets and zero local Gumbo errors. `dune runtest --force` passes 41 suites and 297 cases; see `/tmp/campfire-runtest-group-avatar-escalated.log`. `/tmp/campfire-2a511ac-upstream-provenance.json` independently checks the locally retained Nokogiri archive hash, 46 archived Gumbo source files, clean WebSocket Git commit and ISC license; the separate local Gumbo notice is absent from the upstream archive. |
| HTTP/state | `/tmp/m3-2a511ac-five-seed-audit.md` records 3,186/3,186 exact eligible route/state cases and 354 unavailable first-run signed/denied cells. `/tmp/m3-2a511ac-positive-writes.json` records 30/30 exact writes. The historical Lexxy room-script difference is fixed on this source. |
| Browser | Focused group-name and avatar-upload recapture passes 8/8 cells across six layers; attachment-edit and involvement-frame recaptures passed on preceding code revisions carried into `2a511ac`. The final five-seed lean/full run is active at `/tmp/m8-t3-harness-wt/parity/out/m8-t3-2a511ac-final-all/summary.json`. |
| Images and copied installation | `/tmp/campfire-image-2a511ac-{amd64,arm64}.json` reports 321 exact assets and zero issues in each image. `/tmp/campfire-lifecycle-2a511ac-{amd64,arm64}.log` records upgrade, restart, backup/restore, rollback, stable 169 messages and 14 blobs, SQLite integrity and clean shutdown. |
| Runtime protocol and media | `/tmp/campfire-2a511ac-protocol-{amd64,arm64}.json` records local ACME issue/renewal, HTTP/2, redirect, unknown Host, TLS Cable restart and shutdown. `/tmp/m8-t5-2a511ac-{amd64,arm64}-signed-media.json` records 233/233 exact signed-media cases on each image. |
| Performance and assets | The measured throughput gap and ten gzip-wire plus one malformed-path asset differences were captured on `d6600ed`. Their current-image status is unverified; see the historical record below. |
| Reproducible build | Base image digests and direct apt versions are pinned, and package/binary inventories are retained. Mutable transitive apt resolution and the absence of a repeat image build leave byte reproducibility unproven. |
| External release | Multiarchitecture publication and actual ONCE deployment are pending a registry destination, credentials, target host and CLI. |

### Historical `d6600ed` release command log

| Check | Reproduction command or source | Current evidence |
| --- | --- | --- |
| Source provenance | `python3 scripts/release_source_manifest.py --output /tmp/campfire-source-d6600ed.json` | **Pass locally on clean d660**: zero Gumbo local checksum errors; 321 assets, 87 application files, eight C stubs and 11 release files. The upstream Gumbo archive hash and Cable commit were recorded, not independently refetched. |
| Copied-install lifecycle | `python3 scripts/m7_image_lifecycle.py --image campfire-ocaml:rc-d6600ed-ARCH --old-image campfire-reference:app` for amd64 and arm64 | **Pass on both d660 images**: old Rails, upgrade, restart, backup/restore and rollback `/up=200`; OCaml SIGTERM=0; 169 messages and 14 blob SHA-256 hashes stable; two additive indexes; table schema and SQLite integrity stable. Logs: `/tmp/campfire-lifecycle-d6600ed-{amd64,arm64}.log`. The prior bcb images passed the same check. |
| Native tests and views | `dune clean && dune build --profile release && dune runtest --force`; `python3 test/view_golden_matrix.py --require-all --output /tmp/campfire-d6600ed-view-goldens.json` | **Pass on clean d660 source**: release build and complete test suite exit 0, with logs `/tmp/campfire-d6600ed-clean-release-build.log` and `/tmp/campfire-d6600ed-clean-runtest.log`. View matrix: 121 rendered passes, two linked input-metadata cases, zero fail/unsupported. |
| HTTP/state and shared harness | `/tmp/m8-t2-d6600ed-matrix.sh`; `scripts/m8_t2_contract_run.sh`; shared `bin/check` | Packaged d660 five-seed 177×4 matrices: **3,170 exact, 16 documented Lexxy room-script differences, 354 explicit not-run** because first-run lacks a signed fixture. All response statuses and SQLite state match; no other header class differs. Crowd autocomplete Link/JSON 3/3, HEAD gzip/Vary semantics, and public logo cache 5/5 match. Packaged Cable ordered frames/revocation, signed media **233/233**, and shared eight-route/one-acknowledged-write contracts pass with the same frozen clock; see `/tmp/m8-t2-d6600ed-full-handoff.md` and `/tmp/m8-t2-d6600ed-external-gates-handoff.md`. The final d660 static comparison is **1,004/1,015 exact**, with ten gzip wire/framing differences and malformed `/assets/%GG` 400 versus Rust 404. |
| Browser | `scripts/m8_browser_parity.sh` on pinned Rust and d660 OCaml wrapper; shared `bin/browser` | The corrected detached harness replays sign-in and Rust/Rust controls without retries. A fresh packaged room cell has equal pixels/live DOM/ARIA/Cable, with only the retained Lexxy script and response hash difference. Controlled d660 32-cell default-seed captures at 2/2 and 4/4 workers/isolated slots have identical 8 pass/24 fail layer signatures, zero capture errors or retries; all 24 differences are the Lexxy script or its response hash. 4/4 took 145 seconds versus 285 seconds at 2/2. The all-seed lean/full matrix remains pending; see `/tmp/m8-t3-d6600ed-browser-runbook.md`. |
| Performance/resilience | Shared `bin/benchmark --apps rust,ocaml --rounds 2`; `scripts/m8_t4_resilience.py` on clean d660 image | **Pass for M8-T4 on d660**: preflight and timed summaries are `complete: true`, `release_comparable: true`; all 32 route samples have zero errors/invalid responses and exact acknowledged-write/rich-text/SQLite audits. Packaged header and 60-second resilience pass, including two-client Cable fanout, body/header limits, crash/restart and backup/restore. Room-show median Rust 81,888 versus OCaml 1,889 req/s; POST 4,926 versus 502 req/s. Retain the gap as a release limitation. Raw summaries: shared `tmp/bench/m8-t4-d6600ed-{preflight,timed}/`, `tmp/bench/m8-t4-resilience-1791561006-2326118/` and `tmp/bench/m8-t4-resilience-1791561012-2327394/`; see [performance evidence](m8-t4-performance.md). |
| Runtime contracts | `python3 scripts/release_image_inventory.py --image IMAGE --revision d6600ed... --output /tmp/IMAGE-inventory.json`; focused final-image HTTP/2/TLS/ACME, signed media and Cable/shutdown probes on both architectures | **Inventory and lifecycle pass on d660 amd64 and arm64**: exact assets, notices/hooks, native link checks, copied Rails upgrade/restart/backup/restore/rollback. Both images passed disposable local Pebble certificate issuance and renewal, HTTPS HTTP/2 `/up=200`, HTTP 301, foreign Host 421, TLS Cable 101/restart, and SIGTERM exit 0; reports `/tmp/campfire-d6600ed-protocol-{amd64,arm64}.json`. Packaged signed media passed 233/233 on each architecture, including the independent arm64 comparison in `/tmp/m8-t5-arm64-signed-media.json`. |
| Published manifest and ONCE | `.github/workflows/publish-image.yml`, `docker buildx imagetools inspect`, then `once deploy IMAGE --host HOST` | **Not run**: no Git remote, registry identity/credentials, ONCE CLI or target host in this workspace. The local images are not a pushed multiarchitecture manifest or an actual ONCE deployment. |

For the current source, the **local** remaining gates are the broad browser
matrix, repeatability evidence for the release build, and current-image review
of the earlier Caddy malformed-path, gzip-wire and measured performance
differences. The earlier Lexxy room-script difference has been fixed.
Pinned base digests and direct apt versions plus complete package inventories
support deployment by immutable image digest, but mutable transitive apt
resolution does not guarantee a byte-reproducible rebuild. The absent Git
remote/registry/ONCE host are additional **external** publication and deployment
requirements, not the only reason M8-T5 remains open.

For an immutable local candidate, first record a clean `git rev-parse HEAD` and source
manifest. Build each architecture from that source, setting `APP_VERSION` and `GIT_REVISION`
to the same revision, then retain the resulting image IDs and per-architecture package
inventories. The M7-tested local form is:

```sh
release_rev="$(git rev-parse HEAD)"
test -z "$(git status --porcelain)"
python3 scripts/release_source_manifest.py --output "/tmp/campfire-source-${release_rev}.json"
docker buildx build --platform linux/amd64 --load -t "campfire-ocaml:rc-${release_rev}-amd64" \
  --build-arg "APP_VERSION=${release_rev}" --build-arg "GIT_REVISION=${release_rev}" .
docker buildx build --platform linux/arm64 --load -t "campfire-ocaml:rc-${release_rev}-arm64" \
  --build-arg "APP_VERSION=${release_rev}" --build-arg "GIT_REVISION=${release_rev}" .
python3 scripts/m7_image_lifecycle.py --image "campfire-ocaml:rc-${release_rev}-amd64" \
  --old-image campfire-reference:app
python3 scripts/m7_image_lifecycle.py --image "campfire-ocaml:rc-${release_rev}-arm64" \
  --old-image campfire-reference:app
python3 scripts/release_image_inventory.py --image "campfire-ocaml:rc-${release_rev}-amd64" \
  --revision "${release_rev}" --output "/tmp/campfire-rc-${release_rev}-amd64-inventory.json"
python3 scripts/release_image_inventory.py --image "campfire-ocaml:rc-${release_rev}-arm64" \
  --revision "${release_rev}" --output "/tmp/campfire-rc-${release_rev}-arm64-inventory.json"
```

The pinned GitHub workflow builds native architecture tags and assembles/signs the manifest
on a tag or manual dispatch. Once a Git remote, registry identity and release tag exist,
inspect the pushed digest and both platforms with `docker buildx imagetools inspect
ghcr.io/OWNER/REPO:TAG`; deploy **that digest** using `once deploy
ghcr.io/OWNER/REPO@sha256:DIGEST --host HOST`. Preserve the current immutable image digest,
`SECRET_KEY_BASE`, `/rails/storage` (including `db`, `files`, `backups`, `thruster`), and the
backup before upgrade. Rollback uses `once deploy OLD_IMAGE_DIGEST --host HOST`; restore, if
needed, is performed only while the app is stopped through the existing ONCE backup/restore
flow and `/hooks/post-restore`. The local copied-install lifecycle is the reviewable rehearsal,
not evidence that remote ONCE operations occurred.

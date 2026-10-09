# M8-T5 release candidate audit (in progress)

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
| Application | `LICENSE` is 37signals MIT, SHA-256 `fa0d1454375cbc7701bc13d916c3ae71e613b8ae718321641e678e09409393c4`; byte-identical to pinned Rust `MIT-LICENSE`. | The Dockerfile now copies it to `/usr/share/doc/once-campfire-ocaml/LICENSE`. Recheck in final image. |
| WebSocket | `vendor/cable_websocket/README.md` identifies `vbmithr/ocaml-websocket` commit `133eda58386c43b95fed21ba1921cbc37b629b98`; its ISC license SHA-256 is `e598f1a9f8adc81453a95e665925a110254d5f4b97c1027ba66a11c9ee16e878`. Eight local files include Campfire frame/extension changes. | The Dockerfile now copies `LICENSE.md` to the image. Preserve upstream attribution and local changes in source. |
| HTML parser | `vendor/gumbo/provenance.json` identifies Nokogiri commit `bce9a50af78a9f2ef469761a95b22886a2ab0031` and source archive SHA-256 `362d888e868240977e7c01932c8f2e106487c8d16984f82532d07023e2f1eb12`. Its 47 upstream file hashes, two original patch hashes, and four patched local hashes were checked. The OCaml include-path patch, `campfire-ocaml-include.patch`, takes the C port's `util.c` hash `cdc636b38710abbdb5637364238e4cc093a28b18fc4d42abefc456f2ad5cd76f` to `b656af1cfe709bfba2f1669dc403414fcb69bedb9d32ba0ab781ede6ac3ad6c0`; `patch --dry-run` succeeded against that source. The 54-file tree plus new patch has 55 files. | The Dockerfile now copies `LICENSE-DEPENDENCIES.md` and `provenance.json`; Apache 2.0 terms for libgumbo and bundled hashmap remain in the notice. The upstream archive itself was not present locally, so its recorded archive hash was not independently recomputed. |
| Static assets | `assets/README.md` records pinned Rust `9872c1d9541551c0889a60e3d49a14488bd1e403` and Rails `90b330024dec3e757c79b6a7e6568f93da8e3148`; `scripts/export_assets.py` verifies both. `assets/files` contains 321 files; the path/hash tree digest is `b22f9fe3787b4f1f52def29a89befb3503a6cf9f56223248d824a2db2c80e91f`; `assets/manifest.json` SHA-256 is `572180221700940817fbdac20953f81109f5cc161c54275611ec54d2e9cbd069`. JS bundle copyright/license comments remain in the copied files, including Turbo, Stimulus, Trix, Rails UJS, Lexxy, DOMPurify (Apache 2.0/MPL 2.0) and regenerator-runtime. | Both bcb images contain all 321 source assets byte for byte. A pinned Rust/packaged OCaml live comparison matches 1,004/1,015 paired cases; ten gzip wire responses have equal decoded content but different compressed bytes/framing, and Caddy returns 400 for malformed `/assets/%GG` versus Rust 404. See `/tmp/m8-t2-bcb440c-assets-summary.md`. |
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

## Release command log and outstanding checks

| Check | Reproduction command or source | Current evidence |
| --- | --- | --- |
| Source provenance | `python3 scripts/release_source_manifest.py --output /tmp/campfire-source-d6600ed.json` | **Pass locally on clean d660**: zero Gumbo local checksum errors; 321 assets, 87 application files, eight C stubs and 11 release files. The upstream Gumbo archive hash and Cable commit were recorded, not independently refetched. |
| Copied-install lifecycle | `python3 scripts/m7_image_lifecycle.py --image campfire-ocaml:rc-d6600ed-ARCH --old-image campfire-reference:app` for amd64 and arm64 | **Pass on both d660 images**: old Rails, upgrade, restart, backup/restore and rollback `/up=200`; OCaml SIGTERM=0; 169 messages and 14 blob SHA-256 hashes stable; two additive indexes; table schema and SQLite integrity stable. Logs: `/tmp/campfire-lifecycle-d6600ed-{amd64,arm64}.log`. The prior bcb images passed the same check. |
| Native tests and views | `dune clean && dune build --profile release && dune runtest --force`; `python3 test/view_golden_matrix.py --require-all --output /tmp/campfire-d6600ed-view-goldens.json` | **Pass on clean d660 source**: release build and complete test suite exit 0, with logs `/tmp/campfire-d6600ed-clean-release-build.log` and `/tmp/campfire-d6600ed-clean-runtest.log`. View matrix: 121 rendered passes, two linked input-metadata cases, zero fail/unsupported. |
| HTTP/state and shared harness | `/tmp/m8-t2-d6600ed-matrix.sh`; `scripts/m8_t2_contract_run.sh`; shared `bin/check` | Packaged d660 five-seed 177×4 matrices: **3,170 exact, 16 documented Lexxy room-script differences, 354 explicit not-run** because first-run lacks a signed fixture. All response statuses and SQLite state match; no other header class differs. Crowd autocomplete Link/JSON 3/3, HEAD gzip/Vary semantics, and public logo cache 5/5 match. Packaged Cable ordered frames/revocation, signed media **233/233**, and shared eight-route/one-acknowledged-write contracts pass with the same frozen clock; see `/tmp/m8-t2-d6600ed-full-handoff.md` and `/tmp/m8-t2-d6600ed-external-gates-handoff.md`. Prior packaged static comparison: **1,004/1,015 exact**, with ten gzip wire/framing differences and malformed `/assets/%GG` 400 versus Rust 404. Final d660 asset sweep is pending. |
| Browser | `scripts/m8_browser_parity.sh` on pinned Rust and bcb OCaml wrapper; shared `bin/browser` | Inventories pass all five seeds. Bounded bcb captures: default 32/40, custom styles lean 25/33, restricted lean 8/8, Firefox PWA 0/2; recorded failures have matching pixels/live DOM/ARIA/Cable and the retained Lexxy script/document hash difference. An intermittent sign-in readiness stall was traced to requests from a superseded document in the detached harness worktree. Reviewed replay and all-seed lean/full matrix remain pending; see `/tmp/m8-t3-browser-bcb440c-notes.md`. |
| Performance/resilience | Shared `bin/benchmark --apps rust,ocaml --rounds 2`; `scripts/m8_t4_resilience.py` on clean d660 image | **Pass for M8-T4 on d660**: preflight and timed summaries are `complete: true`, `release_comparable: true`; all 32 route samples have zero errors/invalid responses and exact acknowledged-write/rich-text/SQLite audits. Packaged header and 60-second resilience pass, including two-client Cable fanout, body/header limits, crash/restart and backup/restore. Room-show median Rust 81,888 versus OCaml 1,889 req/s; POST 4,926 versus 502 req/s. Retain the gap as a release limitation. Raw summaries: shared `tmp/bench/m8-t4-d6600ed-{preflight,timed}/`, `tmp/bench/m8-t4-resilience-1791561006-2326118/` and `tmp/bench/m8-t4-resilience-1791561012-2327394/`; see [performance evidence](m8-t4-performance.md). |
| Runtime contracts | `python3 scripts/release_image_inventory.py --image IMAGE --revision d6600ed... --output /tmp/IMAGE-inventory.json`; focused final-image HTTP/2/TLS/ACME, signed media and Cable/shutdown probes on both architectures | **Inventory and lifecycle pass on d660 amd64 and arm64**: exact assets, notices/hooks, native link checks, copied Rails upgrade/restart/backup/restore/rollback. The d660 amd64 packaged Cable, signed media and resilience gates pass; equivalent final-image HTTP/2/TLS/ACME and arm64 protocol/media smoke remain to record. |
| Published manifest and ONCE | `.github/workflows/publish-image.yml`, `docker buildx imagetools inspect`, then `once deploy IMAGE --host HOST` | **Not run**: no Git remote, registry identity/credentials, ONCE CLI or target host in this workspace. The local images are not a pushed multiarchitecture manifest or an actual ONCE deployment. |

The **local** remaining gates are the broad browser matrix, final-image
HTTP/2/TLS/ACME and arm64 protocol/media smoke; review of the Lexxy,
Caddy malformed-path, gzip-wire and measured performance differences; and an
accurate rebuild promise.
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

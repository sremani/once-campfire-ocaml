# M8-T5 release candidate audit (in progress)

This is a working provenance record, **not release clearance**. The OCaml tree was dirty at
`cbf7bb5412e725a6705a76aa6f24f82bb4f912a8` when this audit began. M3/M4/M8 work is
still changing source; the M7 images below predate the final source and the license-copy fix.
The final clean source revision, image digests, complete parity gates, pushed multiarchitecture
manifest and ONCE deployment must be recorded before M8-T5 is checked.

## Source and notices

| Input | Pinned origin and local evidence | Distribution action |
| --- | --- | --- |
| Application | `LICENSE` is 37signals MIT, SHA-256 `fa0d1454375cbc7701bc13d916c3ae71e613b8ae718321641e678e09409393c4`; byte-identical to pinned Rust `MIT-LICENSE`. | The Dockerfile now copies it to `/usr/share/doc/once-campfire-ocaml/LICENSE`. Recheck in final image. |
| WebSocket | `vendor/cable_websocket/README.md` identifies `vbmithr/ocaml-websocket` commit `133eda58386c43b95fed21ba1921cbc37b629b98`; its ISC license SHA-256 is `e598f1a9f8adc81453a95e665925a110254d5f4b97c1027ba66a11c9ee16e878`. Eight local files include Campfire frame/extension changes. | The Dockerfile now copies `LICENSE.md` to the image. Preserve upstream attribution and local changes in source. |
| HTML parser | `vendor/gumbo/provenance.json` identifies Nokogiri commit `bce9a50af78a9f2ef469761a95b22886a2ab0031` and source archive SHA-256 `362d888e868240977e7c01932c8f2e106487c8d16984f82532d07023e2f1eb12`. Its 47 upstream file hashes, two original patch hashes, and four patched local hashes were checked. The OCaml include-path patch, `campfire-ocaml-include.patch`, takes the C port's `util.c` hash `cdc636b38710abbdb5637364238e4cc093a28b18fc4d42abefc456f2ad5cd76f` to `b656af1cfe709bfba2f1669dc403414fcb69bedb9d32ba0ab781ede6ac3ad6c0`; `patch --dry-run` succeeded against that source. The 54-file tree plus new patch has 55 files. | The Dockerfile now copies `LICENSE-DEPENDENCIES.md` and `provenance.json`; Apache 2.0 terms for libgumbo and bundled hashmap remain in the notice. The upstream archive itself was not present locally, so its recorded archive hash was not independently recomputed. |
| Static assets | `assets/README.md` records pinned Rust `9872c1d9541551c0889a60e3d49a14488bd1e403` and Rails `90b330024dec3e757c79b6a7e6568f93da8e3148`; `scripts/export_assets.py` verifies both. `assets/files` contains 321 files; the path/hash tree digest is `b22f9fe3787b4f1f52def29a89befb3503a6cf9f56223248d824a2db2c80e91f`; `assets/manifest.json` SHA-256 is `572180221700940817fbdac20953f81109f5cc161c54275611ec54d2e9cbd069`. JS bundle copyright/license comments remain in the copied files, including Turbo, Stimulus, Trix, Rails UJS, Lexxy, DOMPurify (Apache 2.0/MPL 2.0) and regenerator-runtime. | The Dockerfile copies the complete `assets` tree, including `assets/README.md`; run the final asset parity test and compare manifest bytes inside each image. |
| Native bridge | Eight `lib/*_stubs.c` files cover bcrypt, gzip, QR, Gumbo, Cable zlib, libvips, curl, and webhook inflate. Current path/hash tree digest: `81d6a5b9db2dca35b5adfbb12e9ade1e693a9911b5e6d11c527e0fe8c27433d7`. Gumbo's native allocator is a separate vendored local file. | Recompute on clean revision; inspect `ldd` and Debian package copyright files in final images. |

`python3 scripts/release_source_manifest.py --output /tmp/campfire-ocaml-source-manifest.json`
records per-file SHA-256 values, both base image digests, source revision and dirty state. It
fails if the checked-in Gumbo files or patches diverge from their recorded hashes. Its
working-tree run found zero Gumbo mismatches. Re-run on the final clean revision and retain
the JSON with the release evidence. The script verifies local files and patch metadata; it
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

The prior M7 local images are **historical checks only**:

| Architecture | Local image ID | Runtime packages | Copyright files | Binary/link inventory |
| --- | --- | --- | --- | --- |
| amd64 | `sha256:4a4c24c2425bc31c9cc1e5bcf026f88ab7358c7d5fcb57a7ba1fe0dd3cec8500` | 350, [TSV](release-inventory/m7-amd64-packages.tsv) | 350/350 present, [hashes](release-inventory/m7-amd64-copyright-hashes.txt) | [ldd and SHA-256](release-inventory/m7-amd64-linked-libs.txt), no missing link |
| arm64 | `sha256:d7649972b7143ac106326ec38c32baa715c8f4529b6223823c355c1846f14426` | 347, [TSV](release-inventory/m7-arm64-packages.tsv) | 347/347 present, [hashes](release-inventory/m7-arm64-copyright-hashes.txt) | [ldd and SHA-256](release-inventory/m7-arm64-linked-libs.txt), no missing link |

The arm64 inventory ran under the already installed QEMU binfmt. Debian package copyright
files were found for every installed package in both images. The `ldd` files are raw process
output and include changing load addresses; their library names and binary SHA-256 values
are the useful evidence. The two architecture images have different transitive package sets
(for example, the amd64 image contains `libdrm-intel1`, `libpciaccess0`, and `libvpl2`).

This is **not yet a reproducible rebuild guarantee**: `apt-get update` resolves transitive
packages against mutable Ubuntu/Debian repositories, and `dune-project`/opam constraints do
not lock every OCaml package version. Capture complete builder and runtime `dpkg-query`
inventories on the final images; retain immutable final image digests for deployment and
rollback. The old M7 images also had an empty OCI source label in local builds because
`OCI_SOURCE` was unset; the publish workflow supplies it.

## Release command log and outstanding checks

| Check | Reproduction command or source | Current evidence |
| --- | --- | --- |
| Source provenance | `python3 scripts/release_source_manifest.py --output /tmp/campfire-ocaml-source-manifest.json` | Working tree only; Gumbo 0 checksum errors, 321 assets, eight stubs. Re-run on clean commit. |
| M7 copied-install lifecycle | `python3 scripts/m7_image_lifecycle.py --image campfire-ocaml:m7-t3 --old-image campfire-reference:app` (and `m7-t3-arm64`) | Previously passed for both local M7 image IDs: old Rails, upgrade, restart, backup/restore and rollback; 169 messages and 14 blob hashes retained. Re-run on final images. |
| Native tests and views | `dune clean && dune build --profile release && dune runtest --force`; `python3 test/view_golden_matrix.py --require-all --output /tmp/campfire-final-views.json` | Final revision pending; all 123 view cases and complete suite are required. |
| HTTP/state and shared harness | `python3 scripts/m8_t2_http_state.py --seed default --rust-port RUST_PORT --ocaml-port OCAML_PORT --rust-db RUST_DB --ocaml-db OCAML_DB --ocaml-seed-dir OCAML_SEED_DIR --output /tmp/campfire-final-http.json --isolate`; `../once-campfire-verification/bin/check` | Final 177-route/role matrix and shared gates pending. Substitute disposable ports/seed copies, then repeat the required scenarios/seeds. |
| Browser | `../once-campfire-rust/parity/bin/check-inventory`, then `parity/bin/compare --matrix lean` and `--matrix full` against pinned Rust and final OCaml image; separately run shared `bin/browser`. | M8-T3 active; final all-engine/full matrix pending. |
| Performance/resilience | `../once-campfire-verification/bin/benchmark --apps rust,ocaml` on immutable pinned images and fixture | M8-T4 active; validated throughput and resilience evidence pending. |
| Runtime contracts | Read image metadata, `dpkg-query`, `ldd`, packaged licenses/assets; run M7 HTTP/2, ACME renewal, media, Cable and shutdown checks on both final architectures | Historical M7 evidence only; final images pending. |
| Published manifest and ONCE | `.github/workflows/publish-image.yml`, `docker buildx imagetools inspect`, then `once deploy IMAGE --host HOST` | No Git remote, ONCE CLI, target host or registry publication evidence in this workspace. |

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

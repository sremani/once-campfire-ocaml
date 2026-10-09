# M6-T2 image processor handoff

`Storage_vips` calls libvips through the narrow `storage_vips_stubs.c` binding.
The library loads at first use, so a host without libvips can still build and
run non-media tests. Production and strict vector runs need libvips 8.16.1.
The binding mirrors pinned Rust `crates/storage/src/vips.rs`: blocked untrusted
loaders and OpenSlide, conditional `page: 0`, autorotation, `thumbnail_image`
with `size: down` and `no_rotate`, the image_processing sharpen mask, and the
extension-selected saver. `Storage_variation` preserves ordered Ruby symbol
versus string values for Marshal/digest parity. `Storage_image` provides image
analysis and tracked variant generation over T1's staged file API, with one
winner per variation digest. Generated files are kept only after the row
transaction commits. T1's blob purge removes their attachment, row, and file.

The pinned Rust Dockerfile's `media-base` and `vips` stages build libvips
8.16.1 from Debian trixie source `vips 8.16.1-1+deb13u1`, checking the `.dsc`
SHA-256 `60205e00d061b9d8072938e04899f2ca2fdac0513068e561d33f7c87fae1ae2e`.
The OCaml runtime and CI images should copy that stage's `/opt/vips` tree and
set `LD_LIBRARY_PATH=/opt/vips/lib`. The existing Rails reference image also
contains libvips 8.16.1 and was used for the strict checks below. A generic
host libvips version is insufficient for byte parity.

`test/m6_t2_test.ml` checks all 12 pinned variation Marshal and SHA-1 digest
vectors. With `CAMPFIRE_REQUIRE_MEDIA_VECTORS=1`, it requires libvips 8.16.1
and checks all seven pinned image derivative files byte for byte, their MD5
checksums, original and derivative dimensions, a tracked `moon-thumb` blob's
metadata and bytes, malformed-image rejection, concurrent first generation
with one persisted winner and no orphan files, repeated cache hits, failed
processing cleanup, and recursive purge. This suite passed inside the local
`campfire-reference:latest` image on 2026-10-09. The host lacked libvips, so
the strict cases were executed in the matching image. The test binary required
the host's `libev.so.4` mounted read-only because that Rails image lacks it.

Reproduce the strict run from the OCaml repository root, after building the
Rails image from pinned `once-campfire-rust/reference` as
`campfire-reference:latest`:

```sh
dune build --build-dir _build_m6_t2 test/m6_t2_test.exe
docker run --rm \
  --entrypoint /home/srikanth/projects/once-campfire-ocaml/_build_m6_t2/default/test/m6_t2_test.exe \
  -v /home/srikanth/projects:/home/srikanth/projects:rw \
  -v /lib/x86_64-linux-gnu/libev.so.4:/opt/ocaml-libs/libev.so.4:ro \
  -w /home/srikanth/projects/once-campfire-ocaml/test \
  -e LD_LIBRARY_PATH=/opt/ocaml-libs \
  -e CAMPFIRE_REQUIRE_MEDIA_VECTORS=1 \
  campfire-reference:latest
```

The absolute paths above describe this workspace; CI should mount its own
checkout path and link libev in its OCaml test image. The source fixture and
golden derivative files are read from the pinned Rust checkout alongside it.

Current composition boundary: M6-T3 owns the shared
`Storage_http.register_representation` callback for image and video processing.
M4/M3 avatar and logo actions and M7 production image packaging remain their
own integration tasks. `Storage_image.process_variant` is blocking and must be
called through an Lwt worker before the HTTP callback returns.

Closure audit (2026-10-09): the representation callback, avatar/logo actions,
and amd64 production image are integrated. The manager reran the strict image
suite against libvips 8.16.1, and M6-T4 matched signed image routes with live
Rails. See [M6 audit](m6-audit.md).

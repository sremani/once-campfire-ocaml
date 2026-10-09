# M6-T3 audio/video and representations

`Storage_media` uses the system `ffprobe` and `ffmpeg` binaries. The ffprobe
command, 30 second limit, video stream fields, audio stream fields, rotation,
display aspect ratio, and ffmpeg frame selection arguments match the pinned
Rust and Rails implementations. The process runner drains stdout and stderr,
bounds their memory, kills and reaps timed out children, and applies a 60 second
limit to frame extraction. It retries interrupted `select`, `read`, and
`waitpid` calls, retaining the original deadline. Content types outside audio
and video never invoke ffprobe; image analysis uses libvips, and text and other
null analyzer types save `analyzed: true` without reading the blob file.
Generated previews are JPEG blobs attached to the
source video as `ActiveStorage::Blob` / `preview_image`; video variations run
through `Storage_image` on that image. The database writer is held only for the
winner transaction. `bin/main.ml` registers the shared `Storage_http`
representation callback, and runs blocking media work in `Lwt_preemptive`.

`Storage_variation.key` signs the ordered transformation JSON with purpose
`variation`; `from_key` verifies it. `Storage_blob.representation_path` encodes
the signed blob and variation keys for redirect or proxy routes.

`test/m6_t3_test.ml` checks all 12 pinned variation signatures, signed-key
decoding and tamper rejection, all four message and one avatar representation
path vectors, actual ffprobe video and WAV audio metadata, synthetic rotation
and audio analyzer fields, malformed media, process output limits and timeouts.
It injects three `EINTR` errors into both wait and select retry paths, and
checks that a text blob persists analyzed metadata with a nonexistent storage
path and ffprobe binary.
With `CAMPFIRE_REQUIRE_MEDIA_VECTORS=1`, it also checks the exact ffmpeg preview
bytes, all three video derivative files and checksums, source and preview
metadata, simultaneous first-generation requests sharing one winner, and
recursive purge. A focused test also reads 1,600 random values from 16 threads.
The strict suite passed in `campfire-reference:latest`, which has ffmpeg/ffprobe
7.1.5 and libvips 8.16.1. The host suite passes, with strict media cases gated
by that environment variable. `Secure_random.bytes` now uses Unix file
descriptors; an 8-thread generation run exposed a channel close race in the
old implementation.

The fixture bytes compared without a digest-only shortcut are:

| File | Bytes | Base64 MD5 |
| --- | ---: | --- |
| `alpha-centuri-preview_image.jpg` | 11,788 | `untJ1VKBeYvbPA/dvRXh9A==` |
| `alpha-centuri-preview-webp.webp` | 3,326 | `f41i6Z376J8tfJGLMf6SEw==` |
| `alpha-centuri-poster.webp` | 4,962 | `XtJzWPB2ohtXI1XdqZll1A==` |
| `alpha-centuri-poster-from-key.webp` | 4,962 | `XtJzWPB2ohtXI1XdqZll1A==` |

Reproduction from the OCaml repository root:

```sh
dune build --build-dir _build_m6_t3 test/m6_t3_test.exe test/m1_t2_test.exe test/m1_t3_test.exe test/m1_t4_test.exe bin/main.exe
(cd test && ../_build_m6_t3/default/test/m6_t3_test.exe)
(cd test && ../_build_m6_t3/default/test/m1_t2_test.exe)
(cd test && ../_build_m6_t3/default/test/m1_t3_test.exe)
(cd test && ../_build_m6_t3/default/test/m1_t4_test.exe)
docker run --rm \
  --entrypoint /home/srikanth/projects/once-campfire-ocaml/_build_m6_t3/default/test/m6_t3_test.exe \
  -v /home/srikanth/projects:/home/srikanth/projects:rw \
  -v /lib/x86_64-linux-gnu/libev.so.4:/opt/ocaml-libs/libev.so.4:ro \
  -w /home/srikanth/projects/once-campfire-ocaml/test \
  -e LD_LIBRARY_PATH=/opt/ocaml-libs \
  -e CAMPFIRE_REQUIRE_MEDIA_VECTORS=1 \
  campfire-reference:latest
```

The seeded bot reply was inspected with
`dune exec --build-dir _build_m6t3 test/m5_t3_integration_test.exe -- test webhook 1`.
The test's own assertion correction and full-suite rerun are tracked by M5-T3.

The final local runs passed 5 host media tests, 6 strict media tests, 12 M1
signed-id tests, 3 M1 session/cookie tests, and 6 M1 Rack/cookie/CSRF tests.
The strict 6-case suite was rerun after the MIME and EINTR fixes, with exact
video preview and derivative bytes still passing. In M5-T3's seeded bot
attachment reply, the resulting text/plain blob had metadata
`{"identified":true,"analyzed":true}`; webhook job stats showed one completion
and zero failures. Its first failing assertion had reversed arguments to the
test's `contains` helper. M5-T3's corrected seeded route assertion and full
integration suite passed 8/8; M6-T4 subsequently audited route parity.

Closure audit (2026-10-09): M6-T4's strict and live differential suites and the
amd64 production media image passed the M6 gate. The runtime selects ffmpeg
and ffprobe from `PATH`, like the pinned Rails config. See
[M6 audit](m6-audit.md).

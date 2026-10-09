# M4-T1 asset pipeline acceptance

Pinned source: `7bd8a4964603e3de3800c1edf45674be08dd3a9f`. The clean release image was `campfire-ocaml:rc-7bd8a49-amd64` (`sha256:1ffb96c88fc92ee90710e27b7f2fcc03b540b3cd7ec8210c7c09c03e21b44c3b`). Its 321 asset files and four asset metadata files matched the clean source byte for byte (325/325); the packaged `manifest.json` SHA-256 was `572180221700940817fbdac20953f81109f5cc161c54275611ec54d2e9cbd069`. Evidence: `/tmp/m4-t1-package-7bd8a49.json`. The asset tree SHA-256 was `b22f9fe3787b4f1f52def29a89befb3503a6cf9f56223248d824a2db2c80e91f`.

The pinned Rails manifest has 314 entries. The OCaml manifest has 315: four source-controlled JavaScript overrides have intentionally different digests, and `install-edge.svg` is added. The focused suite checks all 310 unchanged compiled SHA-256 values, the manifest/importmap/stylesheet/Link fixtures, and all 332 upstream static response vectors. It also checks missing and traversal paths, NUL, HEAD, conditional 304, multipart ranges, and integrated 416 headers. No runtime Node step is used. Commands and results:

```text
dune exec ./test/m4_t1_test.exe -- -q    6/6 pass
dune exec ./test/m7_t1_test.exe -- -q    8/8 pass
```

## Live clean-base comparison

The initial clean image exposed two front response differences: Caddy implicitly requested gzip from the app for clients with no `Accept-Encoding`, then decompressed and removed `Content-Length`; the generic HTTP cache finalizer added `Cache-Control: no-cache` to static 416 responses. Direct upstream requests confirmed that the app already sent the correct `Content-Length`. A narrow source patch disables Caddy upstream compression and leaves static responses under their own cache policy. The patch is in `lib/front_config.ml` and `lib/http_app.ml`, with regressions in `test/m4_t1_test.ml` and `test/m7_t1_test.ml`.

For isolation, the live retest image was built from the clean commit plus only that runtime patch (`/tmp/m4_asset_audit/m4-t1-runtime.patch`, SHA-256 `9fe2f1b36f31f8a5de3313ab9a1e799209d2946ff719a91d309bbff030ecb921`). App image: `campfire-ocaml:m4t1-fix-7bd8a49`, `sha256:255cb4ffc4a8d246eb61620991b8aadbed25f3ea406ecf8c4ea32e46205d5af7`. Parity wrapper: `campfire-ocaml:m4t1-fix-7bd8a49-parity`, `sha256:5dc5a70be6a222d81073959f1e9b329494259235fa88ac918cdbc0f1b5bc8497`. Both sides used disposable default seed copies and the same frozen app clock (`2026-03-02T16:00:00Z`). The pinned Rust service was on port 4891; OCaml was on 4892.

Live HTTP results (`/tmp/m4-t1-live-fixed-7bd8a49.json`):

| Check | Exact agreement |
| --- | ---: |
| Upstream static response fixture requests | 332/332 |
| All packaged/static GET paths | 321/321 |
| All packaged/static HEAD paths | 321/321 |
| Cache-bypassed `If-Modified-Since` plus `Range` requests with 304 and empty body | 10/10 |
| Single, multipart, and unsatisfiable range samples | 15/15 |

The comparison checks status, response body SHA-256, stable content/cache/range/encoding headers, and presence of `Last-Modified`. The `Last-Modified` value itself is normalized because each independently built source image has its own build time; each side's own value is used for conditional requests. The fixture's `GET /` expects direct static-handler fallthrough 404; both complete applications return the intended 302 redirect, so this is not a cross-app difference.

Explicit `Accept-Encoding: gzip` and `br,gzip` produced gzip on both services. On five sampled paths, decompression returned identical source bytes and hashes (5/5). The compressed byte streams and their wire `Content-Length`/chunked framing differ because the two front compressors use different gzip metadata and encoding implementations; those requests are **not** claimed exact. The edge sweep was 25/36 exact: ten gzip cases differed at the raw transport level, and malformed `/assets/%GG` yielded Rust 404 versus Caddy 400. That malformed URI is a front error-path gap for M3/M8, outside valid packaged assets. Invalid and multipart byte ranges, 416, identity encoding, and cache-bypassed 304 were exact in the sampled paths.

One bounded pinned Chromium comparison of `auth/sign_in` at desktop/light passed 1/1 across pixels, server DOM, live DOM, accessibility, network, and Cable layers. The two network traces were identical: 129 unique `/assets/` GETs, all 200, zero 404 or network errors. Report: `../once-campfire-rust/parity/parity/out/m4-t1-asset-smoke-7bd8a49/report.json`.

M4-T1's packaging, manifest, byte, valid static HTTP, and browser asset-fetch scope is met on the isolated patched image. The raw gzip and malformed URI differences remain explicit full-response parity work; this asset ticket does not close the M8 gate.

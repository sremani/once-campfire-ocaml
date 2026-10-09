# M6-T4 storage differential handoff

Pinned Rust `9872c1d9541551c0889a60e3d49a14488bd1e403`, Rails
`90b330024dec3e757c79b6a7e6568f93da8e3148`, and shared `default`
seed. The matching `campfire-reference:latest` image supplies libvips 8.16.1
and ffmpeg/ffprobe 7.1.5. The new `test/m6_t4_test.ml` requires those exact
versions when `CAMPFIRE_REQUIRE_MEDIA_VECTORS=1`; byte comparisons cannot
silently skip on a host with different media libraries.

## Strict pinned corpus

`m6_t4_test.exe` passed all three cases in the matching image. Its corpus
inventory runs on the host as well, checking every pinned fixture and golden
file's size/checksum. The complete
pipeline case independently stages and analyzes all eight original fixtures
(five messages, two avatars, one logo), compares stable original row fields and
raw file byte for byte, then compares all ten variant files and the video
preview against `vectors/storage/`. It checks generated row metadata,
checksums, size, content type, variation digest, variant/preview attachment
relations, repeated cache hits, and one winner with no abandoned file from
eight concurrent first transforms. The signed HTTP case checks image and
video blob/representation redirect, proxy, and disk responses; exact served
bytes; signed URL and ETag calculation; cache and conditional headers; ranges,
including the representation proxy's intentional full-body answer; and a
tampered variation signature.

After the final storage HTTP changes, all focused suites passed in the same
image: M6-T1 **10/10**, M6-T2 **6/6**, M6-T3 **6/6**, M6-T4 **3/3**, and M4
media integration **4/4**. T1 includes 51 Marcel cases, 16 filename cases,
original row/URL vectors, direct-upload rejection and cleanup, and seed HTTP
paths. T2 covers malformed images, tracked variants, concurrent winners and
failed cleanup. T3 covers malformed media, bounded ffmpeg/ffprobe timeouts,
video preview bytes, and concurrent preview reuse.

Reproduce the strict run from the OCaml checkout, with the pinned Rails
image and the pinned Rust checkout alongside it:

```sh
dune build test/m6_t1_test.exe test/m6_t2_test.exe test/m6_t3_test.exe test/m6_t4_test.exe test/m4_integration_test.exe
for name in m6_t1_test m6_t2_test m6_t3_test m6_t4_test m4_integration_test; do
  docker run --rm \
    --entrypoint "$PWD/_build/default/test/$name.exe" \
    -v /home/srikanth/projects:/home/srikanth/projects:rw \
    -v /lib/x86_64-linux-gnu/libev.so.4:/opt/ocaml-libs/libev.so.4:ro \
    -v /lib/x86_64-linux-gnu/libqrencode.so.4:/opt/ocaml-libs/libqrencode.so.4:ro \
    -w "$PWD/test" -e LD_LIBRARY_PATH=/opt/ocaml-libs \
    -e CAMPFIRE_REQUIRE_MEDIA_VECTORS=1 campfire-reference:latest
done
```

## Disposable live Rails/OCaml comparison

`test/m6_t4_live.py` uses the pinned test-session fixture and fetches a CSRF
token from a disposable authenticated Rails room page. It never prints cookie,
CSRF, signing key, or signed URL values. Both servers were started from
independent copies of the `default` seed at frozen
`2026-09-26T12:00:00Z`, with the same `Host: campfire.test`. The Rails server
used port 3116; the OCaml binary ran in the same pinned image on port 3117.
From the OCaml checkout, start both as follows:

```sh
M6_LIVE_STORAGE=$(mktemp -d /tmp/campfire-m6-t4-live.XXXXXX)
cp -a ../once-campfire-rust/parity/.seed/default/. "$M6_LIVE_STORAGE/"
../once-campfire-rust/parity/bin/reference up --seed default --port 3116 \
  --time 2026-09-26T12:00:00Z --freeze
docker run --rm -d --network host --name campfire-m6-t4-ocaml \
  --user "$(id -u):$(id -g)" \
  -v /home/srikanth/projects:/home/srikanth/projects:rw \
  -v "$M6_LIVE_STORAGE:/data:rw" \
  -v /lib/x86_64-linux-gnu/libev.so.4:/opt/ocaml-libs/libev.so.4:ro \
  -v /lib/x86_64-linux-gnu/libqrencode.so.4:/opt/ocaml-libs/libqrencode.so.4:ro \
  --env-file ../once-campfire-rust/parity/.env.reference \
  -e LD_LIBRARY_PATH=/opt/ocaml-libs \
  -e LD_PRELOAD=/usr/local/lib/faketime/libfaketime.so.1 \
  -e 'FAKETIME=2026-09-26 12:00:00' \
  -e FAKETIME_DONT_FAKE_MONOTONIC=1 -e FAKETIME_DONT_RESET=1 \
  -e CAMPFIRE_DATABASE_PATH=/data/db/production.sqlite3 \
  -e CAMPFIRE_FILES_PATH=/data/storage \
  -e CAMPFIRE_BACKUPS_PATH=/data/backups \
  -e CAMPFIRE_ASSETS_DIR=/home/srikanth/projects/once-campfire-ocaml/assets \
  -e THRUSTER_TARGET_PORT=3117 -e THRUSTER_TARGET_BIND=127.0.0.1 \
  --entrypoint /home/srikanth/projects/once-campfire-ocaml/_build/default/bin/main.exe \
  campfire-reference:latest serve --port 3117
```

Then run the comparator, substituting the directory created above:

```sh
python3 test/m6_t4_live.py \
  --rails-port 3116 --ocaml-port 3117 \
  --rails-storage /home/srikanth/projects/once-campfire-rust/parity/.seed/.instances/3116 \
  --ocaml-storage "$M6_LIVE_STORAGE"
```

Result: **256 comparisons, zero mismatches**. Compared status, body bytes,
MIME, disposition, cache policy, ETag, Last-Modified, range, and conditional
responses for a signed seed blob, signed disk GET, image and video
representation redirect/proxy routes, invalid signatures, both stock logo
sizes, one stored WebP avatar and one initials SVG. Direct-upload POST and
signed PUT used the test cookie plus Rails CSRF token; successful PUT, bad
checksum rejection, matching stable JSON fields, SQLite row fields, exact
stored bytes, and failed-file absence passed. The live check caught and led
to fixes for blob and representation proxy cache/ETag/conditional behavior,
`Range` handling, and the storage controller's `head` content type.

The comparison deliberately excludes four known Rails-versus-pinned-Rust
differences, each noted in the script: Rust's `fresh_when` returns 304 before
stream/disposition headers are set; Rust's disk FileServer retains
`Content-Type` on 304; first-generated variant blob keys are random, so
their signed disk paths differ while content and metadata match; and Rust
stores empty direct-upload metadata as `{}` while Rails stores SQL `NULL`.
Rails' direct-upload JSON also includes `attachable_sgid`, omitted by the
pinned Rust `direct_upload_json` and the OCaml port. The disk file's
`Last-Modified` is excluded because Rails' frozen clock alters file stat
times while the separately copied OCaml seed retains its filesystem mtime.
These differences do not mask mismatched bodies, checksums, statuses, or
other compared headers.

Closure audit (2026-10-09): the manager independently rebuilt and passed the
strict 3/3 suite in both the pinned Rails media image and built OCaml amd64
production image. All four M6 tickets are verified complete; arm64 and release
publication remain M7/M8 gates. See [M6 audit](m6-audit.md).

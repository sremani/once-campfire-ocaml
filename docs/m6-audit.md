# M6 storage and media audit

Pinned Rust source: `crates/storage` at `9872c1d9541551c0889a60e3d49a14488bd1e403`.
Pinned Rails reference: `90b330024dec3e757c79b6a7e6568f93da8e3148`.
The source vectors are `vectors/storage.json` and `vectors/storage/` in the Rust checkout;
their generator is `reference-tools/storage/generate.rb`. The Rust crate's
`tests/vectors.rs` is the comparison specification.

## Existing seams

- M2 has schema-compatible `Db_remaining.Blob`, `Attachment`, and
  `Variant_record` rows. `Blob.destroy` removes rows, while the disk purge is
  deferred to M6. File operations should run outside the database writer,
  followed by short row transactions; stage ownership must delete abandoned
  files on failed copies or rolled-back writes.
- M3-T4 owns Active Storage route policy and `Controller_aux.register_storage`;
  M6 now registers blob redirect/proxy, representation redirect/proxy, signed
  disk GET/PUT, and direct-upload POST actions. Blob GETs are public; writes
  require a real signed-in session and CSRF. Signed route responses passed the
  live Rails/OCaml storage comparison below.
- M3-T1 now streams multipart files to request-owned `RackMultipart` temp
  paths, with a 10 GiB default body cap, 4,096-part, 128-file, and 16 MiB
  aggregate text limits. It has tested a 129 MiB file, configured rejection,
  cancellation cleanup, and seeded message/bot attachment writes. M6 stages
  the temp file before the request ends.
- Rails uses the `local` disk service at `storage/files`; keys use
  `<first 2>/<next 2>/<key>`. The parity seeds already contain storage files
  next to SQLite databases. Existing keys and their raw files must survive.
  Blob checksums are Base64 MD5. Signed blob ids have purpose `blob_id`;
  variation keys use `variation`; disk read keys use `blob_key`; direct-upload
  tokens use `blob_token`, all through the ActiveStorage app verifier.

## Source and vector inventory

- `vectors/storage.json` holds 12 ordered variation/Marshal/digest/key cases,
  51 Marcel content-type cases, 16 filename cases, five message attachments,
  two avatars, one logo, signed URL samples, and original/variant/preview
  metadata. `vectors/storage/` has eleven expected derivative files. The
  original upload fixtures live in `reference/test/fixtures/files`.
- Rust's `storage.rs` stages a file or bytes, identifies content type from a
  short Marcel prefix, streams MD5, copies to disk, then inserts rows. `open`
  copies to a named tempfile and verifies the stored checksum. Variant and
  preview creation use a fast insert-after-processing transaction and reuse a
  winner on concurrent requests. Purge deletes the source and legacy
  `variants/<key>/` files where applicable.
- `disk.rs` specifies direct-upload token payload order, checksum and size
  validation, URL escaping, disk paths, and failure cleanup. `file_server.rs`
  specifies conditional GET, HEAD, single/multiple byte ranges, 416, and
  content headers. `marcel.rs` uses tables generated from the pinned Rails
  bundle; generic `magic-mime` is installed locally but is not a parity
  substitute for these tables.
- `analyze.rs` uses libvips image dimensions and EXIF orientation; ffprobe
  handles audio/video metadata with a 30-second timeout. `process.rs` uses
  libvips for the only named operation, `resize_to_limit`, and ffmpeg for video
  preview extraction, with a 60-second timeout. Vips disables untrusted
  loaders and OpenSlide like the Rails initializer. Invalid formats,
  unsupported operations, corrupt media, and timeout cleanup need tests.

## Reproducible media dependency

The vector producer used **libvips 8.16.1** and **ffmpeg/ffprobe
7.1.5-0+deb13u1**. The pinned Rust `Dockerfile` already builds these from
Debian trixie source packages with checked `.dsc` SHA-256 values:
`vips 8.16.1-1+deb13u1` and `ffmpeg 7:7.1.5-0+deb13u1`. Reuse those media
stages for the OCaml CI/runtime image and run byte comparisons there. The
current Ubuntu host has ffmpeg/ffprobe but no libvips library, headers, or
command. Its available `libvips-dev` package is 8.15.1, suitable for local
functional work after installation, but not as byte-identical vector evidence.
The local `campfire-reference:latest` image already has libvips **8.16.1**
(queried through its shared library) and ffmpeg/ffprobe **7.1.5-0+deb13u1**;
it can serve as an immediate matching media runtime while a reproducible OCaml
toolchain image reuses the pinned source-build stages.
The Rust vector suite itself makes byte checks mandatory only when versions
match (or `CAMPFIRE_REQUIRE_MEDIA_VECTORS` is set); the final M6 gate must
exercise matching versions and compare bytes without skips.

## Acceptance matrix

| Evidence family | Rust source | OCaml target |
| --- | --- | --- |
| Marshal, variation signatures/digests, URL path and filename encoding | `storage/tests/vectors.rs`: `variation_digests_and_keys`, `verifier_messages_and_disk_urls`, `filenames_and_dispositions`, `route_paths` | Exact vector bytes and rejected signatures |
| Blob upload and disk behavior | `storage/tests/vectors.rs`: `staging_a_file_unfurls_it_as_its_bytes_would`, `a_staged_file_is_deleted_unless_kept`; `disk.rs` tests | Existing seed read, checksum/size rejection, rollback and failed-copy cleanup, direct upload, conditional and range HTTP |
| Content identification | `storage/tests/vectors.rs`: `marcel_identification` | All 51 pinned cases, including malformed/ambiguous declarations |
| Image/audio/video pipeline | `storage/tests/vectors.rs`: `pipeline_matches_the_reference`; `process.rs` malformed/timeout tests | Metadata, row relations, generated image/video bytes with the matching media versions, concurrent generation and failure cleanup |

The matrix is satisfied by the M6-T1 through T4 tests and the live comparison
below. Every M6 ticket is verified complete; broader browser, release, and
multiarchitecture deployment gates remain with M4, M7, and M8.

## Handoff evidence after T1–T3

M6-T1's pinned URL, Marcel, seed file, direct upload, range, and cleanup cases
pass. M3-T1 has since implemented request-owned streamed multipart and tested
a 129 MiB file, cancellation cleanup, and seeded message/bot attachment
writes; the configured 10 GiB cap is checked as an incremental byte counter.
`App_jobs.on_purge` now loads the blob and calls `Storage_blob.purge` after
commit. The manager independently reran M5's seeded integration suite (8/8):
rollback retained the blob row and file, while a committed PurgeBlob event
removed both. The seeded bot text attachment and webhook completion also pass.

M6-T2's strict suite was rerun by the manager in `campfire-reference:latest`
with libvips 8.16.1 after changing the derivative assertions from digest
equality to direct file-byte equality. All six focused cases passed, including
seven derivative files, concurrent winner reuse, malformed image rejection,
and cleanup. M6-T3 was independently rebuilt and rerun in the same image with
ffmpeg 7.1.5; all five strict cases passed, including exact JPEG preview and
three video derivative files, signed variation keys and paths, ffprobe
metadata, bounded subprocess behavior, and the concurrent entropy regression.
M6-T3's null analyzer now skips ffprobe for text and other non-media types;
its process runner retries interrupted select/read/wait operations. The
manager reran its updated five host cases and six matching-media cases, all
passing.

## Final M6 differential and packaging audit

Dedicated M6-T4 agent compared all eight original fixtures and all eleven
golden derivative files (ten variants plus the video preview) byte for byte,
along with row metadata, checksums, signed storage HTTP responses, malformed
signatures, and eight concurrent first transforms with one winner and no
orphan file. The manager independently rebuilt and reran M6-T4's strict
**3/3** suite in both `campfire-reference:latest` and the built
`campfire-ocaml:m7-t3` production image; both passed. T2/T3 also passed their
strict six-case suites in the production image. The Dockerfile pins Debian
libvips `8.16.1-1+deb13u1` and ffmpeg `7:7.1.5-0+deb13u1`; its amd64 image
therefore contains the tested media runtime. Arm64 image and ONCE publication
checks remain M7/M8 release work.

The live comparator started disposable Rails and OCaml services from separate
copies of the pinned default seed at frozen time. It reported **256
comparisons, zero mismatches** across signed disk/blob/representation
responses, image/video poster, avatar and logo routes, direct upload POST/PUT,
failed-checksum cleanup, stable SQLite rows, bodies, cache and range headers.
It omits only documented Rails-versus-pinned-Rust differences: supplementary
304 headers, Rails-only `attachable_sgid`, Rails SQL `NULL` versus Rust JSON
`{}` for empty direct-upload metadata, random generated variant keys, and
file mtimes affected by the frozen Rails clock. These exclusions do not hide
status, body byte, checksum, or stable metadata differences. Reproduction
and comparison details are in [M6-T4 handoff](m6-t4-differential.md).

## Full-route matrix follow-up (2026-10-09)

M8-T2's later pinned Rust/OCaml default-seed route matrix found one storage
response discrepancy outside the earlier Rails/OCaml media corpus: a malformed
signed disk GET (`/rails/active_storage/disk/invalid-token/moon.jpg`) returned
the right 404 and empty body, but OCaml omitted Rust's public cache header and
used `text/html` instead of the negotiated `image/jpeg`. Pinned Rust's
`disk_show` applies `Cache-Control: max-age=3600, public` after `disk_serve`
returns, including its 404 branches, and `Ctx.head` uses the rendered request
format. `Storage_http.disk_show` now follows both rules for invalid tokens and
missing files. M6-T4's signed HTTP case asserts status, MIME, and cache for
both branches.

The manager rebuilt and reran M6-T1 **10/10** on the host and M6-T4 strict
**3/3** in the pinned media image after this change. M8-T2 reset Rust and
OCaml from separate seeds for each role and reran route 174: **4/4** anonymous,
signed, denied, and bot cases passed with exact status, headers, body bytes,
and unchanged SQLite tables (`/tmp/m8-t2-row174.md`). M6 ticket closure is
unchanged; M8 owns the broader route matrix.

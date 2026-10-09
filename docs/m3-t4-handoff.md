# M3-T4 auxiliary HTTP handoff

`lib/controller_aux.ml` owns all 31 route rows assigned in `docs/m3-route-audit.md`.
`test/m3_t4_test.ml` checks the route inventory, fixture-backed HTTP cases,
39 pinned RQRCode matrix vectors, and 18 extra version-boundary vectors from
the pinned Rust encoder. The targeted suite passes with
`dune exec test/m3_t4_test.exe` (9/9 cases). It also checks the first-run
seed's `Campfire` manifest fallback and unversioned logo path.

Implemented behavior:

- Public web manifest with the seed account name, logo routes, asset URLs, shortcuts,
  screenshots, and a service worker copied from the pinned template. Public health
  HTML/JSON and the three Turbo native navigation bodies use their standalone
  controller policy without the app's version headers.
- Public Base64url QR endpoint with actual SVG output from system `libqrencode.so.4`.
  The binding chooses a single numeric/alphanumeric or byte segment, and OCaml
  selects the mask using RQRCode's lost-points score. Its 39 pinned module
  matrices and every included golden SVG match byte for byte. Malformed Base64
  yields the upstream 500; an unencodable payload yields 422.
- Unconfigured Action Mailbox ingress responds 404 even for banned IPs, matching
  its separate Rails base controller. Conductor checks CSRF first, then responds
  403. Unfurling requires a Campfire session and a nonblank URL.
- Active Storage reads are public. Disk PUT requires a valid Campfire session;
  direct-upload POST checks CSRF before the same session lookup. This dedicated
  lookup does not refresh activity or apply the app's banned-IP hook. `bin/main.ml` registers M6's `Storage_http`
  handlers through `Controller_aux.register_storage`; unregistered actions
  still respond 501 when a controller is tested without the service.
- Missing direct-upload `blob` parameters use the pinned PublicExceptions 400
  response: empty body, uppercase UTF-8 charset, Content-Length 0, and no
  controller cache or security headers. The focused test covers signed and
  banned addresses through the registered M6 storage adapter.

The M8-T2 rebuilt live Rust/OCaml comparison passed all four roles for each
Action Mailbox route 154–160 and disk PUT row 175. A later focused rerun passed
all eight role cells for logo DELETE row 38 and direct-upload POST row 176,
including exact response and persisted state. M6 subsequently fixed disk GET
row 174's invalid-token cache and content type and reran all four roles exactly.

On the 2026-10-09 source update, production `/webmanifest.json` now calls
`Views.pwa_manifest_json` with the request context, seed account name,
versioned logo paths, and packaged asset map. This replaces the compact JSON
builder; the exact M4 golden manifest and service-worker body have already
passed in the view matrix. The auxiliary focused test now asserts that the
production manifest uses the renderer's multiline byte shape. The latest
708-case M8-T2 report had already passed route rows 148 and 149 in all four
roles, but used the earlier compact manifest because it requested the
extensionless paths (406). A focused live `.json`/`.js` comparison is still
needed for the new production response bytes.

The same update makes a signed `POST /unfurl_link` without `url` return the
PublicExceptions 400 shape: uppercase UTF-8 content type, zero content
length, and no controller cache, security, version, or refreshed-cookie
headers. The latest M8-T2 report identified this as the only auxiliary
route-row failure (row 147, signed): status and persisted state already
matched, while those headers differed. The focused test checks the new
header behavior; the live row has not yet been rerun. The 31-row auxiliary
matrix otherwise passed 123/124 role cases in that report.

M8-T2's next immutable candidate reported **124/124 auxiliary role cases
passing** in the ordinary default-seed matrix, including row 147 signed. It
still requests extensionless `/webmanifest` and `/service-worker`, which
negotiate 406. The positive `.json` and `.js` responses were checked in a
separate focused live comparison on independent disposable default-seed copies
at the pinned frozen clock `2026-03-02T16:00:00Z`.
`docs/m3-t4-live-aux.json` records **3/3 exact passes**: manifest 200,
service worker 200, and signed missing-URL unfurl 400. Every response header,
body byte, and before/after SQLite table hash matched. The immutable OCaml
binary's SHA-256 was
`90b091071bdb9e6d39913273b772fd876f2ff7d0aa334ca608a18c360dae5c78`.
Both disposable app containers were stopped after the run; the shared Caddy
and network were left in place for M8-T2's full matrix.

`scripts/m3_t4_live_aux.py` is the focused check.
It compares exact status, headers, and body bytes for the two public paths and
the signed missing-URL POST, plus every SQLite table before/after the POST.
It only sends pinned test credentials and reports response-header names and
body digests on a mismatch. It neither starts nor resets containers. Run it
only after both pinned apps are started on independent disposable seed copies
at the same frozen clock:

```sh
python3 scripts/m3_t4_live_aux.py --seed default \
  --rust-port RUST_PORT --ocaml-port OCAML_PORT \
  --rust-db RUST_DB --ocaml-db OCAML_DB \
  --output /tmp/campfire-m3-t4-live-aux.json
```

For a separately isolated rerun of row 147 across all four roles, use
`scripts/m8_t2_http_state.py --row 147 --isolate` with the documented M8-T2
port, DB, seed-copy, container, and immutable-binary arguments.

Open integration and parity work:

- **QR deployment:** Raw `libqrencode` matched 7/39
  golden matrices. The encoder-mode split and RQRCode mask scoring bring this to
  39/39, including the fixed empty-input matrix; all golden SVG bodies match.
  The pinned source's strict capacity rule is now applied before calling
  `libqrencode`: `test/fixtures/qr_version_boundaries.json` records 18 exact
  SVG lengths and SHA-256 hashes from the pinned Rust encoder for numeric,
  alphanumeric, and byte payloads on both sides of versions 1→2, 2→3, and
  9→10. All 18 pass; the 3,000-byte overflow is rejected. The fixture records
  its pinned Rust source hash, which the test verifies.
  The C binding uses the stable ABI declarations because the local development
  header is absent; deployment needs `libqrencode.so.4`.
- **M5 OpenGraph:** production `bin/main.ml` registers the M5 guarded fetcher,
  and the 90-case seeded HTTP oracle passes. The controller retains a 204
  fallback only when tested without registration; live public-network cases
  still need the final gate.
- **M6 storage:** production registers the M6 storage adapter and representation
  processor. The 256-case M6 storage differential passed separately; M8-T2's
  four-role route matrix passed rows 168–176. Final image and route reruns
  remain outstanding.
- **M4 views:** `Views.pwa_manifest_json` now renders production manifest bytes;
  its pinned golden passed in the 123-file M4 view matrix and the live
  `.json`/`.js` response comparison above passed exactly.
- **M3-T5 cache:** QR's public max-age header is set, but complete conditional
  GET/freshness behavior remains with T5. Storage cache policy belongs with M6/T5.
- **M3-T1 dispatcher:** `Controller_aux.endpoint` is now wired in
  `App_dispatch`. The T4 tests still dispatch directly to isolate ownership.

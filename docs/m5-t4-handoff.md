# M5-T4 guarded outbound integrations handoff

## Implementation

- `lib/network_guard.ml`: Surfguard default IPv4/IPv6 classification, numeric/legacy host parsing, DNS answer filtering, IPv4 preference, injected/system resolvers.
- `lib/outbound_http.ml` and `lib/outbound_curl_stubs.c`: guarded one-shot HTTP/1.1 exchange with a pinned address via `CURLOPT_RESOLVE`; verified TLS against the original URL host; no proxies or automatic redirects; connect, idle-read, and whole-call timeouts; decoded-body cap. Production callers leave `ca_bundle=None`; a fixture CA is injected only in the TLS test.
- `lib/webhook_transport.ml` and `lib/webhook_inflate_stubs.c`: webhook-only direct Conduit connection with verified OpenSSL TLS and original-host SNI, ordered Cohttp request serialization, no proxies or redirects, per-read and whole-call deadlines, and incremental bounded gzip/deflate decoding.
- `lib/webhook.ml`: administrator-configured, intentionally unguarded bot webhook policy using the ordered transport, with 7-second connect/read limits, 60-second whole-call limit, 100 MiB decoded reply cap, Rails MIME mapping and reply selection.
- `lib/opengraph.ml`: guarded document GET and image HEAD, 10-response redirect limit, re-resolve/re-pin on each redirect, 5 MiB decoded HTML cap, 10-second whole-call bound, 16 concurrent unfurls, Rails metadata extraction and JSON order. It reuses the pinned Gumbo parser already linked for rich text.
- `Outbound_http.web_push_outbound`: production adapter for `Web_push.outbound`, using the request's pinned IP, 10/10/30-second limits, and 64 KiB response cap. It rejects private/reserved pinned addresses.

## Evidence

`dune build` and `dune exec ./test/m5_t4_test.exe` with loopback socket permission both passed after the shared tree stabilized. The focused suite has 13 passing tests and replays all 90 pinned OpenGraph oracle cases, including exact JSON body, DNS lookup sequence, and request sequence; all 19 webhook oracle cases, including reply bytes, MIME mapping, and request header values; Surfguard address and numeric-host matrix; live pinned HTTP and fixture-CA TLS hostname checks; decompressed gzip cap; gzip/x-gzip/deflate aliases and Content-Range behavior; whole-call trickle deadline; idle-read timeout. The live webhook test asserts the exact seven raw headers in the pinned Rails order and the exact request body. A later transport-only run passed 7/7 cases after the inflater gained concatenated gzip member support; a direct decoder test feeds each byte separately, checks the cap across members, and rejects a truncated second member.

The fixture files are copied byte-for-byte from pinned Rust `crates/campfire/src/integrations/testdata`. The TLS certificate covers `www.example.com`; the test pins it to 127.0.0.1 and confirms that a different URL hostname fails validation.

The seeded `test/m5_t4_route_test.ml` now posts every one of the 90 pinned OpenGraph URLs through `Http_app.handle` and `/unfurl_link` using injected guarded resolver/perform functions. It compares HTTP status, exact Rails JSON response bytes, DNS lookup order, and outgoing request order. All 90 pass. The controller adapter preserves the already serialized Rails JSON and propagates the oracle's exceptional 500 responses.

The seeded `test/m5_t4_integration_test.ml` has three passing checks: a signed Bender mention in non-direct All Talk schedules exactly one webhook while an ordinary post schedules none; a bot file reply is stored and its attachment HTML reaches the Cable stream; and a real local listener accepts the source HTTP post, delivers to a local webhook with the pinned seven-header order, persists the text reply, and broadcasts that reply over a WebSocket on the same listener. `test/m5_t4_attachment_test.ml` compares the file presentation HTML byte-for-byte to the pinned Rust `messages/presentation.rs:file_link` output, including escaped filename and URL. The live integrated test was run with loopback socket permission on a disposable copy of the pinned seed. Commands: `dune exec ./test/m5_t4_route_test.exe` (90/90), `dune exec ./test/m5_t4_attachment_test.exe` (1/1), `dune exec ./test/m5_t4_integration_test.exe` (3/3), and `dune exec ./test/m5_t4_test.exe` (13/13).

The manager corrected the attachment renderer's three image closing tags to
match Rust's `<img ... />` bytes and strengthened the 204 route assertion to
require an empty body. Independent reruns passed the four suites above and
`dune build @check`. M5-T4 is accepted.

## Verification limits

- Startup attaches `Outbound_http.web_push_outbound` to the Web Push pool. Live guarded Web Push delivery to an external endpoint remains unverified under M5-T3; the pinned-IP/TLS adapter has a local fixture test.
- The 90 unfurl cases cover the full `Http_app.handle` route with injected transport; they have not been replayed over a TCP listener. Malformed response and large compressed-body cases remain verified at the focused transport layer.

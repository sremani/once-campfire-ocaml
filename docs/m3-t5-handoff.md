# M3-T5 response/cache handoff

The implementation is `lib/http_cache.ml`, integrated through `lib/http_app.ml`
and the eligible room/message/search controllers. Its focused suite is
`test/m3_t5_test.ml` (13 passing cases). It was read against pinned Rust
`crates/kit/src/ctx.rs`, `crates/kit/src/front/cache.rs`,
`crates/kit/src/front/handler.rs`, `crates/campfire/src/response_cache.rs`,
and the room/message controller route tests. M3-T5 stays open for the gaps below.

## Response finalization contract

* `Http_app.handle` calls `Http_cache.finish ~request` on a response after cookies
  and action headers are committed, before `Http_gzip.apply`. It hashes a nonempty
  200/201 byte body with SHA-256, takes the first 16 bytes as a weak Rack ETag,
  supplies Rack's default `Cache-Control`, handles conditional GET/HEAD, and
  drops the HEAD body. Pass `~digestible:false` for live/file/stream responses.
  Existing `Content-Length` and multipart/large-body behavior need review for
  HEAD and compression.
* Controllers that use Rails `fresh_when` should call
  `Http_cache.fresh_when` with expanded cache keys, template digest, frame
  variant and `Last-Modified` as appropriate. It returns headers, cache
  control, and a freshness boolean. `expires_in` provides `Date` plus Rails
  directive ordering. `apply_control` retains an explicit controller header.
* `If-None-Match` takes precedence over `If-Modified-Since`; a comma list and
  `*` match the exact validator. `If-Modified-Since` is consulted only when
  the response has `Last-Modified`. Message pages must omit `Last-Modified`
  because foreign edits to displayed dependencies can omit timestamp changes.
* Redirects and errors get `Cache-Control: no-cache` absent an explicit
  directive; a 200 with a nonempty body gets `max-age=0, private,
  must-revalidate` when Rack generates its ETag. Empty 200s have no Rack ETag.

## Public front cache contract

`Http_app.serve` owns a 64 MiB `Http_cache.Front`; callers of `handle` may pass
one explicitly. `Http_cache.Front` accepts GET/HEAD without upgrade or Range and a raw path
and query no longer than 2048 bytes. A 200..399 response except 304 can enter
only with `public` and positive `s-max-age` or `max-age`, and without
`no-cache` or `Vary: *`. The store charges key, headers, variant, body and
256 bytes overhead to both total and per-item limits. It strips `Set-Cookie`
before storage, preserves Vary header values in the key, expires entries, and
accepts a caller-supplied generation for invalidation. To match Rust's front
handler, run this cache **after** response gzip; a hit should set `X-Cache:
hit`, a miss `X-Cache: miss`, and a bypass `X-Cache: bypass`. Rust front cache
conditional hits compare the exact cached ETag and `If-None-Match` list.

## Private completed-response cache contract

`Http_cache.Private` provides the bounded 15-second store for
`rooms#show`, `messages#index`, `users/sidebars#show`, and `searches#index`.
It limits body input to 1 MiB, item charge to 2 MiB, and key input to 8192
bytes. The caller chooses the overall capacity (Rust defaults to 64 MiB and
uses `CAMPFIRE_RESPONSE_CACHE_MB=0` to disable). A ticket hashes database
generation, endpoint, user/session IDs, URI, origin and all request header
values except validators and tracing. Stored responses strip cookies, Date
and tracing headers. `lookup` and `store` require the current generation and
reject an old ticket.

`Http_app` captures generation before authentication and checks it again at
lookup and admission. A separate read-only SQLite observer connection uses
`PRAGMA data_version`, matching Rust's commit observation. Room/message/search
controllers and `users/sidebars#show` call lookup after authentication,
authorization and their existing request side effects. The completed bounded identity/gzip body enters the
store; a hit still passes through response finalization for fresh cookies,
conditional replies and HEAD. File and live streams do not enter the store.
`Http_app` now sets the completed body length and fixed Cohttp framing on
initial private cache misses, and `Private.store` records that length in
cached headers, including gzip bytes. This matches pinned Rust's
`response_cache::completed` behavior for initial GETs, hits and HEAD hits.

The offline 2026-10-09 HEAD gate found and fixed two response errors: a room
HEAD returned `Content-Length: 0` for a nonempty GET representation, and a
gzip-advertising HEAD emitted a gzip member for the already dropped body.
`Http_cache.finish` now retains identity length before dropping the body;
`Http_gzip.apply` follows pinned Rust's HEAD no-compression selection. The
scoped seed test checks identity GET, gzip GET, identity HEAD, gzip-advertising
HEAD, conditional HEAD, gzip private-cache hits, and a streamed file HEAD.

## M8-T2 ordinary HTTP-state audit (2026-10-09)

The pinned default 579/708 report has 129 failures. Of these, 85 contain a
body difference; all 55 ETag differences and all 85 Content-Length
differences occur in this group. They derive from differing view/error body
bytes, so changing validators or lengths alone would be incorrect.
The other 44 failures contain only header differences:

* 22 empty 400 exception responses differed across default headers and
  `Vary`. M3-T1 addressed the public-exception `Vary` seam after this
  baseline; the next differential rerun must measure its effect.
* Nine room-list redirects differ only in `Set-Cookie` (M3-T3/T2 session
  behavior), six bot-boost 404s and three bot-message 422s only in
  `Content-Type` (M3-T3), three join redirects only in `Location` (M3-T2),
  and one boost-delete 204 only in `Content-Type` (M3-T3).

This baseline has no isolated ETag/cache validator mismatch to repair in
`Http_cache`. The room integration test now also proves an old ETag returns
the changed 200 body after a SQLite commit, and a future
`If-Modified-Since` cannot manufacture a 304 or `Last-Modified` for the room.
It does not assert Rails view bytes. M3-T5 stays open pending the next live
HTTP/state rerun and conditional/public/private cache route scenarios.

## Open parity work

1. Integrate remaining controller-specific cache keys and page-part digests
   for rooms/messages and template/frame/flash etaggers.
   `Controller_rooms.message_index` now uses `Http_cache.rendered_freshness`
   for the pinned `messages#index` byte-body fallback: SHA-256 of rendered
   bytes, template `messages/index`, an optional nonblank Turbo frame etagger,
   and no `Last-Modified`. The scoped seed test checks its 304 GET, HEAD
   validator and identity length, and IMS-only 200. Current views do not
   expose page-part digests; a room page still gets a Rack body digest.
   `Http_cache.Page_parts.of_offsets` now matches the pinned Rust whole/mixed
   splice ETag vectors exactly. It requires renderer-recorded fragment byte
   offsets and applies Rust's 1024-byte minimum fragment and 256-byte glue
   threshold. Current `Views.room_show` returns one string and exposes no
   offsets or parts, so the room route still gets Rack's whole-body ETag and
   one materialized body. Integration requires a renderer seam and frame
   transport work; deriving offsets by searching final HTML is unsafe when
   identical fragments repeat. Account avatar/logo handlers already set record-key validators; no-account
   logo must omit ETag, which was sent to M3-T2.
2. Compare exact route headers and body frames with pinned Rust/Rails after
   M4 views, M5 live responses and M6 storage streams settle. Pinned Rust
   `rooms/tests.rs::pages_of_messages_go_out_in_parts` requires over 40 body
   frames, identical plain/gzip/HEAD ETags, plain `Content-Length`, and no gzip
   `Content-Length`; this OCaml stack currently materializes those pages as a
   string. Pinned `messages/tests.rs::index_pages_with_conditional_gets`
   requires a weak ETag, 304 and no `Last-Modified`; the focused room route
   confirms those response semantics, but does not claim exact message-page parity.

## 2026-10-09 offline flash, Vary and finite-body gate

`Http_app.flash` loads Rails' `{"discard":[],"flashes":{...}}` session value
lazily, filters previously discarded keys, and marks loaded flashes for
consumption during commit. `View_presenter.context` supplies notice/alert to
the existing view. Pending flash bypasses private lookup and admission, while
a newly assigned redirect flash survives for the next request. This follows
pinned `kit/session.rs::Flash::from_session_value` and
`campfire/response_cache.rs::{lookup,prepare}`. The seeded route test warms a
room response, creates a denied-room flash, verifies `/up` leaves it pending,
then verifies room rendering, cookie consumption, no cache admission and a
clean cached response afterward.

`Http_format.should_apply_vary_header` follows pinned
`kit/format.rs::should_apply_vary_header`; `Http_app.commit` adds `Vary: Accept`
to rendered HTML responses when format negotiation used a valid Accept
header. The seeded room and sidebar responses now retain it alongside
`Accept-Encoding`, including private cache hits. Browser-like wildcard Accept
and explicit format parameters are covered by focused tests. This addresses
the network-header portion of the M8-T3 browser capture; its sidebar body
hash still belongs to view parity.

`Http_cache.finish` hashes finite `String`/`Strings` bodies in 64 KiB slices
without joining their chunks, preserving the original body and exact Rack
SHA-256/HEAD length for a 3 MiB regression. Stream bodies are marked
`digestible:false` at the sole application finalizer call in `Http_app.handle`;
file routes keep their explicit length/Last-Modified or model validator, as
in pinned Rust `kit/ctx.rs::rack_etag` (Bytes/Parts only).

The thirteen tests exercise actual SHA-256 bytes, 304/HEAD/empty body behavior,
date and directive formatting, public eligibility, Vary/URI/limit checks,
private ticket isolation and generation/TTL/size rejection, a public QR route
miss/hit/304/Range bypass, and pinned Rails seed room/sidebar routes through
private hits, message-index conditional GET/HEAD, identity/gzip lengths, streamed HEAD,
SQLite commit invalidation and session revocation.
`dune exec --build-dir _build_m3_t5 ./test/m3_t5_test.exe` passed 13/13;
M3-T3 focused suite passed 9/9 after message-index integration. These are
targeted route checks, not full body/header parity.

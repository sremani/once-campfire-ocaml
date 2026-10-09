# M5 realtime and integration audit

The source is the pinned Rust commit in [milestones.md](milestones.md). This audit
lists the contracts the four M5 tickets must verify. It is not completion
evidence; milestone checkboxes remain open until the implementation and tests
pass.

## Transport dependency and server seam

The existing OCaml app uses Cohttp 5.3 and Lwt 5.7. No OCaml WebSocket package is
installed, and this environment has no `opam` binary. The established
[`vbmithr/ocaml-websocket`](https://github.com/vbmithr/ocaml-websocket) source at
`133eda58386c43b95fed21ba1921cbc37b629b98` is ISC licensed. Its
`websocket-lwt-unix.cohttp` module supplies `upgrade_connection`, returning
Cohttp's `Expert` response action for the same listening socket. Its declared
OCaml dependencies (`astring`, `base64`, `ocplib-endian`, `conduit`, `cohttp`,
`mirage-crypto-rng`, `logs`) are installed here. Vendor the pinned source and
license so a build does not require an online package manager.

The library does not negotiate `permessage-deflate`, rejects extension bits,
and does not enforce Campfire's one-megabyte command limit. Its Cohttp upgrade
adapter also needs explicit version/key validation and protocol negotiation;
its frame reader needs tested fragmentation behavior. M5-T1 must add and test
these compatibility pieces around or in a minimal fork of the library.
`Http_app.serve` currently uses `Cohttp_lwt_unix.Server.make`; M5-T1 should
expose a Cable `response_action` and integrate the `/cable` path with
`Server.make_response_action` in agreement with M3, preserving the normal
controller callback for other paths. The agreed seam is
`Cable_transport.handle : ?config:config -> Cohttp.Request.t ->
run:(connection -> unit Lwt.t) -> Server.response_action Lwt.t`; M5-T2 supplies
the authenticated connection runner. The separate `httpun-ws` implementation inspected at
`5b9cd6ec8f2ddf4589d119d543f13c49a9fbe3f9` targets httpaf, which is
absent from the current Cohttp listener, and supplies no apparent compression
advantage.
`Http_app.serve` passes `cable_run request` into this transport handler so the
runner can verify the signed cookie from the upgrade request. With no
`cable_run`, `/cable` remains the ordinary route's 404.
M5-T2's planned application API is `Cable_channels.create ~db
~secret_key_base ~now:(unit -> string) ()`, `Cable_channels.run t request
connection` (passed to `Http_app.serve ~cable_run`), and
`Cable_channels.event_sink t` for M2 after-commit events. Its hub accepts
`broadcast t ~stream ~payload`; a mutex-protected bounded queue and Lwt's
thread-safe notification wake the event loop from database worker callbacks.

## Ticket contract and pinned tests

| Ticket | Source and exact checks | Integration seam |
| --- | --- | --- |
| M5-T1 | `crates/cable/src/{server,connection,socket,protocol,pubsub}.rs`; `crates/cable/tests/{protocol,golden}.rs`; `crates/cable/tests/golden/reference.json`. Match the 404 for plain/cross-origin requests, HTTPS assumed-origin check, Action Cable subprotocol, welcome/unauthorized disconnect, 3-second shared heartbeat, WebSocket ping/pong/close, fragmented and compressed text, 1 MiB inbound limit, 64 subscriptions, 4 KiB identifier, ring capacity 256 and 64-frame write batch. Preserve the reference frame order and bounded slow-subscriber close. | Cohttp expert callback and existing `Authentication` session lookup; upgrade must use the same application listener. |
| M5-T2 | `crates/campfire/src/channels/` and its socket-driven tests. Match Room, Presence, TypingNotifications, ReadRooms, UnreadRooms and Turbo streams, membership rejection, signed stream names, broadcasts, and remote revocation. | M2 `Db_remaining.Event` typed after-commit sink and M3 write/controllers' broadcast hooks. `DisconnectUser` is a synchronous Cable broadcast after commit. |
| M5-T3 | `crates/campfire/src/jobs.rs`, `integrations/{jobs,web_push}.rs`, and `integrations/testdata/web_push_expected.json`. Match independent bounded queues (1024 per kind), worker isolation, no retry, drain-with-deadline shutdown, VAPID ES256, RFC 8291/8188 `aes128gcm`, push payloads, invalid-subscription deletion and at-most-50 active/10,000 pending sends. | M2 events `PushMessage`, `RemoveBannedContent`, `PurgeBlob`; M6 owns disk purge and M4 supplies rich-text/presentation where notification content needs it. |
| M5-T4 | `integrations/{net,webhook,opengraph}.rs` and pinned `webhook_cases/expected.json`, `opengraph_cases/expected.json`. Match DNS/private-address guard, address pinning through redirects, HTTPS hostname verification, per-read and total deadlines, decompressed body limits, JSON request wire format, webhook text/attachment replies, OpenGraph extraction and link unfurl. | M3 bot/webhook and unfurl controllers, M4 rich text and M6 attachment staging. No request may resolve once and then connect to a different address. |

M2 already has `Db_remaining.Event` variants and `emit_after_commit`. They are
the single event handoff; jobs and Cable should consume them only after a
successful transaction. The M3 application has not yet wired all event sinks,
and M4/M6 presentation/media work is in progress, so tests must cover both
each M5 module and its eventual request path.
Current room/message controller writes call bare model methods, and
`Controller_rooms` passes a no-op `on_disconnect` to membership revision.
M5-T2 and M3-T3 require a coordinated call-site pass, plus a live two-client
broadcast and revocation test, before either ticket can be accepted.

For M5-T3, installed `mirage-crypto-ec` has P-256 ECDH and ECDSA, while
`mirage-crypto` has AES-GCM and SHA-256; these should supply Web Push crypto
without a custom curve implementation. For M5-T4, the installed Cohttp client
does not directly expose the Rust transport's pinned-address/TLS-hostname
combination. `libcurl` and its executable are available on the host, while the
OCaml curl binding is in apt but not installed. Select a reusable HTTP client
path that preserves DNS pinning, TLS verification, independent redirect checks,
and bounded decompression before wiring untrusted URLs.

## T1/T2 evidence audit after the M3 request-path pass

The M5-T1 suite has six passing cases, including an actual `Http_app.serve`
upgrade with same-origin 101, cross-origin 404, and ordinary HTTP on the same
socket listener. It checks compression, fragmentation, masking, close codes,
UTF-8, and a header-time 1 MiB limit. The M5-T2 suite has seven passing cases,
including the live two-client HTTP/Cable flow with fixture sessions. HTTP
message creation delivers the same append frame to both subscribers; the
other member gets an unread frame. HTTP membership removal sends
`remote/reconnect:true`, rejects renewed room subscription, and HTTP ban sends
`remote/reconnect:false` and rejects reconnection. The in-process suite also
checks signed STI room streams, typing, presence, 64 subscriptions, bounded
slow-consumer close, and rollback-safe after-commit revocation. See
[transport](m5-transport.md), [channel handoff](m5-t2-handoff.md), and
[request-path integration](m3-cable-integration.md).

The pinned Cable golden has 26 scripted steps across five sessions; an
independent manager replay passed all 26 byte for byte on the same live
listener using a disposable seed copy and the pinned test-only secret.
`m5_t1_test.exe` passed 7/7 and `m5_ring_test.exe` passed 3/3. The production
hub now keeps one 256-entry ring per broadcasting with independent subscriber
cursors, detects lag at entry 257, and drains at most 64 frames into one socket
write. These match the Rust `crates/cable` limits and frame order. M5-T1 is
verified. An independent manager replay of the pinned 47-step application
channel golden passed on the same live listener with fixture rows and signed
test cookies. It compares every text and close frame byte for byte, sorting
frames within each step as the Rust replay driver does. The channel suite
passed 7/7, and the live HTTP-to-two-socket request test passed. Membership
revocation and deactivation are delivered after commit. M5-T2 is verified.
Sidebar creation/replacement HTML lies outside this golden and remains an M4
view parity dependency for the full milestone.

## Next ticket implementation seams

M5-T3 can own new `lib/jobs.ml`, `lib/web_push.ml`,
`lib/web_push_crypto.ml`, and `lib/web_push_vapid.ml` plus focused tests. Use
installed `mirage-crypto-ec` P-256, `mirage-crypto` AES-GCM/SHA-256, and
`mirage-crypto-rng.unix` for RFC 8291/8188 and VAPID; inject an outbound HTTP
sender until M5-T4's guarded transport exists. Keep job queues independent and
bounded, with a thread-safe event sink for M2 after-commit callbacks. Compose
that sink with `Cable_channels.event_sink`; `PurgeBlob` delegates disk cleanup
to M6, and message notification content depends on M4 rich text.

M5-T4 can own new `lib/network_guard.ml`, `lib/outbound_http.ml`,
`lib/webhook.ml`, and `lib/opengraph.ml` plus pinned integration fixtures. Use
installed `uri`/`ipaddr` for parsing and classification, M4's HTML parser for
OpenGraph extraction, and installed system `libcurl` through a narrow binding
for pinned IP connections with TLS hostname verification. Disable curl's
automatic redirects: resolve, classify, and pin every hop separately. Bound
connect/read/whole-call time, decompressed response bytes, and concurrent
unfurls before passing replies to M3/M6 call sites. The `libcurl` OCaml binding
is not installed here, so T4 should first check whether its source can be
vendored cleanly; otherwise use the narrow C API wrapper rather than custom
HTTP/TLS code.

## T3 evidence audit

M5-T3 delivered `Jobs`, `Web_push`, `Web_push_crypto`, and `Web_push_vapid`.
Eight focused cases pass, and the suite passed 20 repeated runs after a
condition-variable wakeup race was fixed. The tests cover independent job
queues and failure isolation, RFC 8291 ciphertext, pinned Rails gem
decryption, VAPID claims/signature and key rejection, payload JSON, delivery
ordering and pool capacity, and invalid-subscription decisions. Details are
in [m5-t3-handoff.md](m5-t3-handoff.md).

The production integration handoff adds `App_jobs.start`, guarded Web Push,
database job handlers, a scoped inline test-notification route, and webhook
enqueue from both regular and bot message-create controllers. The controller
selection matches Rust: every active bot in a direct room, otherwise active
mentioned bots, excluding the creator. `Hooks.deliver_webhook_later` schedules
the job after commit. An independent run of `m5_t3_test.exe` and
`m5_t3_integration_test.exe` passed 8/8 each. The seeded suite covers rollback
versus committed PurgeBlob file-and-row deletion, push order and scoped route
responses, HTTP message to bot text and text/plain attachment persistence and
Cable broadcast, banned-content removal, and sanitizer failure without raw
reply persistence. This provides M6's purge-worker evidence.

M7-T2 changed `Jobs.shutdown` to wait for quiescence before stopping workers.
Its deterministic follow-on PurgeBlob and Lwt-dependent worker drain tests
passed 4/4 with the rest of its operations suite. `bin/main.ml` pumps Lwt
while draining jobs. `App_jobs.webhook_delivery` now marshals its Cohttp
delivery to that Lwt loop, and a seeded HTTP-message job to disposable local
webhook test passed exact raw header order, payload, and reply persistence
(`CAMPFIRE_LIVE_JOB_WIRE_TEST=1`, 9/9 seeded integration cases). The later T4
integrated test covers a real shared HTTP/Cable listener, the non-direct
mentioned-bot request path, and bot attachment broadcast. File-link HTML now
matches the pinned Rust spacing and escaping byte for byte. Live guarded Web
Push delivery now has a controlled TLS test using the production request
construction and libcurl transfer with a test-only socket/CA remap.

The manager independently reran the T3 core 8/8 and seeded integration 12/12.
The four controlled TLS cases verify a decrypted encrypted payload, dynamic
ES256 VAPID signature and claims, original Host and TLS name, 410 deletion,
deadline 500 without deletion, and one real HTTP/Cable listener whose message
also triggers a push job. The default outbound adapter rejects a private pin;
the test remaps only the socket address, port, CA, and a shortened deadline
after `web_push_exchange` builds the production request. This is sufficient
local evidence for T3; literal delivery to a public push provider was not
performed. T3 is accepted.

After T3 acceptance, the manager reran the pinned live Cable 26-step and
application-channel 47-step golden suites; both passed. Along with T4's
guarded transport and integration suites, the M5 local milestone gate passes.

## T4 evidence audit

M5-T4 delivered `Network_guard`, `Outbound_http`, `Webhook`, and `Opengraph`
with a narrow libcurl binding for guarded OpenGraph and Web Push and an
ordered Cohttp/Conduit transport for webhooks. Its 13 focused tests pass,
including an exact live raw webhook request, all 90
pinned OpenGraph oracle cases and 19 webhook oracle cases. The live tests
exercise pinned-address HTTP, original-host TLS verification with a fixture
CA, decoded gzip size, read idle timeout, and whole-call deadline. See
[m5-t4-handoff.md](m5-t4-handoff.md) for exact evidence and limitations.

The Rust webhook test in `integrations/webhook.rs` asserts ordered raw headers
against `webhook_expected.json`. The webhook-only Cohttp sender and the
production job bridge match that order; the seeded job-to-local-wire test
proves the production path. Startup registers the guarded OpenGraph controller
and Web Push outbound pool. I independently reran the 90 seeded
`/unfurl_link` route cases, including empty 204 bodies, the exact file-link
HTML differential, 3 seeded integration cases, and all 13 transport cases.
The shared-listener case follows HTTP message creation through the job webhook
request, reply persistence, and Cable broadcast. The C inflater resets between
gzip members; a regression passes concatenated members split at every byte,
the decoded-size cap across members, and truncated-member rejection. T4 is
accepted. The 90 route cases use `Http_app.handle` with injected transport;
guarded real HTTP/TLS behavior is exercised by focused loopback tests.

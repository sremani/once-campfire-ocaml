# M5-T3 jobs and Web Push handoff

Implemented `lib/jobs.ml`, `lib/web_push.ml`, `lib/web_push_crypto.ml`, and
`lib/web_push_vapid.ml`. The pinned Rails gem fixture lives at
`test/fixtures/web_push_expected.json`; `test/m5_t3_test.ml` has eight focused
cases. Run with `dune exec test/m5_t3_test.exe` (or another Dune build directory
if the shared `_build` is locked). The eight cases passed on 20 repeated runs.

`Jobs.create` provides independent 1024-slot queues by kind with configurable
workers, failure isolation, no retries, nonblocking `Jobs.event_sink` enqueue,
and `Jobs.shutdown ~deadline` drain. `DisconnectUser` is synchronous through
`Jobs.compose_sinks cable jobs`; `PurgeBlob` has an explicit callback for M6.

`Web_push_crypto.encrypt_with` matches the RFC 8291 ciphertext exactly;
`decrypt` reads the pinned Rails gem ciphertext. `Web_push_vapid` rejects invalid
and mismatched keys and emits a verified ES256 signature with the pinned JWT
claims. `Web_push` matches the Rails payload JSON, delivers subscriptions in ID
order, limits running/waiting work to 50/10,000 by default, and invalidates only
404/410 or a malformed client P-256 point. Its outbound HTTP function is injected
and receives a pinned IP, ordered headers, and connect/read/whole-call deadlines.
Production startup attaches the guarded M5-T4 libcurl transport.

The pool tests exposed a wakeup race: delivery and invalidation workers share a
condition variable, so signalling one worker could wake the invalidator and
strand a queued delivery. Enqueue now broadcasts. The 20 repeated runs include
this regression case.

## Production integration update

`lib/app_jobs.ml` now starts the five job queues and guarded Web Push pool,
registers database-backed push, webhook, banned-content, and blob-purge
handlers, and composes the cable disconnect sink. `bin/main.ml` starts and
drains it around `Http_app.serve`. `lib/config.ml` reads and validates the VAPID
key pair, defaults the subject from the first TLS domain, and disables push
when keys are absent or invalid. `lib/controller_accounts.ml` now handles the
scoped test-notification route inline, returning 302 on delivery and 500 for
disabled or failed delivery.

`lib/controller_rooms.ml` now selects active direct-room bots or mentioned
active bots after a message is created, then calls
`Db_remaining.Hooks.deliver_webhook_later` in a write transaction. The hook
emits the job only after commit. The relevant call sites are
`deliver_webhooks_to_bots`, `message_create`, and `bot_create`.

The seeded `test/m5_t3_integration_test.ml` cases pass for VAPID startup,
PurgeBlob rollback/commit and disk deletion, banned-content deletion and cable
removal, scoped inline test delivery including encrypted Rails payload, seeded
message push ordering, HTTP-to-bot text reply persistence and broadcast, and
oversized webhook reply failure without raw persistence. The bot attachment
case passes for file persistence, analyzed metadata, and Cable broadcast after
M6-T3 corrected media MIME routing and EINTR handling. All eight seeded cases
and the original eight crypto/queue cases pass with the isolated `_build_m5t3`
build directory.

## Controlled live transport and listener gate

Run `CAMPFIRE_LIVE_PUSH_TLS_TEST=1 dune exec test/m5_t3_integration_test.exe`
in an environment that permits loopback sockets. The four added cases passed:
an HTTP test-notification request reached a disposable TLS push endpoint with
the original `fcm.googleapis.com` Host, a valid test certificate, VAPID audience,
subject, expiration, public key and verified ES256 signature, and an encrypted payload decrypted with the
test subscription key; a 410 response to an HTTP message deleted only that
subscription while Cable still broadcast the source message; a stalled TLS
response hit a shortened absolute deadline, returned 500, and retained its
subscription; and one live HTTP listener served `/cable` WebSocket traffic and
an HTTP message that triggered a push job. All 12 seeded cases, the eight core
crypto/queue cases, and an isolated `@all` build pass.

The production Web Push guard correctly rejects 127.0.0.1, so the controlled
TLS test injects an outbound function into `App_jobs.start`. It uses the same
`Outbound_http.web_push_exchange` request construction and
`Outbound_http.perform` libcurl transfer as the default adapter, but replaces
the socket IP with 127.0.0.1, appends the ephemeral listener port to the URL,
and supplies the generated test certificate as the CA bundle. The timeout case
also shortens the absolute deadline to 150 ms. The Web Push layer still sees a
public pinned IP and the original allowed endpoint host; the test separately
checks that `Outbound_http.web_push_outbound` rejects private pins. This is
deterministic transport evidence, not a literal default-adapter delivery to a
public push service. M5-T4 separately verifies that libcurl rejects a
certificate for the wrong original URL hostname.

The M5 manager independently reran the core 8/8 and controlled TLS seeded
integration 12/12, and accepted T3. The M5/M4 exact bot file-link HTML
differential now matches the pinned Rust bytes. Literal default-adapter
delivery to a public push provider remains outside local test evidence.

## M8 positive-write subscription correction

The clean M8-T2 bot-message differential found that OCaml deleted David's
Firefox subscription 782661004 while Rust retained it. Its seeded P-256 key is
noncanonical Base64: the final `...FZgc` decodes to bytes whose canonical
encoding ends `...FZgQ`. Pinned Rust rejects this in strict Base64 decoding as
an `ArgumentError`, which does not invalidate a subscription. The previous
OCaml decoder accepted those trailing bits, then classified the resulting
invalid curve point as a subscription fault and deleted the row.

`Web_push_crypto.decode64` now checks canonical encoding after accepting either
standard or URL-safe alphabet, with optional complete padding. The new focused
test checks canonical controls, malformed padding/trailing bits, and the exact
seeded key's noninvalidating error class. A seeded pool test proves that
subscription 782661004 is retained and never sent or invalidated. All nine
core tests, nine seeded integration tests, and `dune build @check` pass. An
offline scan of all five default-seed subscriptions found only 782661004 has a
noncanonical key; the other keys' classification is unchanged. M8-T2 will
rerun the live positive-write case after its current Docker interval.

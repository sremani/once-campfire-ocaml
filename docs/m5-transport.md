# M5-T1 Cable transport audit

`vendor/cable_websocket` is pinned to `vbmithr/ocaml-websocket` commit
`133eda58386c43b95fed21ba1921cbc37b629b98` (ISC; license copied). The
small fork adapts current Cohttp and Mirage Crypto APIs, validates frame flags
and masking before payload reads, enforces the 1 MiB limit before allocation
including the bytes already held in fragments, and flushes protocol-error
close frames. `Cable_transport` supplies the Action Cable origin, handshake,
subprotocol and permessage-deflate policy plus framed Lwt input/output.

`Http_app.serve` routes `/cable` through `Cable_transport.handle` when a
`cable_run` handler is supplied. The handler receives both the original
`Cohttp.Request.t` and the upgraded connection. Ordinary HTTP is served by
the existing dispatcher on the same listener; an unconfigured `/cable` is 404.

Evidence:

- `dune exec test/m5_t1_test.exe`: seven test cases pass. They check RFC accept,
  origin and version rejection, protocol order, deflate negotiation, masked
  fragmentation with interleaved Ping/Pong, close replies, UTF-8, compressed
  input/output, malformed frames, header-time size limits, and a 64-frame
  ordered socket-write batch.
- `CAMPFIRE_LIVE_CABLE_TEST=1 dune exec test/m5_t1_test.exe -- test frames 4`
  passes with local-socket access. The test uses `Http_app.serve` and checks a
  101 plus welcome text, the request cookie delivered to `cable_run`, a
  cross-origin 404, an ordinary HTTP 200, and an unconfigured Cable 404.
  The cookie is a dummy value, not a session credential.
- `CAMPFIRE_LIVE_CABLE_GOLDEN=1 dune exec test/m5_golden_replay_test.exe`
  passes all 26 scripted steps in the pinned Cable golden JSON byte for byte
  on one live listener. It uses a disposable copy of the Rails default seed,
  the pinned test-only secret, and the real signed-cookie and stream verifiers.
- `dune exec test/m5_ring_test.exe` passes three direct ring tests: exactly 256
  unread frames per broadcasting, overflow at 257, independent streams and
  subscriber cursors, cross-stream frame order, 64-frame drains, and cleanup
  after unsubscribe.
- `CAMPFIRE_LIVE_CABLE_TEST=1 dune exec test/m5_t2_test.exe` passes 7/7,
  including live HTTP-to-two-WebSocket broadcast and revocation.

`Cable_channels` now drains the shared per-stream ring in batches of at most
64 through `Cable_transport.send_texts`, which builds one buffer and makes
one `Lwt_io.write` before flushing. `send_texts` rejects larger batches.
The old per-connection queue and its fabricated test path have been removed;
the job integration tests subscribe to the production hub. The authenticated
welcome/disconnect decision, heartbeat, subscription policy, and HTTP event
integration remain owned by M5-T2.

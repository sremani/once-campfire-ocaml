# M7-T1 front server handoff

The front uses packaged Caddy 2.6.2 for HTTP/1.1, HTTP/2, TLS, and ACME.
`campfire-front config` emits a Caddyfile; `campfire-front run` writes it under
`STORAGE_PATH/caddy/Caddyfile`, imports valid legacy certificates, then executes
`caddy run`. The OCaml app continues to own public caching and gzip, so the
Caddyfile has no encode or cache handler. The image contains Debian Caddy
`2.6.2-12+deb13u1` and OpenSSL for certificate import. Local protocol tests
also used the Ubuntu `2.6.2-6ubuntu0.24.04.3` binary.

`Front_config.from_env` applies Rust's `THRUSTER_` precedence and defaults.
The OCaml target binds `127.0.0.1:3000` by default, or `TARGET_BIND:TARGET_PORT`.
The front overwrites incoming `X-Forwarded-*` in TLS mode, and `Front_proxy`
accepts its marker only from a loopback peer. The app uses the original Host
including nonstandard port for origin checks and computes scheme and remote IP
per request. A positive `MAX_REQUEST_BODY` reaches the OCaml parser, which
returns an empty 413 for declared and chunked oversized requests. Caddy 2.6's
`request_body max_size` was unsuitable: a live oversized proxied POST returned
502, so it is deliberately absent. Caddy enforces front read, write, and idle
timeouts. `Front_target` now uses Cohttp's HTTP parser, body reader, and response
writer over a timed Conduit connection: 64 KiB and 256-line header bounds, a
header deadline, a per-read body deadline, a per-write deadline, and a separate
keepalive idle deadline. Expert WebSocket streams have no HTTP lifetime deadline.
Using Conduit's absolute `Server.create ?timeout` would close active uploads and
upgraded connections, so it is not used.

## Live evidence

Tests used a disposable copy of the pinned Rails default seed, ports
18300/18380/18343, the Ubuntu Caddy 2.6.2 binary, curl 8.5.0, OpenSSL, and
Pebble 2.4.0. All connections were loopback. The front's eight focused OCaml
tests pass, and `dune build bin/main.exe bin/front.exe` succeeds.

| Check | Observation |
| --- | --- |
| Target bind | `ss -ltn '( sport = :18300 )'` showed `127.0.0.1:18300`; direct `curl http://127.0.0.1:18300/up` returned 200. |
| HTTP redirect and Host | `curl -i -H 'Host: chat.example.com' http://127.0.0.1:18380/hello?x=1` returned 301 with `Location: https://chat.example.com/hello?x=1`; an unknown Host returned 421. |
| TLS and HTTP/2 | `curl -k --http2 --resolve chat.example.com:18343:127.0.0.1 https://chat.example.com:18343/up` returned HTTP/2 200 from the OCaml app. HTTP/1.1 also passed. |
| h2c | With `THRUSTER_H2C_ENABLED=1`, `curl --http2-prior-knowledge http://127.0.0.1:18381/up` returned HTTP/2 200. |
| Proxy spoofing | A request carrying `X-Forwarded-For: 198.51.100.8` and `X-Forwarded-Proto: http` reached the target with actual peer `127.0.0.1`, proto `https`, and the configured Host. Focused OCaml tests also cover opt-in `FORWARD_HEADERS=1`. |
| Body limit | With `MAX_REQUEST_BODY=32`, declared and chunked 36-byte POSTs through Caddy returned HTTP 413 with empty bodies. |
| WebSocket upgrade | A raw TLS GET `/cable` with `Upgrade: websocket`, valid key, subprotocol, and `Origin: https://eab.example.com:18343` returned HTTP 101 with `Sec-WebSocket-Accept` and `actioncable-v1-json`. |
| Long WebSocket | `CAMPFIRE_LIVE_M7_T1=1 CAMPFIRE_CADDY_BIN=/tmp/campfire-caddy/usr/bin/caddy dune exec test/m7_t1_test.exe` exchanged `welcome`, then `ping`/`pong` after 2.2 seconds through both the direct target and Caddy front with read, write, and idle HTTP timeouts set to one second. |
| Direct target bounds | `scripts/m7_resilience_check.py` cases `direct-read-timeout`, `direct-idle-timeout`, and `direct-body-timeout` closed stalled header, keepalive, and body connections after their one-second limits; `direct-header-limit` rejected 65 KiB headers. `direct-active-upload` streamed >1 MiB for >1.75 seconds successfully because each read made progress. `graceful-early` completed an active request during SIGTERM; `graceful-deadline` ended a stalled request at the 10-second shutdown grace. |
| ACME TLS-ALPN-01 | Caddy obtained `chat.example.com` from local Pebble at `https://127.0.0.1:14000/dir`; logs recorded `tls-alpn-01` validation and successful certificate issuance. |
| ACME EAB and HTTP-01 | Pebble required the public sample EAB fixture from its packaged `pebble-config-external-account-bindings.json`. With TLS-ALPN validation unavailable, Caddy logs recorded `http-01` validation and issuance for `eab.example.com`; HTTPS `/up` returned HTTP/2 200. |
| ACME renewal | `python3 scripts/m7_acme_renewal_check.py` obtained a certificate from disposable Pebble, then replaced the cached leaf with a five-minute certificate signed by that same disposable CA and matching the original private key. On restart, Caddy served a new leaf; the cache fingerprint matched it and Pebble logged a second issuance. This exercises near-expiry detection, account reuse, and a new ACME order. |
| Thruster certificate import | A combined private-key-and-chain PEM at `STORAGE_PATH/chat.example.com` was imported with `campfire-front migrate`; a second run imported zero. Caddy restarted with the imported cert and served the same SHA256 leaf fingerprint `1E:90:44:2E:AC:CB:BF:69:01:ED:DE:BF:42:73:47:94:09:F7:80:82:FF:2C:69:3E:E6:00:A0:D0:29:46:01:46`, without a new ACME order. |

## Remaining acceptance checks

- Pebble's ordinary ACME issuance used a five-year leaf. The renewal test
  shortened a cached certificate using the same disposable Pebble CA; natural
  expiry of a CA-issued short-lived leaf was unavailable with this Pebble build.
  The importer retains the old `acme_account+key` untouched, while Caddy creates
  its own ACME account. Its first subsequent renewal uses the new account.
- A real prior Thruster storage directory was unavailable in the pinned seed.
  The import test used a Pebble-issued key and chain assembled in Thruster's
  documented combined PEM layout. An old-image upgrade must verify a genuine
  production-format cache on copied storage.
- Front settings that configure Rust's extra gzip
  layer have no separate effect because `Http_gzip` already encodes responses;
  compare gzip vectors during the final HTTP differential gate.

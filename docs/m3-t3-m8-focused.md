# M3-T3 focused default-seed HTTP differential, 2026-10-09

This is a controller follow-up to the immutable 708-case report in
`docs/m8-t2-http-state.md`. It uses the same pinned Rust candidate, shared
verification script, fixture credentials, frozen clock, independently copied
default seeds, exact header/body comparison, and SQLite state hashes. The live
servers occupied only localhost ports 3260 and 3262, with a disposable Caddy
proxy to the OCaml app on port 3261. The separate Rust, OCaml, Caddy, and network
containers were stopped after the run.

Four sanitized reports contain the focused results:

| Report | Selected cases | Result | OCaml binary SHA-256 |
| --- | ---: | ---: | --- |
| `/tmp/m3-t3-focused-bot.json` | 56 | 47 pass, 9 bot MIME fail | `2b60778b632c679b1784a8d66ffcd96e4c49db86758a7f0c1b1a3ceefd081f03` |
| `/tmp/m3-t3-focused-bot-v2.json` | 12 | 12 pass | `1f6c5d2922a9b9afacef2d670085dd022c2cc61b0ac8d62e0b68b64f7377c216` |
| `/tmp/m3-t3-focused-404.json` | 56 | 51 pass, 5 fail | same v2 binary |
| `/tmp/m3-t3-focused-param.json` | 7 signed | 7 pass | `d03a45130a4ab7c6c519e324a5a348875771f3cb89c8ea000c73e096c27af592` |

The scoped runs newly close **56 role-cases** that failed in the 579/708 default
matrix. Rows and roles: 76 signed; 78–79 signed/denied; 80–82 signed;
83–84 anonymous/signed/bot; 85 all four roles; 86–89 anonymous/signed/bot;
104 signed/denied; 105 signed; 109–110 signed; 112 signed/denied;
113 signed; 117–118 signed; 120 signed/denied; 123 signed/denied;
127 signed; 129 signed; 135 signed; 136 signed/denied;
139–140 signed/denied; 141–143 signed.

The controller changes are limited to its own module. Missing room/message
records now use the pinned Rust PublicExceptions body and headers, including
the 34-byte JSON 404 on bot update/delete and the empty public 400 on missing
room, message, and boost parameters. Bot `head` responses use bare `text/html`
for the relevant before-action and validation paths, and 204 omits Content-Type.
Room scope redirects persist the exact alert flash in the encrypted session
cookie. Bot index and update JSON use M4's `Views.message_json` serializer and
`View_presenter` so body bytes, Content-Length, and ETag agree for row 85.

Four sampled role-cases remain in this follow-up: row 128 signed/denied and
row 130 signed/denied. They return 200 on both implementations, with different
boost page bodies and derived Content-Length/ETag/Link headers. M4 owns the
boost index/new HTML renderers. The old whole-route report remains immutable;
M8 must rerun the full matrix on one final binary before treating these focused
closures as the new whole-route count.

`dune exec test/m3_t3_test.exe` passes **7/7** after the controller changes,
including a new seed-backed exception-response case. `dune build bin/main.exe`
also passes. M3-T3 remains open for the full route and positive-write gates.

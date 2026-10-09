# M8-T2 live Rust/OCaml HTTP and state differential: default, ordinary

Pinned Rust `9872c1d9541551c0889a60e3d49a14488bd1e403` and shared verification `6f71d70b5e1f17507404ad06cac134aa453a04a6`. Each server uses its own Rails seed copy.
OCaml candidate `/tmp/m8-t2-main-checkpoint-7bd8a496.exe` SHA-256 `e4917ea03168aa25ac42afcad711de14c8ee58c4a15c26c8e2642692b59a3fe8`.
Clean OCaml checkpoint `7bd8a4964603e3de3800c1edf45674be08dd3a9f`; source-file hash manifest `docs/m8-t2-checkpoint-7bd8a496-source-files.sha256` (89 files, manifest SHA-256 `92ba118b6002cd93f85cabb79083b040253e0e25bab2f08e972f29e2a3a0d489`). Shared verification checkout `/tmp/m3-t3-verification-pinned` was at the pinned revision above.
Response comparison includes exact status, every returned header value, and every body byte. Only valid current Date, six-decimal X-Runtime, and authenticated equivalent AES-GCM session-cookie plaintext are normalized because each server generates independent time/IV values; header presence and cookie attributes are compared. For transfer, deactivation, and join-code writes, only independently generated base58/UUIDv4/alphanumeric fields are canonicalized after shape, uniqueness, row identity/count, every other column, and signed-cookie HMAC/payload linkage checks. SQLite comparison hashes every table before and after each request. No deterministic values are masked in comparison; credentials and signed URLs are omitted from this report.

Cases: pass **674**, fail **34**, not-run **0**. Case isolation: **fresh seed per case**. Scenario: **ordinary**. Shared contracts, Cable, and media remain separate gates.

Exact command (pinned test fixture credentials only):

```sh
python3 scripts/m8_t2_http_state.py --seed default --rust-port 3228 --ocaml-port 3230 --ocaml-target-port 3229 --rust-db ../once-campfire-rust/parity/.seed/.candidates/3228/db/production.sqlite3 --ocaml-db /tmp/campfire-m8-t2-isolated-default-1000/db/production.sqlite3 --ocaml-seed-dir /tmp/campfire-m8-t2-isolated-default-1000 --ocaml-container campfire-m8-t2-default-ocaml --ocaml-network container:campfire-m8-t2-network --ocaml-binary /tmp/m8-t2-main-checkpoint-7bd8a496.exe --verification-checkout /tmp/m3-t3-verification-pinned --output docs/m8-t2-http-state.md --isolate
```

Against the preserved 661-pass report (`/tmp/m8-t2-default-661.json`), **13 failed cases became passes** on rows 28, 49, 74, 92, 128, 130, and 137; there were no regressions. The 34 remaining failures are signed/denied pairs on exactly 17 rows: 30, 31, 39, 43, 56, 59, 65, 73, 75, 95, 100, 106, 107, 114, 115, 122, and 145. Every failure is a body-byte difference with derived `Content-Length` and `ETag` differences. Status, other headers, and SQLite state match for all 708 cases. All 160 action-not-found and four missing-controller role cells pass.

Pending M8-T2 gates: remaining view bytes; positive CSRF-aware writes across implemented mutating families; default-seed override and malformed-path matrices; ordinary crowd, custom-styles, restricted, and first-run seed matrices; and final-image shared contract/acknowledged-write replay. This default ordinary matrix does not close M8-T2.

## Class and role matrix

| Rust action | Role | Pass | Fail | Not-run |
| --- | --- | ---: | ---: | ---: |
| implemented | anonymous | 136 | 0 | 0 |
| implemented | signed | 119 | 17 | 0 |
| implemented | denied | 119 | 17 | 0 |
| implemented | bot | 136 | 0 | 0 |
| action_not_found | anonymous | 40 | 0 | 0 |
| action_not_found | signed | 40 | 0 | 0 |
| action_not_found | denied | 40 | 0 | 0 |
| action_not_found | bot | 40 | 0 | 0 |
| missing_controller | anonymous | 1 | 0 | 0 |
| missing_controller | signed | 1 | 0 | 0 |
| missing_controller | denied | 1 | 0 | 0 |
| missing_controller | bot | 1 | 0 | 0 |

## Route rows

| Row | Verb | Route pattern | Rust action | Pass | Fail | Not-run |
| ---: | --- | --- | --- | ---: | ---: | ---: |
| 0 | GET | `/` | implemented | 4 | 0 | 0 |
| 1 | GET | `/first_run/new(.:format)` | action_not_found | 4 | 0 | 0 |
| 2 | GET | `/first_run/edit(.:format)` | action_not_found | 4 | 0 | 0 |
| 3 | GET | `/first_run(.:format)` | implemented | 4 | 0 | 0 |
| 4 | PATCH | `/first_run(.:format)` | action_not_found | 4 | 0 | 0 |
| 5 | PUT | `/first_run(.:format)` | action_not_found | 4 | 0 | 0 |
| 6 | DELETE | `/first_run(.:format)` | action_not_found | 4 | 0 | 0 |
| 7 | POST | `/first_run(.:format)` | implemented | 4 | 0 | 0 |
| 8 | GET | `/session/transfers/:id(.:format)` | implemented | 4 | 0 | 0 |
| 9 | PATCH | `/session/transfers/:id(.:format)` | implemented | 4 | 0 | 0 |
| 10 | PUT | `/session/transfers/:id(.:format)` | implemented | 4 | 0 | 0 |
| 11 | GET | `/session/new(.:format)` | implemented | 4 | 0 | 0 |
| 12 | GET | `/session/edit(.:format)` | action_not_found | 4 | 0 | 0 |
| 13 | GET | `/session(.:format)` | action_not_found | 4 | 0 | 0 |
| 14 | PATCH | `/session(.:format)` | action_not_found | 4 | 0 | 0 |
| 15 | PUT | `/session(.:format)` | action_not_found | 4 | 0 | 0 |
| 16 | DELETE | `/session(.:format)` | implemented | 4 | 0 | 0 |
| 17 | POST | `/session(.:format)` | implemented | 4 | 0 | 0 |
| 18 | GET | `/account/users(.:format)` | implemented | 4 | 0 | 0 |
| 19 | POST | `/account/users(.:format)` | action_not_found | 4 | 0 | 0 |
| 20 | GET | `/account/users/new(.:format)` | action_not_found | 4 | 0 | 0 |
| 21 | GET | `/account/users/:id/edit(.:format)` | action_not_found | 4 | 0 | 0 |
| 22 | GET | `/account/users/:id(.:format)` | action_not_found | 4 | 0 | 0 |
| 23 | PATCH | `/account/users/:id(.:format)` | implemented | 4 | 0 | 0 |
| 24 | PUT | `/account/users/:id(.:format)` | implemented | 4 | 0 | 0 |
| 25 | DELETE | `/account/users/:id(.:format)` | implemented | 4 | 0 | 0 |
| 26 | PATCH | `/account/bots/:bot_id/key(.:format)` | implemented | 4 | 0 | 0 |
| 27 | PUT | `/account/bots/:bot_id/key(.:format)` | implemented | 4 | 0 | 0 |
| 28 | GET | `/account/bots(.:format)` | implemented | 4 | 0 | 0 |
| 29 | POST | `/account/bots(.:format)` | implemented | 4 | 0 | 0 |
| 30 | GET | `/account/bots/new(.:format)` | implemented | 2 | 2 | 0 |
| 31 | GET | `/account/bots/:id/edit(.:format)` | implemented | 2 | 2 | 0 |
| 32 | GET | `/account/bots/:id(.:format)` | action_not_found | 4 | 0 | 0 |
| 33 | PATCH | `/account/bots/:id(.:format)` | implemented | 4 | 0 | 0 |
| 34 | PUT | `/account/bots/:id(.:format)` | implemented | 4 | 0 | 0 |
| 35 | DELETE | `/account/bots/:id(.:format)` | implemented | 4 | 0 | 0 |
| 36 | POST | `/account/join_code(.:format)` | implemented | 4 | 0 | 0 |
| 37 | GET | `/account/logo(.:format)` | implemented | 4 | 0 | 0 |
| 38 | DELETE | `/account/logo(.:format)` | implemented | 4 | 0 | 0 |
| 39 | GET | `/account/custom_styles/edit(.:format)` | implemented | 2 | 2 | 0 |
| 40 | PATCH | `/account/custom_styles(.:format)` | implemented | 4 | 0 | 0 |
| 41 | PUT | `/account/custom_styles(.:format)` | implemented | 4 | 0 | 0 |
| 42 | GET | `/account/new(.:format)` | action_not_found | 4 | 0 | 0 |
| 43 | GET | `/account/edit(.:format)` | implemented | 2 | 2 | 0 |
| 44 | GET | `/account(.:format)` | action_not_found | 4 | 0 | 0 |
| 45 | PATCH | `/account(.:format)` | implemented | 4 | 0 | 0 |
| 46 | PUT | `/account(.:format)` | implemented | 4 | 0 | 0 |
| 47 | DELETE | `/account(.:format)` | action_not_found | 4 | 0 | 0 |
| 48 | POST | `/account(.:format)` | action_not_found | 4 | 0 | 0 |
| 49 | GET | `/join/:join_code(.:format)` | implemented | 4 | 0 | 0 |
| 50 | POST | `/join/:join_code(.:format)` | implemented | 4 | 0 | 0 |
| 51 | GET | `/qr_code/:id(.:format)` | implemented | 4 | 0 | 0 |
| 52 | GET | `/users/:user_id/avatar(.:format)` | implemented | 4 | 0 | 0 |
| 53 | DELETE | `/users/:user_id/avatar(.:format)` | implemented | 4 | 0 | 0 |
| 54 | DELETE | `/users/:user_id/ban(.:format)` | implemented | 4 | 0 | 0 |
| 55 | POST | `/users/:user_id/ban(.:format)` | implemented | 4 | 0 | 0 |
| 56 | GET | `/users/:user_id/sidebar(.:format)` | implemented | 2 | 2 | 0 |
| 57 | GET | `/users/:user_id/profile/new(.:format)` | action_not_found | 4 | 0 | 0 |
| 58 | GET | `/users/:user_id/profile/edit(.:format)` | action_not_found | 4 | 0 | 0 |
| 59 | GET | `/users/:user_id/profile(.:format)` | implemented | 2 | 2 | 0 |
| 60 | PATCH | `/users/:user_id/profile(.:format)` | implemented | 4 | 0 | 0 |
| 61 | PUT | `/users/:user_id/profile(.:format)` | implemented | 4 | 0 | 0 |
| 62 | DELETE | `/users/:user_id/profile(.:format)` | action_not_found | 4 | 0 | 0 |
| 63 | POST | `/users/:user_id/profile(.:format)` | action_not_found | 4 | 0 | 0 |
| 64 | POST | `/users/:user_id/push_subscriptions/:push_subscription_id/test_notifications(.:format)` | implemented | 4 | 0 | 0 |
| 65 | GET | `/users/:user_id/push_subscriptions(.:format)` | implemented | 2 | 2 | 0 |
| 66 | POST | `/users/:user_id/push_subscriptions(.:format)` | implemented | 4 | 0 | 0 |
| 67 | GET | `/users/:user_id/push_subscriptions/new(.:format)` | action_not_found | 4 | 0 | 0 |
| 68 | GET | `/users/:user_id/push_subscriptions/:id/edit(.:format)` | action_not_found | 4 | 0 | 0 |
| 69 | GET | `/users/:user_id/push_subscriptions/:id(.:format)` | action_not_found | 4 | 0 | 0 |
| 70 | PATCH | `/users/:user_id/push_subscriptions/:id(.:format)` | action_not_found | 4 | 0 | 0 |
| 71 | PUT | `/users/:user_id/push_subscriptions/:id(.:format)` | action_not_found | 4 | 0 | 0 |
| 72 | DELETE | `/users/:user_id/push_subscriptions/:id(.:format)` | implemented | 4 | 0 | 0 |
| 73 | GET | `/users/:id(.:format)` | implemented | 2 | 2 | 0 |
| 74 | GET | `/autocompletable/users(.:format)` | implemented | 4 | 0 | 0 |
| 75 | GET | `/rooms/:room_id/messages(.:format)` | implemented | 2 | 2 | 0 |
| 76 | POST | `/rooms/:room_id/messages(.:format)` | implemented | 4 | 0 | 0 |
| 77 | GET | `/rooms/:room_id/messages/new(.:format)` | action_not_found | 4 | 0 | 0 |
| 78 | GET | `/rooms/:room_id/messages/:id/edit(.:format)` | implemented | 4 | 0 | 0 |
| 79 | GET | `/rooms/:room_id/messages/:id(.:format)` | implemented | 4 | 0 | 0 |
| 80 | PATCH | `/rooms/:room_id/messages/:id(.:format)` | implemented | 4 | 0 | 0 |
| 81 | PUT | `/rooms/:room_id/messages/:id(.:format)` | implemented | 4 | 0 | 0 |
| 82 | DELETE | `/rooms/:room_id/messages/:id(.:format)` | implemented | 4 | 0 | 0 |
| 83 | POST | `/rooms/:room_id/:bot_key/messages/:message_id/boosts(.:format)` | implemented | 4 | 0 | 0 |
| 84 | DELETE | `/rooms/:room_id/:bot_key/messages/:message_id/boosts/:id(.:format)` | implemented | 4 | 0 | 0 |
| 85 | GET | `/rooms/:room_id/:bot_key/messages(.:format)` | implemented | 4 | 0 | 0 |
| 86 | POST | `/rooms/:room_id/:bot_key/messages(.:format)` | implemented | 4 | 0 | 0 |
| 87 | PATCH | `/rooms/:room_id/:bot_key/messages/:id(.:format)` | implemented | 4 | 0 | 0 |
| 88 | PUT | `/rooms/:room_id/:bot_key/messages/:id(.:format)` | implemented | 4 | 0 | 0 |
| 89 | DELETE | `/rooms/:room_id/:bot_key/messages/:id(.:format)` | implemented | 4 | 0 | 0 |
| 90 | GET | `/rooms/:room_id/refresh(.:format)` | implemented | 4 | 0 | 0 |
| 91 | GET | `/rooms/:room_id/settings(.:format)` | missing_controller | 4 | 0 | 0 |
| 92 | GET | `/rooms/:room_id/involvement(.:format)` | implemented | 4 | 0 | 0 |
| 93 | PATCH | `/rooms/:room_id/involvement(.:format)` | implemented | 4 | 0 | 0 |
| 94 | PUT | `/rooms/:room_id/involvement(.:format)` | implemented | 4 | 0 | 0 |
| 95 | GET | `/rooms/:room_id/@:message_id(.:format)` | implemented | 2 | 2 | 0 |
| 96 | GET | `/rooms(.:format)` | implemented | 4 | 0 | 0 |
| 97 | POST | `/rooms(.:format)` | action_not_found | 4 | 0 | 0 |
| 98 | GET | `/rooms/new(.:format)` | action_not_found | 4 | 0 | 0 |
| 99 | GET | `/rooms/:id/edit(.:format)` | action_not_found | 4 | 0 | 0 |
| 100 | GET | `/rooms/:id(.:format)` | implemented | 2 | 2 | 0 |
| 101 | PATCH | `/rooms/:id(.:format)` | action_not_found | 4 | 0 | 0 |
| 102 | PUT | `/rooms/:id(.:format)` | action_not_found | 4 | 0 | 0 |
| 103 | DELETE | `/rooms/:id(.:format)` | implemented | 4 | 0 | 0 |
| 104 | GET | `/rooms/opens(.:format)` | implemented | 4 | 0 | 0 |
| 105 | POST | `/rooms/opens(.:format)` | implemented | 4 | 0 | 0 |
| 106 | GET | `/rooms/opens/new(.:format)` | implemented | 2 | 2 | 0 |
| 107 | GET | `/rooms/opens/:id/edit(.:format)` | implemented | 2 | 2 | 0 |
| 108 | GET | `/rooms/opens/:id(.:format)` | implemented | 4 | 0 | 0 |
| 109 | PATCH | `/rooms/opens/:id(.:format)` | implemented | 4 | 0 | 0 |
| 110 | PUT | `/rooms/opens/:id(.:format)` | implemented | 4 | 0 | 0 |
| 111 | DELETE | `/rooms/opens/:id(.:format)` | implemented | 4 | 0 | 0 |
| 112 | GET | `/rooms/closeds(.:format)` | implemented | 4 | 0 | 0 |
| 113 | POST | `/rooms/closeds(.:format)` | implemented | 4 | 0 | 0 |
| 114 | GET | `/rooms/closeds/new(.:format)` | implemented | 2 | 2 | 0 |
| 115 | GET | `/rooms/closeds/:id/edit(.:format)` | implemented | 2 | 2 | 0 |
| 116 | GET | `/rooms/closeds/:id(.:format)` | implemented | 4 | 0 | 0 |
| 117 | PATCH | `/rooms/closeds/:id(.:format)` | implemented | 4 | 0 | 0 |
| 118 | PUT | `/rooms/closeds/:id(.:format)` | implemented | 4 | 0 | 0 |
| 119 | DELETE | `/rooms/closeds/:id(.:format)` | implemented | 4 | 0 | 0 |
| 120 | GET | `/rooms/directs(.:format)` | implemented | 4 | 0 | 0 |
| 121 | POST | `/rooms/directs(.:format)` | implemented | 4 | 0 | 0 |
| 122 | GET | `/rooms/directs/new(.:format)` | implemented | 2 | 2 | 0 |
| 123 | GET | `/rooms/directs/:id/edit(.:format)` | implemented | 4 | 0 | 0 |
| 124 | GET | `/rooms/directs/:id(.:format)` | implemented | 4 | 0 | 0 |
| 125 | PATCH | `/rooms/directs/:id(.:format)` | action_not_found | 4 | 0 | 0 |
| 126 | PUT | `/rooms/directs/:id(.:format)` | action_not_found | 4 | 0 | 0 |
| 127 | DELETE | `/rooms/directs/:id(.:format)` | implemented | 4 | 0 | 0 |
| 128 | GET | `/messages/:message_id/boosts(.:format)` | implemented | 4 | 0 | 0 |
| 129 | POST | `/messages/:message_id/boosts(.:format)` | implemented | 4 | 0 | 0 |
| 130 | GET | `/messages/:message_id/boosts/new(.:format)` | implemented | 4 | 0 | 0 |
| 131 | GET | `/messages/:message_id/boosts/:id/edit(.:format)` | action_not_found | 4 | 0 | 0 |
| 132 | GET | `/messages/:message_id/boosts/:id(.:format)` | action_not_found | 4 | 0 | 0 |
| 133 | PATCH | `/messages/:message_id/boosts/:id(.:format)` | action_not_found | 4 | 0 | 0 |
| 134 | PUT | `/messages/:message_id/boosts/:id(.:format)` | action_not_found | 4 | 0 | 0 |
| 135 | DELETE | `/messages/:message_id/boosts/:id(.:format)` | implemented | 4 | 0 | 0 |
| 136 | GET | `/messages(.:format)` | implemented | 4 | 0 | 0 |
| 137 | POST | `/messages(.:format)` | implemented | 4 | 0 | 0 |
| 138 | GET | `/messages/new(.:format)` | action_not_found | 4 | 0 | 0 |
| 139 | GET | `/messages/:id/edit(.:format)` | implemented | 4 | 0 | 0 |
| 140 | GET | `/messages/:id(.:format)` | implemented | 4 | 0 | 0 |
| 141 | PATCH | `/messages/:id(.:format)` | implemented | 4 | 0 | 0 |
| 142 | PUT | `/messages/:id(.:format)` | implemented | 4 | 0 | 0 |
| 143 | DELETE | `/messages/:id(.:format)` | implemented | 4 | 0 | 0 |
| 144 | DELETE | `/searches/clear(.:format)` | implemented | 4 | 0 | 0 |
| 145 | GET | `/searches(.:format)` | implemented | 2 | 2 | 0 |
| 146 | POST | `/searches(.:format)` | implemented | 4 | 0 | 0 |
| 147 | POST | `/unfurl_link(.:format)` | implemented | 4 | 0 | 0 |
| 148 | GET | `/webmanifest(.:format)` | implemented | 4 | 0 | 0 |
| 149 | GET | `/service-worker(.:format)` | implemented | 4 | 0 | 0 |
| 150 | GET | `/up(.:format)` | implemented | 4 | 0 | 0 |
| 151 | GET | `/recede_historical_location(.:format)` | implemented | 4 | 0 | 0 |
| 152 | GET | `/resume_historical_location(.:format)` | implemented | 4 | 0 | 0 |
| 153 | GET | `/refresh_historical_location(.:format)` | implemented | 4 | 0 | 0 |
| 154 | POST | `/rails/action_mailbox/postmark/inbound_emails(.:format)` | implemented | 4 | 0 | 0 |
| 155 | POST | `/rails/action_mailbox/relay/inbound_emails(.:format)` | implemented | 4 | 0 | 0 |
| 156 | POST | `/rails/action_mailbox/sendgrid/inbound_emails(.:format)` | implemented | 4 | 0 | 0 |
| 157 | GET | `/rails/action_mailbox/mandrill/inbound_emails(.:format)` | implemented | 4 | 0 | 0 |
| 158 | POST | `/rails/action_mailbox/mandrill/inbound_emails(.:format)` | implemented | 4 | 0 | 0 |
| 159 | POST | `/rails/action_mailbox/mailgun/inbound_emails/mime(.:format)` | implemented | 4 | 0 | 0 |
| 160 | GET | `/rails/conductor/action_mailbox/inbound_emails(.:format)` | implemented | 4 | 0 | 0 |
| 161 | POST | `/rails/conductor/action_mailbox/inbound_emails(.:format)` | implemented | 4 | 0 | 0 |
| 162 | GET | `/rails/conductor/action_mailbox/inbound_emails/new(.:format)` | implemented | 4 | 0 | 0 |
| 163 | GET | `/rails/conductor/action_mailbox/inbound_emails/:id(.:format)` | implemented | 4 | 0 | 0 |
| 164 | GET | `/rails/conductor/action_mailbox/inbound_emails/sources/new(.:format)` | implemented | 4 | 0 | 0 |
| 165 | POST | `/rails/conductor/action_mailbox/inbound_emails/sources(.:format)` | implemented | 4 | 0 | 0 |
| 166 | POST | `/rails/conductor/action_mailbox/:inbound_email_id/reroute(.:format)` | implemented | 4 | 0 | 0 |
| 167 | POST | `/rails/conductor/action_mailbox/:inbound_email_id/incinerate(.:format)` | implemented | 4 | 0 | 0 |
| 168 | GET | `/rails/active_storage/blobs/redirect/:signed_id/*filename(.:format)` | implemented | 4 | 0 | 0 |
| 169 | GET | `/rails/active_storage/blobs/proxy/:signed_id/*filename(.:format)` | implemented | 4 | 0 | 0 |
| 170 | GET | `/rails/active_storage/blobs/:signed_id/*filename(.:format)` | implemented | 4 | 0 | 0 |
| 171 | GET | `/rails/active_storage/representations/redirect/:signed_blob_id/:variation_key/*filename(.:format)` | implemented | 4 | 0 | 0 |
| 172 | GET | `/rails/active_storage/representations/proxy/:signed_blob_id/:variation_key/*filename(.:format)` | implemented | 4 | 0 | 0 |
| 173 | GET | `/rails/active_storage/representations/:signed_blob_id/:variation_key/*filename(.:format)` | implemented | 4 | 0 | 0 |
| 174 | GET | `/rails/active_storage/disk/:encoded_key/*filename(.:format)` | implemented | 4 | 0 | 0 |
| 175 | PUT | `/rails/active_storage/disk/:encoded_token(.:format)` | implemented | 4 | 0 | 0 |
| 176 | POST | `/rails/active_storage/direct_uploads(.:format)` | implemented | 4 | 0 | 0 |

## Every case

| Row | Role | Result | Rust HTTP | OCaml HTTP | Difference or not-run reason |
| ---: | --- | --- | ---: | ---: | --- |
| 0 | anonymous | pass | 302 | 302 |  |
| 0 | signed | pass | 302 | 302 |  |
| 0 | denied | pass | 302 | 302 |  |
| 0 | bot | pass | 403 | 403 |  |
| 1 | anonymous | pass | 404 | 404 |  |
| 1 | signed | pass | 404 | 404 |  |
| 1 | denied | pass | 404 | 404 |  |
| 1 | bot | pass | 404 | 404 |  |
| 2 | anonymous | pass | 404 | 404 |  |
| 2 | signed | pass | 404 | 404 |  |
| 2 | denied | pass | 404 | 404 |  |
| 2 | bot | pass | 404 | 404 |  |
| 3 | anonymous | pass | 302 | 302 |  |
| 3 | signed | pass | 302 | 302 |  |
| 3 | denied | pass | 302 | 302 |  |
| 3 | bot | pass | 302 | 302 |  |
| 4 | anonymous | pass | 404 | 404 |  |
| 4 | signed | pass | 404 | 404 |  |
| 4 | denied | pass | 404 | 404 |  |
| 4 | bot | pass | 404 | 404 |  |
| 5 | anonymous | pass | 404 | 404 |  |
| 5 | signed | pass | 404 | 404 |  |
| 5 | denied | pass | 404 | 404 |  |
| 5 | bot | pass | 404 | 404 |  |
| 6 | anonymous | pass | 404 | 404 |  |
| 6 | signed | pass | 404 | 404 |  |
| 6 | denied | pass | 404 | 404 |  |
| 6 | bot | pass | 404 | 404 |  |
| 7 | anonymous | pass | 302 | 302 |  |
| 7 | signed | pass | 302 | 302 |  |
| 7 | denied | pass | 429 | 429 |  |
| 7 | bot | pass | 302 | 302 |  |
| 8 | anonymous | pass | 200 | 200 |  |
| 8 | signed | pass | 200 | 200 |  |
| 8 | denied | pass | 200 | 200 |  |
| 8 | bot | pass | 200 | 200 |  |
| 9 | anonymous | pass | 302 | 302 |  |
| 9 | signed | pass | 302 | 302 |  |
| 9 | denied | pass | 429 | 429 |  |
| 9 | bot | pass | 302 | 302 |  |
| 10 | anonymous | pass | 302 | 302 |  |
| 10 | signed | pass | 302 | 302 |  |
| 10 | denied | pass | 429 | 429 |  |
| 10 | bot | pass | 302 | 302 |  |
| 11 | anonymous | pass | 200 | 200 |  |
| 11 | signed | pass | 200 | 200 |  |
| 11 | denied | pass | 200 | 200 |  |
| 11 | bot | pass | 200 | 200 |  |
| 12 | anonymous | pass | 404 | 404 |  |
| 12 | signed | pass | 404 | 404 |  |
| 12 | denied | pass | 404 | 404 |  |
| 12 | bot | pass | 404 | 404 |  |
| 13 | anonymous | pass | 404 | 404 |  |
| 13 | signed | pass | 404 | 404 |  |
| 13 | denied | pass | 404 | 404 |  |
| 13 | bot | pass | 404 | 404 |  |
| 14 | anonymous | pass | 404 | 404 |  |
| 14 | signed | pass | 404 | 404 |  |
| 14 | denied | pass | 404 | 404 |  |
| 14 | bot | pass | 404 | 404 |  |
| 15 | anonymous | pass | 404 | 404 |  |
| 15 | signed | pass | 404 | 404 |  |
| 15 | denied | pass | 404 | 404 |  |
| 15 | bot | pass | 404 | 404 |  |
| 16 | anonymous | pass | 302 | 302 |  |
| 16 | signed | pass | 302 | 302 |  |
| 16 | denied | pass | 429 | 429 |  |
| 16 | bot | pass | 403 | 403 |  |
| 17 | anonymous | pass | 401 | 401 |  |
| 17 | signed | pass | 401 | 401 |  |
| 17 | denied | pass | 429 | 429 |  |
| 17 | bot | pass | 401 | 401 |  |
| 18 | anonymous | pass | 302 | 302 |  |
| 18 | signed | pass | 406 | 406 |  |
| 18 | denied | pass | 406 | 406 |  |
| 18 | bot | pass | 403 | 403 |  |
| 19 | anonymous | pass | 404 | 404 |  |
| 19 | signed | pass | 404 | 404 |  |
| 19 | denied | pass | 404 | 404 |  |
| 19 | bot | pass | 404 | 404 |  |
| 20 | anonymous | pass | 404 | 404 |  |
| 20 | signed | pass | 404 | 404 |  |
| 20 | denied | pass | 404 | 404 |  |
| 20 | bot | pass | 404 | 404 |  |
| 21 | anonymous | pass | 404 | 404 |  |
| 21 | signed | pass | 404 | 404 |  |
| 21 | denied | pass | 404 | 404 |  |
| 21 | bot | pass | 404 | 404 |  |
| 22 | anonymous | pass | 404 | 404 |  |
| 22 | signed | pass | 404 | 404 |  |
| 22 | denied | pass | 404 | 404 |  |
| 22 | bot | pass | 404 | 404 |  |
| 23 | anonymous | pass | 302 | 302 |  |
| 23 | signed | pass | 400 | 400 |  |
| 23 | denied | pass | 429 | 429 |  |
| 23 | bot | pass | 403 | 403 |  |
| 24 | anonymous | pass | 302 | 302 |  |
| 24 | signed | pass | 400 | 400 |  |
| 24 | denied | pass | 429 | 429 |  |
| 24 | bot | pass | 403 | 403 |  |
| 25 | anonymous | pass | 302 | 302 |  |
| 25 | signed | pass | 302 | 302 |  |
| 25 | denied | pass | 429 | 429 |  |
| 25 | bot | pass | 403 | 403 |  |
| 26 | anonymous | pass | 302 | 302 |  |
| 26 | signed | pass | 404 | 404 |  |
| 26 | denied | pass | 429 | 429 |  |
| 26 | bot | pass | 403 | 403 |  |
| 27 | anonymous | pass | 302 | 302 |  |
| 27 | signed | pass | 404 | 404 |  |
| 27 | denied | pass | 429 | 429 |  |
| 27 | bot | pass | 403 | 403 |  |
| 28 | anonymous | pass | 302 | 302 |  |
| 28 | signed | pass | 200 | 200 |  |
| 28 | denied | pass | 200 | 200 |  |
| 28 | bot | pass | 403 | 403 |  |
| 29 | anonymous | pass | 302 | 302 |  |
| 29 | signed | pass | 400 | 400 |  |
| 29 | denied | pass | 429 | 429 |  |
| 29 | bot | pass | 403 | 403 |  |
| 30 | anonymous | pass | 302 | 302 |  |
| 30 | signed | fail | 200 | 200 | headers content-length,etag; body len=24484/24370 sha256=ebe88701671e/50fe5898cc1b |
| 30 | denied | fail | 200 | 200 | headers content-length,etag; body len=24484/24370 sha256=ebe88701671e/50fe5898cc1b |
| 30 | bot | pass | 403 | 403 |  |
| 31 | anonymous | pass | 302 | 302 |  |
| 31 | signed | fail | 200 | 200 | headers content-length,etag; body len=25833/25663 sha256=818353342355/7a127bff7b58 |
| 31 | denied | fail | 200 | 200 | headers content-length,etag; body len=25833/25663 sha256=818353342355/7a127bff7b58 |
| 31 | bot | pass | 403 | 403 |  |
| 32 | anonymous | pass | 404 | 404 |  |
| 32 | signed | pass | 404 | 404 |  |
| 32 | denied | pass | 404 | 404 |  |
| 32 | bot | pass | 404 | 404 |  |
| 33 | anonymous | pass | 302 | 302 |  |
| 33 | signed | pass | 400 | 400 |  |
| 33 | denied | pass | 429 | 429 |  |
| 33 | bot | pass | 403 | 403 |  |
| 34 | anonymous | pass | 302 | 302 |  |
| 34 | signed | pass | 400 | 400 |  |
| 34 | denied | pass | 429 | 429 |  |
| 34 | bot | pass | 403 | 403 |  |
| 35 | anonymous | pass | 302 | 302 |  |
| 35 | signed | pass | 302 | 302 |  |
| 35 | denied | pass | 429 | 429 |  |
| 35 | bot | pass | 403 | 403 |  |
| 36 | anonymous | pass | 302 | 302 |  |
| 36 | signed | pass | 302 | 302 |  |
| 36 | denied | pass | 429 | 429 |  |
| 36 | bot | pass | 403 | 403 |  |
| 37 | anonymous | pass | 200 | 200 |  |
| 37 | signed | pass | 200 | 200 |  |
| 37 | denied | pass | 200 | 200 |  |
| 37 | bot | pass | 200 | 200 |  |
| 38 | anonymous | pass | 302 | 302 |  |
| 38 | signed | pass | 302 | 302 |  |
| 38 | denied | pass | 429 | 429 |  |
| 38 | bot | pass | 403 | 403 |  |
| 39 | anonymous | pass | 302 | 302 |  |
| 39 | signed | fail | 200 | 200 | headers content-length,etag; body len=23662/23526 sha256=2a639a49344f/a4570ca5f8b1 |
| 39 | denied | fail | 200 | 200 | headers content-length,etag; body len=23662/23526 sha256=2a639a49344f/a4570ca5f8b1 |
| 39 | bot | pass | 403 | 403 |  |
| 40 | anonymous | pass | 302 | 302 |  |
| 40 | signed | pass | 400 | 400 |  |
| 40 | denied | pass | 429 | 429 |  |
| 40 | bot | pass | 403 | 403 |  |
| 41 | anonymous | pass | 302 | 302 |  |
| 41 | signed | pass | 400 | 400 |  |
| 41 | denied | pass | 429 | 429 |  |
| 41 | bot | pass | 403 | 403 |  |
| 42 | anonymous | pass | 404 | 404 |  |
| 42 | signed | pass | 404 | 404 |  |
| 42 | denied | pass | 404 | 404 |  |
| 42 | bot | pass | 404 | 404 |  |
| 43 | anonymous | pass | 302 | 302 |  |
| 43 | signed | fail | 200 | 200 | headers content-length,etag; body len=37630/36300 sha256=e142b92544a8/a52983c7ffcb |
| 43 | denied | fail | 200 | 200 | headers content-length,etag; body len=37630/36300 sha256=e142b92544a8/a52983c7ffcb |
| 43 | bot | pass | 403 | 403 |  |
| 44 | anonymous | pass | 404 | 404 |  |
| 44 | signed | pass | 404 | 404 |  |
| 44 | denied | pass | 404 | 404 |  |
| 44 | bot | pass | 404 | 404 |  |
| 45 | anonymous | pass | 302 | 302 |  |
| 45 | signed | pass | 400 | 400 |  |
| 45 | denied | pass | 429 | 429 |  |
| 45 | bot | pass | 403 | 403 |  |
| 46 | anonymous | pass | 302 | 302 |  |
| 46 | signed | pass | 400 | 400 |  |
| 46 | denied | pass | 429 | 429 |  |
| 46 | bot | pass | 403 | 403 |  |
| 47 | anonymous | pass | 404 | 404 |  |
| 47 | signed | pass | 404 | 404 |  |
| 47 | denied | pass | 404 | 404 |  |
| 47 | bot | pass | 404 | 404 |  |
| 48 | anonymous | pass | 404 | 404 |  |
| 48 | signed | pass | 404 | 404 |  |
| 48 | denied | pass | 404 | 404 |  |
| 48 | bot | pass | 404 | 404 |  |
| 49 | anonymous | pass | 200 | 200 |  |
| 49 | signed | pass | 302 | 302 |  |
| 49 | denied | pass | 302 | 302 |  |
| 49 | bot | pass | 200 | 200 |  |
| 50 | anonymous | pass | 400 | 400 |  |
| 50 | signed | pass | 302 | 302 |  |
| 50 | denied | pass | 429 | 429 |  |
| 50 | bot | pass | 400 | 400 |  |
| 51 | anonymous | pass | 200 | 200 |  |
| 51 | signed | pass | 200 | 200 |  |
| 51 | denied | pass | 200 | 200 |  |
| 51 | bot | pass | 200 | 200 |  |
| 52 | anonymous | pass | 302 | 302 |  |
| 52 | signed | pass | 200 | 200 |  |
| 52 | denied | pass | 200 | 200 |  |
| 52 | bot | pass | 403 | 403 |  |
| 53 | anonymous | pass | 302 | 302 |  |
| 53 | signed | pass | 302 | 302 |  |
| 53 | denied | pass | 429 | 429 |  |
| 53 | bot | pass | 403 | 403 |  |
| 54 | anonymous | pass | 302 | 302 |  |
| 54 | signed | pass | 404 | 404 |  |
| 54 | denied | pass | 429 | 429 |  |
| 54 | bot | pass | 403 | 403 |  |
| 55 | anonymous | pass | 302 | 302 |  |
| 55 | signed | pass | 404 | 404 |  |
| 55 | denied | pass | 429 | 429 |  |
| 55 | bot | pass | 403 | 403 |  |
| 56 | anonymous | pass | 302 | 302 |  |
| 56 | signed | fail | 200 | 200 | headers content-length,etag; body len=30763/29934 sha256=8a31e5e0f669/e2dd1bb1c5b2 |
| 56 | denied | fail | 200 | 200 | headers content-length,etag; body len=30763/29934 sha256=8a31e5e0f669/e2dd1bb1c5b2 |
| 56 | bot | pass | 403 | 403 |  |
| 57 | anonymous | pass | 404 | 404 |  |
| 57 | signed | pass | 404 | 404 |  |
| 57 | denied | pass | 404 | 404 |  |
| 57 | bot | pass | 404 | 404 |  |
| 58 | anonymous | pass | 404 | 404 |  |
| 58 | signed | pass | 404 | 404 |  |
| 58 | denied | pass | 404 | 404 |  |
| 58 | bot | pass | 404 | 404 |  |
| 59 | anonymous | pass | 302 | 302 |  |
| 59 | signed | fail | 200 | 200 | headers content-length,etag; body len=41834/40842 sha256=0a5984f54d55/2993e68e30ce |
| 59 | denied | fail | 200 | 200 | headers content-length,etag; body len=41834/40842 sha256=0a5984f54d55/2993e68e30ce |
| 59 | bot | pass | 403 | 403 |  |
| 60 | anonymous | pass | 302 | 302 |  |
| 60 | signed | pass | 400 | 400 |  |
| 60 | denied | pass | 429 | 429 |  |
| 60 | bot | pass | 403 | 403 |  |
| 61 | anonymous | pass | 302 | 302 |  |
| 61 | signed | pass | 400 | 400 |  |
| 61 | denied | pass | 429 | 429 |  |
| 61 | bot | pass | 403 | 403 |  |
| 62 | anonymous | pass | 404 | 404 |  |
| 62 | signed | pass | 404 | 404 |  |
| 62 | denied | pass | 404 | 404 |  |
| 62 | bot | pass | 404 | 404 |  |
| 63 | anonymous | pass | 404 | 404 |  |
| 63 | signed | pass | 404 | 404 |  |
| 63 | denied | pass | 404 | 404 |  |
| 63 | bot | pass | 404 | 404 |  |
| 64 | anonymous | pass | 302 | 302 |  |
| 64 | signed | pass | 500 | 500 |  |
| 64 | denied | pass | 429 | 429 |  |
| 64 | bot | pass | 403 | 403 |  |
| 65 | anonymous | pass | 302 | 302 |  |
| 65 | signed | fail | 200 | 200 | headers content-length,etag; body len=23151/22934 sha256=0ccd247130d6/a6603e843d4c |
| 65 | denied | fail | 200 | 200 | headers content-length,etag; body len=23151/22934 sha256=0ccd247130d6/a6603e843d4c |
| 65 | bot | pass | 403 | 403 |  |
| 66 | anonymous | pass | 302 | 302 |  |
| 66 | signed | pass | 400 | 400 |  |
| 66 | denied | pass | 429 | 429 |  |
| 66 | bot | pass | 403 | 403 |  |
| 67 | anonymous | pass | 404 | 404 |  |
| 67 | signed | pass | 404 | 404 |  |
| 67 | denied | pass | 404 | 404 |  |
| 67 | bot | pass | 404 | 404 |  |
| 68 | anonymous | pass | 404 | 404 |  |
| 68 | signed | pass | 404 | 404 |  |
| 68 | denied | pass | 404 | 404 |  |
| 68 | bot | pass | 404 | 404 |  |
| 69 | anonymous | pass | 404 | 404 |  |
| 69 | signed | pass | 404 | 404 |  |
| 69 | denied | pass | 404 | 404 |  |
| 69 | bot | pass | 404 | 404 |  |
| 70 | anonymous | pass | 404 | 404 |  |
| 70 | signed | pass | 404 | 404 |  |
| 70 | denied | pass | 404 | 404 |  |
| 70 | bot | pass | 404 | 404 |  |
| 71 | anonymous | pass | 404 | 404 |  |
| 71 | signed | pass | 404 | 404 |  |
| 71 | denied | pass | 404 | 404 |  |
| 71 | bot | pass | 404 | 404 |  |
| 72 | anonymous | pass | 302 | 302 |  |
| 72 | signed | pass | 302 | 302 |  |
| 72 | denied | pass | 429 | 429 |  |
| 72 | bot | pass | 403 | 403 |  |
| 73 | anonymous | pass | 302 | 302 |  |
| 73 | signed | fail | 200 | 200 | headers content-length,etag; body len=25218/24878 sha256=f1afc5fa949c/917ec81a730c |
| 73 | denied | fail | 200 | 200 | headers content-length,etag; body len=25218/24878 sha256=f1afc5fa949c/917ec81a730c |
| 73 | bot | pass | 403 | 403 |  |
| 74 | anonymous | pass | 302 | 302 |  |
| 74 | signed | pass | 200 | 200 |  |
| 74 | denied | pass | 200 | 200 |  |
| 74 | bot | pass | 403 | 403 |  |
| 75 | anonymous | pass | 302 | 302 |  |
| 75 | signed | fail | 200 | 200 | headers content-length,etag; body len=382814/343174 sha256=63968eae7b96/dc1f70b5dea8 |
| 75 | denied | fail | 200 | 200 | headers content-length,etag; body len=382814/343174 sha256=63968eae7b96/dc1f70b5dea8 |
| 75 | bot | pass | 403 | 403 |  |
| 76 | anonymous | pass | 302 | 302 |  |
| 76 | signed | pass | 400 | 400 |  |
| 76 | denied | pass | 429 | 429 |  |
| 76 | bot | pass | 403 | 403 |  |
| 77 | anonymous | pass | 404 | 404 |  |
| 77 | signed | pass | 404 | 404 |  |
| 77 | denied | pass | 404 | 404 |  |
| 77 | bot | pass | 404 | 404 |  |
| 78 | anonymous | pass | 302 | 302 |  |
| 78 | signed | pass | 404 | 404 |  |
| 78 | denied | pass | 404 | 404 |  |
| 78 | bot | pass | 403 | 403 |  |
| 79 | anonymous | pass | 302 | 302 |  |
| 79 | signed | pass | 404 | 404 |  |
| 79 | denied | pass | 404 | 404 |  |
| 79 | bot | pass | 403 | 403 |  |
| 80 | anonymous | pass | 302 | 302 |  |
| 80 | signed | pass | 404 | 404 |  |
| 80 | denied | pass | 429 | 429 |  |
| 80 | bot | pass | 403 | 403 |  |
| 81 | anonymous | pass | 302 | 302 |  |
| 81 | signed | pass | 404 | 404 |  |
| 81 | denied | pass | 429 | 429 |  |
| 81 | bot | pass | 403 | 403 |  |
| 82 | anonymous | pass | 302 | 302 |  |
| 82 | signed | pass | 404 | 404 |  |
| 82 | denied | pass | 429 | 429 |  |
| 82 | bot | pass | 403 | 403 |  |
| 83 | anonymous | pass | 404 | 404 |  |
| 83 | signed | pass | 404 | 404 |  |
| 83 | denied | pass | 429 | 429 |  |
| 83 | bot | pass | 404 | 404 |  |
| 84 | anonymous | pass | 404 | 404 |  |
| 84 | signed | pass | 404 | 404 |  |
| 84 | denied | pass | 429 | 429 |  |
| 84 | bot | pass | 404 | 404 |  |
| 85 | anonymous | pass | 200 | 200 |  |
| 85 | signed | pass | 200 | 200 |  |
| 85 | denied | pass | 200 | 200 |  |
| 85 | bot | pass | 200 | 200 |  |
| 86 | anonymous | pass | 422 | 422 |  |
| 86 | signed | pass | 422 | 422 |  |
| 86 | denied | pass | 429 | 429 |  |
| 86 | bot | pass | 422 | 422 |  |
| 87 | anonymous | pass | 404 | 404 |  |
| 87 | signed | pass | 404 | 404 |  |
| 87 | denied | pass | 429 | 429 |  |
| 87 | bot | pass | 404 | 404 |  |
| 88 | anonymous | pass | 404 | 404 |  |
| 88 | signed | pass | 404 | 404 |  |
| 88 | denied | pass | 429 | 429 |  |
| 88 | bot | pass | 404 | 404 |  |
| 89 | anonymous | pass | 404 | 404 |  |
| 89 | signed | pass | 404 | 404 |  |
| 89 | denied | pass | 429 | 429 |  |
| 89 | bot | pass | 404 | 404 |  |
| 90 | anonymous | pass | 302 | 302 |  |
| 90 | signed | pass | 406 | 406 |  |
| 90 | denied | pass | 406 | 406 |  |
| 90 | bot | pass | 403 | 403 |  |
| 91 | anonymous | pass | 500 | 500 |  |
| 91 | signed | pass | 500 | 500 |  |
| 91 | denied | pass | 500 | 500 |  |
| 91 | bot | pass | 500 | 500 |  |
| 92 | anonymous | pass | 302 | 302 |  |
| 92 | signed | pass | 200 | 200 |  |
| 92 | denied | pass | 200 | 200 |  |
| 92 | bot | pass | 403 | 403 |  |
| 93 | anonymous | pass | 302 | 302 |  |
| 93 | signed | pass | 302 | 302 |  |
| 93 | denied | pass | 429 | 429 |  |
| 93 | bot | pass | 403 | 403 |  |
| 94 | anonymous | pass | 302 | 302 |  |
| 94 | signed | pass | 302 | 302 |  |
| 94 | denied | pass | 429 | 429 |  |
| 94 | bot | pass | 403 | 403 |  |
| 95 | anonymous | pass | 302 | 302 |  |
| 95 | signed | fail | 200 | 200 | headers content-length,etag; body len=416349/374749 sha256=aaa9305357de/cc018e329353 |
| 95 | denied | fail | 200 | 200 | headers content-length,etag; body len=416349/374749 sha256=aaa9305357de/cc018e329353 |
| 95 | bot | pass | 403 | 403 |  |
| 96 | anonymous | pass | 302 | 302 |  |
| 96 | signed | pass | 302 | 302 |  |
| 96 | denied | pass | 302 | 302 |  |
| 96 | bot | pass | 403 | 403 |  |
| 97 | anonymous | pass | 404 | 404 |  |
| 97 | signed | pass | 404 | 404 |  |
| 97 | denied | pass | 404 | 404 |  |
| 97 | bot | pass | 404 | 404 |  |
| 98 | anonymous | pass | 404 | 404 |  |
| 98 | signed | pass | 404 | 404 |  |
| 98 | denied | pass | 404 | 404 |  |
| 98 | bot | pass | 404 | 404 |  |
| 99 | anonymous | pass | 404 | 404 |  |
| 99 | signed | pass | 404 | 404 |  |
| 99 | denied | pass | 404 | 404 |  |
| 99 | bot | pass | 404 | 404 |  |
| 100 | anonymous | pass | 302 | 302 |  |
| 100 | signed | fail | 200 | 200 | headers content-length,etag; body len=416349/374749 sha256=aaa9305357de/cc018e329353 |
| 100 | denied | fail | 200 | 200 | headers content-length,etag; body len=416349/374749 sha256=aaa9305357de/cc018e329353 |
| 100 | bot | pass | 403 | 403 |  |
| 101 | anonymous | pass | 404 | 404 |  |
| 101 | signed | pass | 404 | 404 |  |
| 101 | denied | pass | 404 | 404 |  |
| 101 | bot | pass | 404 | 404 |  |
| 102 | anonymous | pass | 404 | 404 |  |
| 102 | signed | pass | 404 | 404 |  |
| 102 | denied | pass | 404 | 404 |  |
| 102 | bot | pass | 404 | 404 |  |
| 103 | anonymous | pass | 302 | 302 |  |
| 103 | signed | pass | 302 | 302 |  |
| 103 | denied | pass | 429 | 429 |  |
| 103 | bot | pass | 403 | 403 |  |
| 104 | anonymous | pass | 302 | 302 |  |
| 104 | signed | pass | 302 | 302 |  |
| 104 | denied | pass | 302 | 302 |  |
| 104 | bot | pass | 403 | 403 |  |
| 105 | anonymous | pass | 302 | 302 |  |
| 105 | signed | pass | 400 | 400 |  |
| 105 | denied | pass | 429 | 429 |  |
| 105 | bot | pass | 403 | 403 |  |
| 106 | anonymous | pass | 302 | 302 |  |
| 106 | signed | fail | 200 | 200 | headers content-length,etag; body len=29387/28857 sha256=241c399175b7/644177e2a5c3 |
| 106 | denied | fail | 200 | 200 | headers content-length,etag; body len=29387/28857 sha256=241c399175b7/644177e2a5c3 |
| 106 | bot | pass | 403 | 403 |  |
| 107 | anonymous | pass | 302 | 302 |  |
| 107 | signed | fail | 200 | 200 | headers content-length,etag; body len=30025/29481 sha256=373c95c79df5/7eb08179c00e |
| 107 | denied | fail | 200 | 200 | headers content-length,etag; body len=30025/29481 sha256=373c95c79df5/7eb08179c00e |
| 107 | bot | pass | 403 | 403 |  |
| 108 | anonymous | pass | 302 | 302 |  |
| 108 | signed | pass | 302 | 302 |  |
| 108 | denied | pass | 302 | 302 |  |
| 108 | bot | pass | 403 | 403 |  |
| 109 | anonymous | pass | 302 | 302 |  |
| 109 | signed | pass | 400 | 400 |  |
| 109 | denied | pass | 429 | 429 |  |
| 109 | bot | pass | 403 | 403 |  |
| 110 | anonymous | pass | 302 | 302 |  |
| 110 | signed | pass | 400 | 400 |  |
| 110 | denied | pass | 429 | 429 |  |
| 110 | bot | pass | 403 | 403 |  |
| 111 | anonymous | pass | 302 | 302 |  |
| 111 | signed | pass | 500 | 500 |  |
| 111 | denied | pass | 429 | 429 |  |
| 111 | bot | pass | 403 | 403 |  |
| 112 | anonymous | pass | 302 | 302 |  |
| 112 | signed | pass | 302 | 302 |  |
| 112 | denied | pass | 302 | 302 |  |
| 112 | bot | pass | 403 | 403 |  |
| 113 | anonymous | pass | 302 | 302 |  |
| 113 | signed | pass | 400 | 400 |  |
| 113 | denied | pass | 429 | 429 |  |
| 113 | bot | pass | 403 | 403 |  |
| 114 | anonymous | pass | 302 | 302 |  |
| 114 | signed | fail | 200 | 200 | headers content-length,etag; body len=30377/29598 sha256=72a976bde72b/4aa4691dbca4 |
| 114 | denied | fail | 200 | 200 | headers content-length,etag; body len=30377/29598 sha256=72a976bde72b/4aa4691dbca4 |
| 114 | bot | pass | 403 | 403 |  |
| 115 | anonymous | pass | 302 | 302 |  |
| 115 | signed | fail | 200 | 200 | headers content-length,etag; body len=31224/30397 sha256=8b2cdf10ed2a/2bd5f0a00211 |
| 115 | denied | fail | 200 | 200 | headers content-length,etag; body len=31224/30397 sha256=8b2cdf10ed2a/2bd5f0a00211 |
| 115 | bot | pass | 403 | 403 |  |
| 116 | anonymous | pass | 302 | 302 |  |
| 116 | signed | pass | 302 | 302 |  |
| 116 | denied | pass | 302 | 302 |  |
| 116 | bot | pass | 403 | 403 |  |
| 117 | anonymous | pass | 302 | 302 |  |
| 117 | signed | pass | 400 | 400 |  |
| 117 | denied | pass | 429 | 429 |  |
| 117 | bot | pass | 403 | 403 |  |
| 118 | anonymous | pass | 302 | 302 |  |
| 118 | signed | pass | 400 | 400 |  |
| 118 | denied | pass | 429 | 429 |  |
| 118 | bot | pass | 403 | 403 |  |
| 119 | anonymous | pass | 302 | 302 |  |
| 119 | signed | pass | 500 | 500 |  |
| 119 | denied | pass | 429 | 429 |  |
| 119 | bot | pass | 403 | 403 |  |
| 120 | anonymous | pass | 302 | 302 |  |
| 120 | signed | pass | 302 | 302 |  |
| 120 | denied | pass | 302 | 302 |  |
| 120 | bot | pass | 403 | 403 |  |
| 121 | anonymous | pass | 302 | 302 |  |
| 121 | signed | pass | 302 | 302 |  |
| 121 | denied | pass | 429 | 429 |  |
| 121 | bot | pass | 403 | 403 |  |
| 122 | anonymous | pass | 302 | 302 |  |
| 122 | signed | fail | 200 | 200 | headers content-length,etag; body len=22796/22604 sha256=70342937dd89/9f86aaabd903 |
| 122 | denied | fail | 200 | 200 | headers content-length,etag; body len=22796/22604 sha256=70342937dd89/9f86aaabd903 |
| 122 | bot | pass | 403 | 403 |  |
| 123 | anonymous | pass | 302 | 302 |  |
| 123 | signed | pass | 302 | 302 |  |
| 123 | denied | pass | 302 | 302 |  |
| 123 | bot | pass | 403 | 403 |  |
| 124 | anonymous | pass | 302 | 302 |  |
| 124 | signed | pass | 302 | 302 |  |
| 124 | denied | pass | 302 | 302 |  |
| 124 | bot | pass | 403 | 403 |  |
| 125 | anonymous | pass | 404 | 404 |  |
| 125 | signed | pass | 404 | 404 |  |
| 125 | denied | pass | 404 | 404 |  |
| 125 | bot | pass | 404 | 404 |  |
| 126 | anonymous | pass | 404 | 404 |  |
| 126 | signed | pass | 404 | 404 |  |
| 126 | denied | pass | 404 | 404 |  |
| 126 | bot | pass | 404 | 404 |  |
| 127 | anonymous | pass | 302 | 302 |  |
| 127 | signed | pass | 302 | 302 |  |
| 127 | denied | pass | 429 | 429 |  |
| 127 | bot | pass | 403 | 403 |  |
| 128 | anonymous | pass | 302 | 302 |  |
| 128 | signed | pass | 200 | 200 |  |
| 128 | denied | pass | 200 | 200 |  |
| 128 | bot | pass | 403 | 403 |  |
| 129 | anonymous | pass | 302 | 302 |  |
| 129 | signed | pass | 400 | 400 |  |
| 129 | denied | pass | 429 | 429 |  |
| 129 | bot | pass | 403 | 403 |  |
| 130 | anonymous | pass | 302 | 302 |  |
| 130 | signed | pass | 200 | 200 |  |
| 130 | denied | pass | 200 | 200 |  |
| 130 | bot | pass | 403 | 403 |  |
| 131 | anonymous | pass | 404 | 404 |  |
| 131 | signed | pass | 404 | 404 |  |
| 131 | denied | pass | 404 | 404 |  |
| 131 | bot | pass | 404 | 404 |  |
| 132 | anonymous | pass | 404 | 404 |  |
| 132 | signed | pass | 404 | 404 |  |
| 132 | denied | pass | 404 | 404 |  |
| 132 | bot | pass | 404 | 404 |  |
| 133 | anonymous | pass | 404 | 404 |  |
| 133 | signed | pass | 404 | 404 |  |
| 133 | denied | pass | 404 | 404 |  |
| 133 | bot | pass | 404 | 404 |  |
| 134 | anonymous | pass | 404 | 404 |  |
| 134 | signed | pass | 404 | 404 |  |
| 134 | denied | pass | 404 | 404 |  |
| 134 | bot | pass | 404 | 404 |  |
| 135 | anonymous | pass | 302 | 302 |  |
| 135 | signed | pass | 204 | 204 |  |
| 135 | denied | pass | 429 | 429 |  |
| 135 | bot | pass | 403 | 403 |  |
| 136 | anonymous | pass | 302 | 302 |  |
| 136 | signed | pass | 404 | 404 |  |
| 136 | denied | pass | 404 | 404 |  |
| 136 | bot | pass | 403 | 403 |  |
| 137 | anonymous | pass | 302 | 302 |  |
| 137 | signed | pass | 200 | 200 |  |
| 137 | denied | pass | 429 | 429 |  |
| 137 | bot | pass | 403 | 403 |  |
| 138 | anonymous | pass | 404 | 404 |  |
| 138 | signed | pass | 404 | 404 |  |
| 138 | denied | pass | 404 | 404 |  |
| 138 | bot | pass | 404 | 404 |  |
| 139 | anonymous | pass | 302 | 302 |  |
| 139 | signed | pass | 404 | 404 |  |
| 139 | denied | pass | 404 | 404 |  |
| 139 | bot | pass | 403 | 403 |  |
| 140 | anonymous | pass | 302 | 302 |  |
| 140 | signed | pass | 404 | 404 |  |
| 140 | denied | pass | 404 | 404 |  |
| 140 | bot | pass | 403 | 403 |  |
| 141 | anonymous | pass | 302 | 302 |  |
| 141 | signed | pass | 404 | 404 |  |
| 141 | denied | pass | 429 | 429 |  |
| 141 | bot | pass | 403 | 403 |  |
| 142 | anonymous | pass | 302 | 302 |  |
| 142 | signed | pass | 404 | 404 |  |
| 142 | denied | pass | 429 | 429 |  |
| 142 | bot | pass | 403 | 403 |  |
| 143 | anonymous | pass | 302 | 302 |  |
| 143 | signed | pass | 404 | 404 |  |
| 143 | denied | pass | 429 | 429 |  |
| 143 | bot | pass | 403 | 403 |  |
| 144 | anonymous | pass | 302 | 302 |  |
| 144 | signed | pass | 302 | 302 |  |
| 144 | denied | pass | 429 | 429 |  |
| 144 | bot | pass | 403 | 403 |  |
| 145 | anonymous | pass | 302 | 302 |  |
| 145 | signed | fail | 200 | 200 | headers content-length,etag; body len=24543/24197 sha256=c932a6fe062d/97c1d885e426 |
| 145 | denied | fail | 200 | 200 | headers content-length,etag; body len=24543/24197 sha256=c932a6fe062d/97c1d885e426 |
| 145 | bot | pass | 403 | 403 |  |
| 146 | anonymous | pass | 302 | 302 |  |
| 146 | signed | pass | 500 | 500 |  |
| 146 | denied | pass | 429 | 429 |  |
| 146 | bot | pass | 403 | 403 |  |
| 147 | anonymous | pass | 302 | 302 |  |
| 147 | signed | pass | 400 | 400 |  |
| 147 | denied | pass | 429 | 429 |  |
| 147 | bot | pass | 403 | 403 |  |
| 148 | anonymous | pass | 406 | 406 |  |
| 148 | signed | pass | 406 | 406 |  |
| 148 | denied | pass | 406 | 406 |  |
| 148 | bot | pass | 406 | 406 |  |
| 149 | anonymous | pass | 406 | 406 |  |
| 149 | signed | pass | 406 | 406 |  |
| 149 | denied | pass | 406 | 406 |  |
| 149 | bot | pass | 406 | 406 |  |
| 150 | anonymous | pass | 200 | 200 |  |
| 150 | signed | pass | 200 | 200 |  |
| 150 | denied | pass | 200 | 200 |  |
| 150 | bot | pass | 200 | 200 |  |
| 151 | anonymous | pass | 200 | 200 |  |
| 151 | signed | pass | 200 | 200 |  |
| 151 | denied | pass | 200 | 200 |  |
| 151 | bot | pass | 200 | 200 |  |
| 152 | anonymous | pass | 200 | 200 |  |
| 152 | signed | pass | 200 | 200 |  |
| 152 | denied | pass | 200 | 200 |  |
| 152 | bot | pass | 200 | 200 |  |
| 153 | anonymous | pass | 200 | 200 |  |
| 153 | signed | pass | 200 | 200 |  |
| 153 | denied | pass | 200 | 200 |  |
| 153 | bot | pass | 200 | 200 |  |
| 154 | anonymous | pass | 404 | 404 |  |
| 154 | signed | pass | 404 | 404 |  |
| 154 | denied | pass | 404 | 404 |  |
| 154 | bot | pass | 404 | 404 |  |
| 155 | anonymous | pass | 404 | 404 |  |
| 155 | signed | pass | 404 | 404 |  |
| 155 | denied | pass | 404 | 404 |  |
| 155 | bot | pass | 404 | 404 |  |
| 156 | anonymous | pass | 404 | 404 |  |
| 156 | signed | pass | 404 | 404 |  |
| 156 | denied | pass | 404 | 404 |  |
| 156 | bot | pass | 404 | 404 |  |
| 157 | anonymous | pass | 404 | 404 |  |
| 157 | signed | pass | 404 | 404 |  |
| 157 | denied | pass | 404 | 404 |  |
| 157 | bot | pass | 404 | 404 |  |
| 158 | anonymous | pass | 404 | 404 |  |
| 158 | signed | pass | 404 | 404 |  |
| 158 | denied | pass | 404 | 404 |  |
| 158 | bot | pass | 404 | 404 |  |
| 159 | anonymous | pass | 404 | 404 |  |
| 159 | signed | pass | 404 | 404 |  |
| 159 | denied | pass | 404 | 404 |  |
| 159 | bot | pass | 404 | 404 |  |
| 160 | anonymous | pass | 403 | 403 |  |
| 160 | signed | pass | 403 | 403 |  |
| 160 | denied | pass | 403 | 403 |  |
| 160 | bot | pass | 403 | 403 |  |
| 161 | anonymous | pass | 403 | 403 |  |
| 161 | signed | pass | 403 | 403 |  |
| 161 | denied | pass | 403 | 403 |  |
| 161 | bot | pass | 403 | 403 |  |
| 162 | anonymous | pass | 403 | 403 |  |
| 162 | signed | pass | 403 | 403 |  |
| 162 | denied | pass | 403 | 403 |  |
| 162 | bot | pass | 403 | 403 |  |
| 163 | anonymous | pass | 403 | 403 |  |
| 163 | signed | pass | 403 | 403 |  |
| 163 | denied | pass | 403 | 403 |  |
| 163 | bot | pass | 403 | 403 |  |
| 164 | anonymous | pass | 403 | 403 |  |
| 164 | signed | pass | 403 | 403 |  |
| 164 | denied | pass | 403 | 403 |  |
| 164 | bot | pass | 403 | 403 |  |
| 165 | anonymous | pass | 403 | 403 |  |
| 165 | signed | pass | 403 | 403 |  |
| 165 | denied | pass | 403 | 403 |  |
| 165 | bot | pass | 403 | 403 |  |
| 166 | anonymous | pass | 403 | 403 |  |
| 166 | signed | pass | 403 | 403 |  |
| 166 | denied | pass | 403 | 403 |  |
| 166 | bot | pass | 403 | 403 |  |
| 167 | anonymous | pass | 403 | 403 |  |
| 167 | signed | pass | 403 | 403 |  |
| 167 | denied | pass | 403 | 403 |  |
| 167 | bot | pass | 403 | 403 |  |
| 168 | anonymous | pass | 302 | 302 |  |
| 168 | signed | pass | 302 | 302 |  |
| 168 | denied | pass | 302 | 302 |  |
| 168 | bot | pass | 302 | 302 |  |
| 169 | anonymous | pass | 200 | 200 |  |
| 169 | signed | pass | 200 | 200 |  |
| 169 | denied | pass | 200 | 200 |  |
| 169 | bot | pass | 200 | 200 |  |
| 170 | anonymous | pass | 302 | 302 |  |
| 170 | signed | pass | 302 | 302 |  |
| 170 | denied | pass | 302 | 302 |  |
| 170 | bot | pass | 302 | 302 |  |
| 171 | anonymous | pass | 404 | 404 |  |
| 171 | signed | pass | 404 | 404 |  |
| 171 | denied | pass | 404 | 404 |  |
| 171 | bot | pass | 404 | 404 |  |
| 172 | anonymous | pass | 404 | 404 |  |
| 172 | signed | pass | 404 | 404 |  |
| 172 | denied | pass | 404 | 404 |  |
| 172 | bot | pass | 404 | 404 |  |
| 173 | anonymous | pass | 404 | 404 |  |
| 173 | signed | pass | 404 | 404 |  |
| 173 | denied | pass | 404 | 404 |  |
| 173 | bot | pass | 404 | 404 |  |
| 174 | anonymous | pass | 404 | 404 |  |
| 174 | signed | pass | 404 | 404 |  |
| 174 | denied | pass | 404 | 404 |  |
| 174 | bot | pass | 404 | 404 |  |
| 175 | anonymous | pass | 401 | 401 |  |
| 175 | signed | pass | 404 | 404 |  |
| 175 | denied | pass | 404 | 404 |  |
| 175 | bot | pass | 401 | 401 |  |
| 176 | anonymous | pass | 401 | 401 |  |
| 176 | signed | pass | 400 | 400 |  |
| 176 | denied | pass | 400 | 400 |  |
| 176 | bot | pass | 401 | 401 |  |

## Failures

- Row 30, signed: headers content-length,etag; body len=24484/24370 sha256=ebe88701671e/50fe5898cc1b
- Row 30, denied: headers content-length,etag; body len=24484/24370 sha256=ebe88701671e/50fe5898cc1b
- Row 31, signed: headers content-length,etag; body len=25833/25663 sha256=818353342355/7a127bff7b58
- Row 31, denied: headers content-length,etag; body len=25833/25663 sha256=818353342355/7a127bff7b58
- Row 39, signed: headers content-length,etag; body len=23662/23526 sha256=2a639a49344f/a4570ca5f8b1
- Row 39, denied: headers content-length,etag; body len=23662/23526 sha256=2a639a49344f/a4570ca5f8b1
- Row 43, signed: headers content-length,etag; body len=37630/36300 sha256=e142b92544a8/a52983c7ffcb
- Row 43, denied: headers content-length,etag; body len=37630/36300 sha256=e142b92544a8/a52983c7ffcb
- Row 56, signed: headers content-length,etag; body len=30763/29934 sha256=8a31e5e0f669/e2dd1bb1c5b2
- Row 56, denied: headers content-length,etag; body len=30763/29934 sha256=8a31e5e0f669/e2dd1bb1c5b2
- Row 59, signed: headers content-length,etag; body len=41834/40842 sha256=0a5984f54d55/2993e68e30ce
- Row 59, denied: headers content-length,etag; body len=41834/40842 sha256=0a5984f54d55/2993e68e30ce
- Row 65, signed: headers content-length,etag; body len=23151/22934 sha256=0ccd247130d6/a6603e843d4c
- Row 65, denied: headers content-length,etag; body len=23151/22934 sha256=0ccd247130d6/a6603e843d4c
- Row 73, signed: headers content-length,etag; body len=25218/24878 sha256=f1afc5fa949c/917ec81a730c
- Row 73, denied: headers content-length,etag; body len=25218/24878 sha256=f1afc5fa949c/917ec81a730c
- Row 75, signed: headers content-length,etag; body len=382814/343174 sha256=63968eae7b96/dc1f70b5dea8
- Row 75, denied: headers content-length,etag; body len=382814/343174 sha256=63968eae7b96/dc1f70b5dea8
- Row 95, signed: headers content-length,etag; body len=416349/374749 sha256=aaa9305357de/cc018e329353
- Row 95, denied: headers content-length,etag; body len=416349/374749 sha256=aaa9305357de/cc018e329353
- Row 100, signed: headers content-length,etag; body len=416349/374749 sha256=aaa9305357de/cc018e329353
- Row 100, denied: headers content-length,etag; body len=416349/374749 sha256=aaa9305357de/cc018e329353
- Row 106, signed: headers content-length,etag; body len=29387/28857 sha256=241c399175b7/644177e2a5c3
- Row 106, denied: headers content-length,etag; body len=29387/28857 sha256=241c399175b7/644177e2a5c3
- Row 107, signed: headers content-length,etag; body len=30025/29481 sha256=373c95c79df5/7eb08179c00e
- Row 107, denied: headers content-length,etag; body len=30025/29481 sha256=373c95c79df5/7eb08179c00e
- Row 114, signed: headers content-length,etag; body len=30377/29598 sha256=72a976bde72b/4aa4691dbca4
- Row 114, denied: headers content-length,etag; body len=30377/29598 sha256=72a976bde72b/4aa4691dbca4
- Row 115, signed: headers content-length,etag; body len=31224/30397 sha256=8b2cdf10ed2a/2bd5f0a00211
- Row 115, denied: headers content-length,etag; body len=31224/30397 sha256=8b2cdf10ed2a/2bd5f0a00211
- Row 122, signed: headers content-length,etag; body len=22796/22604 sha256=70342937dd89/9f86aaabd903
- Row 122, denied: headers content-length,etag; body len=22796/22604 sha256=70342937dd89/9f86aaabd903
- Row 145, signed: headers content-length,etag; body len=24543/24197 sha256=c932a6fe062d/97c1d885e426
- Row 145, denied: headers content-length,etag; body len=24543/24197 sha256=c932a6fe062d/97c1d885e426

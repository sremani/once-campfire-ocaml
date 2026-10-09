# M8-T2 positive-write differential plan

Status: planned, **not run**. The ordinary 177-row matrix sends empty/default bodies on many mutating routes. Each case below needs fresh, independent pinned seed copies, a signed test session when required, a CSRF token fetched from that same server's page, exact Rust/OCaml wire comparison, and all-table before/after SQLite comparison. Read each server's own CSRF token and commit any renewed fixture cookie before POST/PATCH/PUT/DELETE; never log either value.

| Family | Representative route rows | Proposed valid request from pinned controller source/tests | Effect to audit |
| --- | --- | --- | --- |
| Account roles/bots | 23, 33 | `user[role]=member`; `user[name]=Parity Bot` | Target user fields, bot metadata, session and cookie effects |
| Account settings/styles | 40, 45 | `account[custom_styles]=...`; `account[name]=Parity Campfire` | Account row and rendered follow-up |
| Profile and subscriptions | 60, 72 | `user[name]=Parity User`; delete a seeded subscription | User row; exact deleted subscription and push side effects |
| Room creation and changes | 93, 105, 113, 121 | `involvement=invisible`; `room[name]=Parity Room`; closed-room `user_ids[]`; direct-room `user_ids[]` | Memberships, rooms, id allocation, broadcasts and redirects |
| Human messages/boosts | 76, 80, 129 | `message[body]=...`, a distinct `message[client_message_id]`; edit existing body; `boost[content]=🔥` | Messages, Action Text, FTS, boosts, broadcasts and acknowledged ids |
| Bot messages | 86 | Plain UTF-8 request body on seeded bot-key route | Bot-auth message body, response JSON and persisted rows |
| Searches | 144, 146 | Clear seeded search; submit nonempty query according to source form | Search rows and response body |
| Storage | 175, 176 | Pinned signed disk key and valid direct-upload JSON from M6 fixtures | File bytes, blob rows, signed response and failed-file absence |
| Session/onboarding | 9, 17, 50, 7 | Valid transfer, test password login, valid join form, first-run create on the first-run seed | Signed cookies, new session/user/account rows, random-generator invariants |

Start with one representative successful write per family, then cover the alternate HTTP methods and denied/bot roles. The shared `AcknowledgedWrites` audit already passes one human message POST on both servers, but does not establish the other families. M6's 256-case Rails/OCaml media gate supplies fixtures for storage, while this gate must compare pinned Rust live responses and state. The first-run seed lacks the default signed session, so signed/denied cells there require a deliberately created fixture session or an explicit not-run result.

Additional pending matrices: ordinary requests on `crowd`, `custom_styles`, `restricted`, and `first_run`; default-seed method override on 59 PATCH/PUT/DELETE route rows (236 exercised role cells, 472 explicit not-run); and malformed paths on all 177 route rows (708 role cells). Run these after a scheduled quiet Docker interval for browser and benchmark checks.

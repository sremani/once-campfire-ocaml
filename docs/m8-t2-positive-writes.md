# M8-T2 pinned Rust/OCaml positive-write differential

Status: **26 pass, 4 fail, 0 not-run** in 30 isolated cases across 18 implemented mutating families. This is a representative successful-write sweep, not exhaustive coverage of the mutating route catalog. The per-case status, safe response hashes/header differences, changed-table lists, and mismatch details are in [`m8-t2-positive-writes-postfix.json`](m8-t2-positive-writes-postfix.json). The runner compares all-table SQLite before/after snapshots but retains only changed-table names and validated random-field hashes in this compact report.

The reference is pinned Rust `9872c1d9541551c0889a60e3d49a14488bd1e403` with shared verification `6f71d70b5e1f17507404ad06cac134aa453a04a6`. The immutable OCaml executable is `/tmp/m8-t2-main-positive-postfix-20261009.exe`, SHA-256 `b30ff25a75e6690d08cc0b672779b6d677a8f4162899d13be65b9f0b461efba6`; the 89-file source manifest is [`m8-t2-positive-postfix-source-files.sha256`](m8-t2-positive-postfix-source-files.sha256), manifest SHA-256 `33e24cf22c0897a5908495cf26dadb0f65ad232d8b2a376efa27a6b5ea444f32`. Every case starts with independent disposable copies of the same default Rails seed. The request uses only pinned fixture credentials. Pinned Rust's `header_only` CSRF policy accepts matching `Origin` and `Sec-Fetch-Site: same-origin`; the tested pages do not supply a CSRF meta token. The runner uses any token returned by its own server if present and never logs it.

Exact status, all response header values, body bytes, and every SQLite table before/after are compared. The shared comparator validates the session-cookie signature/payload and compares equivalent authenticated plaintext while allowing independent AES-GCM IVs; it also validates the format and linkage of generated session tokens. For new deactivation email UUIDs, bot tokens, account join codes, and bot message UUIDs, the runner validates generator shape, uniqueness, affected row identity/count, and equality of all other columns before canonicalizing that one generated value. It does not suppress a deterministic column or table difference. A two-second bounded settle is used for human/bot message creation and ban creation because pinned post-response jobs mutate the seed; these three cases pass after the same settle on each side.

Run from the OCaml repository:

```sh
python3 scripts/m8_t2_positive_writes.py \
  --ocaml-binary /tmp/m8-t2-main-positive-postfix-20261009.exe \
  --verification-checkout /tmp/m3-t3-verification-pinned \
  --settle-seconds 2 \
  --output docs/m8-t2-positive-writes-postfix.json
```

| Family | Case names | Result |
| --- | --- | --- |
| Account roles, bots, settings | `account_user_role`, `account_user_deactivate`, `account_bot_create`, `account_bot_rename`, `account_bot_key_reset`, `account_join_code_reset` | 6 pass |
| Account styles/name and user profile | `account_styles`, `account_name`, `profile_name` | 3 fail: redirect cookie only |
| User avatar, bans, push subscriptions | `avatar_delete`, `ban_create`, `ban_delete`, `push_subscription_delete` | 3 pass, 1 fail: avatar state |
| Room involvement and open/closed/direct rooms | `room_involvement`, `open_room_create`, `open_room_rename`, `closed_room_create`, `closed_room_rename`, `direct_room_create` | 6 pass |
| Human messages/boosts | `human_message_create`, `human_message_update`, `human_message_delete`, `human_boost_create`, `human_boost_delete` | 5 pass |
| Bot messages/boosts | `bot_message_create`, `bot_message_update`, `bot_boost_create` | 3 pass |
| Searches and session | `search_clear`, `search_create`, `session_logout` | 3 pass |

## Four residuals

- Rows 40, 45, and 60 (`account_styles`, `account_name`, `profile_name`) have exact 302 status, body, every other header, and changed SQLite rows. Rust emits one `_campfire_session` Set-Cookie for its redirect notice; this frozen OCaml binary emits none. A subsequent `Controller_accounts` flash-notice fix has focused decrypted-cookie tests at 12/12 and needs a fresh pinned live rerun.
- Row 53 (`avatar_delete`) uses a disposable signed Jason session. Authoritative default-seed SQLite has Jason's avatar attachment; David and Kevin have none. Rust and OCaml return the same 302 HTTP response, but Rust removes four affected storage/user table effects while OCaml changes only `active_storage_attachments`. After the request Rust has 12 attachments, 12 blobs, and 5 variant records; OCaml has 13 attachments, 14 blobs, and 6 variant records. OCaml retains attachment id 2, blobs ids 1 and 2, and variant record id 1; Jason's `users.updated_at` is touched only by Rust. The disposable login's independently generated base58(24) token and signed-cookie linkage are validated. M6 owns this cleanup seam; no state difference is masked.

## Remaining coverage

These 30 cases do not cover all 72 implemented mutating route rows, other methods/roles for each positive body, first-run and join writes, successful session transfer/login, Action Mailbox, signed storage/direct-upload writes, or valid asset/Cable/media paths. The [`default override report`](m8-t2-http-state-default-override.md) separately passes 236 applicable role cells with the default empty bodies; it does not substitute for valid-body writes. The [`malformed path report`](m8-t2-http-state-default-malformed.md) records 708 real failures at the front parser. Ordinary default routes remain 674/708; alternate `crowd`, `custom_styles`, `restricted`, and `first_run` seed sweeps and final shared contract/acknowledged-write audits remain open. M8-T2 stays open.

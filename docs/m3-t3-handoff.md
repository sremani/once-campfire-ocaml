# M3-T3 room, message, search and autocomplete controller handoff

`Controller_rooms.endpoint : string -> Http_app.endpoint option` owns the 73 catalog rows
under `rooms`, `messages`, `searches`, and `autocompletable`. It preserves the 13
`action_not_found` route rows as HTTP 404 and the declared but missing
`rooms/settings#show` controller as HTTP 500. Route matching order still belongs
to `Route_catalog`; the controller registry only supplies actions.

Implemented action logic includes room scopes, creation restrictions, open/closed/direct
room create/update/destroy, membership involvement, last-room cookie, message paging,
create/update/destroy, boosts, bot-key JSON API, search history and reachable FTS results,
and user autocomplete with 20-record pages and JSON headers. All database accesses use
`Db_runtime.read_async` or `write_async`. `Search_words` carries the pinned Rust
oracle's Ruby 3.4/Onigmo Unicode 15.0 `[[:word:]]` ranges so query sanitization
matches Rails.

Verification: `dune build @all && dune runtest --force` passed on 2026-10-08.
`m3_t3_test` now runs six cases over copied `default`, `restricted`, and `crowd` Rails
seeds. Requests cover route inventory, anonymous and inaccessible room handling,
restricted creation, message authorization and CRUD, boost creation, involvement,
invalid message cursor, search create/clear, autocomplete membership and pagination,
and bot message/boost lifecycle with JSON responses. The sixth case passes a
multipart file through the streamed HTTP parser and `Storage_blob.stage_file`:
browser message create/remove and bot create/replace/remove persist and update
the expected blob rows and local disk file. `dune exec --build-dir
_build_m3_review ./test/m3_t3_test.exe` passed 6/6 after this integration.

Integrated parity is still pending:

- M4: the shared views and Action Text now render substantial room/message/Turbo
  content, including pinned rich-text vectors, but the 123-view golden corpus is
  only partly asserted. Full response bytes and autocomplete markup remain live
  differential work.
- M5: room/message/boost broadcasts, bot webhooks, push notifications and
  unread/presence events are integrated and have focused live tests. Per-route
  timing, headers and state effects remain in the M8-T2 matrix.
- M6: message attachment assignment and staged disk persistence now work for
  browser and bot multipart routes. Blob analysis, image/video representations,
  purge worker processing and media URLs have since been implemented and passed
  M6's 256-case live storage comparison. The M3-T3 seeded route test covers
  attachment create/replace/remove and stored bytes; full message attachment
  HTML/JSON and route state parity remain open in M4/M8. The streaming parser's
  129 MiB and cancellation proof passed M3-T1's 15-case suite.
- M3/M5: apply HTTP response caching and freshness headers to room and message
  pages after renderers and event invalidation are wired.

Do not mark the full M3 gate from these six tests: action behavior is covered, while
rendered bodies and side effects above remain integration work.

The later M8 default-seed HTTP follow-up is recorded in
`docs/m3-t3-m8-focused.md`. It verifies seven focused seed tests and closes
56 previously failing route/role cells, including exact bot index JSON and
flash cookies. The remaining boost index/new HTML cells stay with M4, and the
full route gate is still open.

# M3/M5 request-path Cable integration

`Http_app.serve` shares one Cohttp listener between ordinary HTTP responses and
Cable upgrades. `campfire serve` creates an authenticated `Cable_channels` hub
and passes its runner and event sink to the listener. Requests outside `/cable`
still use normal HTTP dispatch.

Room pages now sign `[Cable_channels.room_param room; "messages"]`, matching the
room's STI Global ID param used by `RoomMessagesChannel`. Message, boost, room,
and sidebar mutation actions call `Cable_broadcasts` after successful writes.
Membership removal, session termination, deactivation, and ban actions use
`Db_remaining.Hooks` so remote disconnects occur after commit. Message and room
deletion also pass the purge event sink to the model hooks.

The socket-driven request-path test starts with two signed pinned-seed sessions.
It checks that the room page contains the signed STI stream, that an HTTP
message create sends the same append HTML to both room subscribers as the HTTP
response, and that the other member receives an unread frame. An HTTP closed
room update removes that member and sends `remote` with `reconnect:true`; a
new subscription is rejected. An HTTP user ban sends `remote` with
`reconnect:false` and rejects a new connection. The separate live TCP test
runs two WebSocket clients and an HTTP client against the same listener and
checks append delivery and membership revocation.

Verification: `m5_t2_test` passes all seven cases, including the live TCP case
with `CAMPFIRE_LIVE_CABLE_TEST=1` and disposable signed fixture sessions.
`m3_t2_test` and `m3_t3_test` each pass all five focused cases after wiring.
The pinned channel golden corpus contains exact unread fanout, Turbo removal,
remote reconnect, deactivation, and rejected reconnect frames. The request
test's unread and remote frames match those wire shapes and order. It has no
message-create HTML golden: exact Rails fragment parity remains with M4 views
and rich text. The current `room_sidebar_html` is a minimal partial; sidebar
broadcast HTML still needs the M4 presenter for exact parity.

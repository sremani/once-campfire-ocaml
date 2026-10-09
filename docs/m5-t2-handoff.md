# M5-T2 channel runner and request-path handoff

The current implementation is in `lib/cable_channels.ml` and
`lib/cable_broadcasts.ml`. It composes with M5-T1's same-listener callback:

```ocaml
let cable = Cable_channels.create ~db:runtime ~secret_key_base
    ~now:(fun () -> current_rfc3339_time ()) () in
Http_app.serve ~runtime ~secret_key_base ~cable_run:(Cable_channels.run cable) ()
```

`Cable_channels.event_sink cable` handles M2's `DisconnectUser` event. It can
run in a database worker thread: it updates the bounded hub under a mutex and
uses `Lwt_unix.send_notification` to wake the main loop. Other event variants
belong to jobs. Pass a combined event sink to `Db_remaining.Hooks` and route
revocation through `Db_remaining.Hooks.revise`, `ban_user`,
`deactivate_user`, and `reset_remote_connections` after commit. A rollback
must deliver no remote disconnect.

`Cable_channels.broadcast_json`, `read_room`, and `unread_room` cover direct
channel messages. `Cable_broadcasts` supplies the typed Turbo wrappers for
message, boost, and room/sidebar broadcasts; it accepts already-rendered
partial HTML. Its `message_create` accepts the room member IDs and fans out
unread notifications. The owner of request actions must compute recipients
and HTML from committed rows and invoke these wrappers only after a
successful transaction.

## Request-path wiring

The M3 request actions now call `Cable_broadcasts` for message, boost, room,
and sidebar mutations. Membership revision and user ban/deactivation call
M2 `Db_remaining.Hooks`, delivering `DisconnectUser` only after commit.
`Controller_rooms.room_show` signs the room's STI Global ID param for the
messages stream. The same-listener request-path evidence is recorded in
[m3-cable-integration.md](m3-cable-integration.md).

## Evidence and remaining gate

`dune exec test/m5_t2_test.exe` passes seven socket-driven tests on a copied
Rails seed database. They check signed-cookie authentication, unauthorized
disconnect, two-client typing delivery, presence/read-room counters,
membership rejection, signed RoomMessages and guarded Turbo streams, exact
Turbo removal frames, rollback-safe worker-thread revocation, the 64-entry
subscription limit, and bounded lagged-consumer disconnect. The runner
verifies the session again after joining the hub to close the authentication
race. It never refreshes HTTP session timestamps. The same-listener live
case, run with `CAMPFIRE_LIVE_CABLE_TEST=1`, passes two-client HTTP message
delivery and membership revocation.

`CAMPFIRE_APP_CHANNEL_GOLDEN=1 dune exec test/m5_channels_golden_test.exe`
replays all **47** steps in the pinned
`crates/campfire/src/channels/tests/golden/reference.json` corpus against
`Http_app.serve` on `127.0.0.1`. It loads the fixture's users, rooms,
memberships, sessions, and message into a fresh disposable SQLite database,
uses only the pinned signed test cookies and secret, and triggers unread
fanout, message removal, membership revocation, and deactivation through the
OCaml model/event APIs. All 47 steps pass. Every expected text frame and
close frame matches byte for byte; frames delivered to one socket in the
same step are sorted before comparison, following the pinned Rust replay
driver because Redis confirmation and broadcast order can race.

The corpus covers channel frames and a Turbo removal tag, not HTML for
sidebar creation or replacement. `docs/m3-cable-integration.md` records the
remaining sidebar partial parity gap for M4's view work.

The hub now keeps a shared 256-entry ring per broadcasting, with an independent
cursor for each subscription. A cursor more than 256 frames behind is closed
with null reason and `reconnect:true`. The runner drains up to 64 ready frames
into one `Cable_transport.send_texts` socket write. The direct ring boundary
tests and the full 26-step pinned Cable replay are recorded in
[m5-transport.md](m5-transport.md).

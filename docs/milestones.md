# OCaml Campfire milestones and tickets

Source of truth: `basecamp/once-campfire-rust` at
`9872c1d9541551c0889a60e3d49a14488bd1e403`, with its pinned Rails reference
`90b330024dec3e757c79b6a7e6568f93da8e3148` and shared verification harness
`6f71d70b5e1f17507404ad06cac134aa453a04a6`.
The [porting map](porting-map.md) describes subsystem choices. Each ticket is assigned to a
dedicated ticket agent by its milestone manager. Managers review integration and verify the
milestone gate; ticket completion requires code and the stated evidence, not a checked box alone.

The target is the complete Campfire application: existing SQLite/storage/cookie compatibility,
all documented Rust routes and features, browser behavior, WebSockets, jobs, integrations, media,
TLS/deployment, and comparative verification. A passing subset does not complete a milestone.

Legend: `[ ]` open, `[x]` verified complete. The initial OCaml foundation (configuration, route
catalog, cookies, schema checker) predates these tickets and is not counted as a completed
milestone. Managers and ticket agents are started as capacity permits (four concurrent agents
including the coordinator).

## M1 — Compatibility and authenticated sessions

Manager: `m1_manager`. Gate: Rust/Rails compatibility vectors and session/auth integration tests
pass; an existing signed or encrypted session is accepted only for a live authorized user.

- [x] **M1-T1 Ruby and Rails primitives.** Port the remaining `ruby` and `rails_compat` string,
  number, URL, JSON, Marshal, timestamp, and metadata behavior. Verify relevant upstream golden
  vectors, including error cases.
- [x] **M1-T2 Signed identifiers.** Port signed IDs, GlobalID, SGID, Turbo stream names, and key
  rotation with purpose/expiry checks. Verify their upstream vectors and reject tampered tokens.
- [x] **M1-T3 Session cookie and authentication.** Decode and issue Rails session cookies, map
  session tokens to the existing SQLite sessions/users, enforce bans/status/revocation, and test
  existing-install login continuity against Rust fixtures.
- [x] **M1-T4 CSRF and cookie HTTP semantics.** Port CSRF/origin/fetch-site decisions and Rack
  cookie escaping/attributes. Verify upstream CSRF/cookie vectors and HTTP rejection behavior.
- [x] **M1-T5 Route/catalog completion.** Complete path helpers and negative recognition cases,
  including method overrides and encoded paths, with the full route vector corpus.

## M2 — Database models and transactions

Manager: `m2_manager`. Gate: existing schema opens without migration or data loss; model,
transaction, concurrency, and search behavior matches Rust tests and fixture state.

- [x] **M2-T1 Database runtime.** Add prepared statements, busy handling, read/write connection
  scheduling, transactions, callbacks, migrations/index checks, and a backup-safe access pattern.
- [x] **M2-T2 Accounts, users, and sessions.** Port model queries and mutations, validations,
  password checks, account bootstrap, and session lifecycle with upstream model tests.
- [x] **M2-T3 Rooms and memberships.** Port room types, participation, unread/connected state,
  permissions, ordering, and writes with upstream fixture and concurrency tests.
- [x] **M2-T4 Messages, boosts, and search.** Port message lifecycle, rich-text relations, boosts,
  FTS queries, pagination, and search permissions; verify ordering and mutation effects.
- [x] **M2-T5 Remaining models.** Port Active Storage records, push subscriptions, bans, bot
  tokens, webhooks, and the event hooks that notify the application after commit.

## M3 — HTTP application and controllers

Manager: `m3_manager`. Gate: every application route has the Rust status, redirect, headers,
authorization, and response shape under the shared HTTP fixture suite.

- [x] **M3-T1 HTTP foundation.** Build request/response/context, params and multipart parsing,
  sessions, errors, content negotiation, gzip, and server startup with established OCaml HTTP
  libraries. The 16/16 foundation suite, 2,755 Rails parameter vectors, 129 MiB streamed upload,
  all 100 affected `Vary` role cases in the [clean 674/708 matrix](m8-t2-http-state.md), and both
  packaged 65 KiB/1 MiB header-bound probes pass; see [T1 handoff](m3-t1-http-foundation.md).
- [x] **M3-T2 Onboarding and account controllers.** Port first run, sessions/transfers, account,
  users, profiles, bans, joins, bots, and settings routes with permission tests. The clean
  d6600ed five-seed HTTP/state sweep has no T2-owned difference; first-run's 22
  previously failing anonymous/bot cells and custom-styles logo deletion now match
  Rust, including SQLite state. See [T2 handoff](m3-t2-handoff.md).
- [x] **M3-T3 Rooms, messages, and search controllers.** Port all CRUD and fragments, read state,
  boosts, search, and pagination with authenticated end-to-end tests. The clean
  d6600ed five-seed sweep has no controller/status/state difference; crowd
  autocomplete JSON and Link match Rust 3/3. The remaining room-page Lexxy
  script is a documented M4/M8 view difference; see [route audit](m3-route-audit.md).
- [x] **M3-T4 Auxiliary controllers.** Port direct uploads, avatars/logos, PWA, QR, webhook/bot
  routes, link unfurling, and other exposed application paths. Its 31 assigned routes pass
  124/124 default-seed role cases in the [immutable HTTP matrix](m8-t2-http-state.md);
  positive manifest/service-worker and signed unfurl responses pass 3/3 exact live checks,
  with QR, media, and guarded integration evidence in the [T4 handoff](m3-t4-handoff.md).
- [x] **M3-T5 Response/cache semantics.** Port ETags, conditional responses, public/private
  caches, invalidation, redirects, and limits; compare headers and bodies against Rust.
  Clean d6600ed HEAD/gzip and public logo miss, hit, signed hit, conditional
  304 and Range-bypass checks match pinned Rust; the five-seed sweep has no
  independent cache/header mismatch. Libz versus zlib-rs gzip wire bytes and
  room-script-derived validators remain documented M8 differences.

## M4 — Browser assets, views, and rich text

Manager: `m4_manager`. Gate: supported pages, fragments, rich text, assets, and browser flows
pass DOM/accessibility/screenshot comparisons and escaping tests.

- [x] **M4-T1 Asset pipeline.** Package pinned frontend JS/CSS/fonts/images, import maps,
  digests, overrides, manifests, and cache headers without a runtime Node requirement.
- [x] **M4-T2 Templates and helpers.** Port layout, navigation, forms, room/message/search,
  account/user/bot, and media views using an established OCaml HTML/template library.
  All 123 pinned view files are accounted for (121 rendered passes, two semantic
  inputs). On packaged d6600ed, five crowd view rows pass signed and denied
  Rust/OCaml status, header, body, and state comparison (10/10); first-run row 3
  passes anonymous and bot (2/2). Six seeded responses also match full Rust
  SHA-256 digests. Earlier clean browser room cells match pixels, live DOM,
  accessibility, and Cable while retaining a required 557-byte Lexxy readiness
  script. The full five-seed sweep found no additional view gap, and a fresh
  packaged Chromium room capture matched pixels, live DOM, ARIA, and Cable
  with no retries; only server/network bytes from that script differ. See
  [view evidence](m4-t2-views.md).
- [x] **M4-T3 Action Text.** Port HTML parsing, sanitization, attachments, mentions, links,
  plain text, and limits using available libraries; verify upstream rich-text vectors.
- [ ] **M4-T4 Browser behavior.** Match Turbo/Stimulus fragments, composer, installation,
  notifications, and responsive flows in browser parity tests.

## M5 — Realtime, jobs, and integrations

Manager: `m5_manager`. Gate: Cable protocol/frame tests, broadcast/revocation tests, job and
integration fixtures pass; bounded failures do not corrupt or expose data.

- [x] **M5-T1 Action Cable transport.** Implement WebSocket upgrade, framing, connection
  limits, heartbeats, subscriptions, and compression with an established WebSocket library.
- [x] **M5-T2 Channels and events.** Port room, message, typing, presence, read-room channels,
  pub/sub ordering, and ban/deactivation revocation after commit.
- [x] **M5-T3 Jobs and Web Push.** Port queues, workers, VAPID, subscription lifecycle,
  notification payloads, bounded delivery, and failure behavior.
- [x] **M5-T4 Bots, webhooks, and unfurling.** Port outbound HTTP policy, URL safety, webhook
  requests/replies, OpenGraph, and link unfurling with integration fixtures.

M5 local gate verified: pinned live Cable transport 26/26 and application channels 47/47,
jobs/Web Push core 8/8 and controlled TLS seeded integration 12/12, guarded outbound
13/13, seeded unfurl 90/90, and shared-listener webhook integration 3/3.

## M6 — Active Storage and media

Manager: `m6_manager`. Gate: existing blobs and uploads remain compatible; checksums, URLs,
metadata, variants, posters, and failure cleanup match Rust media/storage vectors.

- [x] **M6-T1 Blob and disk service.** Port keys, checksums, direct uploads, disk paths,
  streaming, signed URLs, and Active Storage row lifecycle.
- [x] **M6-T2 Image processing.** Integrate libvips for analysis, thumbnails, variants,
  avatars/logos, cache and cleanup behavior.
- [x] **M6-T3 Audio/video processing.** Integrate ffprobe/ffmpeg for metadata, previews,
  posters, timeouts, format handling, and resource limits.
- [x] **M6-T4 Storage differential tests.** Run byte and metadata comparisons against the
  upstream corpus, including malformed media and concurrent transforms.

## M7 — Front server, operations, and deployment

Manager: `m7_manager`. Gate: the OCaml service starts, serves HTTP/1.1 and HTTP/2 over the
documented TLS/HTTP modes, survives restart, and deploys through ONCE with preserved storage.

- [x] **M7-T1 Front server and TLS.** Port listener binding, proxy trust, limits, keepalive,
  TLS, HTTP/2, ACME certificates, and front cache with established protocol libraries.
- [x] **M7-T2 Runtime operations.** Port configuration, logging, health, graceful shutdown,
  worker supervision, database backups, and restore checks.
- [x] **M7-T3 Container and ONCE.** Produce amd64/arm64 images and deployment configuration;
  verify existing install upgrade and rollback without data migration.

## M8 — Differential verification and release

Manager: `m8_manager`. Gate: all upstream functional and browser parity gates pass, documented
differences are intentional, and deployable release artifacts are verified.

- [x] **M8-T1 Golden-vector coverage.** Inventory every Rust/Rails vector suite and ensure
  equivalent OCaml tests, including rejection/malformed cases and fresh fixtures.
  Six top-level fixtures and the 2,755-case parameter corpus are byte identical;
  the executable view matrix accounts for all 123 files. Packaged logo cache
  miss, hit, signed hit, and conditional 304 match Rust 4/4. See
  [vector inventory](m8-t1-vector-inventory.md).
- [x] **M8-T2 HTTP and state differential.** Compare complete route inventory, persisted
  state, assets, Cable frames, media, and error paths against the pinned Rust app.
  Clean d6600ed five-seed HTTP/state has 3,170 exact, 16 documented room-script
  differences and 354 unavailable first-run signed/denied cells. Packaged Cable,
  signed media 233/233, and shared write contracts pass. Assets are 1,004/1,015
  exact; ten gzip wire bodies and Caddy's malformed-path 400 versus Rust 404
  remain explicit library/front-boundary differences. See
  [coverage audit](m8-coverage-audit.md).
- [ ] **M8-T3 Browser parity.** Run screens, interactions, accessibility trees, and visual
  comparisons; resolve or document deliberate differences.
- [x] **M8-T4 Performance and resilience.** Benchmark representative workloads, concurrency,
  memory, crash recovery, security limits, and long-running service behavior.
  Clean d6600ed preflight, header, 60-second resilience, and alternating timed
  gates pass with exact write audits; the measured throughput gap remains a
  release finding. See [performance evidence](m8-t4-performance.md).
- [ ] **M8-T5 Release audit.** Verify license/dependency provenance, Docker images, upgrade
  instructions, complete tests, known differences, and reproducible release build.

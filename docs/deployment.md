# Container and ONCE deployment

The production image runs `campfire server` on loopback port 3000 and Caddy on
port 80 (and 443 when `TLS_DOMAIN` is set). `/rails/bin/boot` supervises both
processes: a failed child ends the container, and SIGTERM/SIGINT reaches both.
ONCE or a Docker restart policy can then restart the image. The app, front,
packaged assets, and hooks use uid/gid 1000 and `/rails` as the workdir.

Build locally:

```sh
docker build -t campfire-ocaml:local \
  --build-arg APP_VERSION=local --build-arg GIT_REVISION="$(git rev-parse HEAD)" .
```

The pinned multiarchitecture release workflow is
`.github/workflows/publish-image.yml`. It builds on native GitHub amd64 and
arm64 runners, pushes architecture tags, and assembles a manifest. The
Dockerfile pins Debian trixie and the OCaml 5.5.1 build-image digests, plus
Caddy, libvips, and ffmpeg package versions. The runtime
is Debian trixie. Each image includes the exact build-stage package inventory
and copyright notices under `/usr/share/doc/once-campfire-ocaml/`. Transitive apt
dependencies still follow the configured distribution repositories; retain the
built image digest for repeatable deployment and rollback. Run
`scripts/release_image_inventory.py` on each candidate image to record its
runtime packages, linked libraries, packaged notices, hooks, and assets.

The image includes the project MIT license, the vendored WebSocket ISC license,
and the Gumbo dependency notices and provenance record under
`/usr/share/doc/once-campfire-ocaml/`. The release source and dependency audit,
including exact package inventories and the remaining final-image checks, is
in [M8-T5 release audit](m8-t5-release-audit.md).
The [publication handoff](m8-t5-publication-handoff.md) records how to verify
the exact GHCR manifest and architecture images before an ONCE deployment.
The [luigi deployment record](m8-t5-luigi-deployment.md) records the actual
`v0.1.0` ONCE installation and its health, storage, restart, and backup checks.

The image preserves the Rust/Rails ONCE contract:

| Contract | Image value |
| --- | --- |
| User and workdir | `1000:1000`, `/rails` |
| Entrypoint and ports | `bin/boot`, 80 and 443 |
| Storage | `/rails/storage/db`, `files`, `backups`, `thruster` |
| Hooks | `/hooks/pre-backup`, `/hooks/post-restore` |
| Required continuity | existing `SECRET_KEY_BASE`, database, files, and TLS certificate storage |
| Version metadata | `APP_VERSION`, `GIT_REVISION`, OCI source/description labels |

ONCE can deploy a published image with `once deploy IMAGE --host
chat.example.com`. Keep the existing `/rails/storage` volume and secrets.
For a standalone disposable Docker instance, use an environment file that
contains the existing `SECRET_KEY_BASE` and other app secrets:

```sh
docker run -d --restart unless-stopped -p 80:80 -p 443:443 \
  --env-file campfire.env -e TLS_DOMAIN=chat.example.com \
  -v campfire:/rails/storage campfire-ocaml:local
```

`DISABLE_SSL=1` enables plain HTTP. `TLS_DOMAIN` enables Caddy ACME. The
existing `storage/thruster` directory remains mounted. The front imports a
valid legacy combined PEM certificate into Caddy storage on first run. Caddy
uses a separate ACME account for later renewals; renewal continuity remains
under the M7-T1 acceptance checks.

For a private HTTP deployment such as a Tailscale-only hostname, set
`DISABLE_SSL=1 CAMPFIRE_DIRECT_HTTP=1` and leave `TLS_DOMAIN` unset. The app
then listens directly on `HTTP_PORT` (80 by default) and Caddy does not run.
Set `CAMPFIRE_HTTP_WORKERS=2` or `4` to start that many direct listeners on the
same port. The boot script starts one local Cable broker, waits for the first
worker to reset presence, and shares the login rate-limit window across all
workers. The default remains one worker. This topology is still a performance
candidate; use the full benchmark and WebSocket checks before promoting it to
a published image.
`CAMPFIRE_DIRECT_BIND` defaults to `0.0.0.0` inside the container; restrict
the published host port to the Tailscale interface or with a host firewall.
This mode keeps the single application process and its in-process Cable and
jobs. It does not provide TLS or HTTP/2.

`/hooks/pre-backup` invokes `campfire backup`, which writes a consistent
snapshot at `storage/backups/<RAILS_ENV>.sqlite3`. `/hooks/post-restore` is
byte-identical to the pinned Rails hook: it copies that snapshot over the
database and removes stale `-wal` and `-shm` files. Run restore while the app
is stopped. Neither hook rewrites blob files.

To check a copied installation locally, build the pinned Rails reference
image and default seed, then run:

```sh
python3 scripts/m7_image_lifecycle.py --image campfire-ocaml:local \
  --old-image campfire-reference:app
```

That script uses a temporary copy, tests old image, OCaml upgrade, OCaml
restart, backup/restore, and old-image rollback, and compares database table
definitions, row counts, and all blob SHA256 hashes. It never prints secrets.

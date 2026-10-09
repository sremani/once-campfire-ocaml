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
Dockerfile pins Debian trixie and Ubuntu 24.04 base image digests and the
OCaml API, Caddy, libvips, and ffmpeg package versions. Ubuntu 24.04 provides
OCaml 4.14, Mirage Crypto 0.11.2, and PBKDF 1.2.0 for the build. The runtime
is Debian trixie. Transitive apt dependencies still follow the configured
distribution repositories; retain the built image digest for repeatable
deployment and rollback.

The image includes the project MIT license, the vendored WebSocket ISC license,
and the Gumbo dependency notices and provenance record under
`/usr/share/doc/once-campfire-ocaml/`. The release source and dependency audit,
including exact package inventories and the remaining final-image checks, is
in [M8-T5 release audit](m8-t5-release-audit.md).

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

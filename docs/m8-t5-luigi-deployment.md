# `v0.1.0` ONCE deployment on luigi

On 2026-10-10, the published OCaml Campfire image was deployed through ONCE
v0.3.4 on `luigi` as a fresh installation. The application hostname is
`luigi.tailc5ed1.ts.net`, accessible on the private Tailscale network at
`http://luigi.tailc5ed1.ts.net/`. Public TLS is disabled for this private
hostname by the user's choice. Luigi's inspected interfaces have private LAN
and Tailscale addresses, and its firewall permits both networks. No public
DNS name or public TLS endpoint was configured for this deployment.

The deployed image is the immutable manifest
`ghcr.io/sremani/once-campfire-ocaml@sha256:3215a11e11ee5cfb1c5b37ce4312a7292b6e5fe85fb5cfe451c556fcd42a7154`.
The running amd64 image ID is
`sha256:97c4240114e5f05d8b363a9e43595fe4206209201825c53c6cdd8469ee7adaf1`,
matching the independently audited published amd64 image. Its OCI revision is
`2a511ac6f74fc3689f72bd039bc11d286e71d1c4` and version is
`0.1.0-amd64`. See the [release audit](m8-t5-release-audit.md) for the
multiarchitecture manifest, signature, provenance, and published-image gates.

The official ONCE v0.3.4 Linux amd64 binary was checked against its release
`checksums.txt` SHA-256
`074c47b18b879a7473dd8a66c1cab1576c3bb82b788b764b24d12b868cb60d01`,
installed at `/usr/local/bin/once`, and its `once-background.service` is
active. The installation had no prior ONCE application, Campfire container,
or Docker volume to migrate. The deployment used:

```sh
sudo once deploy \
  ghcr.io/sremani/once-campfire-ocaml@sha256:3215a11e11ee5cfb1c5b37ce4312a7292b6e5fe85fb5cfe451c556fcd42a7154 \
  --host luigi.tailc5ed1.ts.net --disable-tls \
  --auto-update=false --auto-backup --backup-path /var/backups/once
```

ONCE reports the app running. The persistent volume
`once-app-once-campfire-ocaml.b689ce` is mounted at both `/storage` and
`/rails/storage`. Its `production.sqlite3` passes `PRAGMA integrity_check`
and has 24 tables. ONCE's stored settings retain the immutable image,
Tailscale hostname, disabled TLS, disabled automatic image updates, and
automatic backups to `/var/backups/once`.

The initial backup
`/var/backups/once/campfire-v0.1.0-initial.tar.gz` was created by
`once backup`, passes `gzip -t`, contains 13 archive entries, and is mode
`0600`. A managed `once stop`/`once start` cycle preserved the volume and
returned the app to a healthy state.

Live checks from luigi and across Tailscale returned HTTP 200 for `/up`.
`/first_run` returned HTTP 200 before and after restart, and three sampled
packaged CSS assets returned HTTP 200. The root redirects through sign-in to
`/first_run`, as expected for a fresh installation. No owner account was
created during deployment; the user can complete onboarding at the private
URL above. Authenticated features were verified on the pinned local and
published-image fixtures; they were not exercised against this fresh host.
There was no prior production data or image on luigi requiring a remote
upgrade or rollback. Both upgrade and rollback paths passed copied-install
rehearsals on the published amd64 and arm64 images.

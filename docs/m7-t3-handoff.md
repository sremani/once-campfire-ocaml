# M7-T3 container and ONCE handoff

Pinned baseline: Rust `9872c1d9541551c0889a60e3d49a14488bd1e403`,
Rails `90b330024dec3e757c79b6a7e6568f93da8e3148`.

## Implementation

- `Dockerfile` builds `campfire` and `campfire-front` for the target architecture
  from Ubuntu 24.04 OCaml 4.14 packages, then places them in a pinned Debian
  trixie runtime. Direct API packages are pinned; the Ubuntu builder is needed
  because Debian trixie Mirage Crypto 2.0 and PBKDF 2.0 do not compile the
  port's Mirage Crypto 0.11.2/PBKDF 1.2.0 calls.
- The runtime pins Debian Caddy `2.6.2-12+deb13u1`, libvips
  `8.16.1-1+deb13u1`, and ffmpeg `7:7.1.5-0+deb13u1`, and includes OpenSSL,
  CA certificates, libev, and all native OCaml-linked libraries. It packages
  the complete checked-in asset corpus. Final libvips and ffmpeg Debian
  packages passed both strict byte-vector suites, despite the Rust image's
  custom minimal source builds.
- `deploy/boot` starts the OCaml target and Caddy front, forwards stop signals,
  and exits if either child exits. The Docker/ONCE supervisor can restart both.
- The image preserves `/rails`, uid/gid 1000, the storage directory layout,
  `RAILS_ENV=production`, ports 80/443, version metadata, and ONCE hook paths.
  `hooks/post-restore` is byte-identical to the pinned Rails hook.
- `.github/workflows/publish-image.yml` builds on native amd64 and arm64
  runners and assembles a multiarchitecture GHCR manifest, following the
  pinned Rust workflow. It has not been executed in this local checkout.

## Local verification

From the OCaml repository root, with Docker access:

```sh
docker build -t campfire-ocaml:m7-t3 \
  --build-arg APP_VERSION=m7-test --build-arg GIT_REVISION=local .
docker image inspect campfire-ocaml:m7-t3
docker run --rm --entrypoint /bin/sh campfire-ocaml:m7-t3 -c \
  'ldd /usr/local/bin/campfire; caddy version; openssl version; ffmpeg -version | head -2'
python3 scripts/m7_image_lifecycle.py
docker run --privileged --rm docker.io/tonistiigi/binfmt:qemu-v9.2.2 --install arm64
docker buildx build --platform linux/arm64 --load -t campfire-ocaml:m7-t3-arm64 \
  --build-arg APP_VERSION=m7-test --build-arg GIT_REVISION=local .
python3 scripts/m7_image_lifecycle.py --image campfire-ocaml:m7-t3-arm64
```

`CAMPFIRE_REQUIRE_MEDIA_VECTORS` applies to the focused media executables.
Both `test/m6_t2_test.exe` and `test/m6_t3_test.exe`
passed their six strict cases with that variable set inside the final amd64
image, mounted at the repository's test directory. Reproduction:

```sh
dune build test/m6_t2_test.exe test/m6_t3_test.exe
projects_dir="$(dirname "$PWD")"
for suite in m6_t2 m6_t3; do
  docker run --rm \
    --entrypoint "$PWD/_build/default/test/${suite}_test.exe" \
    -v "$projects_dir:$projects_dir:rw" -w "$PWD/test" \
    -e CAMPFIRE_REQUIRE_MEDIA_VECTORS=1 campfire-ocaml:m7-t3
done
```

The final amd64 image ID
after package pins and clean signal handling was
`sha256:4a4c24c2425bc31c9cc1e5bcf026f88ab7358c7d5fcb57a7ba1fe0dd3cec8500`.
The final arm64 image ID was
`sha256:d7649972b7143ac106326ec38c32baa715c8f4529b6223823c355c1846f14426`.
These are local image IDs, not pushed registry manifest digests. The arm64
build used `tonistiigi/binfmt:qemu-v9.2.2` (pulled image digest
`sha256:1b804311fe87047a4c96d38b4b3ef6f62fca8cd125265917a9e3dc3c996c39e6`)
because the local host is amd64. Inside the arm64 image, `uname -m` returned
`aarch64`, both OCaml executables started, Caddy adapted the generated config,
and Debian reported the same pinned Caddy, libvips, and ffmpeg versions.

The copied Rails default-seed lifecycle passed on both final image
architectures: old Rails image, OCaml
upgrade, OCaml restart, OCaml pre-backup/post-restore, and Rails rollback all
served `/up` 200. The final OCaml image exited 0 after Docker SIGTERM at both
upgrade and restart stops. The 14 existing blob files retained their SHA256 hashes;
the database retained 169 messages, all table definitions, and integrity.
OCaml added only `index_messages_on_room_id_and_created_at` and
`index_messages_on_room_id_and_updated_at`; the pinned Rust
`crates/db/src/schema.rs` creates those same two indexes on boot. An initial
test stopped the Rails rollback process immediately after `/up` and left the
disposable DB corrupt. The successful check waits three seconds for Rails
workers, verifies the DB while running, then stops; this shutdown sensitivity
remains a lifecycle stress case for the manager to assess.

The ONCE CLI is absent on this host. ONCE validation here covers the image
contract and hooks with Docker, not an actual remote `once deploy`.

## Remaining checks

- Run the published workflow and inspect the pushed multiarchitecture digest
  in a release environment. Its registry credentials and remote ONCE host are
  not available in this local task.
- The front's short-lived ACME renewal and real prior Thruster cache checks
  are tracked in M7-T1. Full differential and browser gates remain M8 work.

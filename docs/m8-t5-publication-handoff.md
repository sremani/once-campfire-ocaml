# 2a511ac publication and ONCE deployment handoff

The public repository is `https://github.com/sremani/once-campfire-ocaml`.
Tag `v0.1.0` points to verified source `2a511ac6f74fc3689f72bd039bc11d286e71d1c4`.
The [successful publication run](https://github.com/sremani/once-campfire-ocaml/actions/runs/38031979097)
published and signed the image at
`ghcr.io/sremani/once-campfire-ocaml@sha256:3215a11e11ee5cfb1c5b37ce4312a7292b6e5fe85fb5cfe451c556fcd42a7154`.
Both published architecture images passed independent inventory, copied-install
lifecycle, TLS/ACME/Cable, and signed-media checks. No ONCE deployment has
occurred: the target host and `once` CLI access are still missing.
The browser and post-browser local gates in
`/tmp/m8-2a511ac-post-browser-checks.md` are complete. If a publication
review requires a source change, freeze the new revision and repeat its local
release checks before using this handoff.

## Freeze the source being released

The locally verified code revision is
`2a511ac6f74fc3689f72bd039bc11d286e71d1c4`, at
`/tmp/campfire-browser-2a511ac`. The main checkout is ahead by documentation
commits. The published tag is pinned to that verified revision:

```sh
SOURCE=/tmp/campfire-browser-2a511ac
SOURCE_REV=2a511ac6f74fc3689f72bd039bc11d286e71d1c4
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$SOURCE_REV"
test -z "$(git -C "$SOURCE" status --porcelain=v1 --untracked-files=all)"
git -C "$SOURCE" show "$SOURCE_REV:.github/workflows/publish-image.yml" >/dev/null
# The annotated v0.1.0 tag has already been pushed to origin.
```

A tag push matching `v*` triggers `.github/workflows/publish-image.yml`.
`workflow_dispatch` is also available; avoid an unreviewed default-branch run.
The workflow also publishes on `main` pushes. It runs source provenance and
Dune tests, builds native amd64/arm64 images, inventories each before push,
creates multiarchitecture tags, and signs those tags with Cosign OIDC. Check
both architecture jobs and the manifest/sign job in the exact tag run. Its
per-architecture inventories are written in runner temp and are not uploaded
as durable artifacts.

## Verify the published artifact

The values below come from the actual GitHub repository and tag. The workflow
lowercases `github.repository` for GHCR. Its
CI image has a release `APP_VERSION` and nonempty OCI source label, whereas
the local candidate uses the source revision as `APP_VERSION` and has an empty
OCI source label. The registry image IDs therefore need independent review.

```sh
SOURCE=/tmp/campfire-browser-2a511ac
SOURCE_REV=2a511ac6f74fc3689f72bd039bc11d286e71d1c4
IMAGE_REPO=ghcr.io/sremani/once-campfire-ocaml
RELEASE_TAG=v0.1.0
docker buildx imagetools inspect "$IMAGE_REPO:$RELEASE_TAG" \
  | tee /tmp/campfire-2a511ac-published-manifest.txt
docker buildx imagetools inspect --raw "$IMAGE_REPO:$RELEASE_TAG" \
  > /tmp/campfire-2a511ac-published-manifest.json
docker buildx imagetools inspect "$IMAGE_REPO:$RELEASE_TAG-amd64" \
  > /tmp/campfire-2a511ac-published-amd64.txt
docker buildx imagetools inspect "$IMAGE_REPO:$RELEASE_TAG-arm64" \
  > /tmp/campfire-2a511ac-published-arm64.txt
python3 - <<'PY'
import json
p='/tmp/campfire-2a511ac-published-manifest.json'
x=json.load(open(p))
platforms={(m.get('platform',{}).get('os'),m.get('platform',{}).get('architecture'))
           for m in x['manifests']}
assert {('linux','amd64'),('linux','arm64')} <= platforms, platforms
print('published platforms:', sorted(platforms))
PY
# Record the immutable top-level sha256 digest printed by imagetools inspect.
# Confirm its amd64/arm64 child digests match the inspected architecture tags.
# Resolve and review the index digest before setting PUBLISHED_DIGEST.
PUBLISHED_DIGEST=sha256:3215a11e11ee5cfb1c5b37ce4312a7292b6e5fe85fb5cfe451c556fcd42a7154
```

Run the following inventory on each matching architecture, or with working
arm64 emulation for the arm64 image. The exact published architecture tags
from the tag event are
`$IMAGE_REPO:$RELEASE_TAG-amd64` and
`$IMAGE_REPO:$RELEASE_TAG-arm64`. Pull and audit them against the clean source
before relying on the CI-only inventory:

```sh
for arch in amd64 arm64; do
  docker pull "$IMAGE_REPO:$RELEASE_TAG-$arch"
  python3 "$SOURCE/scripts/release_image_inventory.py" \
    --image "$IMAGE_REPO:$RELEASE_TAG-$arch" \
    --revision "$SOURCE_REV" \
    --output "/tmp/campfire-2a511ac-published-$arch-inventory.json"
done
```

Inspect each JSON for zero issues, exact architecture, `GIT_REVISION` equal to
`SOURCE_REV`, expected packaged assets and licenses, and the actual GHCR OCI
source label. Keep the manifest JSON, top-level digest, architecture image
IDs and CI run URL together. Re-run copied-install lifecycle and protocol/media
checks against the pulled architecture images, or otherwise produce evidence
for the exact published digests: the local 2a511ac image IDs are not the
published artifacts. Review Cosign signatures and the workflow's architecture
attestations against the same immutable digest; the workflow does not itself
run a post-push manifest/platform inspection.

## Prepare the existing ONCE installation

Confirm the actual ONCE CLI and `once deploy --help` on the operator machine;
CLI syntax has not been checked here because `once` is absent. The repository
documents `once deploy IMAGE --host HOST`. Record the current deployed image
**digest**, preserve the existing `SECRET_KEY_BASE`, and take a verified backup
of `/rails/storage` before changing the image. That storage includes `db`,
`files`, `backups`, and `thruster`; keep TLS/Caddy certificate storage too.
Ensure the target host can pull the public GHCR package.
The local copied-install rehearsal preserved 169 messages and 14 blob hashes
on both architectures; it is not a remote backup or deployment result.

After the publication and exact-digest checks and host review, use the
documented CLI form with explicit values:

```sh
: "${ONCE_HOST:?set the existing ONCE host}"
IMAGE_REPO=ghcr.io/sremani/once-campfire-ocaml
PUBLISHED_DIGEST=sha256:3215a11e11ee5cfb1c5b37ce4312a7292b6e5fe85fb5cfe451c556fcd42a7154
: "${OLD_IMAGE_REF:?record current immutable image reference for rollback}"
once deploy "$IMAGE_REPO@$PUBLISHED_DIGEST" --host "$ONCE_HOST"
# Verify /up, login, messages, attachments, search, Cable, TLS and backup.
# If rollback is required: once deploy "$OLD_IMAGE_REF" --host "$ONCE_HOST"
```

If data restore is required, stop the app first and use the existing ONCE
backup/restore flow and `/hooks/post-restore`; do not invent a CLI restore
command. Save deployment and rollback outputs, resulting digest, health checks,
backup reference, and architecture chosen by the host. M8-T5 remains open
until the actual deployment is evidenced.

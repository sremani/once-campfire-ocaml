#!/usr/bin/env python3
"""Record and verify the checked-in release inputs without Docker or network access."""

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def files_under(path):
    return sorted(p for p in (ROOT / path).rglob("*") if p.is_file())


def file_record(path):
    return {"path": str(path.relative_to(ROOT)), "sha256": sha256(path)}


def tree_record(paths):
    entries = [file_record(path) for path in sorted(paths)]
    digest = hashlib.sha256()
    for entry in entries:
        digest.update(entry["path"].encode())
        digest.update(b"\0")
        digest.update(entry["sha256"].encode())
        digest.update(b"\0")
    return {"count": len(entries), "sha256": digest.hexdigest(), "files": entries}


def verify_gumbo(provenance):
    expected = provenance["files"]
    patches = provenance["local_patches"]
    integration = provenance.get("ocaml_integration", {})
    errors = []
    for name, upstream_hash in expected.items():
        local = ROOT / "vendor/gumbo" / name
        if not local.is_file():
            errors.append(f"missing Gumbo file: {name}")
            continue
        if name in integration:
            wanted = integration[name]["local_sha256"]
            if patches[name]["local_sha256"] != integration[name]["input_sha256"]:
                errors.append(f"Gumbo integration input mismatch: {name}")
        elif name in patches:
            wanted = patches[name]["local_sha256"]
        else:
            wanted = upstream_hash
        if sha256(local) != wanted:
            errors.append(f"Gumbo local checksum mismatch: {name}")
    for details in [*patches.values(), *integration.values()]:
        patch = ROOT / "vendor/gumbo" / details["patch"]
        if not patch.is_file() or sha256(patch) != details["patch_sha256"]:
            errors.append(f"Gumbo patch checksum mismatch: {details['patch']}")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, help="write JSON here instead of stdout")
    args = parser.parse_args()
    provenance = json.loads((ROOT / "vendor/gumbo/provenance.json").read_text())
    gumbo_errors = verify_gumbo(provenance)
    dockerfile = (ROOT / "Dockerfile").read_text()
    base_images = dict(re.findall(r"^ARG (DEBIAN_IMAGE|UBUNTU_BUILD_IMAGE)=(.+)$", dockerfile, re.M))
    static_files = files_under("assets/files")
    manifest = {
        "schema": "campfire-ocaml-source-manifest-v1",
        "source_revision": git("rev-parse", "HEAD"),
        "source_dirty": bool(git("status", "--porcelain")),
        "base_images": base_images,
        "gumbo": {
            "upstream_commit": provenance["commit"],
            "upstream_archive_sha256": provenance["archive_sha256"],
            "local_checksum_errors": gumbo_errors,
            "tree": tree_record(files_under("vendor/gumbo")),
        },
        "cable_websocket": {
            "upstream_commit": "133eda58386c43b95fed21ba1921cbc37b629b98",
            "license": "ISC",
            "tree": tree_record(files_under("vendor/cable_websocket")),
        },
        "static_assets": tree_record(static_files),
        "application_sources": tree_record(files_under("bin") + files_under("lib")),
        "c_stubs": tree_record(sorted((ROOT / "lib").glob("*_stubs.c"))),
        "release_files": tree_record(
            [ROOT / path for path in (
                "LICENSE", "Dockerfile", "dune-project", "once_campfire_ocaml.opam",
                ".github/workflows/publish-image.yml", "assets/manifest.json",
                "assets/built_at.txt", "assets/README.md", "deploy/boot",
                "hooks/pre-backup", "hooks/post-restore",
            )]
        ),
    }
    payload = json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(payload)
    else:
        sys.stdout.write(payload)
    if gumbo_errors:
        print("\n".join(gumbo_errors), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

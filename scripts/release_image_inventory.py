#!/usr/bin/env python3
"""Audit a local release image against the checked-out distribution files.

The result is a portable JSON record for each architecture. It deliberately
uses an isolated, read-only container and does not start the Campfire service.
"""

import argparse
import hashlib
import json
import re
import shlex
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
COPIED_FILES = {
    "/rails/assets/manifest.json": ROOT / "assets/manifest.json",
    "/rails/assets/README.md": ROOT / "assets/README.md",
    "/usr/share/doc/once-campfire-ocaml/LICENSE": ROOT / "LICENSE",
    "/usr/share/doc/once-campfire-ocaml/CABLE-WEBSOCKET-LICENSE.md": ROOT
    / "vendor/cable_websocket/LICENSE.md",
    "/usr/share/doc/once-campfire-ocaml/GUMBO-LICENSE-DEPENDENCIES.md": ROOT
    / "vendor/gumbo/LICENSE-DEPENDENCIES.md",
    "/usr/share/doc/once-campfire-ocaml/GUMBO-PROVENANCE.json": ROOT
    / "vendor/gumbo/provenance.json",
    "/rails/bin/boot": ROOT / "deploy/boot",
    "/hooks/pre-backup": ROOT / "hooks/pre-backup",
    "/hooks/post-restore": ROOT / "hooks/post-restore",
}


def run(*argv, cwd=None):
    return subprocess.run(
        argv, check=True, capture_output=True, text=True, cwd=cwd,
    ).stdout


def in_image(image, script):
    return run(
        "docker", "run", "--rm", "--network", "none", "--read-only",
        "--entrypoint", "/bin/sh", image, "-ec", script,
    )


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def hash_lines(output):
    result = {}
    for line in output.splitlines():
        digest, path = line.split("  ", 1)
        if len(digest) != 64 or path in result:
            raise ValueError(f"invalid or duplicate SHA-256 entry: {line!r}")
        result[path] = digest
    return result


def package_lines(output):
    packages = []
    for line in output.splitlines():
        name, version, architecture = line.split("\t")
        if not all((name, version, architecture)):
            raise ValueError(f"incomplete package inventory entry: {line!r}")
        packages.append({"name": name, "version": version, "architecture": architecture})
    return packages


def audit(image, revision):
    info = json.loads(run("docker", "image", "inspect", image))[0]
    config = info["Config"]
    env = dict(item.split("=", 1) for item in config["Env"])
    issues = []
    source_revision = run("git", "rev-parse", "HEAD", cwd=ROOT).strip()
    source_dirty = bool(run("git", "status", "--porcelain", cwd=ROOT).strip())
    if revision and source_revision != revision:
        issues.append("checked-out source revision differs from the requested revision")
    if revision and source_dirty:
        issues.append("checked-out source is dirty")
    if config["User"] != "1000:1000":
        issues.append("image user is not 1000:1000")
    if config["WorkingDir"] != "/rails":
        issues.append("image workdir is not /rails")
    if config["Cmd"] != ["bin/boot"]:
        issues.append("image command is not bin/boot")
    if not {"80/tcp", "443/tcp"}.issubset(config["ExposedPorts"]):
        issues.append("image does not expose both HTTP and HTTPS ports")
    if revision and env.get("GIT_REVISION") != revision:
        issues.append("GIT_REVISION does not match the requested source revision")
    if not env.get("GIT_REVISION"):
        issues.append("GIT_REVISION is empty")

    copied = in_image(image, "sha256sum " + " ".join(COPIED_FILES))
    image_hashes = hash_lines(copied)
    for image_path, source_path in COPIED_FILES.items():
        if image_hashes[image_path] != sha256(source_path):
            issues.append(f"packaged file differs from source: {image_path}")

    asset_output = in_image(
        image, "find /rails/assets/files -type f -exec sha256sum {} +",
    )
    image_assets = {
        path.removeprefix("/rails/assets/files/"): digest
        for path, digest in hash_lines(asset_output).items()
    }
    source_assets = {
        str(path.relative_to(ROOT / "assets/files")): sha256(path)
        for path in (ROOT / "assets/files").rglob("*") if path.is_file()
    }
    if image_assets != source_assets:
        issues.append("packaged asset path/hash inventory differs from source")

    packages = package_lines(in_image(
        image, "dpkg-query -W -f='${Package}\\t${Version}\\t${Architecture}\\n'",
    ))
    builder_packages = package_lines(in_image(
        image, "cat /usr/share/doc/once-campfire-ocaml/build-packages.tsv",
    ))
    if not builder_packages:
        issues.append("build-stage package inventory is empty")
    builder_notices = hash_lines(in_image(
        image,
        "find /usr/share/doc/once-campfire-ocaml/build-copyrights -type f "
        "-exec sha256sum {} +",
    ))
    expected_builder_notices = {
        "/usr/share/doc/once-campfire-ocaml/build-copyrights/"
        + package["name"] + ".copyright" for package in builder_packages
    }
    if set(builder_notices) != expected_builder_notices:
        issues.append("build-stage copyright notices do not cover the package inventory")
    missing_notices = in_image(
        image,
        "dpkg-query -W -f='${Package}\\n' | while IFS= read -r package; do "
        "test -f \"/usr/share/doc/$package/copyright\" || printf '%s\\n' \"$package\"; "
        "done",
    ).splitlines()
    if missing_notices:
        issues.append(f"{len(missing_notices)} installed packages lack copyright files")
    runtime_notice_paths = [
        "/usr/share/doc/" + package["name"] + "/copyright"
        for package in packages if package["name"] not in missing_notices
    ]
    runtime_notices = hash_lines(in_image(
        image, "sha256sum "
        + " ".join(shlex.quote(path) for path in runtime_notice_paths),
    ))

    binaries = {}
    library_paths = set()
    for path in ("/usr/local/bin/campfire", "/usr/local/bin/campfire-front"):
        linked = in_image(image, "ldd " + path)
        if "not found" in linked:
            issues.append(f"unresolved linked library in {path}")
        for line in linked.splitlines():
            candidate = (line.split("=>", 1)[-1] if "=>" in line else line).strip()
            library_path = candidate.split(" ", 1)[0]
            if library_path.startswith("/"):
                library_paths.add(library_path)
        binaries[path] = {
            "sha256": hash_lines(in_image(image, "sha256sum " + path))[path],
            "ldd": [re.sub(r" \(0x[0-9a-f]+\)$", "", line) for line in linked.splitlines()],
        }
    linked_library_hashes = hash_lines(in_image(
        image, "sha256sum " + " ".join(shlex.quote(path) for path in sorted(library_paths)),
    ))

    return {
        "image": image,
        "image_id": info["Id"],
        "architecture": info["Architecture"],
        "os": info["Os"],
        "git_revision": env.get("GIT_REVISION"),
        "source_revision": source_revision,
        "source_dirty": source_dirty,
        "app_version": env.get("APP_VERSION"),
        "oci_labels": config.get("Labels") or {},
        "copied_files": image_hashes,
        "asset_count": len(image_assets),
        "asset_hashes": image_assets,
        "packages": packages,
        "builder_packages": builder_packages,
        "builder_copyright_hashes": builder_notices,
        "missing_package_copyright": missing_notices,
        "runtime_copyright_hashes": runtime_notices,
        "binaries": binaries,
        "linked_library_hashes": linked_library_hashes,
        "issues": issues,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True, help="local image tag or digest")
    parser.add_argument("--revision", help="expected GIT_REVISION")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = audit(args.image, args.revision)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        f"{result['architecture']} {result['image_id']}: "
        f"{len(result['packages'])} runtime packages, "
        f"{len(result['builder_packages'])} builder packages, "
        f"{result['asset_count']} assets, "
        f"{len(result['issues'])} issues; {args.output}"
    )
    for issue in result["issues"]:
        print("- " + issue)
    raise SystemExit(bool(result["issues"]))


if __name__ == "__main__":
    main()

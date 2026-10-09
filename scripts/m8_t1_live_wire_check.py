#!/usr/bin/env python3
"""Run bounded front wire probes on disposable pinned-seed image copies."""

import argparse
import glob
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import urllib.request
import uuid

from m8_t1_wire_probe import h2_idle, raw_query


ROOT = Path(__file__).resolve().parents[1]
SEED = ROOT.parent / "once-campfire-rust/parity/.seed/default"
ENV = ROOT.parent / "once-campfire-rust/parity/.env.reference"


def docker(*args):
    return subprocess.run(
        ["docker", *args], check=True, capture_output=True, text=True,
    ).stdout.strip()


def storage_copy(path):
    (path / "db").mkdir(parents=True)
    shutil.copytree(SEED / "storage", path / "files")
    for source in glob.glob(str(SEED / "db/production.sqlite3*")):
        shutil.copy2(source, path / "db")


def start(image, path, label):
    name = f"campfire-m8-t1-{label}-{uuid.uuid4().hex[:8]}"
    docker(
        "run", "-d", "--name", name, "-p", "127.0.0.1::80",
        "--env-file", str(ENV), "-v", f"{path}:/rails/storage",
        "-e", "DISABLE_SSL=1", "-e", "THRUSTER_H2C_ENABLED=1",
        "-e", "H2C_ENABLED=1",
        "-e", "THRUSTER_HTTP_IDLE_TIMEOUT=2",
        "-e", "HTTP_IDLE_TIMEOUT=2",
        "-e", "THRUSTER_HTTP_READ_TIMEOUT=1",
        "-e", "HTTP_READ_TIMEOUT=1", image,
    )
    try:
        port = int(docker("port", name, "80/tcp").rsplit(":", 1)[1])
        for _ in range(80):
            try:
                with urllib.request.urlopen(
                    f"http://127.0.0.1:{port}/up", timeout=1,
                ) as response:
                    if response.status == 200:
                        return name, port
            except Exception:
                pass
            if docker("inspect", "--format", "{{.State.Running}}", name) != "true":
                break
            time.sleep(0.25)
        raise RuntimeError(f"{label} image did not serve /up")
    except Exception:
        stop(name)
        raise


def stop(name):
    try:
        docker("stop", "-t", "15", name)
    finally:
        docker("rm", "-f", name)


def probe_h2(port, path):
    args = argparse.Namespace(host="127.0.0.1", port=port, path=path,
        timeout=5.0, min_idle=1.8, max_idle=3.5)
    h2_idle(args)
    return "pass"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--rust-image", default="campfire-rust:app")
    parser.add_argument("--h2-path", default="/session/new")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not SEED.is_dir() or not ENV.is_file():
        raise RuntimeError("pinned seed or disposable environment file is missing")
    names = []
    result = {"ocaml_image": args.image, "rust_image": args.rust_image}
    try:
        with tempfile.TemporaryDirectory(prefix="campfire-m8-t1-wire-") as temp:
            root = Path(temp)
            rust_storage, ocaml_storage = root / "rust", root / "ocaml"
            storage_copy(rust_storage)
            storage_copy(ocaml_storage)
            rust_name, rust_port = start(args.rust_image, rust_storage, "rust")
            names.append(rust_name)
            ocaml_name, ocaml_port = start(args.image, ocaml_storage, "ocaml")
            names.append(ocaml_name)
            result["rust_image_id"] = docker("image", "inspect", "--format", "{{.Id}}", args.rust_image)
            result["ocaml_image_id"] = docker("image", "inspect", "--format", "{{.Id}}", args.image)
            for label, port in (("rust", rust_port), ("ocaml", ocaml_port)):
                try:
                    result[label + "_h2_idle"] = probe_h2(port, args.h2_path)
                except Exception as error:
                    result[label + "_h2_idle"] = f"fail: {error}"
            queries = {}
            for target in (b"/session/new?a=%", b"/session/new?a=%G0",
                           b"/session/new?a=%FF", b"/session/new/%ZZ"):
                pair = {}
                for label, port in (("rust", rust_port), ("ocaml", ocaml_port)):
                    try:
                        pair[label] = raw_query("127.0.0.1", port, target)
                    except Exception as error:
                        pair[label] = {"error": str(error)}
                queries[target.decode("ascii")] = pair
            result["raw_targets"] = queries
            result["issues"] = [
                label + " HTTP/2 idle did not meet the pinned deadline"
                for label in ("rust", "ocaml")
                if result[label + "_h2_idle"] != "pass"
            ]
            for target, pair in queries.items():
                if pair["rust"] != pair["ocaml"]:
                    result["issues"].append("raw target differs: " + target)
    finally:
        for name in reversed(names):
            try:
                stop(name)
            except Exception:
                pass
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps({key: value for key, value in result.items()
                      if key in ("rust_h2_idle", "ocaml_h2_idle", "raw_targets", "issues")},
                     indent=2, sort_keys=True))
    raise SystemExit(bool(result["issues"]))


if __name__ == "__main__":
    main()

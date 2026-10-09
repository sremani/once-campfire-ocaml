#!/usr/bin/env python3
"""Check an old-image -> OCaml -> old-image ONCE lifecycle on copied fixtures.

Requires Docker and the pinned Rails seed/reference image. Never prints secrets.
"""

import argparse
import glob
import hashlib
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import time
import urllib.request
import uuid


ROOT = Path(__file__).resolve().parent.parent
SEED = ROOT.parent / "once-campfire-rust/parity/.seed/default"
ENV = ROOT.parent / "once-campfire-rust/parity/.env.reference"


def docker(*args):
    return subprocess.run(["docker", *args], check=True, capture_output=True, text=True).stdout.strip()


def digest_files(path):
    hashes = {}
    for file in sorted(path.rglob("*")):
        if file.is_file():
            hashes[str(file.relative_to(path))] = hashlib.sha256(file.read_bytes()).hexdigest()
    return hashes


def database_state(path):
    # Docker stop can return a moment before the reference's child process
    # releases its WAL mapping. Require a clean integrity check after it settles.
    for attempt in range(50):
        try:
            return _database_state(path)
        except sqlite3.OperationalError:
            if attempt == 49:
                raise
            time.sleep(0.2)


def _database_state(path):
    assert path.is_file(), path
    with sqlite3.connect(path) as db:
        assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        names = [row[0] for row in db.execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
        counts = {name: db.execute(f'SELECT COUNT(*) FROM "{name}"').fetchone()[0]
                  for name in names if not name.startswith("sqlite_")}
        schema = "\n".join(row[0] for row in db.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND sql IS NOT NULL ORDER BY name"))
        indexes = {row[0] for row in db.execute(
            "SELECT name FROM sqlite_master WHERE type='index'")}
    return counts, hashlib.sha256(schema.encode()).hexdigest(), indexes


def secret():
    for line in ENV.read_text().splitlines():
        if line.startswith("SECRET_KEY_BASE="):
            return line
    raise RuntimeError("pinned fixture secret is missing")


def start(image, storage, environment, label):
    name = f"campfire-m7-t3-{label}-{uuid.uuid4().hex[:8]}"
    docker("run", "-d", "--name", name, "-p", "127.0.0.1::80",
           "-v", f"{storage}:/rails/storage", "--env-file", str(environment), image)
    address = docker("port", name, "80/tcp")
    port = int(address.rsplit(":", 1)[1])
    for _ in range(120):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/up", timeout=1) as response:
                if response.status == 200:
                    return name
        except Exception:
            pass
        if docker("inspect", "--format", "{{.State.Running}}", name) != "true":
            break
        time.sleep(0.25)
    stop(name)
    raise RuntimeError(f"{label} image did not serve /up (check container logs)")


def stop(name):
    try:
        docker("stop", "-t", "15", name)
        return int(docker("inspect", "--format", "{{.State.ExitCode}}", name))
    finally:
        docker("rm", "-f", name)


def one_shot(image, storage, environment, command):
    docker("run", "--rm", "--entrypoint", command,
           "-v", f"{storage}:/rails/storage", "--env-file", str(environment), image)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", default="campfire-ocaml:m7-t3")
    parser.add_argument("--old-image", default="campfire-reference:app")
    args = parser.parse_args()
    if not SEED.exists():
        raise RuntimeError("build the pinned default Rails seed first")

    with tempfile.TemporaryDirectory(prefix="campfire-m7-image-") as temp:
        storage = Path(temp) / "storage"
        (storage / "db").mkdir(parents=True)
        shutil.copytree(SEED / "storage", storage / "files")
        for source in glob.glob(str(SEED / "db/production.sqlite3*")):
            shutil.copy2(source, storage / "db")
        environment = Path(temp) / "fixture.env"
        environment.write_text(secret() + "\nRAILS_ENV=production\nDISABLE_SSL=1\n")
        environment.chmod(0o600)
        original_blobs = digest_files(storage / "files")
        original_counts, original_schema, original_indexes = database_state(
            storage / "db/production.sqlite3")

        for label, image in [("old", args.old_image), ("upgrade", args.image),
                             ("restart", args.image)]:
            name = start(image, storage, environment, label)
            exit_code = stop(name)
            if image == args.image:
                assert exit_code == 0, f"{label} container exited {exit_code} on SIGTERM"
            assert digest_files(storage / "files") == original_blobs, label
            counts, schema, _ = database_state(storage / "db/production.sqlite3")
            assert schema == original_schema, label
            assert counts.get("messages") == original_counts.get("messages"), label

        one_shot(args.image, storage, environment, "/hooks/pre-backup")
        snapshot = storage / "backups/production.sqlite3"
        snapshot_counts, snapshot_schema, upgrade_indexes = database_state(snapshot)
        assert snapshot_schema == original_schema
        assert snapshot_counts.get("messages") == original_counts.get("messages")
        (storage / "db/production.sqlite3").write_bytes(b"disposable damaged database")
        one_shot(args.image, storage, environment, "/hooks/post-restore")
        assert not (storage / "db/production.sqlite3-wal").exists()
        assert not (storage / "db/production.sqlite3-shm").exists()
        restored_counts, restored_schema, _ = database_state(storage / "db/production.sqlite3")
        assert restored_counts == snapshot_counts and restored_schema == snapshot_schema

        name = start(args.old_image, storage, environment, "rollback")
        time.sleep(3)
        running_counts, running_schema, _ = database_state(storage / "db/production.sqlite3")
        assert running_schema == original_schema
        assert running_counts.get("messages") == original_counts.get("messages")
        stop(name)
        assert digest_files(storage / "files") == original_blobs
        rollback_counts, rollback_schema, _ = database_state(storage / "db/production.sqlite3")
        assert rollback_schema == original_schema
        assert rollback_counts.get("messages") == original_counts.get("messages")
        print(f"old/upgrade/restart/rollback /up=200; "
              "OCaml SIGTERM=0; "
              f"{len(original_blobs)} blob SHA256 checksums stable; "
              f"{original_counts.get('messages')} messages stable; "
              f"{len(upgrade_indexes - original_indexes)} additive indexes; "
              "backup/restore integrity and table schema stable")


if __name__ == "__main__":
    main()

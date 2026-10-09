#!/usr/bin/env python3
"""Disposable pinned-seed check for M7-T2; prints no fixture credentials."""

import glob
import http.client
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import sqlite3
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
RUST = ROOT.parent / "once-campfire-rust"
EXE = ROOT / "_build/default/bin/main.exe"


def secret():
    with (RUST / "parity/.env.reference").open() as source:
        for line in source:
            if line.startswith("SECRET_KEY_BASE="):
                return line.rstrip("\n").split("=", 1)[1]
    raise RuntimeError("pinned test secret is missing")


def port_number():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def response(port, path, headers=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
    try:
        conn.request("GET", path, headers=headers or {})
        answer = conn.getresponse()
        answer.read()
        return answer.status, answer.headers
    finally:
        conn.close()


def ready(proc, port):
    for _ in range(100):
        try:
            return response(port, "/up")
        except OSError:
            if proc.poll() is not None:
                raise RuntimeError(f"server exited before readiness: {proc.returncode}")
            time.sleep(0.05)
    raise RuntimeError("server did not become ready")


def read_frame(sock, pending=b""):
    while len(pending) < 2:
        pending += sock.recv(4096)
    opcode = pending[0] & 15
    size = pending[1] & 127
    offset = 2
    if size == 126:
        while len(pending) < 4:
            pending += sock.recv(4096)
        size = int.from_bytes(pending[2:4], "big")
        offset = 4
    elif size == 127:
        while len(pending) < 10:
            pending += sock.recv(4096)
        size = int.from_bytes(pending[2:10], "big")
        offset = 10
    while len(pending) < offset + size:
        pending += sock.recv(4096)
    return opcode, pending[offset : offset + size], pending[offset + size :]


def websocket(port, cookie):
    sock = socket.create_connection(("127.0.0.1", port), timeout=5)
    sock.settimeout(5)
    request = (
        f"GET /cable HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        "Sec-WebSocket-Protocol: actioncable-v1-json\r\n"
        f"Origin: https://127.0.0.1:{port}\r\nCookie: {cookie}\r\n\r\n"
    )
    sock.sendall(request.encode())
    head = b""
    while b"\r\n\r\n" not in head:
        head += sock.recv(4096)
    headers, pending = head.split(b"\r\n\r\n", 1)
    assert headers.split(b" ", 2)[1] == b"101", "WebSocket upgrade failed"
    _, body, pending = read_frame(sock, pending)
    assert json.loads(body).get("type") == "welcome", "Cable welcome missing"
    return sock, pending


def main():
    if not EXE.exists():
        raise RuntimeError("run dune build before this check")
    fixture = json.loads((ROOT / "test/fixtures/campfire_sessions.json").read_text())
    cookie = fixture["sessions"][0]["cookie_header"]
    with tempfile.TemporaryDirectory(prefix="campfire-m7-live-") as temporary:
        storage = Path(temporary)
        database_dir = storage / "db"
        database_dir.mkdir()
        for source in glob.glob(str(RUST / "parity/.seed/default/db/production.sqlite3*")):
            shutil.copy2(source, database_dir)
        environment = dict(os.environ, CAMPFIRE_STORAGE_PATH=str(storage),
                           SECRET_KEY_BASE=secret(), TLS_DOMAIN="example.test")
        subprocess.run([str(EXE), "backup"], env=environment,
                       check=True, capture_output=True, timeout=15)
        backup = storage / "backups/production.sqlite3"
        with sqlite3.connect(backup) as db:
            assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
            count = db.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
        restored = storage / "restored.sqlite3"
        shutil.copy2(backup, restored)
        with sqlite3.connect(restored) as db:
            assert db.execute("SELECT COUNT(*) FROM messages").fetchone()[0] == count

        port = port_number()
        production = dict(environment, THRUSTER_TARGET_PORT=str(port))
        proc = subprocess.Popen([str(EXE), "server"], env=production,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        sock = None
        try:
            status, headers = ready(proc, port)
            assert status == 200
            assert headers.get("strict-transport-security") == (
                "max-age=63072000; includeSubDomains")
            status, headers = response(port, "/up?x=1", {
                "Host": "example.test:8080", "X-Campfire-Front": "caddy",
                "X-Forwarded-Proto": "http"})
            assert status == 301
            assert headers.get("location") == "https://example.test/up?x=1"
            sock, pending = websocket(port, cookie)
            proc.send_signal(signal.SIGTERM)
            _, body, _ = read_frame(sock, pending)
            restart = json.loads(body)
            assert restart.get("reason") == "server_restart"
            assert restart.get("reconnect") is True
            proc.wait(timeout=15)
            assert proc.returncode == 0
        finally:
            if sock is not None:
                sock.close()
            if proc.poll() is None:
                proc.kill()
                proc.wait()

        port = port_number()
        plain = dict(environment, DISABLE_SSL="1", THRUSTER_TARGET_PORT=str(port))
        proc = subprocess.Popen([str(EXE), "server"], env=plain,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            status, _ = ready(proc, port)
            assert status == 200
            proc.send_signal(signal.SIGINT)
            proc.wait(timeout=15)
            assert proc.returncode == 0
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
        print(f"backup/restore={count} messages; direct /up=200; "
              "trusted-front HTTP=301; Cable restart=ok; "
              "SIGTERM/SIGINT=0")


if __name__ == "__main__":
    main()

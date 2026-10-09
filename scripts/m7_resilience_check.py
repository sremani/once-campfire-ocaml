#!/usr/bin/env python3
"""Disposable live M7 timeout and shutdown checks; no production credentials.

Run one case with --case NAME after building bin/main.exe.
"""

import argparse
from contextlib import contextmanager
import glob
import http.client
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import urllib.request


ROOT = Path(__file__).resolve().parent.parent
SEED = ROOT.parent / "once-campfire-rust/parity/.seed/default/db"
EXE = ROOT / "_build/default/bin/main.exe"


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@contextmanager
def server(*, read_timeout=1):
    with tempfile.TemporaryDirectory(prefix="campfire-m7-resilience-") as temp:
        root = Path(temp)
        (root / "db").mkdir()
        for source in glob.glob(str(SEED / "production.sqlite3*")):
            shutil.copy2(source, root / "db")
        port = free_port()
        environment = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "SECRET_KEY_BASE_DUMMY": "1",
            "RAILS_ENV": "production",
            "DISABLE_SSL": "1",
            "CAMPFIRE_STORAGE_PATH": str(root),
            "HTTP_READ_TIMEOUT": str(read_timeout),
            "HTTP_IDLE_TIMEOUT": "1",
            "HTTP_WRITE_TIMEOUT": "1",
        }
        proc = subprocess.Popen(
            [str(EXE), "serve", "--port", str(port)], env=environment,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            for _ in range(100):
                try:
                    with urllib.request.urlopen(
                        f"http://127.0.0.1:{port}/up", timeout=1
                    ) as response:
                        assert response.status == 200
                        break
                except OSError:
                    if proc.poll() is not None:
                        raise RuntimeError("target exited before readiness")
                    time.sleep(0.05)
            else:
                raise RuntimeError("target did not become ready")
            yield proc, port
        finally:
            if proc.poll() is None:
                proc.send_signal(signal.SIGTERM)
                try:
                    proc.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()


def slow_body(port):
    sock = socket.create_connection(("127.0.0.1", port), timeout=3)
    sock.settimeout(3)
    sock.sendall(
        b"POST /up HTTP/1.1\r\nHost: localhost\r\n"
        b"Content-Type: application/x-www-form-urlencoded\r\n"
        b"Content-Length: 12\r\nConnection: close\r\n\r\na="
    )
    return sock


def graceful_early():
    with server() as (proc, port):
        with slow_body(port) as sock:
            time.sleep(0.25)
            proc.send_signal(signal.SIGTERM)
            time.sleep(0.25)
            assert proc.poll() is None, "active request was abandoned immediately"
            sock.sendall(b"x" * 10)
            try:
                reply = sock.recv(4096)
            except ConnectionResetError:
                reply = b""
            assert reply.startswith(b"HTTP/1.1"), "active request got no response"
            proc.wait(timeout=12)
            assert proc.returncode == 0
            print("active request completed during shutdown; exit 0")


def graceful_deadline():
    # The request read deadline must outlast the shutdown grace in this case.
    with server(read_timeout=30) as (proc, port):
        with slow_body(port):
            time.sleep(0.25)
            start = time.monotonic()
            proc.send_signal(signal.SIGTERM)
            proc.wait(timeout=12)
            elapsed = time.monotonic() - start
            assert proc.returncode == 0
            assert 9 <= elapsed <= 11.5, f"shutdown grace was {elapsed:.2f}s"
            print(f"stalled request abandoned after {elapsed:.2f}s; exit 0")


def direct_read_timeout():
    with server() as (_, port):
        with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
            sock.settimeout(3)
            sock.sendall(b"GET /up HTTP/1.1\r\nHost: localhost\r\n")
            time.sleep(2.2)
            try:
                sock.sendall(b"Connection: close\r\n\r\n")
                reply = sock.recv(1024)
            except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError):
                reply = b""
            assert not reply.startswith(b"HTTP/1.1 200"), (
                "direct target accepted headers after HTTP_READ_TIMEOUT=1"
            )
            print("direct target closed slow partial header")


def direct_idle_timeout():
    with server() as (_, port):
        with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
            sock.settimeout(3)
            sock.sendall(b"GET /up HTTP/1.1\r\nHost: localhost\r\n\r\n")
            response = http.client.HTTPResponse(sock)
            response.begin()
            assert response.status == 200
            response.read()
            time.sleep(2.2)
            try:
                sock.sendall(b"GET /up HTTP/1.1\r\nHost: localhost\r\n\r\n")
                reply = sock.recv(1024)
            except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError):
                reply = b""
            assert not reply.startswith(b"HTTP/1.1 200"), (
                "direct target kept connection after HTTP_IDLE_TIMEOUT=1"
            )
            print("direct target closed idle keepalive connection")


def direct_body_timeout():
    with server() as (_, port):
        with slow_body(port) as sock:
            time.sleep(2.2)
            try:
                sock.sendall(b"x" * 10)
                reply = sock.recv(1024)
            except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError):
                reply = b""
            assert not reply.startswith(b"HTTP/1.1 200"), (
                "direct target accepted a body stalled past HTTP_READ_TIMEOUT=1"
            )
            print("direct target closed stalled request body")


def direct_active_upload():
    # The total transfer outlives READ_TIMEOUT; each chunk arrives before it.
    with server() as (_, port):
        boundary = b"BOUNDARY"
        head = (b"--BOUNDARY\r\nContent-Disposition: form-data; "
                b'name="upload"; filename="large.bin"\r\n'
                b"Content-Type: application/octet-stream\r\n\r\n")
        data = b"x" * (256 * 1024)
        tail = b"\r\n--BOUNDARY--\r\n"
        length = len(head) + len(data) * 5 + len(tail)
        with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
            sock.settimeout(5)
            sock.sendall(
                b"POST /up HTTP/1.1\r\nHost: localhost\r\n"
                b"Content-Type: multipart/form-data; boundary=BOUNDARY\r\n"
                + f"Content-Length: {length}\r\nConnection: close\r\n\r\n".encode()
                + head
            )
            for _ in range(5):
                sock.sendall(data)
                time.sleep(0.35)
            sock.sendall(tail)
            reply = sock.recv(1024)
            assert reply.startswith(b"HTTP/1.1 404"), (
                f"active upload was interrupted: {reply[:80]!r}"
            )
            print("streamed upload exceeded total read timeout without interruption")


def direct_header_limit():
    with server() as (_, port):
        with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
            sock.settimeout(3)
            try:
                sock.sendall(b"GET /up HTTP/1.1\r\nHost: localhost\r\n"
                             + b"X-Fill: " + b"a" * (65 * 1024) + b"\r\n\r\n")
                reply = sock.recv(1024)
            except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError):
                reply = b""
            assert not reply.startswith(b"HTTP/1.1 200"), (
                "direct target accepted headers above its configured bound"
            )
            print("direct target rejected oversized headers")


CASES = {
    "graceful-early": graceful_early,
    "graceful-deadline": graceful_deadline,
    "direct-read-timeout": direct_read_timeout,
    "direct-idle-timeout": direct_idle_timeout,
    "direct-body-timeout": direct_body_timeout,
    "direct-active-upload": direct_active_upload,
    "direct-header-limit": direct_header_limit,
}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--case", choices=CASES, required=True)
    arguments = parser.parse_args()
    CASES[arguments.case]()

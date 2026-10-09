#!/usr/bin/env python3
"""Bounded live kit/front probes against disposable loopback listeners.

This script never starts servers or loads credentials. Start the pinned Rust and
OCaml default-seed listeners separately, then select a probe; see the M8-T1
vector inventory for exact setup and expected behavior.
"""

import argparse
import hashlib
import http.client
import socket
import struct
import time


PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
SETTINGS = 0x4
HEADERS = 0x1
RST_STREAM = 0x3
GOAWAY = 0x7
END_STREAM = 0x1


def frame(kind, flags=0, stream=0, payload=b""):
    assert len(payload) < (1 << 24)
    return len(payload).to_bytes(3, "big") + bytes([kind, flags]) + struct.pack(
        "!I", stream
    ) + payload


def recv_exact(sock, size):
    chunks = []
    while size:
        chunk = sock.recv(size)
        if not chunk:
            if chunks:
                raise RuntimeError("HTTP/2 connection ended mid-frame")
            return None
        chunks.append(chunk)
        size -= len(chunk)
    return b"".join(chunks)


def read_frame(sock):
    header = recv_exact(sock, 9)
    if header is None:
        return None
    length = int.from_bytes(header[:3], "big")
    if length > 1 << 20:
        raise RuntimeError(f"unexpected HTTP/2 frame size {length}")
    payload = recv_exact(sock, length)
    if payload is None:
        raise RuntimeError("HTTP/2 frame payload missing")
    return header[3], header[4], struct.unpack("!I", header[5:])[0] & 0x7FFFFFFF, payload


def hpack_get(path, authority):
    """Static HPACK entries for GET and HTTP, with literal :path/:authority."""
    for value in (path, authority):
        if not 0 < len(value) < 127 or not value.isascii():
            raise ValueError("path and authority must be short ASCII strings")
    return (b"\x82\x86\x04" + bytes([len(path)]) + path.encode()
            + b"\x01" + bytes([len(authority)]) + authority.encode())


def h2_idle(args):
    start = time.monotonic()
    deadline = start + args.timeout
    authority = f"{args.host}:{args.port}"
    with socket.create_connection((args.host, args.port), timeout=3) as sock:
        sock.sendall(PREFACE + frame(SETTINGS)
                     + frame(HEADERS, END_STREAM | 0x4, 1,
                             hpack_get(args.path, authority)))
        response_complete = None
        saw_headers = False
        saw_goaway = False
        frames = 0
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("HTTP/2 connection did not close within bounded deadline")
            sock.settimeout(remaining)
            received = read_frame(sock)
            if received is None:
                break
            kind, flags, stream, payload = received
            frames += 1
            if kind == SETTINGS and not (flags & 0x1):
                sock.sendall(frame(SETTINGS, 0x1))
            if kind == HEADERS and stream == 1:
                saw_headers = True
            if kind == RST_STREAM and stream == 1:
                raise RuntimeError("server reset the probe stream")
            if stream == 1 and flags & END_STREAM and kind in (HEADERS, 0x0):
                response_complete = time.monotonic()
            if kind == GOAWAY:
                saw_goaway = True
        if not saw_headers or response_complete is None:
            raise RuntimeError("HTTP/2 response did not complete before connection close")
        elapsed = time.monotonic() - response_complete
        print(f"h2c response complete; EOF after {elapsed:.3f}s; "
              f"GOAWAY={saw_goaway}; frames={frames}")
        if not args.min_idle <= elapsed < args.max_idle:
            raise AssertionError(
                f"idle close outside [{args.min_idle}, {args.max_idle}) seconds"
            )


def raw_query(host, port, target):
    with socket.create_connection((host, port), timeout=3) as sock:
        sock.settimeout(8)
        sock.sendall(
            b"GET " + target + b" HTTP/1.1\r\n"
            + f"Host: {host}:{port}\r\n".encode()
            + b"Accept-Encoding: identity\r\nConnection: close\r\n\r\n"
        )
        response = http.client.HTTPResponse(sock)
        response.begin()
        body = response.read()
        return {
            "status": response.status,
            "content_type": response.getheader("Content-Type"),
            "body_sha256": hashlib.sha256(body).hexdigest(),
            "body_size": len(body),
        }


def query(args):
    targets = (b"/session/new?a=%", b"/session/new?a=%G0",
               b"/session/new?a=%FF")
    mismatches = []
    for target in targets:
        rust = raw_query(args.host, args.rust_port, target)
        ocaml = raw_query(args.host, args.ocaml_port, target)
        print(f"{target.decode('ascii')}: rust={rust}; ocaml={ocaml}")
        if rust["status"] != 400 or ocaml["status"] != 400 or rust != ocaml:
            mismatches.append(target.decode("ascii"))
    if mismatches:
        raise AssertionError("raw malformed-query differences: " + ", ".join(mismatches))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    h2 = commands.add_parser("h2-idle", help="time a completed H2C response to TCP EOF")
    h2.add_argument("--host", default="127.0.0.1")
    h2.add_argument("--port", type=int, required=True)
    h2.add_argument("--path", default="/up")
    h2.add_argument("--timeout", type=float, default=5.0)
    h2.add_argument("--min-idle", type=float, default=1.8)
    h2.add_argument("--max-idle", type=float, default=3.5)
    malformed = commands.add_parser("malformed-query", help="compare literal invalid queries")
    malformed.add_argument("--host", default="127.0.0.1")
    malformed.add_argument("--rust-port", type=int, required=True)
    malformed.add_argument("--ocaml-port", type=int, required=True)
    args = parser.parse_args()
    (h2_idle if args.command == "h2-idle" else query)(args)


if __name__ == "__main__":
    main()

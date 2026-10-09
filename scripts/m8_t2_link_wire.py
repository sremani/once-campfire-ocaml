#!/usr/bin/env python3
"""Compare pinned full-page stylesheet Link wire headers with HEAD, 304 and frame.

Run after m8_t2_http_state.py has started both independent default-seed servers.
Only pinned fixture credentials are sent; no credential or response body is printed.
"""
import argparse
import http.client
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUST = ROOT.parent / "once-campfire-rust"
EXPECTED = (RUST / "crates/assets/tests/reference/link_header.txt").read_text()
COOKIE = json.loads((ROOT / "test/fixtures/campfire_sessions.json").read_text())["sessions"][0]["cookie_header"]


def send(port, method, path, *, signed=False, frame=None, etag=None):
    headers = {"Host": "campfire.test", "Accept-Encoding": "identity",
               "X-Request-Id": "m8-t2-link-wire",
               "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) Chrome/126.0.0.0"}
    if signed:
        headers["Cookie"] = COOKIE
    if frame is not None:
        headers["Turbo-Frame"] = frame
    if etag:
        headers["If-None-Match"] = etag
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    try:
        connection.request(method, path, headers=headers)
        response = connection.getresponse()
        response.read()
        return response.status, response.getheader("Link"), response.getheader("ETag")
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rust-port", type=int, default=3228)
    parser.add_argument("--ocaml-port", type=int, default=3230)
    args = parser.parse_args()
    results = []
    for side, port in (("rust", args.rust_port), ("ocaml", args.ocaml_port)):
        full = send(port, "GET", "/session/new")
        head = send(port, "HEAD", "/session/new")
        conditional = send(port, "GET", "/session/new", etag=full[2])
        sidebar_full = send(port, "GET", "/users/me/sidebar", signed=True)
        sidebar_frame = send(port, "GET", "/users/me/sidebar", signed=True, frame="sidebar")
        health = send(port, "GET", "/up")
        for name, actual, expected_status, expected_link in (
            ("full", full, 200, EXPECTED),
            ("head", head, 200, EXPECTED),
            ("conditional", conditional, 304, EXPECTED),
            ("sidebar_full", sidebar_full, 200, EXPECTED),
            ("sidebar_frame", sidebar_frame, 200, None),
            ("health", health, 200, None),
        ):
            ok = actual[0] == expected_status and actual[1] == expected_link
            results.append((side, name, actual[0], ok))
            print(f"{side} {name}: status={actual[0]} link={'exact' if ok else 'MISMATCH'}")
    if not all(row[3] for row in results):
        raise SystemExit(1)
    by_side = {side: {name: status for s, name, status, _ in results if s == side}
               for side, _, _, _ in results}
    if by_side["rust"] != by_side["ocaml"]:
        raise SystemExit("status mismatch")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Check complete static asset framing through a running disposable listener."""

import argparse
import gzip
import http.client
from pathlib import Path
from urllib.parse import urlsplit


ASSET = "/assets/_reset-9c3efd7b.css"
EXPECTED = Path(__file__).resolve().parents[1] / "assets/files" / ASSET.lstrip("/")


def get(base: str, encoding: str) -> tuple[int, dict[str, str], bytes]:
    parsed = urlsplit(base)
    assert parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost")
    connection = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=5)
    try:
        connection.request("GET", ASSET, headers={"Accept-Encoding": encoding})
        response = connection.getresponse()
        body = response.read()
        return response.status, dict(response.getheaders()), body
    finally:
        connection.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True, help="disposable local OCaml server")
    args = parser.parse_args()
    expected = EXPECTED.read_bytes()
    for attempt in range(2):
        status, headers, body = get(args.base, "gzip")
        assert status == 200, (attempt, status)
        assert headers.get("content-encoding") == "gzip", headers
        assert "content-length" not in headers or int(headers["content-length"]) == len(body), headers
        assert gzip.decompress(body) == expected, attempt
    status, headers, body = get(args.base, "identity")
    assert status == 200 and "content-encoding" not in headers, headers
    assert len(body) == len(expected) and body == expected
    print("PASS: gzip cold/cache responses and identity CSS complete on wire")


if __name__ == "__main__":
    main()

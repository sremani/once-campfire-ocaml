#!/usr/bin/env python3
"""Compare search page sections with direct pinned Rust Askama renders."""

import hashlib
from pathlib import Path
import subprocess
import sys


root = Path(__file__).resolve().parents[1]
exe = str(Path(sys.argv[1]).resolve())
expected = {
    "searches_index_empty": (4069, "c60a69ad58cabe4bb316683d9f61723cf0a495b30ead71c371a67641d256b6bf"),
    "searches_index": (14898, "b612dc0812f1847164c103ddc2a7b506ae66a939b9be5951f76818bdf7ebed7b"),
}
sections = (
    (b'<nav id="nav">', b'</nav>', True),
    (b'<div id="message-area"', b'<footer id="footer">', False),
    (b'<div class="composer flex', b'<aside id="sidebar"', False),
    (b'<aside id="sidebar"', b'</aside>', True),
)
for name, (length, digest) in expected.items():
    body = subprocess.run(
        [exe, "--dump-search-case", name], cwd=root,
        capture_output=True, check=True,
    ).stdout
    chunks = []
    for start, end, include_end in sections:
        first = body.index(start)
        last = body.index(end, first) + (len(end) if include_end else 0)
        chunks.append(body[first:last])
    view = b"".join(chunks)
    actual = hashlib.sha256(view).hexdigest()
    if len(view) != length or actual != digest:
        print(f"{name}: expected {length}/{digest[:12]}, got {len(view)}/{actual[:12]}")
        raise SystemExit(1)
    print(f"{name}: {length} pinned Rust section bytes match")

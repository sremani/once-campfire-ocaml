#!/usr/bin/env python3
"""Assert pinned Askama room-form nav/main bytes, including menu spacing."""

import hashlib
from pathlib import Path
import subprocess
import sys


root = Path(__file__).resolve().parents[1]
renderer = str(Path(sys.argv[1]).resolve())
# Captured from the pinned Rust campfire_views rooms::{Opens,Closeds}{New,Edit}
# renderer with crates/views/tests/golden/b/rooms_{opens,closeds}_{new,edit}.json.
expected = {
    "rooms_opens_new": ((255, "ac3113dab54d32f33f2b6775613747164246e7fc8a8181c9cefea04e2dd783ef"),
                        (7287, "da0ca1d082ee44e4b3078ee51fef8a7805f5d18efc7d28c4ef96b5093bb6531c")),
    "rooms_opens_edit": ((255, "ac3113dab54d32f33f2b6775613747164246e7fc8a8181c9cefea04e2dd783ef"),
                         (7894, "f13567219ec80619bd28118e2ff229bb6a05289152c348dc2c833740adad8d7b")),
    "rooms_closeds_new": ((255, "ac3113dab54d32f33f2b6775613747164246e7fc8a8181c9cefea04e2dd783ef"),
                          (7965, "a5e2742da946d4710128970a3e9faa86ffb08fa3562bc831197543aa6c7a85ad")),
    "rooms_closeds_edit": ((255, "ac3113dab54d32f33f2b6775613747164246e7fc8a8181c9cefea04e2dd783ef"),
                           (8820, "1b9257757a8c2a89d8171de23ae2965f081af7c67eb5e45dca63cc5f70dbea0b")),
}
for case, sections in expected.items():
    body = subprocess.run([renderer, "--dump-room-form", case], cwd=root,
                          capture_output=True, check=True).stdout
    for tag, (size, digest) in zip((b"nav", b"main"), sections):
        start = body.index(b"<" + tag + b" ")
        end = body.index(b"</" + tag + b">", start) + len(tag) + 3
        fragment = body[start:end]
        actual = hashlib.sha256(fragment).hexdigest()
        if len(fragment) != size or actual != digest:
            print(f"{case}/{tag.decode()}: expected {size}/{digest[:12]}, "
                  f"got {len(fragment)}/{actual[:12]}")
            raise SystemExit(1)
    print(f"{case}: pinned Rust nav/main bytes match")

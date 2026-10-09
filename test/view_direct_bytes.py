#!/usr/bin/env python3
"""Check the direct-room form against the pinned Rust DirectsNew template."""

import hashlib
from pathlib import Path
import subprocess
import sys


root = Path(__file__).resolve().parents[1]
body = subprocess.run(
    [str(Path(sys.argv[1]).resolve()), "--dump-direct-new"],
    cwd=root, capture_output=True, check=True,
).stdout
start = b'<turbo-frame id="direct_rooms_control"'
end = b'</turbo-frame>'
first = body.index(start)
last = body.index(end, first) + len(end)
fragment = body[first:last]
expected = "5a253addc9d488e7a75c843a39fdf0051f00ee073a55a986f60daa2a1a8e75ce"
actual = hashlib.sha256(fragment).hexdigest()
if len(fragment) != 2405 or actual != expected:
    print(f"direct_new: expected 2405/{expected[:12]}, got {len(fragment)}/{actual[:12]}")
    raise SystemExit(1)
print("direct_new: 2405 pinned Rust fragment bytes match")

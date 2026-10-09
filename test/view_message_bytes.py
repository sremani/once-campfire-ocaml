#!/usr/bin/env python3
"""Byte fixtures rendered directly by pinned Rust campfire_views templates.

The 12-message index includes rich text, images, audio, attachments, and
boosts. Each digest was captured from the pinned Rust `messages::Index` or
`messages::MessagePartial` using the matching b golden input/context.
"""

import hashlib
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
CASES = {
    "messages_index": (124594, "f9abeec152f1c4c5a8d7ac68d847897136bded30663d580a503a26623b8375ba"),
    "messages_show_text": (9328, "12cd9512b49f81b3f01fc7a8be7659085cffca0f5d7cdeb8134af36318d207ef"),
    "messages_show_image": (10851, "fbf8857ad5a5536e1ed11569cf2a29c2c6d85186670e93ece6bf9227a08147d7"),
}


def main(exe: Path) -> int:
    for name, (length, digest) in CASES.items():
        body = subprocess.run(
            [str(exe), "--dump-b-messages", name], cwd=ROOT,
            capture_output=True, check=True
        ).stdout
        actual = hashlib.sha256(body).hexdigest()
        if len(body) != length or actual != digest:
            print(f"{name}: expected {length} bytes/{digest[:12]}, got {len(body)}/{actual[:12]}")
            return 1
        print(f"{name}: {length} pinned Rust bytes match")
    created = subprocess.run(
        [str(exe), "--dump-message"], cwd=ROOT,
        capture_output=True, check=True,
    ).stdout
    created_digest = hashlib.sha256(created).hexdigest()
    expected_digest = "3abe99bacd62ee64bfb57a0635205d56f11f6806e6a0048558027c362cfce286"
    if len(created) != 9234 or created_digest != expected_digest:
        print(f"messages_create: expected 9234/{expected_digest[:12]}, "
              f"got {len(created)}/{created_digest[:12]}")
        return 1
    print("messages_create: 9234 pinned Rust Turbo stream bytes match")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(Path(sys.argv[1]).resolve()))

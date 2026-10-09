#!/usr/bin/env python3
"""Compare the sidebar frame with pinned Rails bytes, excluding Rails' CSRF field.

The pinned Rust helper omits authenticity_token because request forgery checks
use Sec-Fetch-Site. The Rails goldens include that one hidden field in each
button_to form. Every remaining byte of the frame must match.
"""

from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
GOLDEN = ROOT / "test/fixtures"
TOKEN = re.compile(rb'<input type="hidden" name="authenticity_token" value="[^"]*" />')


def rust_cached_partial_spacing(body: bytes) -> bytes:
    """The Rust cache helper drops Rails' final newline at these boundaries."""
    body = body.replace(b"</a>\n        </div>\n\n        <div contents>",
                        b"</a>        </div>\n\n        <div contents>")
    body = body.replace(b"</button></form>\n        </div>",
                        b"</button></form>        </div>")
    body = body.replace(b"</a>\n          <a id=\"list_rooms_",
                        b"</a>          <a id=\"list_rooms_")
    body = body.replace(b"</a>\n      </div>\n\n        <a class=\"rooms__new-btn",
                        b"</a>      </div>\n\n        <a class=\"rooms__new-btn")
    return body


def frame(body: bytes) -> bytes:
    start = body.rfind(b"<turbo-frame", 0, body.index(b'id="user_sidebar"'))
    tags = re.finditer(rb"<turbo-frame\b|</turbo-frame>", body[start:])
    depth = 0
    for tag in tags:
        depth += 1 if tag.group() == b"<turbo-frame" else -1
        if depth == 0:
            return body[start : start + tag.end()]
    raise AssertionError("sidebar frame has no closing tag")


def main(exe: Path) -> int:
    for name, args in (
        ("sidebar_frame", ["--dump-sidebar"]),
        ("sidebar_david", ["--dump-sidebar-full", "sidebar_david"]),
        ("sidebar_kevin", ["--dump-sidebar-full", "sidebar_kevin"]),
    ):
        expected = rust_cached_partial_spacing(TOKEN.sub(
            b"", frame((GOLDEN / f"views_{name}.html").read_bytes())))
        actual = frame(subprocess.run(
            [str(exe), *args], cwd=ROOT, check=True, capture_output=True
        ).stdout)
        if actual != expected:
            print(f"{name}: sidebar bytes differ ({len(expected)} Rust, {len(actual)} OCaml)")
            return 1
        print(f"{name}: {len(expected)} sidebar bytes match")
    for name in ("shared_room", "shared_room_unread"):
        expected = (GOLDEN / f"views_{name}.html").read_bytes()
        actual = subprocess.run(
            [str(exe), "--dump-shared-room", name], cwd=ROOT,
            check=True, capture_output=True
        ).stdout
        if actual != expected:
            print(f"{name}: sidebar partial bytes differ")
            return 1
        print(f"{name}: {len(expected)} sidebar partial bytes match")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(Path(sys.argv[1]).resolve()))

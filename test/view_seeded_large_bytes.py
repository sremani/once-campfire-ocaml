#!/usr/bin/env python3
"""Check large seeded view responses against pinned Rust body digests.

Only response sizes and hashes are stored here. The fixture paths and session
cookie stay in their existing local test fixtures and are never printed.
"""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys


root = Path(__file__).resolve().parents[1]
if os.getenv("CAMPFIRE_RUST_ROOT"):
    rust = Path(os.environ["CAMPFIRE_RUST_ROOT"]).expanduser().resolve()
else:
    common_git = Path(subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--path-format=absolute", "--git-common-dir"],
        capture_output=True, check=True, text=True,
    ).stdout.strip())
    rust = next(
        candidate for candidate in (
            root.parent / "once-campfire-rust",
            common_git.parent.parent / "once-campfire-rust",
        )
        if (candidate / "parity/.seed/crowd/labels.json").exists()
    )
spec = importlib.util.spec_from_file_location(
    "m8_routes", root / "scripts/m8_t2_http_state.py"
)
routes_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(routes_module)
routes = json.loads((root / "test/fixtures/campfire_routes.json").read_text())["routes"]
labels = json.loads((rust / "parity/.seed/crowd/labels.json").read_text())
sessions = json.loads((root / "test/fixtures/campfire_sessions.json").read_text())
exe = str(Path(sys.argv[1]).resolve())

# The account pagination frame and two open/two closed room forms exercised
# the same Rails whitespace/void-tag serialization edge in the crowd seed.
# The first-run page uses the pinned golden form's Rails serialization.
cases = (
    ("crowd", 43, "signed", 950788, "6b0553dcb82f0e01ff6dcb95231a0fe8f4349af58a6e178d342a5b5a0a032df1"),
    ("crowd", 106, "signed", 439742, "b1ce81795f37b2160405956cc26f67047a8629b8e671ee9eaa77d34a6fcd2dde"),
    ("crowd", 107, "signed", 440380, "ef19c348e344312cf2c63610c90afe4ba3ea2fd3a922aeee9054b45aa16c7d63"),
    ("crowd", 114, "signed", 521116, "67141061d755c5f258d90d76b3cfbadd00a09e434c776fc71e0196836bf1c411"),
    ("crowd", 115, "signed", 521963, "754af29119ec42596cd983eddef2991c9414e22466aa487544c5984df17849bc"),
    ("first_run", 3, "anonymous", 26440, "97b433dcae8216038d2e416bc313c00ef697e22a7036d4f4edeebf02c7517569"),
)
for seed, row, role, length, expected_digest in cases:
    env = os.environ.copy()
    env["M4_T2_PROBE_SEED"] = seed
    selected_labels = labels if seed == "crowd" else json.loads(
        (rust / "parity/.seed/first_run/labels.json").read_text()
    )
    env["M4_T2_PROBE_PATH"] = routes_module.concrete_path(
        routes[row], selected_labels, sessions
    )
    body = subprocess.run(
        [exe, str(row), role], cwd=root, env=env,
        capture_output=True, check=True,
    ).stdout
    actual_digest = hashlib.sha256(body).hexdigest()
    if len(body) != length or actual_digest != expected_digest:
        raise SystemExit(
            f"row {row}: expected {length}/{expected_digest[:12]}, "
            f"got {len(body)}/{actual_digest[:12]}"
        )
    print(f"{seed} row {row}: {length} Rust bytes match")

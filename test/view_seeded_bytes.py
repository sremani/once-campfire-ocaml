#!/usr/bin/env python3
"""Byte checks against pinned Rust HTTP captures on the default seed.

The expected digests contain no session, signed path, or response body data.
The offline OCaml probe uses the pinned test fixture credentials and clock.
"""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys


root = next(
    candidate for candidate in Path(__file__).resolve().parents
    if (candidate.parent / "once-campfire-rust/parity/.seed/default/labels.json").exists()
)
rust = root.parent / "once-campfire-rust"
spec = importlib.util.spec_from_file_location("m8_routes", root / "scripts/m8_t2_http_state.py")
routes_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(routes_module)
routes = json.loads((root / "test/fixtures/campfire_routes.json").read_text())["routes"]
labels = json.loads((rust / "parity/.seed/default/labels.json").read_text())
sessions = json.loads((root / "test/fixtures/campfire_sessions.json").read_text())
exe = str(Path(sys.argv[1]).resolve())
cases = (
    (8, "anonymous", 20624, "2ba794d671b2c3d97b380b751e44d0e9980340cd82b114130e1594b51878ebf7"),
    (28, "signed", 38500, "de84c7c2585d445e8d3925294cd2aafe432d3947d1f5cf741b509d7f3df33b71"),
    (30, "signed", 24484, "ebe88701671e80ea64726c5642c5ff0d5b8f74e8bc985c6ce0d4111718552c50"),
    (31, "signed", 25833, "8183533423557d7f1962f887ef456dee3e3c918630267e1f5f760b7e9335768f"),
    (39, "signed", 23662, "2a639a49344fa9ca473b6a90031099b843136527cb98c154f73f680704ceb642"),
    (43, "signed", 37630, "e142b92544a8ce5f95f916112ff1feea3c33e346f3d72bec20eafb5430d99041"),
    (49, "anonymous", 27281, "af5286598d43153245c1fae57bf35a3ee3c434b56356e1132b8fb7c793d24622"),
    (56, "signed", 30763, "8a31e5e0f6698b2794daceeec87f74676fad1f1e5349c7a4048589cbce76ec72"),
    (59, "signed", 41834, "0a5984f54d55daf3001fdcc8f9acba5854d03e5292589a5e37a355d774cda93a"),
    (65, "signed", 23151, "0ccd247130d6394ff8df4d86b0107a7c6f2bb0239ee7c0d0d205c82078e42380"),
    (73, "signed", 25218, "f1afc5fa949c89988693ae62df9f627a24801a3bd7e030d9d37947b2a6a4dc99"),
    (74, "signed", 8846, "4a07478af75676d1a1d9c34915351d42b0bf6317177234c55220c0f209073b26"),
    (92, "signed", 21144, "743677e586dad8b0f99326dd479ad9ce02bddd7d3194dc4cdefa3ca6c2b66263"),
    (128, "signed", 22691, "1d6947af92e3e596b938f0bd5336686b41c2add9a8972299341a1ad73aaaee24"),
    (130, "signed", 22146, "e63eab618b97b5f6fc59ecb3e6d60b0ba1f35697697e1ae9909b50c573c9da01"),
    (137, "signed", 20647, "79f1ae9935049d1f7f6b21c23eb9c4ac1a74ba9b4af0880e20b2ca3b8080b24a"),
)
for row, role, length, expected in cases:
    env = os.environ.copy()
    env["M4_T2_PROBE_PATH"] = routes_module.concrete_path(routes[row], labels, sessions)
    body = subprocess.run(
        [exe, str(row), role], cwd=root, env=env,
        capture_output=True, check=True,
    ).stdout
    actual = hashlib.sha256(body).hexdigest()
    if len(body) != length or actual != expected:
        print(f"row {row}: expected {length}/{expected[:12]}, "
              f"got {len(body)}/{actual[:12]}")
        raise SystemExit(1)
    print(f"row {row}: {length} seeded Rust bytes match")

#!/usr/bin/env python3
"""Run the two already-started localhost probe servers with the shared loadgen."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parents[3]
LOADGEN = Path(os.environ.get(
    "LOADGEN", ROOT / "once-campfire-verification/loadgen/target/release/loadgen"))
PROXIED = os.environ.get("PROXIED") == "1"
OUTPUT = Path(os.environ.get("OUTPUT", Path(__file__).with_name(
    "results-proxied.json" if PROXIED else "results.json")))
CLIENT_CPUS = os.environ.get("CLIENT_CPUS", "12-15")
PORTS = {"lwt": 25172, "async": 25173} if PROXIED else {"lwt": 25170, "async": 25171}
PATHS = ("/up", "/rooms/1")
CONCURRENCIES = (1, 16)


def load(backend, path, conc, seconds):
    cmd = ["taskset", "-c", CLIENT_CPUS, str(LOADGEN), "http",
           "--base", f"http://127.0.0.1:{PORTS[backend]}",
           "--path", path, "--conc", str(conc),
           "--duration", str(seconds), "--gzip", "0"]
    result = subprocess.run(cmd, text=True, capture_output=True, check=True)
    data = json.loads(result.stdout)
    if data["errors"] or data["invalid_responses"] or data["statuses"] != {"200": data["ok"]}:
        raise RuntimeError(f"invalid {backend} {path} {conc}: {data}")
    return data


def main():
    bodies = {}
    for backend, port in PORTS.items():
        for path in PATHS:
            with urlopen(f"http://127.0.0.1:{port}{path}") as response:
                assert response.status == 200
                bodies[backend, path] = response.read()
    for path in PATHS:
        assert bodies["lwt", path] == bodies["async", path]
    assert len(bodies["lwt", "/up"]) == 3
    assert len(bodies["lwt", "/rooms/1"]) == 21_267

    result = {
        "started_at": time.time(), "client_cpus": CLIENT_CPUS,
        "topology": "caddy" if PROXIED else "direct",
        "loadgen_sha256": hashlib.sha256(LOADGEN.read_bytes()).hexdigest(),
        "body_sha256": {path: hashlib.sha256(bodies["lwt", path]).hexdigest()
                        for path in PATHS},
        "samples": [],
    }
    for backend in PORTS:
        for path in PATHS:
            load(backend, path, 16, 1)
    for round_index in range(3):
        order = ("lwt", "async") if round_index % 2 == 0 else ("async", "lwt")
        for path in PATHS:
            for conc in CONCURRENCIES:
                for backend in order:
                    sample = load(backend, path, conc, 4)
                    result["samples"].append({"round": round_index + 1,
                                              "backend": backend, **sample})
                    OUTPUT.write_text(json.dumps(result, indent=2) + "\n")
                    print(f"round {round_index + 1} {backend} {path} {conc}: "
                          f"{sample['rps']:.1f} req/s", flush=True)


if __name__ == "__main__":
    main()

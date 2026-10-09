#!/usr/bin/env python3
"""Focused exact auxiliary HTTP differential on already running pinned servers.

Both servers must use independent copies of the same Rails seed and frozen clock.
This script does not start, stop, or reset Docker. Its report omits credentials,
raw response bodies, and signed headers. The full route gate is M8-T2's matrix.
"""

import argparse
import json
import subprocess
from pathlib import Path

from m8_t2_http_state import (
    RUST, RUST_REVISION, SESSIONS, changed, compare_response, has_session, request,
    snapshot,
)


def pinned_rust():
    actual = subprocess.run(
        ["git", "-C", str(RUST), "rev-parse", "HEAD"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    if actual != RUST_REVISION:
        raise RuntimeError(f"Rust source drift: {actual}")


def compare(label, method, path, role, args, labels, cookie):
    before = snapshot(args.rust_db), snapshot(args.ocaml_db)
    rust = request(args.rust_port, method, path, role, cookie, labels)
    ocaml = request(args.ocaml_port, method, path, role, cookie, labels)
    problems = compare_response(rust, ocaml)
    after = snapshot(args.rust_db), snapshot(args.ocaml_db)
    if before[0] != before[1]:
        problems.append("database baseline differs")
    if changed(before[0], after[0]) != changed(before[1], after[1]):
        problems.append("changed tables differ")
    if after[0] != after[1]:
        problems.append("database state differs")
    return {
        "case": label, "result": "pass" if not problems else "fail",
        "rust_status": rust["status"], "ocaml_status": ocaml["status"],
        "problems": problems,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", default="default", choices=(
        "default", "crowd", "custom_styles", "first_run", "restricted"))
    parser.add_argument("--rust-port", type=int, required=True)
    parser.add_argument("--ocaml-port", type=int, required=True)
    parser.add_argument("--rust-db", type=Path, required=True)
    parser.add_argument("--ocaml-db", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.rust_db.resolve() == args.ocaml_db.resolve():
        parser.error("Rust and OCaml must use independent database copies")
    pinned_rust()
    labels = json.loads((RUST / "parity/.seed" / args.seed / "labels.json").read_text())
    sessions = json.loads(SESSIONS.read_text())
    if not has_session(args.rust_db, sessions["sessions"][0]["session_id"]):
        parser.error("pinned signed session is absent from the Rust seed copy")
    if not has_session(args.ocaml_db, sessions["sessions"][0]["session_id"]):
        parser.error("pinned signed session is absent from the OCaml seed copy")
    cookie = sessions["sessions"][0]["cookie_header"]
    cases = [
        ("row 148 /webmanifest.json", "GET", "/webmanifest.json", "anonymous"),
        ("row 149 /service-worker.js", "GET", "/service-worker.js", "anonymous"),
        ("row 147 signed missing url", "POST", "/unfurl_link", "signed"),
    ]
    results = [compare(*case, args, labels, cookie) for case in cases]
    report = {"seed": args.seed, "rust_revision": RUST_REVISION,
              "cases": results,
              "counts": {"pass": sum(case["result"] == "pass" for case in results),
                         "fail": sum(case["result"] == "fail" for case in results)}}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["counts"]))
    return 0 if report["counts"]["fail"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())

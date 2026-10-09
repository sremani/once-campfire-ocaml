#!/usr/bin/env python3
"""Run M8-T2's isolated live HTTP/state matrix on the remaining Rails seeds."""
import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seeds", nargs="+", default=["crowd", "custom_styles", "first_run", "restricted"],
                        choices=["default", "crowd", "custom_styles", "first_run", "restricted"])
    parser.add_argument("--ocaml-binary", type=Path, required=True)
    parser.add_argument("--scenario", choices=["ordinary", "override", "malformed"],
                        default="ordinary")
    parser.add_argument("--roles", default="anonymous,signed,denied,bot")
    parser.add_argument("--rust-port", type=int, default=3228)
    parser.add_argument("--ocaml-port", type=int, default=3230)
    parser.add_argument("--ocaml-target-port", type=int, default=3229)
    parser.add_argument("--ocaml-network", default="container:campfire-m8-t2-network")
    parser.add_argument("--verification-checkout", type=Path,
                        help="Checkout of the pinned shared verification revision")
    args = parser.parse_args()
    binary = args.ocaml_binary.resolve(strict=True)
    for seed in args.seeds:
        ocaml_dir = Path(f"/tmp/campfire-m8-t2-isolated-{seed}-1000")
        suffix = "" if args.scenario == "ordinary" else f"-{args.scenario}"
        output = ROOT / "docs" / f"m8-t2-http-state-{seed}{suffix}.md"
        command = [sys.executable, str(ROOT / "scripts/m8_t2_http_state.py"),
                   "--seed", seed,
                   "--rust-port", str(args.rust_port),
                   "--ocaml-port", str(args.ocaml_port),
                   "--ocaml-target-port", str(args.ocaml_target_port),
                   "--rust-db", str(ROOT.parent / "once-campfire-rust/parity/.seed/.candidates" /
                                      str(args.rust_port) / "db/production.sqlite3"),
                   "--ocaml-db", str(ocaml_dir / "db/production.sqlite3"),
                   "--ocaml-seed-dir", str(ocaml_dir),
                   "--ocaml-container", "campfire-m8-t2-default-ocaml",
                   "--ocaml-network", args.ocaml_network,
                   "--ocaml-binary", str(binary),
                   "--output", str(output), "--scenario", args.scenario,
                   "--roles", args.roles, "--isolate"]
        if args.verification_checkout:
            command += ["--verification-checkout", str(args.verification_checkout.resolve(strict=True))]
        print(f"M8-T2: starting {seed} from independent seed copies", flush=True)
        subprocess.run(command, cwd=ROOT, check=True)
    print("M8-T2: all requested seed matrices completed", flush=True)


if __name__ == "__main__":
    main()

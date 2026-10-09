#!/usr/bin/env python3
"""Focused, redacted column-level SQLite differential for a pinned HTTP case."""
import argparse
import hashlib
import json
import sqlite3
from pathlib import Path

import m8_t2_http_state as parity


def rows(path, table):
    db = sqlite3.connect(path)
    try:
        columns = [row[1] for row in db.execute(f'PRAGMA table_info("{table}")')]
        data = [dict(zip(columns, row)) for row in db.execute(f'SELECT * FROM "{table}" ORDER BY rowid')]
        return data
    finally:
        db.close()


def safe(column, value):
    if value is None or isinstance(value, (int, float, bool)):
        return value
    if column in ("created_at", "updated_at", "last_seen_at", "last_active_at",
                  "ip_address", "last_ip_address", "name", "time_zone", "banned"):
        return value
    raw = value if isinstance(value, bytes) else str(value).encode()
    return {"sha256": hashlib.sha256(raw).hexdigest()[:16], "bytes": len(raw)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--row", type=int, required=True)
    parser.add_argument("--role", choices=("anonymous", "signed", "denied", "bot"), required=True)
    parser.add_argument("--table", action="append", required=True)
    parser.add_argument("--rust-port", type=int, default=3228)
    parser.add_argument("--ocaml-port", type=int, default=3230)
    parser.add_argument("--ocaml-target-port", type=int, default=3229)
    parser.add_argument("--ocaml-seed-dir", type=Path, default=Path("/tmp/campfire-m8-t2-isolated-default-1000"))
    args = parser.parse_args()
    routes = json.loads(parity.ROUTES.read_text())["routes"]
    labels = json.loads((parity.RUST / "parity/.seed/default/labels.json").read_text())
    sessions = json.loads(parity.SESSIONS.read_text())
    route = routes[args.row]
    parity.reset_isolated("default", args.rust_port, args.ocaml_target_port,
                          args.ocaml_port, args.ocaml_seed_dir,
                          "campfire-m8-t2-default-ocaml", "container:campfire-m8-t2-network", labels)
    rust_db = parity.RUST / f"parity/.seed/.candidates/{args.rust_port}/db/production.sqlite3"
    ocaml_db = args.ocaml_seed_dir / "db/production.sqlite3"
    path = parity.concrete_path(route, labels, sessions)
    cookie = sessions["sessions"][0]["cookie_header"]
    before = {table: {"rust": rows(rust_db, table), "ocaml": rows(ocaml_db, table)} for table in args.table}
    response = {"rust": parity.request(args.rust_port, route["verb"], path, args.role, cookie, labels),
                "ocaml": parity.request(args.ocaml_port, route["verb"], path, args.role, cookie, labels)}
    result = {"row": args.row, "role": args.role, "statuses": {side: value["status"] for side, value in response.items()},
              "tables": {}}
    for table in args.table:
        after = {"rust": rows(rust_db, table), "ocaml": rows(ocaml_db, table)}
        changes = []
        size = max(len(after["rust"]), len(after["ocaml"]))
        for index in range(size):
            left = after["rust"][index] if index < len(after["rust"]) else {}
            right = after["ocaml"][index] if index < len(after["ocaml"]) else {}
            for column in left.keys() | right.keys():
                if left.get(column) != right.get(column):
                    changes.append({"row_index": index, "column": column,
                                    "rust": safe(column, left.get(column)),
                                    "ocaml": safe(column, right.get(column))})
        result["tables"][table] = {"before_equal": before[table]["rust"] == before[table]["ocaml"],
                                    "rust_count": len(after["rust"]), "ocaml_count": len(after["ocaml"]),
                                    "differing_columns": changes}
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()

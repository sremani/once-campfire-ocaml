#!/usr/bin/env python3
"""Generate OCaml route declarations from the pinned Rust/Rails route vectors."""

import json
import pathlib
import sys


def quoted(value):
    return json.dumps(value, ensure_ascii=True)


def main(source, output):
    routes = json.loads(pathlib.Path(source).read_text())["routes"]
    lines = [
        "(* Generated from the pinned once-campfire-rust/vectors/campfire_routes.json. *)",
        "let routes = [",
    ]
    for route in routes:
        defaults = "; ".join(
            f"({quoted(key)}, {quoted(value)})"
            for key, value in route["defaults"].items()
        )
        lines.append(
            f"  ({quoted(route['verb'])}, {quoted(route['path'])}, "
            f"{quoted(route['endpoint'])}, [{defaults}]);"
        )
    lines.append("]")
    pathlib.Path(output).write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])

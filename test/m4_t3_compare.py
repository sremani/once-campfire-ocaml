#!/usr/bin/env python3
"""Compare the pinned Rails corpus with the OCaml Action Text converter.

The Rust-compatible mode applies exactly the deliberate divergences recorded in
once-campfire-rust/crates/richtext/tests/corpus.rs. It never changes the OCaml
output to match a Rails response that the Rust port intentionally made safer.
"""

import json
import html.parser
import hashlib
import os
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PRESENTATION_TAGS = set("""a abbr acronym address b big blockquote br cite code dd del
dfn div dl dt em h1 h2 h3 h4 h5 h6 hr i img ins kbd li mark ol p pre s samp
small span strong sub sup table tbody thead tfoot tr th td time tt u ul var""".split())
PRESENTATION_ATTRS = set("""abbr alt cite class datetime height href lang src title
width xml:lang data-language target""".split())


class SecurityAudit(html.parser.HTMLParser):
    """Browser-facing subset of the pinned Rust corpus security gate."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.violations = []

    def handle_starttag(self, tag, attrs):
        if tag not in PRESENTATION_TAGS:
            self.violations.append(f"<{tag}> outside allowlist")
        for name, value in attrs:
            if name not in PRESENTATION_ATTRS or name.startswith("on") or name == "style":
                self.violations.append(f"{name} on <{tag}> outside allowlist")
            if name in {"href", "src", "cite", "poster", "action", "formaction", "data"}:
                cleaned = re.sub(r"[\x00-\x20\x7f]", "", value or "").lower()
                if cleaned.startswith(("javascript:", "vbscript:", "livescript:")) or re.match(
                    r"data:[^,;]*(?:html|xml|svg|script|ecmascript)", cleaned
                ):
                    self.violations.append(f"unsafe {name} on <{tag}>")


def rust_presentation(rails):
    inserted = '<a target="_blank" href="'
    output = []
    state = "text"
    index = 0
    while index < len(rails):
        if state == "value" and rails.startswith(inserted, index):
            text_start = rails.find('\">', index) + 2
            text_end = rails.find("</a>", text_start)
            if text_start >= 2 and text_end >= 0:
                output.append(rails[text_start:text_end].replace(">", "&gt;"))
                index = text_end + 4
                continue
        if state == "tag" and rails.startswith(' name="', index):
            value_end = rails.find('"', index + len(' name="'))
            if value_end >= 0:
                index = value_end + 1
                continue
        char = rails[index]
        if state == "text" and char == "<":
            state = "tag"
        elif state == "tag" and char == ">":
            state = "text"
        elif state == "tag" and char == '"':
            state = "value"
        elif state == "value" and char == '"':
            state = "tag"
        output.append("&lt;" if state == "value" and char == "<" else
                      "&gt;" if state == "value" and char == ">" else char)
        index += 1
    return "".join(output)


def matches(case, actual, field, rust):
    expected = case[field]
    observed = actual[field]
    if field == "presentation":
        if "error" in expected:
            return "error" in observed
        value = observed.get("ok", "")  # Rails' message rescue returns blank HTML.
        if rust and "to_missing_attachable_partial_path" in (case.get("presentation_raised_message") or ""):
            return "☒" in value
        target = rust_presentation(expected["ok"]) if rust else expected["ok"]
        return target == value
    if field == "editable" and rust and "MissingAttachable" in expected.get("message", ""):
        # Rust accepts either a detached editable value or the same failed
        # lookup Rails reported; only a successful value is an intentional
        # divergence (corpus.rs:325-336).
        return "ok" in observed or "error" in observed
    if "error" in expected:
        return "error" in observed
    target = "<none>" if expected.get("ok") is None else expected["ok"]
    return observed.get("ok") == target


def direct_rust_matches(rust, ocaml, field):
    expected, observed = rust[field], ocaml[field]
    if field == "presentation":
        if "error" in expected:  # Rust's Unrenderable message variant.
            return "error" in observed
        # OCaml's render returns Error; present_message rescues it to blank HTML.
        return expected["ok"] == observed.get("ok", "")
    if "error" in expected:
        return "error" in observed
    value = expected["ok"]
    return observed.get("ok") == ("<none>" if field == "editable" and value is None else value)


def run_direct_rust(actual):
    fixture = ROOT / "test/fixtures/rich_text_expected.json"
    rust_fixture = ROOT.parent / "once-campfire-rust/crates/richtext/tests/corpus/expected.json"
    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    assert digest(fixture) == digest(rust_fixture), "OCaml and Rust fixtures differ"
    print(f"Pinned fixture SHA-256: {digest(fixture)}")
    env = os.environ.copy()
    env["RUSTC_WRAPPER"] = ""  # sccache cannot open its socket in this sandbox.
    env.setdefault("CARGO_TARGET_DIR", str(ROOT.parent / "once-campfire-rust/target"))
    output = subprocess.check_output(
        ["cargo", "run", "--manifest-path", "test/m4_t3_rust_oracle/Cargo.toml",
         "--locked", "--offline", "-q"], cwd=ROOT, text=True, env=env,
    )
    # splitlines() also treats U+2028 inside a JSON string as a line break.
    rows = [json.loads(line) for line in output.split("\n") if line]
    assert len(rows) == len(actual) == 658
    print("Direct pinned Rust")
    failed = False
    for field in ("presentation", "plain_text", "editable"):
        gaps = [rust["name"] for rust, ocaml in zip(rows, actual)
                if rust["name"] != ocaml["name"] or
                not direct_rust_matches(rust, ocaml, field)]
        print(f"  {field}: {658-len(gaps)}/658")
        if gaps:
            failed = True
            print(f"  remaining {field}: {', '.join(gaps)}")
    if failed:
        raise SystemExit("Direct pinned Rust corpus differs")


def main():
    expected = json.loads((ROOT / "test/fixtures/rich_text_expected.json").read_text())["cases"]
    output = subprocess.check_output(
        ["dune", "exec", "./test/m4_t3_test.exe", "--", "--dump-json"],
        cwd=ROOT, text=True,
    )
    actual = json.loads(output)
    assert len(expected) == len(actual) == 658
    fields = ("presentation", "plain_text", "editable")
    for rust in (False, True):
        print("Rust-compatible" if rust else "Raw Rails")
        for label, chosen in (
            ("all", lambda name: True),
            ("curated", lambda name: not name.startswith("fuzz ")),
            ("fuzz", lambda name: name.startswith("fuzz ")),
        ):
            cases = [(case, row) for case, row in zip(expected, actual)
                     if chosen(case["name"])]
            gaps = {field: [case["name"] for case, row in cases
                            if not matches(case, row, field, rust)] for field in fields}
            counts = ", ".join(f"{field} {len(cases) - len(gaps[field])}/{len(cases)}"
                               for field in fields)
            print(f"  {label}: {counts}")
            if rust and label == "fuzz":
                for field in fields:
                    if gaps[field]:
                        print(f"  remaining {field}: {', '.join(gaps[field])}")
            if rust and label == "curated" and any(gaps.values()):
                raise SystemExit("Rust-compatible curated corpus regressed")
    violations = []
    for row in actual:
        html = row["presentation"].get("ok", "")
        audit = SecurityAudit()
        audit.feed(html)
        violations.extend(f"{row['name']}: {v}" for v in audit.violations)
    print(f"Presentation security: {len(actual)} outputs, {len(violations)} violations")
    if violations:
        raise SystemExit("\n".join(violations[:20]))
    if "--direct-rust" in sys.argv[1:]:
        run_direct_rust(actual)


if __name__ == "__main__":
    main()

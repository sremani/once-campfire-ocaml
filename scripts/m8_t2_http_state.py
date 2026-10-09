#!/usr/bin/env python3
"""Live Rust/OCaml route and SQLite-state differential.

Start both pinned implementations on *independent copies* of one Rails parity
seed, at the same frozen clock.  This tool sends only pinned test credentials.
Its JSON and Markdown reports contain no cookie, bot key, CSRF token, or signed
URL.  A failed request is a failed case, never a skipped success.
"""

import argparse
import base64
import binascii
import email.utils
import hashlib
import hmac
import http.client
import json
import re
import shutil
import sqlite3
import subprocess
import time
from collections import Counter
from pathlib import Path
from urllib.parse import quote, unquote_plus

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.exceptions import InvalidTag

ROOT = Path(__file__).resolve().parents[1]
RUST = ROOT.parent / "once-campfire-rust"
VERIFICATION = ROOT.parent / "once-campfire-verification"
RUST_REVISION = "9872c1d9541551c0889a60e3d49a14488bd1e403"
VERIFICATION_REVISION = "6f71d70b5e1f17507404ad06cac134aa453a04a6"
ROUTES = ROOT / "test/fixtures/campfire_routes.json"
SESSIONS = ROOT / "test/fixtures/campfire_sessions.json"
SECRET = json.loads((ROOT / "test/fixtures/rails_compat.json").read_text())["secret_key_base"]


def sha(value):
    return hashlib.sha256(value).hexdigest()


def stable(value):
    if isinstance(value, bytes):
        return {"bytes_b64": base64.b64encode(value).decode()}
    return value


def snapshot(path):
    """Hash every logical and FTS table's ordered contents, not file metadata."""
    db = sqlite3.connect(f"file:{quote(str(path))}?mode=ro", uri=True, timeout=30)
    try:
        tables = [row[0] for row in db.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")]
        result = {}
        for table in tables:
            escaped = table.replace('"', '""')
            try:
                rows = db.execute(f'SELECT * FROM "{escaped}" ORDER BY rowid')
            except sqlite3.OperationalError:
                rows = db.execute(f'SELECT * FROM "{escaped}"')
            digest = hashlib.sha256()
            count = 0
            for row in rows:
                digest.update(json.dumps([stable(v) for v in row],
                                         separators=(",", ":"), ensure_ascii=False).encode())
                digest.update(b"\n")
                count += 1
            result[table] = {"count": count, "sha256": digest.hexdigest()}
        return result
    finally:
        db.close()


def has_session(path, session_id):
    db = sqlite3.connect(f"file:{quote(str(path))}?mode=ro", uri=True)
    try:
        return db.execute("SELECT 1 FROM sessions WHERE id=?", (session_id,)).fetchone() is not None
    finally:
        db.close()


def table_rows(path, table):
    db = sqlite3.connect(f"file:{quote(str(path))}?mode=ro", uri=True)
    try:
        columns = [item[1] for item in db.execute(f'PRAGMA table_info("{table}")')]
        return [dict(zip(columns, row)) for row in
                db.execute(f'SELECT * FROM "{table}" ORDER BY rowid')]
    finally:
        db.close()


RANDOM_STATE_TABLE = {9: "sessions", 10: "sessions", 25: "users", 36: "accounts"}
BASE58 = re.compile(r"[123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz]{24}\Z")
JOIN_CODE = re.compile(r"[A-Za-z0-9]{4}-[A-Za-z0-9]{4}-[A-Za-z0-9]{4}\Z")
UUID4 = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\Z")


def validated_random_state(route_index, before_r, before_o, after_r, after_o):
    """Accept only the three pinned generators' independent outputs, with all other rows exact."""
    if before_r != before_o or len(after_r) != len(after_o):
        return None
    column = {9: "token", 10: "token", 25: "email_address", 36: "join_code"}.get(route_index)
    if column is None:
        return None
    if [row.get("id") for row in after_r] != [row.get("id") for row in after_o]:
        return None
    old = {row["id"]: row for row in before_r}
    differences = []
    for left, right in zip(after_r, after_o):
        if left == right:
            continue
        if {key: value for key, value in left.items() if key != column} != \
           {key: value for key, value in right.items() if key != column}:
            return None
        differences.append((left, right))
    if len(differences) != 1:
        return None
    left, right = differences[0]
    values = (left[column], right[column])
    if values[0] == values[1] or not all(isinstance(value, str) for value in values):
        return None
    if route_index in (9, 10):
        if len(after_r) != len(before_r) + 1 or left["id"] in old:
            return None
        old_tokens = {row["token"] for row in before_r}
        if not all(BASE58.fullmatch(value) and value not in old_tokens for value in values):
            return None
    elif route_index == 25:
        original = old.get(left["id"], {}).get("email_address")
        if len(after_r) != len(before_r) or not isinstance(original, str) or "@" not in original:
            return None
        local, domain = original.split("@", 1)
        prefix, suffix = local + "-deactivated-", "@" + domain
        if not all(value.startswith(prefix) and value.endswith(suffix) and
                   UUID4.fullmatch(value[len(prefix):-len(suffix)]) for value in values):
            return None
    else:
        if len(after_r) != len(before_r) or left["id"] not in old:
            return None
        old_code = old[left["id"]]["join_code"]
        if not all(JOIN_CODE.fullmatch(value) and value != old_code for value in values):
            return None
    return {"table": RANDOM_STATE_TABLE[route_index], "column": column,
            "row_id": left["id"], "rust_sha256": sha(values[0].encode()),
            "ocaml_sha256": sha(values[1].encode()),
            "generator": {9: "base58(24)", 10: "base58(24)",
                          25: "UUIDv4 deactivated email", 36: "alphanumeric(12) grouped 4-4-4"}[route_index],
            "tokens": values if route_index in (9, 10) else None}


def classified_routes(rows):
    source = (RUST / "crates/campfire/src/controllers.rs").read_text()
    mapped = []
    for line in source.splitlines():
        if not re.match(r"\s*(?:get|post|put|patch|delete)\(\"/", line):
            continue
        if "action_not_found" in line:
            mapped.append("action_not_found")
        elif "missing_controller" in line:
            mapped.append("missing_controller")
        else:
            mapped.append("implemented")
    if len(mapped) != len(rows) or Counter(mapped) != Counter(
        {"implemented": 136, "action_not_found": 40, "missing_controller": 1}):
        raise RuntimeError(f"Rust route source drift: fixture={len(rows)}, source={len(mapped)}, classes={dict(Counter(mapped))}")
    return mapped


def concrete_path(row, labels, sessions):
    endpoint = row["endpoint"]
    path = row["path"].replace("(.:format)", "")
    def label(name, fallback="1"):
        return str(labels.get(name, fallback))
    def replace(match):
        key = match.group(1)
        if key == "room_id":
            return label("rooms.watercooler")
        if key == "message_id":
            return label("messages.first")
        if key == "bot_key":
            return label("bot_keys.bender", "invalid-bot-key")
        if key == "user_id":
            return "me" if "avatar" not in endpoint else label("avatar_tokens.david", "invalid-avatar")
        if key == "push_subscription_id":
            return label("push_subscriptions.david_chrome")
        if key == "join_code":
            return label("join_codes.signal", "invalid-join-code")
        if key == "signed_id" or key == "signed_blob_id":
            return sessions["blobs"][0]["signed_id"]
        if key == "variation_key":
            return "invalid-variation"
        if key == "encoded_key" or key == "encoded_token":
            return "invalid-token"
        if key == "filename":
            return "moon.jpg"
        if key == "inbound_email_id":
            return "1"
        if key == "id":
            if endpoint.startswith("sessions/transfers"):
                return label("transfers.david")
            if endpoint.startswith("qr_code"):
                return base64.urlsafe_b64encode(b"https://campfire.test").decode().rstrip("=")
            if endpoint.startswith("accounts/bots"):
                return label("users.bender")
            if endpoint.startswith("accounts/users") or endpoint.startswith("users#"):
                return label("users.david")
            if endpoint.startswith("users/push_subscriptions"):
                return label("push_subscriptions.david_chrome")
            if endpoint.startswith("rooms"):
                return label("rooms.watercooler")
            if endpoint.startswith("messages/boosts"):
                return label("boosts.first")
            if endpoint.startswith("messages"):
                return label("messages.first")
            return "1"
        return "1"
    return re.sub(r"(?:\*|:)([A-Za-z_]+)", replace, path)


def request(port, method, path, role, cookie, labels, *, override=False, malformed=False):
    if malformed:
        path += "/%ZZ"
    body = b""
    if override:
        body = ("_method=" + method).encode()
        method = "POST"
    headers = {
        "Host": "campfire.test", "Accept-Encoding": "identity",
        "Origin": "http://campfire.test", "Sec-Fetch-Site": "same-origin",
        "X-Request-Id": "m8-t2-differential",
        "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/126.0.0.0 Safari/537.36",
    }
    if role in ("signed", "denied"):
        headers["Cookie"] = cookie
    if role == "denied":
        headers["X-Forwarded-For"] = str(labels.get("ips.banned", "203.0.113.199"))
    if role == "bot":
        separator = "&" if "?" in path else "?"
        path += separator + "bot_key=" + quote(str(labels.get("bot_keys.bender", "invalid-bot-key")))
    if body:
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    try:
        conn.request(method, path, body=body, headers=headers)
        response = conn.getresponse()
        data = response.read()
        raw_headers = sorted((name.lower(), value) for name, value in response.getheaders())
        # Exact values participate in comparison.  Reports emit only names and
        # value digests, so a Set-Cookie or signed Location never leaks.
        return {"status": response.status, "headers": raw_headers, "body": data}
    finally:
        conn.close()


def changed(before, after):
    return sorted(name for name in before.keys() | after.keys()
                  if before.get(name) != after.get(name))


def compare_response(a, b, *, generated_tokens=None):
    problems = []
    if a["status"] != b["status"]:
        problems.append(f"status {a['status']}/{b['status']}")
    def normalized_cookie(value, expected_token=None):
        name_value, *attrs = value.split(";")
        name, separator, encoded = name_value.partition("=")
        if not separator:
            return value
        if name == "session_token" and expected_token is not None:
            try:
                signed = unquote_plus(encoded)
                payload, signature = signed.rsplit("--", 1)
                key = hashlib.pbkdf2_hmac("sha256", SECRET.encode(), b"signed cookie", 1000, 64)
                digest = hmac.new(key, payload.encode(), hashlib.sha1).hexdigest()
                if not hmac.compare_digest(digest, signature):
                    return value
                envelope = json.loads(base64.b64decode(payload))
                rails = envelope["_rails"]
                if rails.get("pur") != "cookie.session_token":
                    return value
                token = json.loads(base64.b64decode(rails["message"]))
                if token != expected_token:
                    return value
                rails["message"] = "<verified generated base58 token>"
                canonical = json.dumps(envelope, sort_keys=True, separators=(",", ":"))
                return name + "=<authenticated " + sha(canonical.encode()) + ">;" + ";".join(attrs)
            except (ValueError, KeyError, TypeError, binascii.Error):
                return value
        if name != "_campfire_session":
            return value
        try:
            ciphertext, iv, tag = (base64.b64decode(part) for part in unquote_plus(encoded).split("--"))
            key = hashlib.pbkdf2_hmac("sha256", SECRET.encode(),
                                      b"authenticated encrypted cookie", 1000, 32)
            plaintext = AESGCM(key).decrypt(iv, ciphertext + tag, None)
            envelope = json.loads(plaintext)
            if envelope.get("_rails", {}).get("pur") != "cookie._campfire_session":
                return value
            message = envelope["_rails"]["message"]
            payload = json.loads(base64.b64decode(message))
            if isinstance(payload, dict) and re.fullmatch(
                    r"[0-9a-f]{32}", str(payload.get("session_id", ""))):
                payload["session_id"] = "<random 128-bit session id>"
            envelope["_rails"]["message"] = payload
            # Compare the authenticated plaintext and every cookie attribute;
            # only the independently random AES-GCM IV/ciphertext is removed.
            canonical = json.dumps(envelope, sort_keys=True, separators=(",", ":"))
            return name + "=<authenticated " + sha(canonical.encode()) + ">;" + ";".join(attrs)
        except (ValueError, KeyError, TypeError, binascii.Error, InvalidTag):
            return value

    def normalized(headers, expected_token=None):
        result = []
        for name, value in headers:
            if name == "date":
                try:
                    parsed = email.utils.parsedate_to_datetime(value)
                    if parsed.tzinfo is not None and abs(parsed.timestamp() - time.time()) <= 60:
                        value = "<valid current HTTP date>"
                except (TypeError, ValueError, OverflowError):
                    pass
            elif name == "x-runtime" and re.fullmatch(r"\d+\.\d{6}", value):
                value = "<valid six-decimal runtime>"
            elif name == "set-cookie":
                value = normalized_cookie(value, expected_token)
            result.append((name, value))
        return result
    token_a, token_b = generated_tokens if generated_tokens else (None, None)
    if normalized(a["headers"], token_a) != normalized(b["headers"], token_b):
        by_name_a = {}
        by_name_b = {}
        for name, value in normalized(a["headers"], token_a):
            by_name_a.setdefault(name, []).append(value)
        for name, value in normalized(b["headers"], token_b):
            by_name_b.setdefault(name, []).append(value)
        names = sorted(name for name in by_name_a.keys() | by_name_b.keys()
                       if by_name_a.get(name) != by_name_b.get(name))
        problems.append("headers " + ",".join(names))
    if a["body"] != b["body"]:
        problems.append(f"body len={len(a['body'])}/{len(b['body'])} sha256={sha(a['body'])[:12]}/{sha(b['body'])[:12]}")
    return problems


def reset_isolated(seed, rust_port, ocaml_port, ready_port, ocaml_dir, container, network, labels,
                   binary=None):
    """Boot both apps from fresh, independent seed copies before one HTTP case."""
    stamp = labels["clock.now"]
    command = [str(RUST / "parity/bin/candidate"), "reset", "--app", "candidate",
               "--port", str(rust_port), "--seed", seed, "--time", stamp]
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["docker", "rm", "-f", container], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    marker = ocaml_dir / ".m8-t2-disposable"
    if ocaml_dir.exists():
        if not marker.exists():
            raise RuntimeError("refusing to replace a directory without the disposable marker")
        shutil.rmtree(ocaml_dir)
    ocaml_dir.mkdir(parents=True)
    shutil.copytree(RUST / "parity/.seed" / seed, ocaml_dir, dirs_exist_ok=True)
    marker.write_text("M8-T2 disposable fixture copy\n")
    binary = binary or ROOT / "_build/default/bin/main.exe"
    command = ["docker", "run", "--rm", "-d", "--read-only",
               "--tmpfs", "/tmp:rw,nosuid,size=64m", "--network", network, "--name", container,
               "--user", "1000:1000", "-v", f"{binary}:/app/campfire:ro",
               "-v", f"{ROOT / 'assets'}:/assets:ro", "-v", f"{ocaml_dir}:/data:rw",
               "-v", "/lib/x86_64-linux-gnu/libev.so.4:/opt/ocaml-libs/libev.so.4:ro",
               "-v", "/lib/x86_64-linux-gnu/libqrencode.so.4:/opt/ocaml-libs/libqrencode.so.4:ro",
               "--env-file", str(RUST / "parity/.env.reference"),
               "-e", "LD_LIBRARY_PATH=/opt/ocaml-libs",
               "-e", "LD_PRELOAD=/usr/local/lib/faketime/libfaketime.so.1",
               "-e", "FAKETIME=" + stamp.replace("T", " ").removesuffix("Z"),
               "-e", "FAKETIME_DONT_FAKE_MONOTONIC=1", "-e", "FAKETIME_DONT_RESET=1",
               "-e", "CAMPFIRE_FROZEN_TIME=" + stamp,
               "-e", "CAMPFIRE_DATABASE_PATH=/data/db/production.sqlite3",
               "-e", "CAMPFIRE_FILES_PATH=/data/storage",
               "-e", "CAMPFIRE_BACKUPS_PATH=/data/backups",
               "-e", "CAMPFIRE_ASSETS_DIR=/assets",
               "-e", f"THRUSTER_TARGET_PORT={ocaml_port}",
               "-e", "THRUSTER_TARGET_BIND=127.0.0.1", "--entrypoint", "/app/campfire",
               "campfire-reference:latest", "serve", "--port", str(ocaml_port)]
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(120):
        try:
            response = request(ready_port, "GET", "/up", "anonymous", "", labels)
            if response["status"] == 200:
                return
        except (ConnectionError, OSError):
            pass
        time.sleep(.05)
    raise RuntimeError("disposable OCaml server did not become ready")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", choices=("default", "crowd", "custom_styles", "first_run", "restricted"), required=True)
    parser.add_argument("--rust-port", type=int, required=True)
    parser.add_argument("--ocaml-port", type=int, required=True)
    parser.add_argument("--ocaml-target-port", type=int,
                        help="Target listener to reset when --ocaml-port is a stable front proxy")
    parser.add_argument("--rust-db", type=Path, required=True)
    parser.add_argument("--ocaml-db", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--limit", type=int, default=177, help="For focused debugging only; never a completion run")
    parser.add_argument("--row", type=int, action="append", help="Focused route row; may repeat")
    parser.add_argument("--roles", default="anonymous,signed,denied,bot",
                        help="Comma-separated role subset for focused debugging")
    parser.add_argument("--scenario", choices=("ordinary", "override", "malformed"),
                        default="ordinary", help="wire path/method scenario")
    parser.add_argument("--plan", action="store_true", help="Validate fixture/source and list counts; make no requests")
    parser.add_argument("--isolate", action="store_true", help="Reset both pinned apps from independent seed copies before each case")
    parser.add_argument("--ocaml-container", default="campfire-m8-t2-ocaml")
    parser.add_argument("--ocaml-seed-dir", type=Path)
    parser.add_argument("--ocaml-network", default="host",
                        help="Docker network for OCaml; use container:NAME to match Rust's bridge ingress")
    parser.add_argument("--ocaml-binary", type=Path,
                        help="Immutable built OCaml binary to mount for every isolated case")
    parser.add_argument("--verification-checkout", type=Path, default=VERIFICATION,
                        help="Checkout of the pinned shared verification revision")
    args = parser.parse_args()
    revisions = ((RUST, RUST_REVISION),
                 (args.verification_checkout, VERIFICATION_REVISION))
    for checkout, pinned in revisions:
        actual = subprocess.run(["git", "-C", str(checkout), "rev-parse", "HEAD"],
                                check=True, capture_output=True, text=True).stdout.strip()
        if actual != pinned:
            raise RuntimeError(f"pinned checkout drift: {checkout.name} is {actual}, expected {pinned}")
    binary = args.ocaml_binary or ROOT / "_build/default/bin/main.exe"
    binary_hash = sha(binary.read_bytes()) if binary.is_file() else None
    routes = json.loads(ROUTES.read_text())["routes"]
    classes = classified_routes(routes)
    labels = json.loads((RUST / "parity/.seed" / args.seed / "labels.json").read_text())
    sessions = json.loads(SESSIONS.read_text())
    seed_db = RUST / "parity/.seed" / args.seed / "db/production.sqlite3"
    valid_signed = has_session(seed_db, sessions["sessions"][0]["session_id"])
    if args.isolate and not args.ocaml_seed_dir:
        parser.error("--isolate requires --ocaml-seed-dir")
    selected = list(enumerate(zip(routes, classes)))
    selected = [(index, route, kind) for index, (route, kind) in selected]
    selected = selected[:args.limit]
    if args.row is not None:
        selected = [entry for entry in selected if entry[0] in args.row]
    roles = tuple(args.roles.split(","))
    if not roles or any(role not in ("anonymous", "signed", "denied", "bot") for role in roles):
        parser.error("--roles must contain only anonymous,signed,denied,bot")
    if args.plan:
        print(json.dumps({"seed": args.seed, "route_rows": len(routes), "classes": dict(Counter(classes)),
                          "signed_fixture_valid": valid_signed, "planned_rows": len(selected),
                          "planned_cases": len(selected) * len(roles)}))
        return
    cookie = sessions["sessions"][0]["cookie_header"]
    rows = []
    cases = []
    for index, route, kind in selected:
        path = concrete_path(route, labels, sessions)
        row_status = Counter()
        for role in roles:
            if args.scenario == "override" and route["verb"] not in ("PATCH", "PUT", "DELETE"):
                cases.append({"route": index, "role": role, "status": "not-run",
                              "reason": "method override applies only to PATCH, PUT, DELETE rows"})
                row_status["not-run"] += 1
                continue
            if role in ("signed", "denied") and not valid_signed:
                cases.append({"route": index, "role": role, "status": "not-run", "reason": "no matching pinned session in seed"})
                row_status["not-run"] += 1
                continue
            try:
                if args.isolate:
                    reset_isolated(args.seed, args.rust_port,
                                   args.ocaml_target_port or args.ocaml_port,
                                   args.ocaml_port, args.ocaml_seed_dir,
                                   args.ocaml_container, args.ocaml_network, labels,
                                   args.ocaml_binary)
                before_r, before_o = snapshot(args.rust_db), snapshot(args.ocaml_db)
                random_table = RANDOM_STATE_TABLE.get(index)
                random_before = ((table_rows(args.rust_db, random_table),
                                  table_rows(args.ocaml_db, random_table))
                                 if random_table else None)
                rust = request(args.rust_port, route["verb"], path, role, cookie, labels,
                               override=args.scenario == "override",
                               malformed=args.scenario == "malformed")
                ocaml = request(args.ocaml_port, route["verb"], path, role, cookie, labels,
                                override=args.scenario == "override",
                                malformed=args.scenario == "malformed")
                after_r, after_o = snapshot(args.rust_db), snapshot(args.ocaml_db)
                random_validated = (validated_random_state(
                    index, *random_before, table_rows(args.rust_db, random_table),
                    table_rows(args.ocaml_db, random_table)) if random_before else None)
                token_pair = random_validated.pop("tokens") if random_validated else None
                problems = compare_response(rust, ocaml, generated_tokens=token_pair)
                if before_r != before_o:
                    problems.append("boot baseline tables " + ",".join(sorted(
                        name for name in before_r.keys() | before_o.keys()
                        if before_r.get(name) != before_o.get(name))))
                rust_change, ocaml_change = changed(before_r, after_r), changed(before_o, after_o)
                if rust_change != ocaml_change:
                    problems.append("changed tables " + ",".join(rust_change) + "/" + ",".join(ocaml_change))
                for name in rust_change:
                    if after_r.get(name) != after_o.get(name) and not (
                            random_validated and name == random_validated["table"]):
                        problems.append("state " + name)
                status = "fail" if problems else "pass"
                case = {"route": index, "role": role, "status": status, "rust_status": rust["status"],
                        "ocaml_status": ocaml["status"], "rust_changed": rust_change,
                        "ocaml_changed": ocaml_change, "problems": problems}
                if random_validated:
                    case["validated_random_state"] = random_validated
                if problems:
                    names = set(rust_change) | set(ocaml_change)
                    case["table_hashes"] = {
                        name: {"rust": after_r.get(name), "ocaml": after_o.get(name)}
                        for name in sorted(names) if after_r.get(name) != after_o.get(name)
                    }
                cases.append(case)
            except Exception as exc:
                status = "fail"
                cases.append({"route": index, "role": role, "status": status,
                              "problems": ["request or snapshot error: " + type(exc).__name__ + ": " + str(exc)[:160]]})
            row_status[status] += 1
        rows.append((index, route, kind, row_status))
        if index % 20 == 19:
            print(f"{args.seed}: {index + 1}/{args.limit} route rows", flush=True)
    counts = Counter(case["status"] for case in cases)
    class_role = Counter((classes[case["route"]], case["role"], case["status"])
                         for case in cases)
    report = [f"# M8-T2 live Rust/OCaml HTTP and state differential: {args.seed}, {args.scenario}", "",
              f"Pinned Rust `{RUST_REVISION}` and shared verification `{VERIFICATION_REVISION}`."
              " Each server uses its own Rails seed copy.",
              f"OCaml candidate `{binary}` SHA-256 `{binary_hash or 'not available (plan only)'}`.",
              "Response comparison includes exact status, every returned header value, and every body byte."
              " Only valid current Date, six-decimal X-Runtime, and authenticated equivalent"
              " AES-GCM session-cookie plaintext are normalized because each server generates"
              " independent time/IV values; header presence and cookie attributes are compared."
              " For transfer, deactivation, and join-code writes, only independently generated"
              " base58/UUIDv4/alphanumeric fields are canonicalized after shape, uniqueness,"
              " row identity/count, every other column, and signed-cookie HMAC/payload linkage"
              " checks. SQLite comparison hashes every table before and after each request."
              " No deterministic values are masked in comparison;"
              " credentials and signed URLs are omitted from this report.", "",
              f"Cases: pass **{counts['pass']}**, fail **{counts['fail']}**, not-run **{counts['not-run']}**."
              f" Case isolation: **{'fresh seed per case' if args.isolate else 'none'}**."
              f" Scenario: **{args.scenario}**. Shared contracts, Cable, and media remain separate gates.", "",
              "## Class and role matrix", "",
              "| Rust action | Role | Pass | Fail | Not-run |", "| --- | --- | ---: | ---: | ---: |"]
    for kind in ("implemented", "action_not_found", "missing_controller"):
        for role in roles:
            report.append(f"| {kind} | {role} | {class_role[(kind,role,'pass')]} | "
                          f"{class_role[(kind,role,'fail')]} | {class_role[(kind,role,'not-run')]} |")
    report.extend(["", "## Route rows", "",
                   "| Row | Verb | Route pattern | Rust action | Pass | Fail | Not-run |",
                   "| ---: | --- | --- | --- | ---: | ---: | ---: |"])
    for index, route, kind, statuses in rows:
        report.append(f"| {index} | {route['verb']} | `{route['path']}` | {kind} | {statuses['pass']} | {statuses['fail']} | {statuses['not-run']} |")
    report.extend(["", "## Every case", "",
                   "| Row | Role | Result | Rust HTTP | OCaml HTTP | Difference or not-run reason |",
                   "| ---: | --- | --- | ---: | ---: | --- |"])
    for case in cases:
        detail = "; ".join(case.get("problems", [])) or case.get("reason", "")
        detail = detail.replace("|", "\\|").replace("\n", " ")
        report.append(f"| {case['route']} | {case['role']} | {case['status']} | "
                      f"{case.get('rust_status', '')} | {case.get('ocaml_status', '')} | {detail} |")
    report.extend(["", "## Failures", ""])
    for case in cases:
        if case["status"] == "fail":
            report.append(f"- Row {case['route']}, {case['role']}: {'; '.join(case['problems'])}")
    if counts["fail"] == 0:
        report.append("None in the exercised subset.")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(report) + "\n")
    args.output.with_suffix(".json").write_text(json.dumps({"seed": args.seed,
                                                            "scenario": args.scenario,
                                                            "rust_revision": RUST_REVISION,
                                                            "verification_revision": VERIFICATION_REVISION,
                                                            "ocaml_binary_sha256": binary_hash,
                                                            "counts": counts,
                                                            "cases": cases}, indent=2) + "\n")
    print(f"{args.seed}: {dict(counts)}; report {args.output}")


if __name__ == "__main__":
    main()

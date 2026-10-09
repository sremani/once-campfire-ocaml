#!/usr/bin/env python3
"""Compare successful pinned Rust/OCaml writes on independent disposable seeds.

Only fixture credentials are read. Reports contain response hashes and table
hashes, never cookies, CSRF tokens, bot keys, signed URLs, or response bodies.
"""

import argparse
import base64
import hashlib
import html
import http.client
import json
import re
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlencode
from urllib.parse import unquote_plus

import m8_t2_http_state as h


@dataclass(frozen=True)
class Case:
    name: str
    row: int
    family: str
    fields: tuple[tuple[str, str], ...] = ()
    expected_table: str = ""
    accept: str = "text/html, application/xhtml+xml"
    bootstrap: str = "/account/edit"
    bot: bool = False
    path: str = ""
    raw_body: str = ""


CASES = (
    Case("account_user_role", 23, "account roles", (("user[role]", "member"),), "users"),
    Case("account_user_deactivate", 25, "account roles", expected_table="users"),
    Case("account_bot_create", 29, "account bots", (("user[name]", "Parity Probe Bot"),), "users"),
    Case("account_bot_rename", 33, "account bots", (("user[name]", "Parity Probe Bender"),), "users"),
    Case("account_bot_key_reset", 26, "account bots", expected_table="users",
         path="/account/bots/{users.bender}/key"),
    Case("account_join_code_reset", 36, "account settings", expected_table="accounts"),
    Case("account_styles", 40, "account styles", (("account[custom_styles]", "body { color: #224466; }"),), "accounts"),
    Case("account_name", 45, "account settings", (("account[name]", "Parity Probe Campfire"),), "accounts"),
    Case("profile_name", 60, "user profile", (("user[name]", "Parity Probe David"),), "users"),
    Case("avatar_delete", 53, "user avatar", expected_table="active_storage_attachments",
         path="/users/{users.jason}/avatar"),
    Case("ban_create", 55, "user bans", expected_table="users", path="/users/{users.jason}/ban"),
    Case("ban_delete", 54, "user bans", expected_table="bans", path="/users/{users.mallory}/ban"),
    Case("push_subscription_delete", 72, "push subscriptions", expected_table="push_subscriptions"),
    Case("room_involvement", 93, "room involvement", (("involvement", "invisible"),), "memberships"),
    Case("open_room_create", 105, "open rooms", (("room[name]", "Parity Probe Open"),), "rooms"),
    Case("open_room_rename", 109, "open rooms", (("room[name]", "Parity Probe Renamed"),), "rooms"),
    Case("closed_room_create", 113, "closed rooms", (("room[name]", "Parity Probe Closed"),
                                                          ("user_ids[]", "{users.jason}")), "rooms"),
    Case("closed_room_rename", 117, "closed rooms", (("room[name]", "Parity Probe Closed Rename"),
                                                          ("user_ids[]", "{users.david}")), "rooms"),
    Case("direct_room_create", 121, "direct rooms", (("user_ids[]", "{users.rita}"),), "rooms"),
    Case("human_message_create", 76, "human messages", (("message[body]", "Parity probe message"),
                                                        ("message[client_message_id]", "m8t2-positive-1")), "messages",
         "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"),
    Case("human_message_update", 80, "human messages", (("message[body]", "Parity probe edit"),), "messages",
         path="/rooms/{rooms.designers}/messages/{messages.edited}"),
    Case("human_message_delete", 82, "human messages", expected_table="messages",
         accept="text/vnd.turbo-stream.html, text/html, application/xhtml+xml",
         path="/rooms/{rooms.designers}/messages/{messages.edited}"),
    Case("human_boost_create", 129, "human boosts", (("boost[content]", "👍"),), "boosts"),
    Case("human_boost_delete", 135, "human boosts", expected_table="boosts"),
    Case("bot_message_create", 86, "bot messages", expected_table="messages", bot=True,
         raw_body="Parity probe bot message"),
    Case("bot_message_update", 87, "bot messages", expected_table="messages", bot=True,
         path="/rooms/{rooms.watercooler}/{bot_keys.bender}/messages/{messages.bot_in_watercooler}",
         raw_body="Parity probe bot edit"),
    Case("bot_boost_create", 83, "bot boosts", expected_table="boosts", bot=True,
         path="/rooms/{rooms.watercooler}/{bot_keys.bender}/messages/{messages.bot_in_watercooler}/boosts",
         raw_body="👍", accept="application/json"),
    Case("search_clear", 144, "searches", expected_table="searches"),
    Case("search_create", 146, "searches", (("q", "parity probe search"),), "searches"),
    Case("session_logout", 16, "sessions", expected_table="sessions"),
)


def safe_hash(body):
    return {"length": len(body), "sha256": hashlib.sha256(body).hexdigest()}


def safe_headers(response):
    return {name: [value for key, value in response["headers"] if key == name]
            for name in ("content-type", "vary")}


def safe_cookie_difference(left, right):
    """Expose only cookie names, attributes, and authenticated payload paths."""
    def cookie_parts(response):
        result = []
        for key, value in response["headers"]:
            if key != "set-cookie":
                continue
            name_value, *attrs = value.split(";")
            name, _, encoded = name_value.partition("=")
            result.append((name, encoded, tuple(attr.strip() for attr in attrs)))
        return result
    def payload(encoded):
        try:
            ciphertext, iv, tag = (base64.b64decode(part) for part in unquote_plus(encoded).split("--"))
            key = hashlib.pbkdf2_hmac("sha256", h.SECRET.encode(), b"authenticated encrypted cookie", 1000, 32)
            envelope = json.loads(h.AESGCM(key).decrypt(iv, ciphertext + tag, None))
            if envelope.get("_rails", {}).get("pur") != "cookie._campfire_session":
                return None
            message = envelope["_rails"]["message"]
            parsed = json.loads(base64.b64decode(message))
            if isinstance(parsed, dict) and re.fullmatch(r"[0-9a-f]{32}", str(parsed.get("session_id", ""))):
                parsed["session_id"] = "<validated random session id>"
            return parsed
        except (ValueError, KeyError, TypeError, UnicodeDecodeError, h.InvalidTag, base64.binascii.Error):
            return None
    def paths(a, b, prefix=""):
        if isinstance(a, dict) and isinstance(b, dict):
            keys = sorted(a.keys() | b.keys())
            return [path for key in keys for path in paths(a.get(key), b.get(key), prefix + "." + key)]
        if isinstance(a, list) and isinstance(b, list):
            return [path for i in range(max(len(a), len(b))) for path in
                    paths(a[i] if i < len(a) else None, b[i] if i < len(b) else None,
                          prefix + "[" + str(i) + "]")]
        return [prefix or "<root>"] if a != b else []
    a, b = cookie_parts(left), cookie_parts(right)
    result = {"rust_cookie_names": [item[0] for item in a],
              "ocaml_cookie_names": [item[0] for item in b],
              "attributes_equal": [(x[0] == y[0] and x[2] == y[2]) for x, y in zip(a, b)]}
    if len(a) == len(b) == 1 and a[0][0] == b[0][0] == "_campfire_session":
        pa, pb = payload(a[0][1]), payload(b[0][1])
        result["authenticated_payloads"] = pa is not None and pb is not None
        if pa is not None and pb is not None:
            result["payload_difference_paths"] = paths(pa, pb)[:20]
    return result


def fill(value, labels):
    return re.sub(r"\{([a-z_]+\.[a-z_]+)\}", lambda match: str(labels[match.group(1)]), value)


def validated_new_random(before_pair, after_pair, column, pattern, generator):
    """Accept one new row's generated field only after all other columns match."""
    before_r, before_o = before_pair
    after_r, after_o = after_pair
    if before_r != before_o or len(after_r) != len(before_r) + 1 or len(after_o) != len(before_o) + 1:
        return None
    if after_r[:-1] != before_r or after_o[:-1] != before_o:
        return None
    left, right = after_r[-1], after_o[-1]
    if left.get("id") != right.get("id"):
        return None
    if {k: v for k, v in left.items() if k != column} != {k: v for k, v in right.items() if k != column}:
        return None
    values = (left.get(column), right.get(column))
    old_values = {row.get(column) for row in before_r}
    if not all(isinstance(value, str) and pattern.fullmatch(value) and value not in old_values
               for value in values):
        return None
    return {"column": column, "generator": generator, "row_id": left["id"],
            "rust_sha256": h.sha(values[0].encode()), "ocaml_sha256": h.sha(values[1].encode())}


def validated_existing_random(before_pair, after_pair, column, pattern, generator):
    before_r, before_o = before_pair
    after_r, after_o = after_pair
    if before_r != before_o or len(after_r) != len(before_r) or len(after_o) != len(before_o):
        return None
    changed = [(left, right) for left, right in zip(after_r, after_o) if left != right]
    if len(changed) != 1:
        return None
    left, right = changed[0]
    if [row.get("id") for row in after_r] != [row.get("id") for row in after_o]:
        return None
    if {k: v for k, v in left.items() if k != column} != {k: v for k, v in right.items() if k != column}:
        return None
    old = next((row for row in before_r if row.get("id") == left.get("id")), None)
    if old is None:
        return None
    old_values = {row.get(column) for row in before_r}
    values = (left.get(column), right.get(column))
    if not all(isinstance(value, str) and pattern.fullmatch(value) and value not in old_values
               for value in values):
        return None
    return {"column": column, "generator": generator, "row_id": left["id"],
            "rust_sha256": h.sha(values[0].encode()), "ocaml_sha256": h.sha(values[1].encode())}


def wire(port, method, path, cookie, body=b"", *, csrf=None, accept="text/html, application/xhtml+xml",
         bot=False, raw_body=False):
    headers = {
        "Host": "campfire.test", "Accept-Encoding": "identity", "Accept": accept,
        "Origin": "http://campfire.test", "Sec-Fetch-Site": "same-origin",
        "X-Request-Id": "m8-t2-positive-write",
        "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/126.0.0.0 Safari/537.36",
    }
    if cookie and not bot:
        headers["Cookie"] = cookie
    if body:
        headers["Content-Type"] = "text/plain; charset=utf-8" if raw_body else "application/x-www-form-urlencoded"
    if csrf:
        headers["X-CSRF-Token"] = csrf
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    try:
        conn.request(method, path, body=body, headers=headers)
        response = conn.getresponse()
        data = response.read()
        return {"status": response.status,
                "headers": sorted((name.lower(), value) for name, value in response.getheaders()),
                "body": data}
    finally:
        conn.close()


def csrf_from(port, cookie, path):
    page = wire(port, "GET", path, cookie)
    if page["status"] != 200:
        raise RuntimeError(f"CSRF bootstrap returned HTTP {page['status']}")
    match = re.search(rb'<meta name="csrf-token" content="([^"]+)"', page["body"])
    # Pinned Rust uses Rails header_only protection: same-origin Origin and
    # Sec-Fetch-Site validate the write, and these pages omit CSRF meta tokens.
    token = html.unescape(match.group(1).decode("ascii")) if match else None
    if token is not None and len(token) < 32:
        raise RuntimeError("CSRF token has unexpected length")
    renewed = [value.split(";", 1)[0] for key, value in page["headers"]
               if key == "set-cookie" and value.startswith("session_token=")]
    return token, renewed[-1] if renewed else cookie


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ocaml-binary", type=Path, required=True)
    parser.add_argument("--verification-checkout", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("docs/m8-t2-positive-writes.json"))
    parser.add_argument("--case", action="append", help="Run only named cases; may repeat")
    parser.add_argument("--settle-seconds", type=float, default=0,
                        help="Bounded post-response wait before SQLite snapshot for asynchronous jobs")
    parser.add_argument("--rust-port", type=int, default=3228)
    parser.add_argument("--ocaml-port", type=int, default=3230)
    parser.add_argument("--ocaml-target-port", type=int, default=3229)
    args = parser.parse_args()
    if not 0 <= args.settle_seconds <= 10:
        parser.error("--settle-seconds must be between 0 and 10")
    h.RUST_REVISION = "9872c1d9541551c0889a60e3d49a14488bd1e403"
    import subprocess
    for checkout, pinned in ((h.RUST, h.RUST_REVISION),
                             (args.verification_checkout, h.VERIFICATION_REVISION)):
        actual = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
        if actual != pinned:
            raise RuntimeError(f"pinned checkout drift: {checkout.name}")
    binary = args.ocaml_binary.resolve(strict=True)
    labels = json.loads((h.RUST / "parity/.seed/default/labels.json").read_text())
    sessions = json.loads(h.SESSIONS.read_text())
    routes = json.loads(h.ROUTES.read_text())["routes"]
    cookie = sessions["sessions"][0]["cookie_header"]
    selected = [case for case in CASES if args.case is None or case.name in args.case]
    if args.case and set(args.case) != {case.name for case in selected}:
        parser.error("unknown --case name")
    rust_db = h.RUST / f"parity/.seed/.candidates/{args.rust_port}/db/production.sqlite3"
    ocaml_dir = Path("/tmp/campfire-m8-t2-isolated-default-1000")
    ocaml_db = ocaml_dir / "db/production.sqlite3"
    results = []
    for case in selected:
        route = routes[case.row]
        path = fill(case.path, labels) if case.path else h.concrete_path(route, labels, sessions)
        if case.bot:
            # The route path itself carries the pinned bot key; never emit it.
            pass
        entry = {"name": case.name, "family": case.family, "route": case.row,
                 "method": route["verb"], "route_pattern": route["path"]}
        try:
            h.reset_isolated("default", args.rust_port, args.ocaml_target_port,
                             args.ocaml_port, ocaml_dir, "campfire-m8-t2-default-ocaml",
                             "container:campfire-m8-t2-network", labels, binary)
            setup_random_validated = None
            cookies = (cookie, cookie)
            if case.name == "avatar_delete":
                def own_avatar(path_db):
                    return any(row.get("record_type") == "User" and row.get("name") == "avatar" and
                               row.get("record_id") == labels["users.jason"]
                               for row in h.table_rows(path_db, "active_storage_attachments"))
                if not own_avatar(rust_db) and not own_avatar(ocaml_db):
                    entry.update({"status": "not-run", "reason": "pinned Jason user has no avatar attachment"})
                    results.append(entry)
                    print(f"positive write {len(results)}/{len(selected)}: {case.name} not-run", flush=True)
                    continue
                prior_sessions = (h.table_rows(rust_db, "sessions"), h.table_rows(ocaml_db, "sessions"))
                login_body = urlencode({"email_address": labels["emails.jason"],
                                        "password": labels["passwords.all"]}).encode()
                login = (wire(args.rust_port, "POST", "/session", None, login_body),
                         wire(args.ocaml_port, "POST", "/session", None, login_body))
                setup_random_validated = h.validated_random_state(
                    9, *prior_sessions, h.table_rows(rust_db, "sessions"),
                    h.table_rows(ocaml_db, "sessions"))
                if setup_random_validated is None:
                    raise RuntimeError("Jason login did not produce one validated base58 session token per server")
                setup_problems = h.compare_response(*login, generated_tokens=setup_random_validated["tokens"])
                if login[0]["status"] != 302 or setup_problems:
                    raise RuntimeError("Jason login did not match pinned HTTP and signed-cookie linkage")
                def session_cookie(response):
                    items = [value.split(";", 1)[0] for key, value in response["headers"]
                             if key == "set-cookie" and value.startswith("session_token=")]
                    if len(items) != 1:
                        raise RuntimeError("Jason login did not issue one signed session cookie")
                    return items[0]
                cookies = tuple(session_cookie(response) for response in login)
                setup_random_validated.pop("tokens")
            tokens = (None, None)
            if not case.bot:
                bootstrap = fill(case.bootstrap, labels)
                prepared = (csrf_from(args.rust_port, cookies[0], bootstrap),
                            csrf_from(args.ocaml_port, cookies[1], bootstrap))
                tokens = tuple(item[0] for item in prepared)
                cookies = tuple(item[1] for item in prepared)
            before = (h.snapshot(rust_db), h.snapshot(ocaml_db))
            random_spec = {"account_bot_create": ("users", "bot_token", re.compile(r"[A-Za-z0-9]{12}\Z"),
                                                   "alphanumeric(12)", "new"),
                           "account_bot_key_reset": ("users", "bot_token", re.compile(r"[A-Za-z0-9]{12}\Z"),
                                                     "alphanumeric(12)", "existing"),
                           "bot_message_create": ("messages", "client_message_id", h.UUID4,
                                                  "UUIDv4", "new"),
                           "account_user_deactivate": ("users", "email_address", None,
                                                       "UUIDv4 deactivated email", "builtin"),
                           "account_join_code_reset": ("accounts", "join_code", None,
                                                       "alphanumeric(12) grouped 4-4-4", "builtin")}.get(case.name)
            random_before = ((h.table_rows(rust_db, random_spec[0]), h.table_rows(ocaml_db, random_spec[0]))
                             if random_spec else None)
            bodies = []
            for token in tokens:
                if case.raw_body:
                    bodies.append(case.raw_body.encode())
                else:
                    fields = [(key, fill(value, labels)) for key, value in case.fields]
                    if token:
                        fields.append(("authenticity_token", token))
                    bodies.append(urlencode(fields).encode())
            rust = wire(args.rust_port, route["verb"], path, cookies[0], bodies[0],
                        csrf=tokens[0], accept=case.accept, bot=case.bot, raw_body=bool(case.raw_body))
            ocaml = wire(args.ocaml_port, route["verb"], path, cookies[1], bodies[1],
                         csrf=tokens[1], accept=case.accept, bot=case.bot, raw_body=bool(case.raw_body))
            if args.settle_seconds and case.name in ("human_message_create", "bot_message_create", "ban_create"):
                time.sleep(args.settle_seconds)
            after = (h.snapshot(rust_db), h.snapshot(ocaml_db))
            random_validated = None
            if random_spec:
                random_after = (h.table_rows(rust_db, random_spec[0]),
                                h.table_rows(ocaml_db, random_spec[0]))
                if random_spec[4] == "builtin":
                    random_validated = h.validated_random_state(case.row, *random_before, *random_after)
                    if random_validated:
                        random_validated.pop("tokens", None)
                else:
                    validator = validated_new_random if random_spec[4] == "new" else validated_existing_random
                    random_validated = validator(random_before, random_after, random_spec[1],
                                                 random_spec[2], random_spec[3])
            rust_change = h.changed(before[0], after[0])
            ocaml_change = h.changed(before[1], after[1])
            problems = h.compare_response(rust, ocaml)
            baseline_differences = sorted(table for table in before[0].keys() | before[1].keys()
                                          if before[0].get(table) != before[1].get(table))
            if baseline_differences and not (setup_random_validated and baseline_differences == ["sessions"]):
                problems.append("boot baseline tables " + ",".join(baseline_differences))
            if rust_change != ocaml_change:
                problems.append("changed tables " + ",".join(rust_change) + "/" + ",".join(ocaml_change))
            for table in rust_change:
                if after[0].get(table) != after[1].get(table) and not (
                        random_validated and table == random_spec[0]):
                    problems.append("state " + table)
            if not 200 <= rust["status"] < 400:
                problems.append(f"Rust write rejected with HTTP {rust['status']}")
            if case.expected_table and case.expected_table not in rust_change:
                problems.append("Rust expected table unchanged: " + case.expected_table)
            entry.update({"status": "fail" if problems else "pass",
                          "rust_status": rust["status"], "ocaml_status": ocaml["status"],
                          "rust_body": safe_hash(rust["body"]), "ocaml_body": safe_hash(ocaml["body"]),
                          "rust_safe_headers": safe_headers(rust), "ocaml_safe_headers": safe_headers(ocaml),
                          "rust_changed": rust_change, "ocaml_changed": ocaml_change,
                          "problems": problems})
            if random_validated:
                entry["validated_random_state"] = random_validated
            if setup_random_validated:
                entry["validated_setup_random_state"] = setup_random_validated
            if any(problem == "headers set-cookie" for problem in problems):
                entry["safe_cookie_difference"] = safe_cookie_difference(rust, ocaml)
        except Exception as exc:
            entry.update({"status": "fail", "problems": ["request or snapshot error: " +
                          type(exc).__name__ + ": " + str(exc)[:120]]})
        results.append(entry)
        print(f"positive write {len(results)}/{len(selected)}: {case.name} {entry['status']}", flush=True)
    report = {"rust_revision": h.RUST_REVISION, "verification_revision": h.VERIFICATION_REVISION,
              "ocaml_binary_sha256": h.sha(binary.read_bytes()), "seed": "default",
              "csrf_policy": "pinned header_only: matching Origin and Sec-Fetch-Site same-origin",
              "settle_seconds": args.settle_seconds,
              "counts": {kind: sum(item["status"] == kind for item in results)
                         for kind in ("pass", "fail", "not-run")}, "cases": results}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(report["counts"], flush=True)


if __name__ == "__main__":
    main()

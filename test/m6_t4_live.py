#!/usr/bin/env python3
"""Compare disposable pinned Rails and OCaml Active Storage HTTP servers.

The caller starts two servers from separate copies of the same `default` seed,
at the same frozen time. Only the pinned test-session fixture is used. Signed
URLs, cookies, and CSRF tokens are never printed.
"""

import argparse
import base64
import hashlib
import hmac
import html
import http.client
import json
import re
import sqlite3
from http.cookies import SimpleCookie
from pathlib import Path
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = ROOT.parent / "once-campfire-rust"
VECTORS = json.loads((ROOT / "test/fixtures/storage.json").read_text())
SESSIONS = json.loads((ROOT / "test/fixtures/campfire_sessions.json").read_text())
SECRET = json.loads((ROOT / "test/fixtures/rails_compat.json").read_text())["secret_key_base"]
LABELS = json.loads((UPSTREAM / "parity/.seed/default/labels.json").read_text())
FIELDS = (
    "cache-control", "etag", "last-modified", "accept-ranges", "content-type",
    "content-disposition", "content-range",
)


def signed_blob_id(blob_id):
    key = hashlib.pbkdf2_hmac("sha256", SECRET.encode(), b"ActiveStorage", 1000, 64)
    payload = json.dumps({"_rails": {"data": blob_id, "pur": "blob_id"}},
                         separators=(",", ":")).encode()
    encoded = base64.b64encode(payload).decode()
    return encoded + "--" + hmac.new(key, encoded.encode(), hashlib.sha1).hexdigest()


def representation_path(blob_id, fixture, vector_field):
    item = next(item for item in VECTORS["messages"] if item["fixture"] == fixture)
    parts = item[vector_field].split("/")
    parts[5] = signed_blob_id(blob_id)
    return "/".join(parts)


def request(port, method, path, *, body=b"", headers=None):
    headers = {
        "Host": "campfire.test", "Origin": "http://campfire.test",
        "Sec-Fetch-Site": "same-origin", "Accept-Encoding": "identity",
        **(headers or {}),
    }
    client = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    try:
        client.request(method, path, body=body, headers=headers)
        response = client.getresponse()
        contents = response.read()
        fields = {name.lower(): value for name, value in response.getheaders()}
        return response.status, fields, contents, response.getheaders()
    finally:
        client.close()


class Comparison:
    def __init__(self, rails_port, ocaml_port):
        self.ports = rails_port, ocaml_port
        self.checks = 0
        self.differences = []

    def equal(self, label, rails, ocaml):
        self.checks += 1
        if rails != ocaml:
            self.differences.append(label)

    def responses(self, label, rails, ocaml, *, skip=()):
        self.equal(label + " status", rails[0], ocaml[0])
        self.equal(label + " exact body", rails[2], ocaml[2])
        for name in FIELDS:
            if name not in skip:
                self.equal(label + " " + name, rails[1].get(name), ocaml[1].get(name))

    def pair(self, method, path, *, headers=None, body=b""):
        return tuple(request(port, method, path, headers=headers, body=body)
                     for port in self.ports)


def compare_public(c):
    path = SESSIONS["blobs"][0]["redirect_path"]
    redirected = c.pair("GET", path)
    c.responses("blob redirect", *redirected)
    disk_paths = tuple(urlsplit(response[1]["location"]).path for response in redirected)
    c.equal("blob redirect signed disk path", *disk_paths)

    proxy = path.replace("/blobs/redirect/", "/blobs/proxy/")
    c.responses("blob proxy", *c.pair("GET", proxy))
    for label, fields in (
        ("range", {"Range": "bytes=0-9"}),
        ("unsatisfiable", {"Range": "bytes=999999-"}),
    ):
        # The Rails Thruster caches a previous full GET by URL, so vary the query.
        c.responses("blob proxy " + label,
                    *(request(port, "GET", proxy + "?m6=" + label, headers=fields)
                      for port in c.ports))
    cached = [request(port, "GET", proxy,
                      headers={"If-None-Match": answer[1]["etag"]})
              for port, answer in zip(c.ports, c.pair("GET", proxy))]
    # Rust returns from `fresh_when` before setting stream/range headers;
    # Rails' streaming layer retains them on 304.
    c.responses("blob proxy 304", *cached,
                skip=("accept-ranges", "content-disposition"))

    for label, fields in (("GET", {}), ("range", {"Range": "bytes=0-9"}),
                          ("unsatisfiable", {"Range": "bytes=999999-"})):
        pair = [request(port, "GET", path + "?m6=" + label, headers=fields)
                for port, path in zip(c.ports, disk_paths)]
        c.responses("signed disk " + label, *pair, skip=("last-modified",))
    disk = [request(port, "GET", path)
            for port, path in zip(c.ports, disk_paths)]
    conditional = [request(port, "GET", path + "?m6=conditional",
                           headers={"If-Modified-Since": answer[1]["last-modified"]})
                   for port, path, answer in zip(c.ports, disk_paths, disk)]
    # Rust FileServer writes Content-Type on 304; Rails' Rack response strips it.
    c.responses("signed disk conditional", *conditional,
                skip=("last-modified", "content-type"))

    malformed = path.split("/")
    malformed[5] += "x"
    c.responses("malformed blob signature", *c.pair("GET", "/".join(malformed)))


def compare_representations(c):
    for label, blob_id, fixture, field in (
        ("image", 1, "moon.jpg", "thumb_path"),
        ("video", 9, "alpha-centuri.mov", "poster_path"),
    ):
        path = representation_path(blob_id, fixture, field)
        redirect = c.pair("GET", path)
        c.responses(label + " representation redirect", *redirect)
        disk_paths = tuple(urlsplit(answer[1]["location"]).path for answer in redirect)
        # First-time transformations choose independent random blob keys. Compare
        # their signed disk responses and stored bytes, not the URL token itself.
        c.responses(label + " representation disk",
                    *(request(port, "GET", location)
                      for port, location in zip(c.ports, disk_paths)),
                    skip=("last-modified",))
        proxy = path.replace("/representations/redirect/", "/representations/proxy/")
        responses = c.pair("GET", proxy)
        c.responses(label + " representation proxy", *responses)
        c.responses(label + " representation 304",
                    *(request(port, "GET", proxy,
                              headers={"If-None-Match": answer[1]["etag"]})
                      for port, answer in zip(c.ports, responses)),
                    skip=("content-disposition",))
        c.responses(label + " representation ignores range",
                    *(request(port, "GET", proxy + "?m6=range",
                              headers={"Range": "bytes=0-9"}) for port in c.ports))
        parts = path.split("/")
        parts[6] += "x"
        c.responses(label + " malformed variation", *c.pair("GET", "/".join(parts)))


def compare_presenters(c):
    cookie = SESSIONS["sessions"][0]["cookie_header"]
    for label, path in (
        ("stock logo", "/account/logo"),
        ("stock logo small", "/account/logo?size=small"),
        ("stored avatar", "/users/" + LABELS["avatar_tokens.jason"] + "/avatar"),
        ("initials avatar", "/users/" + LABELS["avatar_tokens.david"] + "/avatar"),
    ):
        c.responses(label, *c.pair("GET", path, headers={"Cookie": cookie}))


def stored_row(root, key):
    with sqlite3.connect(root / "db/production.sqlite3") as database:
        row = database.execute(
            "SELECT filename,content_type,metadata,service_name,byte_size,checksum "
            "FROM active_storage_blobs WHERE key=?", (key,)).fetchone()
    return row


def stored_file(root, key):
    return root / "storage" / key[:2] / key[2:4] / key


def csrf_session(port):
    cookie = SimpleCookie()
    cookie.load(SESSIONS["sessions"][0]["cookie_header"])
    status, _, body, headers = request(port, "GET",
        "/rooms/" + str(LABELS["rooms.hq"]),
        headers={"Cookie": SESSIONS["sessions"][0]["cookie_header"]})
    if status != 200:
        raise RuntimeError("pinned Rails test session did not open a room")
    token = re.search(rb'<meta[^>]+name="csrf-token"[^>]+content="([^"]+)', body)
    if token is None:
        raise RuntimeError("pinned Rails room did not expose its CSRF token")
    for name, value in headers:
        if name.lower() == "set-cookie":
            cookie.load(value)
    return (
        "; ".join(name + "=" + morsel.value for name, morsel in cookie.items()),
        html.unescape(token.group(1).decode()),
    )


def compare_upload(c, roots):
    rails_cookie, csrf = csrf_session(c.ports[0])
    cookies = rails_cookie, SESSIONS["sessions"][0]["cookie_header"]
    contents = b"m6 pinned live differential\n"
    checksum = base64.b64encode(hashlib.md5(contents).digest()).decode()
    payload = json.dumps({"blob": {"filename": "m6-live-differential.txt",
        "byte_size": len(contents), "checksum": checksum,
        "content_type": "text/plain"}}).encode()
    rows = []
    for index, port in enumerate(c.ports):
        headers = {"Cookie": cookies[index], "X-CSRF-Token": csrf,
                   "Content-Type": "application/json"}
        result = request(port, "POST", "/rails/active_storage/direct_uploads",
                         headers=headers, body=payload)
        rows.append(result)
    c.equal("direct upload POST status", rows[0][0], rows[1][0])
    if any(row[0] != 200 for row in rows):
        raise RuntimeError("authenticated direct upload POST failed")
    decoded = [json.loads(row[2]) for row in rows]
    # The pinned Rust JSON omits Rails' extra attachable_sgid method.
    fields = ("filename", "content_type", "metadata", "service_name",
              "byte_size", "checksum", "created_at")
    for field in fields:
        c.equal("direct upload " + field, decoded[0][field], decoded[1][field])
    c.equal("direct upload headers", decoded[0]["direct_upload"]["headers"],
            decoded[1]["direct_upload"]["headers"])
    direct_rows = [stored_row(root, value["key"])
                   for root, value in zip(roots, decoded)]
    # Rails records NULL metadata for the empty input, while pinned Rust's
    # NewBlob inserts JSON `{}`. Both respond with `{}`.
    c.equal("direct upload DB row fields", direct_rows[0][:2] + direct_rows[0][3:],
            direct_rows[1][:2] + direct_rows[1][3:])

    for index, port in enumerate(c.ports):
        path = urlsplit(decoded[index]["direct_upload"]["url"]).path
        headers = {"Cookie": cookies[index], "X-CSRF-Token": csrf,
                   "Content-Type": "text/plain"}
        rows[index] = request(port, "PUT", path, body=contents, headers=headers)
    c.responses("signed direct PUT", *rows)
    for root, value in zip(roots, decoded):
        c.equal("direct PUT stored bytes", contents,
                stored_file(root, value["key"]).read_bytes())

    failures = []
    for index, port in enumerate(c.ports):
        headers = {"Cookie": cookies[index], "X-CSRF-Token": csrf,
                   "Content-Type": "application/json"}
        created = request(port, "POST", "/rails/active_storage/direct_uploads",
                          body=payload, headers=headers)
        if created[0] != 200:
            raise RuntimeError("checksum rejection setup failed")
        value = json.loads(created[2])
        path = urlsplit(value["direct_upload"]["url"]).path
        rejected = request(port, "PUT", path, body=b"x" * len(contents),
            headers={"Cookie": cookies[index], "X-CSRF-Token": csrf,
                     "Content-Type": "text/plain"})
        failures.append(rejected)
        c.equal("failed PUT leaves no file " + str(index), False,
                stored_file(roots[index], value["key"]).exists())
    c.responses("checksum-mismatch direct PUT", *failures)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rails-port", type=int, required=True)
    parser.add_argument("--ocaml-port", type=int, required=True)
    parser.add_argument("--rails-storage", type=Path, required=True)
    parser.add_argument("--ocaml-storage", type=Path, required=True)
    args = parser.parse_args()
    if signed_blob_id(SESSIONS["blobs"][0]["blob_id"]) != SESSIONS["blobs"][0]["signed_id"]:
        raise RuntimeError("fixture signing key does not match pinned session")
    comparison = Comparison(args.rails_port, args.ocaml_port)
    compare_public(comparison)
    compare_representations(comparison)
    compare_presenters(comparison)
    compare_upload(comparison, (args.rails_storage, args.ocaml_storage))
    print(f"M6 live differential: {comparison.checks} comparisons, "
          f"{len(comparison.differences)} mismatches")
    for label in comparison.differences:
        print("mismatch:", label)
    raise SystemExit(bool(comparison.differences))


if __name__ == "__main__":
    main()

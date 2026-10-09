#!/usr/bin/env python3
"""Disposable Pebble/Caddy renewal check. Run only with loopback sockets."""

from contextlib import ExitStack
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import ssl
import subprocess
import tempfile
import time
import urllib.request

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization


ROOT = Path(__file__).resolve().parent.parent
CADDY = Path(os.environ.get("CAMPFIRE_CADDY_BIN", "/tmp/campfire-caddy/usr/bin/caddy"))
PEBBLE = Path(os.environ.get("CAMPFIRE_PEBBLE_BIN", "/tmp/campfire-pebble/usr/bin/pebble"))
FRONT = ROOT / "_build/default/bin/front.exe"
DOMAIN = "renew.example.com"


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def stop(process):
    if process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def fingerprint(port):
    context = ssl._create_unverified_context()
    with socket.create_connection(("127.0.0.1", port), timeout=2) as raw:
        with context.wrap_socket(raw, server_hostname=DOMAIN) as tls:
            return hashlib.sha256(tls.getpeercert(binary_form=True)).hexdigest()


def await_fingerprint(port, *, unlike=None):
    last = None
    for _ in range(120):
        try:
            value = fingerprint(port)
            if value != unlike:
                return value
        except (OSError, ssl.SSLError) as error:
            last = error
        time.sleep(0.25)
    raise RuntimeError(f"certificate not served/renewed; last error: {last}")


def fetch(url, context):
    return urllib.request.urlopen(url, context=context, timeout=3).read()


def main():
    if not CADDY.is_file() or not PEBBLE.is_file() or not FRONT.is_file():
        raise RuntimeError("build front.exe and set CAMPFIRE_CADDY_BIN/CAMPFIRE_PEBBLE_BIN")
    with tempfile.TemporaryDirectory(prefix="campfire-m7-renew-") as name, ExitStack() as stack:
        root = Path(name)
        ca_port, mgmt_port, http_port, https_port, target_port = [free_port() for _ in range(5)]
        key, cert = root / "pebble.key", root / "pebble.crt"
        run("openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
            "-nodes", "-keyout", str(key), "-out", str(cert), "-days", "2",
            "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1,DNS:localhost")
        config = {"pebble": {
            "listenAddress": f"127.0.0.1:{ca_port}",
            "managementListenAddress": f"127.0.0.1:{mgmt_port}",
            "certificate": str(cert), "privateKey": str(key),
            "httpPort": http_port, "tlsPort": https_port,
            "ocspResponderURL": "", "externalAccountBindingRequired": False}}
        pebble_config = root / "pebble.json"
        pebble_config.write_text(json.dumps(config))
        pebble_log = (root / "pebble.log").open("wb")
        stack.callback(pebble_log.close)
        pebble = subprocess.Popen([str(PEBBLE), "-config", str(pebble_config)],
            env={**os.environ, "PEBBLE_VA_ALWAYS_VALID": "1", "PEBBLE_VA_NOSLEEP": "1"},
            stdout=pebble_log, stderr=subprocess.STDOUT)
        stack.callback(stop, pebble)
        context = ssl.create_default_context(cafile=str(cert))
        for _ in range(100):
            try:
                fetch(f"https://127.0.0.1:{ca_port}/dir", context)
                break
            except OSError:
                if pebble.poll() is not None:
                    raise RuntimeError("Pebble exited before readiness")
                time.sleep(0.05)
        else:
            raise RuntimeError("Pebble did not become ready")

        storage = root / "storage"
        environment = {**os.environ,
            "STORAGE_PATH": str(storage), "TLS_DOMAIN": DOMAIN,
            "ACME_DIRECTORY": f"https://127.0.0.1:{ca_port}/dir",
            "HTTP_PORT": str(http_port), "HTTPS_PORT": str(https_port),
            "TARGET_PORT": str(target_port), "SSL_CERT_FILE": str(cert),
            "XDG_CONFIG_HOME": str(root / "config"),
            "XDG_DATA_HOME": str(root / "data")}
        caddyfile = root / "Caddyfile"
        caddyfile.write_bytes(subprocess.check_output([str(FRONT), "config"], env=environment))
        caddy_log = (root / "caddy.log").open("ab", buffering=0)
        stack.callback(caddy_log.close)

        def start_caddy():
            return subprocess.Popen([str(CADDY), "run", "--config", str(caddyfile),
                "--adapter", "caddyfile"], env=environment,
                stdout=caddy_log, stderr=subprocess.STDOUT)

        caddy = start_caddy()
        stack.callback(stop, caddy)
        first = await_fingerprint(https_port)
        print(f"initial ACME certificate: {first}")
        stop(caddy)

        issuer = f"127.0.0.1-{ca_port}-dir"
        cache = storage / "caddy" / "certificates" / issuer / DOMAIN
        cert_file, key_file = cache / f"{DOMAIN}.crt", cache / f"{DOMAIN}.key"
        original_chain = cert_file.read_bytes()
        chain = re.findall(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----\n?",
            original_chain, re.DOTALL)
        assert len(chain) >= 2, "Pebble did not return a leaf and intermediate"
        intermediate = root / "intermediate.crt"
        intermediate_key = root / "intermediate.key"
        intermediate.write_bytes(fetch(f"https://127.0.0.1:{mgmt_port}/intermediates/0", context))
        intermediate_key.write_bytes(fetch(f"https://127.0.0.1:{mgmt_port}/intermediate-keys/0", context))
        short_cert = root / "short.crt"
        issuer_cert = x509.load_pem_x509_certificate(intermediate.read_bytes())
        issuer_key = serialization.load_pem_private_key(
            intermediate_key.read_bytes(), password=None)
        leaf_key = serialization.load_pem_private_key(key_file.read_bytes(), password=None)
        now = datetime.now(timezone.utc)
        near_expiry = (x509.CertificateBuilder()
            .subject_name(x509.Name([x509.NameAttribute(x509.NameOID.COMMON_NAME, DOMAIN)]))
            .issuer_name(issuer_cert.subject)
            .public_key(leaf_key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(hours=2))
            .not_valid_after(now + timedelta(minutes=5))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName(DOMAIN)]), critical=False)
            .add_extension(x509.ExtendedKeyUsage([x509.oid.ExtendedKeyUsageOID.SERVER_AUTH]),
                critical=False)
            .sign(issuer_key, hashes.SHA256()))
        short_cert.write_bytes(near_expiry.public_bytes(serialization.Encoding.PEM))
        cert_file.write_bytes(short_cert.read_bytes() + b"".join(chain[1:]))
        short_fingerprint = hashlib.sha256(ssl.PEM_cert_to_DER_cert(
            short_cert.read_text())).hexdigest()
        print(f"near-expiry cached certificate: {short_fingerprint}")

        caddy = start_caddy()
        stack.callback(stop, caddy)
        try:
            renewed = await_fingerprint(https_port, unlike=short_fingerprint)
        except Exception:
            print(f"Caddy restart exit: {caddy.poll()}")
            print("Caddy log tail:\n" + (root / "caddy.log").read_text()[-5000:])
            print("Pebble log tail:\n" + (root / "pebble.log").read_text()[-2500:])
            raise
        assert renewed != first, "renewal reused the original certificate"
        assert hashlib.sha256(ssl.PEM_cert_to_DER_cert(
            cert_file.read_text().split("-----END CERTIFICATE-----")[0]
            + "-----END CERTIFICATE-----")).hexdigest() == renewed
        assert (root / "pebble.log").read_text().count("Issued certificate serial") >= 2, (
            "Pebble did not issue a second certificate")
        print(f"ACME renewed near-expiry certificate: {renewed}")


if __name__ == "__main__":
    main()

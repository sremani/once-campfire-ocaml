#!/usr/bin/env python3
"""Bounded, disposable M8 resilience run against the packaged OCaml image.

All fixture credentials stay in the ignored shared verification tree. Results
contain status, counts and resource readings, never cookies or CSRF tokens.
"""

import argparse
import concurrent.futures
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import socket
import sqlite3
import subprocess
import time
import urllib.request


PROJECTS = Path(__file__).resolve().parents[2]
VERIFY = PROJECTS / "once-campfire-verification"
SEED = VERIFY / "fixtures/default"
LOADGEN = VERIFY / "loadgen/target/release/loadgen"
TOOLCHAIN = "campfire-m8-check:pinned"


def command(args, *, label, input_text=None, timeout=120):
    result = subprocess.run(args, input=input_text, text=True, capture_output=True,
                            timeout=timeout, check=False)
    if result.returncode:
        error_file = VERIFY / "tmp/bench" / f"m8-t4-command-error-{os.getpid()}.log"
        error_file.parent.mkdir(parents=True, exist_ok=True)
        error_file.write_text(result.stderr)
        raise RuntimeError(f"{label} failed with exit status {result.returncode}; see {error_file}")
    return result.stdout


def loadgen(action, *args, timeout=120):
    return json.loads(command([str(LOADGEN), action, *map(str, args)],
                              label=f"loadgen {action}", timeout=timeout))


def sql(database, query):
    with sqlite3.connect(database, timeout=10) as connection:
        return connection.execute(query).fetchone()[0]


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def toolchain(script, *, input_text=None, timeout=120):
    return command(["docker", "run", "--rm", "-i", "--network", "host",
                    "--user", f"{os.getuid()}:{os.getgid()}",
                    "-v", f"{VERIFY}:{VERIFY}", "-w", str(VERIFY),
                    TOOLCHAIN, "ruby", script, "--stdin-json"],
                   label=f"{script} validation", input_text=input_text, timeout=timeout)


def contracts(base, cookie, database, labels_path, css, destination):
    payload = dict(base=base, cookie=cookie, database=str(database),
                   labels=str(labels_path), css=css, destination=str(destination))
    result = toolchain("bench/contracts.rb", input_text=json.dumps(payload))
    return json.loads(result)["contracts"]


def audit(database, room, audit_file, expected):
    result = command(["docker", "run", "--rm", "--user", f"{os.getuid()}:{os.getgid()}",
                      "-v", f"{VERIFY}:{VERIFY}", "-w", str(VERIFY), TOOLCHAIN,
                      "ruby", "bench/validate_acks.rb", str(database), str(room),
                      str(expected), str(audit_file)], label="acknowledged-write audit")
    assert json.loads(result) == {"verified": True, "acknowledged": expected}


def wait_ready(base, container):
    for _ in range(150):
        try:
            with urllib.request.urlopen(base + "/up", timeout=1) as response:
                if response.status == 200:
                    return
        except (OSError, TimeoutError):
            pass
        time.sleep(0.1)
    raise RuntimeError(f"{container} did not become healthy")


def sample_stats(container):
    value = json.loads(command(["docker", "stats", "--no-stream", "--format", "{{json .}}", container],
                               label="Docker resource sample"))
    text = value["MemUsage"].split("/", 1)[0].strip()
    match = re.fullmatch(r"([0-9.]+)([KMG]iB|B)", text)
    if not match:
        raise RuntimeError("unrecognized Docker memory unit")
    multiplier = {"B": 1, "KiB": 1024, "MiB": 1024**2, "GiB": 1024**3}[match[2]]
    return {"elapsed_s": round(time.monotonic(), 3),
            "memory_bytes": round(float(match[1]) * multiplier),
            "pids": int(value["PIDs"])}


def raw_http(port, request, *, wait=0):
    with socket.create_connection(("127.0.0.1", port), timeout=4) as client:
        client.settimeout(4)
        client.sendall(request)
        if wait:
            time.sleep(wait)
        try:
            line = bytearray()
            while b"\r\n" not in line and len(line) < 256:
                chunk = client.recv(256 - len(line))
                if not chunk:
                    break
                line.extend(chunk)
            line = bytes(line).split(b"\r\n", 1)[0]
        except TimeoutError as error:
            raise RuntimeError("raw HTTP probe timed out") from error
        except (ConnectionResetError, BrokenPipeError, OSError):
            line = b""
    match = re.match(rb"HTTP/1\.[01] (\d{3})", line)
    return int(match[1]) if match else None


def check_header_probe(probe):
    assert probe["front_normal"] == probe["target_normal"] == 302, probe
    rejected = (None, 400, 413, 431)
    assert probe["front_large"] in rejected, probe
    assert probe["target_large"] in rejected, probe
    assert probe["target_host_interface_reachable"] is False, probe


def check_sample(value, name):
    assert value["validation"] == "route-contract-v1", name
    assert value["errors"] == value["invalid_responses"] == 0, name
    assert value["ok"] > 0 and value["statuses"] == {"200": value["ok"]}, name


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", default="campfire-candidate:latest")
    parser.add_argument("--port", type=int, default=26380)
    parser.add_argument("--duration", type=int, default=60)
    parser.add_argument("--header-probe", action="store_true", help="probe front and loopback target headers without workload")
    parser.add_argument("--header-size", type=int, default=65 * 1024)
    args = parser.parse_args()
    if args.duration < 30:
        parser.error("sustained duration must be at least 30 seconds")
    image = command(["docker", "image", "inspect", "-f", "{{.Id}}", args.image], label="image inspect").strip()
    reference = json.loads((SEED / "source.json").read_text())
    labels = json.loads((SEED / "labels.json").read_text())
    run_dir = VERIFY / "tmp/bench" / f"m8-t4-resilience-{int(time.time())}-{os.getpid()}"
    storage = run_dir / "storage"
    storage.mkdir(parents=True)
    shutil.copytree(SEED / "db", storage / "db")
    shutil.copytree(SEED / "storage", storage / "files")
    for name in ("logs", "backups", "thruster"):
        (storage / name).mkdir()
    database = storage / "db/production.sqlite3"
    with sqlite3.connect(database) as connection:
        connection.execute("UPDATE push_subscriptions SET endpoint = 'https://127.0.0.1:9/push/' || id")
        connection.execute("UPDATE webhooks SET url = 'http://127.0.0.1:9/hook/' || id")
    container = f"cf-m8-t4-resilience-{os.getpid()}"
    base = f"http://127.0.0.1:{args.port}"
    summary = {"image": image, "source_head": command(["git", "-C", str(PROJECTS / "once-campfire-ocaml"),
        "rev-parse", "HEAD"], label="source revision").strip(),
        "seed_sha256": reference["seed_sha256"], "loadgen_sha256": sha256(LOADGEN),
        "host_cpus": os.cpu_count(), "port": args.port,
        "criteria": {"concurrent": "four validated workers, four clients each, 8 seconds; zero errors and exact acknowledged writes in two rooms",
          "cable": "two subscribers; all acknowledged posts delivered to both and persisted",
          "sustained": f"{args.duration} seconds, eight validated room readers; peak <1 GiB, PIDs <200, tail memory <1.5x settled plus 64 MiB",
          "security": "malformed and oversized requests rejected; slow/disconnected clients do not lose health",
          "recovery": "SIGKILL/restart and backup/restore retain every acknowledged write and pass SQLite integrity"}}
    started = False
    try:
        config = ["docker", "run", "-d", "--name", container, "--network", "host",
                  "--cpuset-cpus", "8-11", "--env-file", str(SEED / "reference.env"),
                  "-e", f"HTTP_PORT={args.port}", "-e", f"TARGET_PORT={args.port + 1}",
                  "-e", "MAX_REQUEST_BODY=1048576", "-e", "HTTP_READ_TIMEOUT=2",
                  "-e", "HTTP_IDLE_TIMEOUT=2", "-e", "HTTP_WRITE_TIMEOUT=5"]
        for name in ("db", "files", "logs", "backups", "thruster"):
            config.extend(["-v", f"{storage / name}:/rails/storage/{name}"])
        config.append(image)
        command(config, label="disposable container start")
        started = True
        wait_ready(base, container)
        if args.header_probe:
            room = int(labels["rooms.watercooler"])
            normal = f"GET /rooms/{room} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".encode()
            large = f"GET /rooms/{room} HTTP/1.1\r\nHost: localhost\r\nX-Fill: ".encode() + b"a" * args.header_size + b"\r\nConnection: close\r\n\r\n"
            probe = {"front_normal": raw_http(args.port, normal),
                     "front_large": raw_http(args.port, large),
                     "target_normal": raw_http(args.port + 1, normal),
                     "target_large": raw_http(args.port + 1, large),
                     "header_size": args.header_size}
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as ip_probe:
                ip_probe.connect(("192.0.2.1", 80))
                host_ip = ip_probe.getsockname()[0]
            try:
                with socket.create_connection((host_ip, args.port + 1), timeout=2):
                    probe["target_host_interface_reachable"] = True
            except OSError:
                probe["target_host_interface_reachable"] = False
            summary["header_probe"] = probe
            check_header_probe(probe)
            summary["complete"] = True
            return
        login = loadgen("login", "--base", base, "--email", labels["emails.david"],
                        "--password", labels["passwords.all"])
        cookie = login["cookie"]
        room_a = int(labels["rooms.hq"])
        room_b = int(labels["rooms.watercooler"])
        scrape_a = loadgen("scrape", "--base", base, "--cookie", cookie, "--room", room_a)
        scrape_b = loadgen("scrape", "--base", base, "--cookie", cookie, "--room", room_b)
        csrf = scrape_a["csrf"]
        contract_a = contracts(base, cookie, database, SEED / "labels.json",
                               scrape_b["css"], run_dir / "contracts-a")
        labels_b = dict(labels, **{"rooms.hq": room_b})
        labels_b_path = run_dir / "labels-b.json"
        labels_b_path.write_text(json.dumps(labels_b))
        contract_b = contracts(base, cookie, database, labels_b_path,
                               scrape_b["css"], run_dir / "contracts-b")
        before = {room: sql(database, f"SELECT COUNT(*) FROM messages WHERE room_id={room}")
                  for room in (room_a, room_b)}
        jobs = [
            ("read-room", ["--path", f"/rooms/{room_b}/messages?before={labels['messages.busy_060']}",
                           "--validate", contract_a["messages_page"]]),
            ("read-search", ["--path", "/searches?q=coffee", "--validate", contract_a["search"]]),
            ("write-hq", ["--post-room", str(room_a), "--csrf", csrf, "--validate", contract_a["post_message"],
                            "--audit-writes", str(run_dir / "write-hq.jsonl")]),
            ("write-watercooler", ["--post-room", str(room_b), "--csrf", csrf,
                                    "--validate", contract_b["post_message"],
                                    "--audit-writes", str(run_dir / "write-watercooler.jsonl")]),
        ]
        def work(job):
            name, extra = job
            value = loadgen("http", "--base", base, "--cookie", cookie, *extra,
                            "--conc", "4", "--duration", "8", timeout=55)
            check_sample(value, name)
            (run_dir / f"{name}.json").write_text(json.dumps(value, indent=2) + "\n")
            return name, value
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = dict(pool.map(work, jobs))
        for room, name, audit_name in ((room_a, "write-hq", "write-hq.jsonl"),
                                       (room_b, "write-watercooler", "write-watercooler.jsonl")):
            acknowledged = results[name]["ok"]
            assert sql(database, f"SELECT COUNT(*) FROM messages WHERE room_id={room}") - before[room] == acknowledged
            audit(database, room, run_dir / audit_name, acknowledged)
        assert sql(database, "PRAGMA integrity_check") == "ok"
        summary["concurrent"] = {name: {"ok": value["ok"], "errors": value["errors"],
                                          "invalid": value["invalid_responses"]}
                                 for name, value in results.items()}
        cable_before = sql(database, "SELECT MAX(id) FROM messages")
        cable = loadgen("cable", "--base", base, "--cookie", cookie, "--room", room_b,
                        "--csrf", csrf, "--clients", "2", "--streams", ",".join(scrape_b["streams"]),
                        "--latency-msgs", "5", "--interval-ms", "150", "--tput-secs", "3",
                        "--posters", "1", timeout=100)
        (run_dir / "cable.json").write_text(json.dumps(cable, indent=2) + "\n")
        assert cable["ready"] == 2 and cable["failed"] == 0
        assert cable["latency"]["post_errors"] == cable["throughput"]["post_errors"] == 0
        assert cable["latency"]["complete"] == cable["latency"]["post_successes"]
        assert cable["throughput"]["complete"] == cable["throughput"]["posted"]
        cable_posts = cable["latency"]["post_successes"] + cable["throughput"]["posted"]
        assert sql(database, f"SELECT COUNT(*) FROM messages WHERE id>{cable_before} AND room_id={room_b}") == cable_posts
        assert sql(database, f"SELECT COUNT(*) FROM messages WHERE id>{cable_before} AND id NOT IN (SELECT rowid FROM message_search_index)") == 0
        summary["cable"] = {"ready": 2, "latency_complete": cable["latency"]["complete"],
                            "throughput_complete": cable["throughput"]["complete"]}
        slow = b"POST /up HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 12\r\nConnection: close\r\n\r\n{"
        slow_status = raw_http(args.port, slow, wait=3)
        assert slow_status != 200
        malformed = b"POST /up HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 1\r\nConnection: close\r\n\r\n{"
        malformed_status = raw_http(args.port, malformed)
        assert malformed_status == 400
        oversized = b"POST /up HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 1048577\r\nConnection: close\r\n\r\n"
        oversized_status = raw_http(args.port, oversized)
        assert oversized_status == 413
        large_header = f"GET /rooms/{room_b} HTTP/1.1\r\nHost: localhost\r\nX-Fill: ".encode() + b"a" * 65536 + b"\r\n\r\n"
        header_status = raw_http(args.port, large_header)
        assert header_status in (None, 400, 413, 431), header_status
        for _ in range(20):
            with socket.create_connection(("127.0.0.1", args.port), timeout=3) as client:
                client.sendall(b"GET /up HTTP/1.1\r\nHost: localhost\r\n\r\n")
        wait_ready(base, container)
        summary["security"] = {"slow_status": slow_status, "malformed_status": malformed_status,
                               "oversized_status": oversized_status, "large_header_status": header_status,
                               "disconnected_clients": 20, "health_after": 200}
        samples = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(loadgen, "http", "--base", base, "--cookie", cookie,
                                 "--path", f"/rooms/{room_b}/messages?before={labels['messages.busy_060']}",
                                 "--validate", contract_a["messages_page"],
                                 "--conc", "8", "--duration", str(args.duration), timeout=args.duration + 45)
            while not future.done():
                samples.append(sample_stats(container))
                time.sleep(5)
            sustained = future.result()
        check_sample(sustained, "sustained room reads")
        (run_dir / "sustained.json").write_text(json.dumps(sustained, indent=2) + "\n")
        (run_dir / "resources.json").write_text(json.dumps(samples, indent=2) + "\n")
        assert samples and max(item["memory_bytes"] for item in samples) < 1024**3
        assert max(item["pids"] for item in samples) < 200
        assert samples[-1]["memory_bytes"] < 1.5 * samples[min(2, len(samples)-1)]["memory_bytes"] + 64 * 1024**2
        summary["sustained"] = {"ok": sustained["ok"], "memory_peak_bytes": max(item["memory_bytes"] for item in samples),
                                "pids_peak": max(item["pids"] for item in samples), "samples": len(samples)}
        command(["docker", "kill", "--signal", "KILL", container], label="process crash")
        command(["docker", "start", container], label="container restart")
        wait_ready(base, container)
        for room, name, audit_name in ((room_a, "write-hq", "write-hq.jsonl"),
                                       (room_b, "write-watercooler", "write-watercooler.jsonl")):
            audit(database, room, run_dir / audit_name, results[name]["ok"])
        assert sql(database, "PRAGMA integrity_check") == "ok"
        command(["docker", "exec", container, "/hooks/pre-backup"], label="backup hook", timeout=90)
        backup = storage / "backups/production.sqlite3"
        assert backup.is_file() and sql(backup, "PRAGMA integrity_check") == "ok"
        restored = run_dir / "restored.sqlite3"
        shutil.copy2(backup, restored)
        for room, name, audit_name in ((room_a, "write-hq", "write-hq.jsonl"),
                                       (room_b, "write-watercooler", "write-watercooler.jsonl")):
            audit(restored, room, run_dir / audit_name, results[name]["ok"])
        assert sql(restored, "SELECT COUNT(*) FROM messages") == sql(database, "SELECT COUNT(*) FROM messages")
        summary["recovery"] = {"restart_health": 200, "database_integrity": "ok",
                               "backup_integrity": "ok", "backup_sha256": sha256(backup),
                               "restored_messages": sql(restored, "SELECT COUNT(*) FROM messages")}
        summary["complete"] = True
    except Exception as error:
        summary["complete"] = False
        summary["failure"] = str(error)
        raise
    finally:
        if started:
            subprocess.run(["docker", "logs", container], stdout=(run_dir / "container.log").open("wb"),
                           stderr=subprocess.STDOUT, check=False)
            subprocess.run(["docker", "rm", "-f", container], capture_output=True, check=False)
        (run_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(f"raw results: {run_dir}; complete={summary['complete']}")


if __name__ == "__main__":
    main()

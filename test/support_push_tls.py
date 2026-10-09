#!/usr/bin/env python3
"""One-request TLS endpoint for the M5 Web Push integration test."""

import base64
import json
import socket
import ssl
import sys
import time


def main():
    cert, key, capture, response_code, delay = sys.argv[1:]
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(5)
    print(listener.getsockname()[1], flush=True)
    try:
        raw, _ = listener.accept()
        with context.wrap_socket(raw, server_side=True) as peer:
            peer.settimeout(5)
            wire = b""
            while b"\r\n\r\n" not in wire:
                chunk = peer.recv(65536)
                if not chunk:
                    raise EOFError("request headers ended early")
                wire += chunk
            head, body = wire.split(b"\r\n\r\n", 1)
            lines = head.decode("ascii").split("\r\n")
            headers = [line.split(":", 1) for line in lines[1:]]
            headers = [[key, value.lstrip()] for key, value in headers]
            length = int(next((value for key, value in headers
                               if key.lower() == "content-length"), "0"))
            while len(body) < length:
                chunk = peer.recv(length - len(body))
                if not chunk:
                    raise EOFError("request body ended early")
                body += chunk
            with open(capture, "w", encoding="utf-8") as output:
                json.dump({"request_line": lines[0], "headers": headers,
                           "body_base64": base64.b64encode(body).decode("ascii")}, output)
            time.sleep(float(delay))
            reason = "Created" if response_code == "201" else "Gone"
            reply = (f"HTTP/1.1 {response_code} {reason}\r\n"
                     "Content-Length: 0\r\nConnection: close\r\n\r\n")
            try:
                peer.sendall(reply.encode("ascii"))
            except OSError:
                pass  # The deadline case closes the client connection first.
    finally:
        listener.close()


if __name__ == "__main__":
    main()

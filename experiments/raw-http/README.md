# Raw HTTP transport probes

`raw_up.ml` serves the fixed `/up` body through Lwt sockets. It measures a
transport ceiling and does not call the application.

`http_raw.ml` calls the real `Http_app.handle` from a small HTTP/1.1 adapter.
Build its disposable image with `docker build -f
experiments/raw-http/Dockerfile.runtime -t campfire-ocaml:raw-http .`.
This adapter exists only to isolate parser and writer cost. It does not support
WebSocket upgrades, chunked requests, streaming responses, all production
limits, or graceful shutdown. The accepted sockets use TCP_NODELAY; without
it, separate header and body writes caused a delayed-ACK stall in the probe.

Results and interpretation are in `docs/performance-escalation-progress.md`.

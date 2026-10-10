# HTTP/af transport probe

This disposable probe swaps the Cohttp socket/parser/writer for `httpaf` and
its Lwt adapter while calling the real Campfire router. It exists to measure
the transport portion of the request cost. It is not a deployable server:
WebSocket upgrades, streaming uploads, target timeouts, graceful shutdown,
and the full production front policy are not implemented. The response bridge
buffers bodies and converts them to fixed-length HTTP/af responses.

Build the dependency image, then the probe image:

```sh
docker build -f experiments/httpaf/Dockerfile.deps -t campfire-ocaml:httpaf-deps .
docker build -f experiments/httpaf/Dockerfile.runtime -t campfire-ocaml:httpaf-probe-exp .
```

The build copies `httpaf_probe.ml` into the container's `bin` directory and
adds a temporary Dune stanza there. The normal Campfire package keeps its
original dependencies and server executable.

The pinned benchmark preflight passed in
`once-campfire-verification/tmp/bench/ocaml55-httpaf-framed-preflight-20261010/`.
The first timed run is in `tmp/bench/ocaml55-httpaf-r1-20261010/`; it passed
every route contract and exact POST write audit, but compiler load on its
assigned cores made its two rounds incomparable. A later same-source pair on
quieter physical cores is in
`tmp/bench/ocaml55-{httpaf,cohttp}-current-quietcores-20261010/`.
See `docs/performance-escalation-progress.md` for the measured differences
and the remaining compatibility work.

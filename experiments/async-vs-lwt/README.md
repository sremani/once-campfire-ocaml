# Cohttp Async versus Lwt transport probe

This is a standalone OCaml 4.14 transport experiment, separate from the Campfire
application build. Both servers return byte-identical bodies: 3 bytes for
`/up` and 21,267 bytes for `/rooms/1`. The load generator ran three alternating
rounds with server CPUs 8–11 and client CPUs 12–15; all 24 samples had zero
errors and invalid responses. Raw samples are in `results.json`.

| Route | Clients | Lwt median req/s | Async median req/s | Async/Lwt |
| --- | ---: | ---: | ---: | ---: |
| `/up` | 1 | 71,004 | 62,829 | 0.88× |
| `/up` | 16 | 83,424 | 104,542 | 1.25× |
| `/rooms/1` | 1 | 38,301 | 57,629 | 1.50× |
| `/rooms/1` | 16 | 41,906 | 87,244 | 2.08× |

Build from this directory with `docker build -t campfire-async-lwt:probe .`.
Then run the two servers and the shared verification load generator:

```sh
docker run -d --name campfire-probe-lwt --network host --cpuset-cpus 8-11 \
  campfire-async-lwt:probe ./_build/default/lwt_server.exe 25170
docker run -d --name campfire-probe-async --network host --cpuset-cpus 8-11 \
  campfire-async-lwt:probe ./_build/default/async_server.exe 25171
python3 run.py
docker rm -f campfire-probe-lwt campfire-probe-async
```

These numbers isolate Cohttp transport and
fixed-body writes. They do not include Campfire routing, authentication, SQLite,
templates, Cable, or Caddy, so they are a reason to test Async in the real app,
not a projected Campfire speedup.

# M3-T1 HTTP foundation handoff

The Cohttp/Lwt application boundary is in `Http_app`. Controllers register an
`endpoint` record with an `action` and `before_action`. `App_dispatch.endpoint`
is the central endpoint registry. `campfire serve --port PORT --database PATH`
opens the configured SQLite runtime, serves via Cohttp, and closes the runtime
when the listener returns. `Config.from_env` supplies the secret and storage
defaults.

The request context exposes the selected route, original and overridden method,
raw body, body/query/path/merged params, Rails encrypted session, cookie jar,
negotiated formats, typed current user, bot authentication source, and the
asynchronous database runtime. Path params include `controller` and `action` and
override query params, which override body params. `before` checks banned IPs
on writes even for public actions; authenticated routes try signed sessions,
then active bot keys; ordinary routes reject bot users. A valid bot key skips
CSRF on bot-enabled routes. The named endpoint hook lets controllers select
public, guest-only, user, or bot-enabled behavior.

`Http_params` matches all **2,755** pinned Rails nested-query output vectors.
Direct parser tests check malformed encoding, hash/array type conflicts, depth,
form limits, empty JSON, missing multipart boundary fallback, binary file
content, delimiter-prefix safety, malformed closing delimiters, blank file
selection, and multipart part limits. `Http_format` covers the pinned Rails MIME
registrations and tested
quality ordering, wildcard, XML, browser Accept, extension, and explicit format
precedence. `Http_gzip` uses system zlib for Rack-style gzip and Vary headers.

Verification after streamed multipart integration:

- `dune build --build-dir _build_m3_t1 @all`: passed.
- `dune runtest --build-dir _build_m3_t1 --force test`: passed across the current
  M1–M8 suites with loopback access, including **16/16** M3-T1 cases and
  **7/7** seeded M3-T3 controller cases. The restricted sandbox run failed
  only where other suites require loopback sockets and received `EPERM`;
  the socket-enabled rerun passed.
- The earlier M3-T1 executable passed with socket access; its real TCP listener
  accepted a request and returned the expected response.
- `campfire serve` ran against a disposable SQLite database on localhost and
  returned the expected anonymous `302` to `/session/new` on `/`.

## Streamed multipart completion

`Http_params.parse_multipart_stream` now parses Cohttp body chunks incrementally
and spools each file to a request-owned `RackMultipart*.tmp` path. An upload
contains its `path` and `size` instead of in-memory contents. The whole
multipart stream has Rust's **10 GiB** default limit, or the smaller configured
`max_body_bytes` limit. Non-multipart bodies retain their **16 MiB** limit.
Multipart requests retain the **4,096-part**, **128-file**, and **16 MiB**
aggregate text-field limits; size rejection returns **413**.

The parser cleans paths on parse rejection, exception, or cancellation. After a
successful parse, `Http_app` owns them until the request handler finishes. A
controller starting an asynchronous file staging worker registers its promise
with `Http_app.track_upload_worker ctx worker`; request cleanup waits for all
registered workers before unlinking temp paths, including when the request is
cancelled. `Controller_rooms` stages message and bot attachments through
`Storage_blob.stage_file` using this contract. The API assumes controllers do
not retain a request upload path after the handler's tracked work completes.

The focused M3-T1 executable passes **16/16** cases and all **2,755** nested
parameter vectors. It streams a **129 MiB** file past the former buffered cap,
tests delimiter prefixes in file data and malformed close markers, verifies
configured size rejection and parse cleanup, and proves request cleanup after
success, before-action rejection, handler exception, and cancellation while a
tracked staging worker is still reading the file. The seeded M3-T3 attachment
route suite passes **6/6**, including browser create/remove and bot creation
with persisted blob bytes. The 10 GiB limit is checked as a byte-counting rule;
the suite does not write a 10 GiB fixture to disk.

## M8 request bound and public exception follow-up

The fresh-source direct `Front_target` listener regression sends raw HTTP/1.1
requests over loopback. A normal 4,096-byte `X-Fill` header returns **200**;
66,560-byte and 1,048,576-byte `X-Fill` headers close without a response and
never reach route dispatch. `Front_target.read_line` counts request-line and
header bytes against **64 KiB**, with a separate 256-line cap. The earlier
**302** observation came from the old `campfire-ocaml:m7-t3` image; a current
packaged-image probe remains for the M8 security gate. The current Caddy
configuration also sets `max_header_size 64KiB`.

The first immutable M8-T2 default-seed matrix had 20 signed **400** cases with
different cache, MIME, cookie, security, version and `Vary` headers: route rows
**23/24, 29, 33/34, 40/41, 45/46, 60/61, 66, 105, 109/110, 113,
117/118, 129, 147**. The current controller sources return marked
`PublicExceptions` responses for the missing-parameter paths. `Http_app.commit`
bypasses app headers and cookies on that marker; `Http_cache.finish` removes
the marker without adding cache headers.

The subsequent immutable **620/708** matrix isolated those 20 signed **400**
cases to `Vary` alone and exposed 14 formerly passing empty public exception
cases with the same header gap: rows **18** and **90** signed/denied,
**148/149** all four roles, and **176** signed/denied. A saved live sample showed
Rust sends `Vary: Accept-Encoding` and OCaml had none on empty **400** and
**406** public exceptions. The earlier attempt to omit synthetic `Vary` was
incorrect: Rack::Deflater skips an explicit `Content-Length: 0`, but Thruster's
front compression adds `Vary: Accept-Encoding` on every response. The HTTP
boundary now adds one fallback `Vary` on empty marked exceptions, without
adding a duplicate. The focused test checks one `Vary` on empty **400/406**,
the exact empty **400** MIME and length, omission of app version, security,
cookie, cache and internal marker headers, and the expected two `Vary` fields
on a nonempty response when the front cache is bypassed. A targeted live row
probe and fresh 708-cell differential remain the completion gates.

## Cable listener seam

`Http_app.serve` now uses Cohttp's `make_response_action`. Ordinary HTTP
requests remain `Response` actions. An explicit `cable_run` callback routes
`/cable` through `Cable_transport.handle`, which can return an `Expert` action
for a valid upgrade. The listener returns the ordinary 404 without that
callback, so a WebSocket connection cannot be accepted before M5-T2 supplies
authenticated Action Cable behavior. `cable_config` can override the transport
origin policy; its default follows the listener's `ssl` setting.

Response/cache finalization (ETag, conditional responses, gzip streaming/cache,
and public/private headers) belongs to M3-T5. Front server TLS, proxy behavior,
and zstd compression belong to M7.

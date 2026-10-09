# M6-T1 blob and disk service

Source contract: pinned Rust `crates/storage` at
`9872c1d9541551c0889a60e3d49a14488bd1e403`, Rails reference
`90b330024dec3e757c79b6a7e6568f93da8e3148`.

`Storage_disk` supplies base36 keys, `<first 2>/<next 2>/<key>` paths,
Base64 MD5 checksums, atomic file copies, signed disk GET keys and direct PUT
tokens. `Storage_blob` supplies signed blob IDs, MIME identification, staged
file ownership, row insertion, verified tempfile opens, and purge of tracked
variant/preview children and legacy image variants. `Storage_marcel` uses tables
generated from the pinned Rails bundle's Marcel 1.1.0 dump. `Storage_http`
registers blob redirect/proxy, disk GET/PUT, and direct-upload POST handlers
through `Controller_aux.register_storage`; the executable registers the local
service using `Config.storage.files`.

The disk GET file server sends bounded chunks and supports conditional GET,
HEAD, single/multiple byte ranges, and 416. Direct-upload POST rejects sizes
above 16 MiB, matching the Rust buffered PUT path. This limit is distinct from
the 10 GiB multipart message upload limit.

## Multipart file handoff to M3-T1

The current `Http_params.File.contents : string` and `Http_app.body : string`
still buffer multipart requests to 128 MiB. M3-T1 owns the parser and request
lifetime change. Its request-scoped upload handle should contain a temporary
file path, byte size, original filename, content type, and raw headers. The
parser should enforce 10 GiB total, 4,096 parts, 128 files, and 16 MiB total
text fields while consuming the Cohttp stream incrementally. `Http_app` should
own every temp path and delete it on parse failure, before-action rejection,
handler success, handler exception, and client cancellation. A handler must not
retain a request temp path after completion.

The storage consumer API is:

```ocaml
Storage_blob.stage_file service ~source:request_temp_path
  ~filename:original_filename ~content_type:declared_type
  (fun prepared staged ->
    let blob = Db_runtime.write runtime (fun tx ->
      Storage_blob.insert tx ~now prepared) in
    Storage_disk.keep staged; (* only after the row commits *)
    blob)
```

`stage_file` streams a copy into the disk service, identifies MIME from the
copied file using Marcel, checksums that file, then enters the callback. Its
`with_staged` owner deletes the copied service file if the callback exits
without `keep`, including failed database writes. Run this blocking work in a
worker thread, outside the Lwt event loop and the SQLite writer. The request
temp path may be deleted immediately after `stage_file` returns. `open_verified`
copies a stored file to a named temporary file, verifies its checksum, and
deletes the temporary file after the callback exits.

M6-T2/M6-T3 can register a representation processor with
`Storage_http.register_representation`. Until they do, representation routes
return 501 after validating the signed variation key. The processing callback
must return the stored variant or preview blob and handle concurrent winner
reuse; the existing redirect/proxy actions then serve that blob.

## Evidence

`test/m6_t1_test.ml` compares three pinned signed disk/direct-upload URLs,
16 filename cases, five message blob path cases, all 51 Marcel MIME cases,
and eight original blob checksum/size/MIME cases (five messages, two avatars,
one logo). It covers malformed, expired and wrong-service tokens;
large streamed copy and checksum mismatch; abandoned staged files; a rolled
back row; commit, verified open, dependent purge; pinned Rails seed blob GET
and checksum; eight concurrent uploads (the test exposed and fixed a directory
creation race, then passed 20 repeated runs); byte ranges; public blob redirect;
authenticated direct POST/PUT;
anonymous PUT; and failed PUT cleanup. `dune build && dune runtest test --force`
passed after this implementation.

Closure audit (2026-10-09): M3-T1 streams request-owned temp files through the
storage service with a 10 GiB incremental cap; its 129 MiB upload and cleanup
cases pass. M5's after-commit `PurgeBlob` worker removes the row and file, while
rollback retains both (seeded integration suite 8/8). M6-T4 compared signed
storage routes with live Rails. See [M6 audit](m6-audit.md).

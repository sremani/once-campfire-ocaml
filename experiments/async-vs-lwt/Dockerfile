FROM ocaml/opam:ubuntu-24.04-ocaml-4.14@sha256:654a3f4a8efb541bb9d6b64ef55b5e7430ffae325d739a4016e456e2448ba888 AS deps

RUN opam install -y --jobs=4 dune cohttp-async.5.3.0 cohttp-lwt-unix.5.3.0

FROM deps
WORKDIR /home/opam/probe
COPY --chown=opam:opam . .
RUN opam exec -- dune build --profile release ./lwt_server.exe ./async_server.exe

ENTRYPOINT ["opam", "exec", "--"]

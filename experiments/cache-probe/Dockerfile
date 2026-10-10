FROM campfire-ocaml:ocaml55-deps AS build
WORKDIR /home/opam/campfire
COPY --chown=opam:opam . .
RUN opam exec -- dune build --profile release bin/main.exe

FROM campfire-ocaml:authread-exp
COPY --from=build /home/opam/campfire/_build/default/bin/main.exe /usr/local/bin/campfire

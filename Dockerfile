# syntax=docker/dockerfile:1.7
# Build with OCaml 5.5.1 and package into the pinned Debian trixie runtime.
ARG DEBIAN_IMAGE=docker.io/library/debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f
ARG OCAML_BUILD_IMAGE=ocaml/opam:ubuntu-24.04-ocaml-5.5@sha256:612f36244a0a6b24e2a3bcdcb8555da8ec21c5cb6a37741b5fc20d3a7c8f1630
FROM ${OCAML_BUILD_IMAGE} AS build
USER root
RUN apt-get update -qq && apt-get install --no-install-recommends -y \
    build-essential pkg-config libsqlite3-dev libssl-dev libcurl4-openssl-dev \
    libqrencode4 zlib1g-dev libgmp-dev libcrypt-dev && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /out && chown opam:opam /out
USER opam
RUN opam install -y --jobs=4 \
    dune.3.24.2 sqlite3 uri ipaddr yojson.2.2.2 base64 astring ocplib-endian \
    conduit.6.2.3 conduit-lwt-unix.6.2.3 \
    mirage-crypto.0.11.3 mirage-crypto-rng.0.11.3 \
    cstruct pbkdf.1.2.0 eqaf ptime uutf \
    cohttp.5.3.0 cohttp-lwt.5.3.0 cohttp-lwt-unix.5.3.0 \
    ssl lwt logs fmt cmdliner tyxml
# Installing lwt_ssl before the Conduit rebuild enables its real TLS backend.
RUN opam install -y lwt_ssl.1.2.0 && \
    opam reinstall -y conduit-lwt-unix.6.2.3
WORKDIR /home/opam/campfire
COPY --chown=opam:opam . .
RUN opam exec -- dune build --profile release bin/main.exe bin/front.exe && \
    install -D -m 755 _build/default/bin/main.exe /out/campfire && \
    install -D -m 755 _build/default/bin/front.exe /out/campfire-front && \
    opam list --installed --short --columns=package --color=never \
      > /out/build-opam-packages.txt && \
    dpkg-query -W --showformat='${Package}\t${Version}\t${Architecture}\n' \
      > /out/build-packages.tsv && \
    mkdir -p /out/build-copyrights && \
    dpkg-query -W --showformat='${Package}\n' | \
      while IFS= read -r package; do \
        cp -L "/usr/share/doc/${package}/copyright" \
          "/out/build-copyrights/${package}.copyright" || exit 1; \
      done

FROM ${DEBIAN_IMAGE}
ARG CADDY_VERSION=2.6.2-12+deb13u1
ARG LIBVIPS_VERSION=8.16.1-1+deb13u1
ARG FFMPEG_VERSION=7:7.1.5-0+deb13u1
RUN apt-get update -qq && apt-get install --no-install-recommends -y \
    ca-certificates openssl caddy=${CADDY_VERSION} \
    libvips42t64=${LIBVIPS_VERSION} ffmpeg=${FFMPEG_VERSION} \
    libsqlite3-0 libssl3t64 libcurl4t64 libqrencode4 libcrypt1 libev4t64 zlib1g && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
WORKDIR /rails
COPY --from=build /out/campfire /usr/local/bin/campfire
COPY --from=build /out/campfire-front /usr/local/bin/campfire-front
COPY --chown=1000:1000 assets /rails/assets
COPY --chmod=644 LICENSE /usr/share/doc/once-campfire-ocaml/LICENSE
COPY --chmod=644 vendor/cable_websocket/LICENSE.md /usr/share/doc/once-campfire-ocaml/CABLE-WEBSOCKET-LICENSE.md
COPY --chmod=644 vendor/gumbo/LICENSE-DEPENDENCIES.md /usr/share/doc/once-campfire-ocaml/GUMBO-LICENSE-DEPENDENCIES.md
COPY --chmod=644 vendor/gumbo/provenance.json /usr/share/doc/once-campfire-ocaml/GUMBO-PROVENANCE.json
COPY --from=build --chmod=644 /out/build-packages.tsv /usr/share/doc/once-campfire-ocaml/build-packages.tsv
COPY --from=build --chmod=644 /out/build-opam-packages.txt /usr/share/doc/once-campfire-ocaml/build-opam-packages.txt
COPY --from=build --chmod=644 /out/build-copyrights/ /usr/share/doc/once-campfire-ocaml/build-copyrights/
RUN chmod 755 /usr/share/doc/once-campfire-ocaml /usr/share/doc/once-campfire-ocaml/build-copyrights
COPY --chmod=755 deploy/boot /rails/bin/boot
COPY --chmod=755 hooks/pre-backup /hooks/pre-backup
COPY --chmod=755 hooks/post-restore /hooks/post-restore
RUN mkdir -p /rails/storage/db /rails/storage/files /rails/storage/backups \
    /rails/storage/thruster && chown -R 1000:1000 /rails
ARG OCI_DESCRIPTION="OCaml port of ONCE Campfire"
ARG OCI_SOURCE
LABEL org.opencontainers.image.description="${OCI_DESCRIPTION}" \
      org.opencontainers.image.source="${OCI_SOURCE}" \
      org.opencontainers.image.licenses="MIT"
USER 1000:1000
ENV RAILS_ENV=production \
    CAMPFIRE_ASSETS_DIR=/rails/assets \
    HTTP_IDLE_TIMEOUT=60 \
    HTTP_READ_TIMEOUT=300 \
    HTTP_WRITE_TIMEOUT=300
ARG APP_VERSION
ARG GIT_REVISION
ENV APP_VERSION=${APP_VERSION} GIT_REVISION=${GIT_REVISION}
EXPOSE 80 443
CMD ["bin/boot"]

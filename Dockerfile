# syntax=docker/dockerfile:1.7
# Build from the pinned Debian trixie multi-architecture base. The package
# versions below are the Debian equivalents of the pinned Rust image.
ARG DEBIAN_IMAGE=docker.io/library/debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f
ARG UBUNTU_BUILD_IMAGE=docker.io/library/ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55
# Ubuntu 24.04 carries Mirage Crypto 0.11.2 and PBKDF 1.2.0, the APIs this
# port was built against. Debian trixie's Mirage Crypto 2.0 breaks those APIs.
FROM ${UBUNTU_BUILD_IMAGE} AS build
RUN apt-get update -qq && apt-get install --no-install-recommends -y \
    build-essential pkg-config ocaml-nox=4.14.1-1ubuntu1 ocaml-findlib \
    ocaml-dune=3.14.0-1 \
    libsqlite3-ocaml-dev liburi-ocaml-dev libipaddr-ocaml-dev \
    libyojson-ocaml-dev libbase64-ocaml-dev libastring-ocaml-dev \
    libocplib-endian-ocaml-dev libconduit-ocaml-dev=6.2.1-1build3 \
    libmirage-crypto-ocaml-dev=0.11.2-2build3 libcstruct-ocaml-dev \
    libpbkdf-ocaml-dev=1.2.0-3build7 \
    libeqaf-ocaml-dev libptime-ocaml-dev libuutf-ocaml-dev \
    libcohttp-ocaml-dev libcohttp-lwt-ocaml-dev \
    libcohttp-lwt-unix-ocaml-dev=5.3.0-1build6 \
    libconduit-lwt-ocaml-dev libssl-ocaml-dev liblwt-ocaml-dev \
    liblogs-ocaml-dev libfmt-ocaml-dev libcmdliner-ocaml-dev \
    libtyxml-ocaml-dev \
    libcurl4-openssl-dev libqrencode-dev zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN dune build --profile release bin/main.exe bin/front.exe && \
    install -D -m 755 _build/default/bin/main.exe /out/campfire && \
    install -D -m 755 _build/default/bin/front.exe /out/campfire-front

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

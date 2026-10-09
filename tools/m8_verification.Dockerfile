# Disposable toolchain for the pinned shared verification harness's bin/check.
FROM node:22.18.0-trixie@sha256:5329a2a013f6a49e8698609f9b20aa9aac670672ab6d88af73e3517cd79790e7 AS node
FROM rust:1.98.1-trixie@sha256:a8a5f0a1e5fe7dfe1d352591e4a1c7dd2c08fd70475cae872cf3458ba0df0546
COPY --from=node /usr/local/bin/node /usr/local/bin/node
RUN rustup component add rustfmt clippy && \
    apt-get update -qq && apt-get install --no-install-recommends -y ruby sqlite3 ffmpeg && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /verify

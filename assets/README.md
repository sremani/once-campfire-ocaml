# Pinned frontend assets

`files/` is the complete static asset tree served by the OCaml app: the reference Rails app's
JS, CSS, images, fonts, sounds, and public error pages, plus the Rust port's five intentional
frontend overrides. The files and `manifest.json` are digested Propshaft output. They are
committed so building or running the OCaml app needs neither Node nor Rails nor Rust.

The source is the pinned Rust checkout `9872c1d9541551c0889a60e3d49a14488bd1e403`
and its Rails submodule `90b330024dec3e757c79b6a7e6568f93da8e3148`.
`scripts/export_assets.py` verifies those commits and copies the output of the Rust asset
crate after its reference tests pass. To refresh reproducibly:

```sh
cd ../once-campfire-rust
RUSTC_WRAPPER= SOURCE_DATE_EPOCH=1791490381 cargo test -p campfire_assets --test reference
cd ../once-campfire-ocaml
python3 scripts/export_assets.py
dune exec ./test/m4_t1_test.exe -- -q
```

`built_at.txt` is the pinned build timestamp used for `Last-Modified`. The test fixtures in
`test/fixtures/assets/` are the Rails outputs pinned by the Rust crate.

At runtime, `Assets` finds this directory by walking up from the working directory. Set
`CAMPFIRE_ASSETS_DIR` to this `assets/` directory when running from elsewhere. Static paths
are served only if listed in the manifest or in the five public files; no arbitrary file in
the directory is addressable by an HTTP path.

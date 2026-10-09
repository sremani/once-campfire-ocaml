#!/usr/bin/env bash
# Fresh default-seed pinned BenchmarkContracts and AcknowledgedWrites on both apps.
set -euo pipefail
if [[ $# -ne 2 ]]; then
  echo 'usage: scripts/m8_t2_contract_run.sh /absolute/path/to/immutable-ocaml-binary /absolute/path/to/pinned-verification-checkout' >&2
  exit 2
fi
m8_root=$(cd "$(dirname "$0")/.." && pwd)
m8_rust="$m8_root/../once-campfire-rust"
m8_verify=$(realpath "$2")
if [[ $(git -C "$m8_verify" rev-parse HEAD) != 6f71d70b5e1f17507404ad06cac134aa453a04a6 ]]; then
  echo 'verification checkout is not at pinned revision 6f71d70' >&2
  exit 2
fi
m8_binary=$(realpath "$1")
m8_seed=/tmp/campfire-m8-t2-isolated-default-1000
m8_output=/tmp/m8-t2-contract-final
mkdir -p "$m8_output/rust" "$m8_output/ocaml"
python3 "$m8_root/scripts/m8_t2_http_state.py" \
  --seed default --rust-port 3228 --ocaml-port 3230 --ocaml-target-port 3229 \
  --rust-db "$m8_rust/parity/.seed/.candidates/3228/db/production.sqlite3" \
  --ocaml-db "$m8_seed/db/production.sqlite3" \
  --ocaml-seed-dir "$m8_seed" --ocaml-container campfire-m8-t2-default-ocaml \
  --ocaml-network container:campfire-m8-t2-network \
  --ocaml-binary "$m8_binary" --output "$m8_output/reset-check.md" \
  --verification-checkout "$m8_verify" \
  --isolate --row 150 --roles anonymous
python3 - "$m8_output/reset-check.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
if result['counts'].get('pass') != 1:
    raise SystemExit('fresh-server health comparison failed')
PY
for m8_side in rust ocaml; do
  if [[ $m8_side == rust ]]; then
    m8_port=3228
    m8_db_dir="$m8_rust/parity/.seed/.candidates/3228/db"
  else
    m8_port=3230
    m8_db_dir="$m8_seed/db"
  fi
  docker run --rm --network host --read-only --tmpfs /tmp:rw,nosuid,size=64m \
    --user 1000:1000 \
    -v "$m8_verify:/verify:ro" \
    -v "$m8_root/scripts/m8_t2_shared_contracts.rb:/scripts/m8_t2_shared_contracts.rb:ro" \
    -v "$m8_rust/parity/.seed/default/labels.json:/seed/labels.json:ro" \
    -v "$m8_root/test/fixtures/campfire_sessions.json:/seed/sessions.json:ro" \
    -v "$m8_root/assets/manifest.json:/assets/manifest.json:ro" \
    -v "$m8_db_dir:/data/db:rw" \
    -v "$m8_output/$m8_side:/out:rw" \
    --entrypoint ruby campfire-reference:latest /scripts/m8_t2_shared_contracts.rb \
    "http://127.0.0.1:$m8_port" /data/db/production.sqlite3 \
    /seed/labels.json /assets/manifest.json /seed/sessions.json /out
done

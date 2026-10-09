#!/usr/bin/env bash
# Compare the pinned Rust image with the OCaml image using the Rust browser harness.
# The same pinned candidate wrapper supplies libfaketime to both app images.
set -euo pipefail

OCAML_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RUST_ROOT=$(cd "${M8_RUST_ROOT:-$OCAML_ROOT/../once-campfire-rust}" && pwd)
CANDIDATE=$RUST_ROOT/parity/bin/candidate
RUST_IMAGE=${M8_RUST_PARITY_IMAGE:-campfire-candidate:latest}
OCAML_APP_IMAGE=${M8_OCAML_APP_IMAGE:-campfire-ocaml:browser-app}
OCAML_IMAGE=${M8_OCAML_PARITY_IMAGE:-campfire-ocaml:browser-parity}
RUBY_IMAGE=${M8_RUBY_IMAGE:-campfire-m8-check:pinned}
SEEDS=$RUST_ROOT/parity/.seed

usage() {
  cat >&2 <<'EOF'
usage: m8_browser_parity.sh build-app | build-wrapper
       m8_browser_parity.sh inventory --seed NAME [--ports RUST,OCAML]
       m8_browser_parity.sh run --seed NAME --matrix lean|full --out DIR
         [--ports RUST,OCAML] [--isolated N] [--workers N] [compare filters...]
       m8_browser_parity.sh reset --target expected|actual --seed NAME --port N --time ISO

Inventory and run use pinned fixture credentials on disposable, independent seed
copies. Outputs stay in the Rust harness's ignored parity/out directory.
EOF
  exit 2
}

die() { echo "m8 browser parity: $*" >&2; exit 1; }
require_seed() {
  case "$1" in default|crowd|custom_styles|first_run|restricted) ;; *) die "unknown seed $1";; esac
  [ -f "$SEEDS/$1/labels.json" ] || die "seed $1 is not built"
  [ -f "$SEEDS/$1/db/production.sqlite3" ] || die "seed $1 has no database"
}
seed_time() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["clock.now"])' "$SEEDS/$1/labels.json"
}
candidate() {
  PARITY_SEED_DIR=$SEEDS PARITY_CANDIDATE_IMAGE=$1 "$CANDIDATE" "${@:2}"
}
check_inventory() {
  local seed=$1 port=$2
  docker run --rm --network host --read-only --tmpfs /tmp:rw,nosuid,nodev \
    --mount "type=bind,src=$RUST_ROOT,dst=$RUST_ROOT,readonly" \
    --mount "type=bind,src=$OCAML_ROOT/scripts,dst=$OCAML_ROOT/scripts,readonly" \
    --workdir "$RUST_ROOT" -e "M8_RUST_ROOT=$RUST_ROOT" \
    --entrypoint ruby "$RUBY_IMAGE" \
    "$OCAML_ROOT/scripts/m8_check_inventory.rb" --seed "$seed" --port "$port"
}

command=${1:-}; [ -n "$command" ] || usage; shift
case "$command" in
  build-app)
    docker build -t "$OCAML_APP_IMAGE" -f "$OCAML_ROOT/Dockerfile" \
      --build-arg APP_VERSION=parity \
      --build-arg "GIT_REVISION=$(git -C "$OCAML_ROOT" rev-parse HEAD)" "$OCAML_ROOT"
    ;;
  build-wrapper)
    docker image inspect "$OCAML_APP_IMAGE" >/dev/null
    docker build -t "$OCAML_IMAGE" --build-arg "BASE_IMAGE=$OCAML_APP_IMAGE" \
      -f "$RUST_ROOT/parity/docker/candidate/Dockerfile" \
      "$RUST_ROOT/parity/docker/candidate"
    ;;
  reset)
    target= seed= port= time=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --target) target=$2; shift 2;;
        --seed) seed=$2; shift 2;;
        --port) port=$2; shift 2;;
        --time) time=$2; shift 2;;
        *) usage;;
      esac
    done
    require_seed "$seed"
    [[ $port =~ ^[0-9]+$ ]] || die "invalid port"
    case "$target" in
      expected) image=$RUST_IMAGE;;
      actual) image=$OCAML_IMAGE;;
      *) die "invalid target $target";;
    esac
    candidate "$image" reset --app candidate --port "$port" --seed "$seed" --time "$time"
    ;;
  inventory|run)
    seed= matrix= out= ports=4511,4512 isolated=3 workers=2 extra=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --seed) seed=$2; shift 2;;
        --matrix) matrix=$2; shift 2;;
        --out) out=$2; shift 2;;
        --ports) ports=$2; shift 2;;
        --isolated) isolated=$2; shift 2;;
        --workers) workers=$2; shift 2;;
        *) extra+=("$1"); shift;;
      esac
    done
    require_seed "$seed"
    [[ $ports =~ ^[0-9]+,[0-9]+$ ]] || die "invalid ports"
    [[ $isolated =~ ^[0-9]+$ ]] || die "invalid isolated count"
    [[ $workers =~ ^[0-9]+$ ]] || die "invalid worker count"
    IFS=, read -r rust_port ocaml_port <<<"$ports"
    [ "$rust_port" != "$ocaml_port" ] || die "ports must differ"
    time=$(seed_time "$seed")
    rust_ports=("$rust_port") ocaml_ports=("$ocaml_port")
    for ((k=1;k<=isolated;k++)); do
      rust_ports+=("$((rust_port+1000*k))")
      ocaml_ports+=("$((ocaml_port+1000*k))")
    done
    cleanup() {
      local port
      for port in "${rust_ports[@]}" "${ocaml_ports[@]}"; do
        candidate "$RUST_IMAGE" down --port "$port" >/dev/null 2>&1 || true
      done
    }
    trap cleanup EXIT INT TERM
    candidate "$RUST_IMAGE" up --port "$rust_port" --seed "$seed" --time "$time" --freeze
    candidate "$OCAML_IMAGE" up --port "$ocaml_port" --seed "$seed" --time "$time" --freeze
    rust_inventory_status=0 ocaml_inventory_status=0 comparison_status=0
    echo "Rust inventory ($seed):"
    check_inventory "$seed" "$rust_port" || rust_inventory_status=$?
    echo "OCaml inventory ($seed):"
    check_inventory "$seed" "$ocaml_port" || ocaml_inventory_status=$?
    if [ "$command" = run ]; then
      # Inventory signs in fixture users. Give the browser fresh copies so its
      # sign-in rate limit and database state are independent of that preflight.
      candidate "$RUST_IMAGE" up --port "$rust_port" --seed "$seed" --time "$time" --freeze
      candidate "$OCAML_IMAGE" up --port "$ocaml_port" --seed "$seed" --time "$time" --freeze
      case "$matrix" in lean|full) ;; *) die "run requires --matrix lean|full";; esac
      [ -n "$out" ] || die "run requires --out"
      case "$out" in /*) ;; *) out="$RUST_ROOT/$out";; esac
      reset_cmd="'$OCAML_ROOT/scripts/m8_browser_parity.sh' reset --target {target} --port {port} --seed '$seed' --time '$time'"
      "$RUST_ROOT/parity/bin/compare" \
        --expected "http://127.0.0.1:$rust_port" \
        --actual "http://127.0.0.1:$ocaml_port" \
        --expected-name expected --actual-name actual \
        --seed "$seed" --time "$time" --matrix "$matrix" --out "$out" \
        --reset-host "$reset_cmd" --isolated "$isolated" --workers "$workers" \
        --no-allowlist "${extra[@]}" || comparison_status=$?
    fi
    echo "m8 browser parity: $seed inventory rust=$rust_inventory_status ocaml=$ocaml_inventory_status compare=$comparison_status"
    [ "$rust_inventory_status" -eq 0 ] && [ "$ocaml_inventory_status" -eq 0 ] && [ "$comparison_status" -eq 0 ]
    ;;
  *) usage;;
esac

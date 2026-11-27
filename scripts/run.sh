#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
BUNDLE_ROOT=$(realpath "$SCRIPT_DIR/..")
ENV_FILE="$BUNDLE_ROOT/.env"
RUNTIME_DIR="$BUNDLE_ROOT/.runtime"
LOG_DIR="$RUNTIME_DIR/logs"
PUBLISHER="$BUNDLE_ROOT/components/publisher"
GATEWAY="$BUNDLE_ROOT/components/gateway"
FRONTEND="$BUNDLE_ROOT/components/frontend"
EXPERIMENT=ZMQ_PUBLISHER_DEMO
GATEWAY_PORT=8000
MIDAS_PORT=8080
RATE_HZ=100
PAYLOAD_BYTES=16384
BANK_MODE=builder
SAMPIC_MODE=periodic_readout
HDSOC_WINDOWS=8
DUMMY_CUT_EVERY=0
HOSTLIST=false
PIDS=()
NAMES=()
CLEANING_UP=false

show_help() {
    cat <<EOF
Usage: ./scripts/run.sh [OPTIONS]

Run the complete local DQM demo and stop every component together.

Options:
  --rate-hz RATE         Event rate per simulated detector (default: 100)
  --payload-bytes BYTES  Requested simulator payload size (default: 16384)
  --gateway-port PORT    Gateway HTTP port (default: 8000)
  --midas-port PORT      MIDAS/mhttpd port (default: 8080)
  --bank-mode MODE      builder (default) or frontend
  --sampic-mode MODE    periodic_readout (default) or time_grouping
  --hdsoc-windows N     Windows per HDSoC waveform, 1..61 (default: 8)
  --dummy-cut-every N   Enable dummy selection; 0 disables it (default)
  --with-hostlist        Keep MIDAS host access control enabled
  -h, --help             Display this help message
EOF
}

require_value() {
    if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == -* ]]; then
        echo "[run, ERROR] $1 requires a value" >&2
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rate-hz) require_value "$@"; RATE_HZ=$2; shift 2 ;;
        --payload-bytes) require_value "$@"; PAYLOAD_BYTES=$2; shift 2 ;;
        --gateway-port) require_value "$@"; GATEWAY_PORT=$2; shift 2 ;;
        --midas-port) require_value "$@"; MIDAS_PORT=$2; shift 2 ;;
        --bank-mode) require_value "$@"; BANK_MODE=$2; shift 2 ;;
        --sampic-mode) require_value "$@"; SAMPIC_MODE=$2; shift 2 ;;
        --hdsoc-windows) require_value "$@"; HDSOC_WINDOWS=$2; shift 2 ;;
        --dummy-cut-every) require_value "$@"; DUMMY_CUT_EVERY=$2; shift 2 ;;
        --with-hostlist) HOSTLIST=true; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "[run, ERROR] Unknown option: $1" >&2; show_help; exit 2 ;;
    esac
done

if [[ ! -f "$ENV_FILE" ]]; then
    echo "[run, ERROR] Run ./scripts/setup.sh first." >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${MIDASSYS:?Set MIDASSYS in $ENV_FILE}"

required_executables=(
    "$PUBLISHER/build/bin/zmq_publisher"
    "$PUBLISHER/build/bin/zmq_publisher_sampic_simulator_frontend"
    "$GATEWAY/build/bin/dqm_gateway"
)
for executable in "${required_executables[@]}"; do
    if [[ ! -x "$executable" ]]; then
        echo "[run, ERROR] Missing executable: $executable" >&2
        echo "[run, ERROR] Build the bundle with ./scripts/build.sh" >&2
        exit 1
    fi
done
if [[ ! -f "$FRONTEND/build/index.html" ]]; then
    echo "[run, ERROR] Missing frontend production build; run ./scripts/build.sh" >&2
    exit 1
fi

cmake -E remove_directory "$LOG_DIR"
cmake -E make_directory "$LOG_DIR"

start_process() {
    local name=$1
    shift
    setsid "$@" >"$LOG_DIR/$name.log" 2>&1 &
    PIDS+=("$!")
    NAMES+=("$name")
    echo "[run] Started $name (PID $!, log: $LOG_DIR/$name.log)"
}

stop_process_group() {
    local pid=$1
    if kill -0 "$pid" 2>/dev/null; then
        kill -INT -- "-$pid" 2>/dev/null || true
    fi
}

cleanup() {
    if [[ "$CLEANING_UP" == true ]]; then
        return
    fi
    CLEANING_UP=true
    trap - INT TERM EXIT
    echo "[run] Stopping DQM demo..."
    if [[ -f "${DEMO_EXPTAB:-}" ]]; then
        MIDAS_EXPTAB="$DEMO_EXPTAB" "$MIDASSYS/bin/mtransition" \
            -e "$EXPERIMENT" STOP >/dev/null 2>&1 || true
    fi
    for ((index=${#PIDS[@]}-1; index>=0; --index)); do
        stop_process_group "${PIDS[index]}"
    done
    # run_midas_demo starts each frontend in its own session. Restrict this
    # fallback to simulator executables from this exact bundle checkout.
    mapfile -t simulator_pids < <(
        pgrep -f "^$PUBLISHER/build/bin/zmq_publisher_(sampic|musip|hdsoc|wfd5)_simulator_frontend" \
            || true)
    if [[ ${#simulator_pids[@]} -gt 0 ]]; then
        kill -TERM "${simulator_pids[@]}" 2>/dev/null || true
    fi
    local deadline=$((SECONDS + 10))
    while (( SECONDS < deadline )); do
        local running=false
        for pid in "${PIDS[@]}"; do
            kill -0 "$pid" 2>/dev/null && running=true
        done
        [[ "$running" == false ]] && break
        sleep 0.2
    done
    for pid in "${PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM -- "-$pid" 2>/dev/null || true
        fi
    done
    wait "${PIDS[@]}" 2>/dev/null || true
    echo "[run] DQM demo stopped."
}
trap cleanup INT TERM EXIT

DEMO_EXPTAB="$PUBLISHER/.artifacts/midas-demo/experiment/exptab"
start_process simulators \
    python3 "$PUBLISHER/benchmarks/rate_tests/run_midas_demo.py" \
    --midas-root "$MIDASSYS" --rate-hz "$RATE_HZ" --payload-bytes "$PAYLOAD_BYTES" \
    --bank-mode "$BANK_MODE" --sampic-mode "$SAMPIC_MODE" \
    --hdsoc-windows "$HDSOC_WINDOWS" --dummy-cut-every "$DUMMY_CUT_EVERY"

MIDAS_READY=false
for _ in $(seq 1 150); do
    if ! kill -0 "${PIDS[0]}" 2>/dev/null; then
        echo "[run, ERROR] Simulator supervisor exited; see $LOG_DIR/simulators.log" >&2
        exit 1
    fi
    if grep -q "MIDAS experiment $EXPERIMENT is running" \
           "$LOG_DIR/simulators.log" 2>/dev/null && \
       [[ -f "$DEMO_EXPTAB" ]] && \
       MIDAS_EXPTAB="$DEMO_EXPTAB" "$MIDASSYS/bin/odbedit" \
           -e "$EXPERIMENT" -c 'ls "/Equipment"' >/dev/null 2>&1; then
        MIDAS_READY=true
        break
    fi
    sleep 0.2
done
if [[ "$MIDAS_READY" == false ]]; then
    echo "[run, ERROR] MIDAS demo did not become ready; see $LOG_DIR/simulators.log" >&2
    exit 1
fi

start_process publisher \
    "$PUBLISHER/scripts/run.sh" \
    --config "$PUBLISHER/config/examples/online_demo.json" \
    --experiment "$EXPERIMENT" --exptab "$DEMO_EXPTAB"

start_process gateway \
    "$GATEWAY/scripts/run.sh" \
    --config "$GATEWAY/config/config.json" --port "$GATEWAY_PORT"

for _ in $(seq 1 100); do
    if curl --silent --fail "http://127.0.0.1:$GATEWAY_PORT/api/v1/health" \
        >/dev/null 2>&1; then
        break
    fi
    sleep 0.2
done
if ! curl --silent --fail "http://127.0.0.1:$GATEWAY_PORT/api/v1/health" \
    >/dev/null 2>&1; then
    echo "[run, ERROR] Gateway did not become ready; see $LOG_DIR/gateway.log" >&2
    exit 1
fi

export MIDAS_EXPTAB="$DEMO_EXPTAB"
export MIDAS_EXPT_NAME="$EXPERIMENT"
FRONTEND_ARGS=(
    --experiment "$EXPERIMENT"
    --gateway-url "http://127.0.0.1:$GATEWAY_PORT"
    --port "$MIDAS_PORT"
    --skip-build
)
[[ "$HOSTLIST" == false ]] && FRONTEND_ARGS+=(--no-hostlist)
start_process dashboard "$FRONTEND/scripts/midas/launch.sh" "${FRONTEND_ARGS[@]}"

for _ in $(seq 1 100); do
    if curl --silent --fail "http://127.0.0.1:$MIDAS_PORT/DQM" >/dev/null 2>&1; then
        break
    fi
    sleep 0.2
done

CATALOG_READY=false
for _ in $(seq 1 300); do
    if curl --silent --fail "http://127.0.0.1:$GATEWAY_PORT/api/v1/catalog" \
        | python3 -c \
            'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("products") else 1)' \
        >/dev/null 2>&1; then
        CATALOG_READY=true
        break
    fi
    sleep 0.2
done
if [[ "$CATALOG_READY" == false ]]; then
    echo "[run, ERROR] No DQM products reached the gateway within 60 seconds." >&2
    echo "[run, ERROR] Inspect $LOG_DIR/publisher.log" >&2
    exit 1
fi

echo
echo "DQM demo is running:"
echo "  Publisher control: http://127.0.0.1:8090"
echo "  Dashboard:       http://127.0.0.1:$MIDAS_PORT/DQM"
echo "  MIDAS:           http://127.0.0.1:$MIDAS_PORT"
echo "  Gateway catalog: http://127.0.0.1:$GATEWAY_PORT/api/v1/catalog"
echo "  Logs:            $LOG_DIR"
echo "Press Ctrl-C to stop every component."

set +e
wait -n "${PIDS[@]}"
status=$?
set -e
if [[ "$CLEANING_UP" == false ]]; then
    echo "[run, ERROR] A demo component exited unexpectedly (status $status)." >&2
    for index in "${!PIDS[@]}"; do
        if ! kill -0 "${PIDS[index]}" 2>/dev/null; then
            echo "[run, ERROR] Stopped: ${NAMES[index]} (log: $LOG_DIR/${NAMES[index]}.log)" >&2
        fi
    done
    exit "$status"
fi


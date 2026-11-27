#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
BUNDLE_ROOT=$(realpath "$SCRIPT_DIR/..")
JOBS=$(nproc)
CLEAN=false
SKIP_SIDECAR=false
WORKING_TREE=false

show_help() {
    cat <<EOF
Usage: ./scripts/build.sh [OPTIONS]

Build every component required by the simulated DQM demo.

Options:
  --clean             Reconfigure clean C++ build directories
  --jobs COUNT        Parallel build jobs (default: detected CPU count)
  --working-tree      Build current component branches and uncommitted reco_testbeam changes
  --skip-sidecar      Reuse an existing Gaudi sidecar build
  -h, --help          Display this help message
EOF
}

require_value() {
    if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == -* ]]; then
        echo "[build, ERROR] $1 requires a value" >&2
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean) CLEAN=true; shift ;;
        --jobs) require_value "$@"; JOBS=$2; shift 2 ;;
        --working-tree) WORKING_TREE=true; shift ;;
        --skip-sidecar) SKIP_SIDECAR=true; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "[build, ERROR] Unknown option: $1" >&2; show_help; exit 2 ;;
    esac
done
if [[ ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "[build, ERROR] --jobs must be a positive integer" >&2
    exit 2
fi

if [[ "$WORKING_TREE" == true ]]; then
    "$SCRIPT_DIR/setup.sh" --working-tree
else
    "$SCRIPT_DIR/setup.sh"
fi

PUBLISHER="$BUNDLE_ROOT/components/publisher"
GATEWAY="$BUNDLE_ROOT/components/gateway"
FRONTEND="$BUNDLE_ROOT/components/frontend"

PUBLISHER_BUILD_ARGS=(--with-gaudi --with-simulators --jobs "$JOBS")
GATEWAY_BUILD_ARGS=(--jobs "$JOBS")
if [[ "$CLEAN" == true ]]; then
    PUBLISHER_BUILD_ARGS=(--overwrite "${PUBLISHER_BUILD_ARGS[@]}")
    GATEWAY_BUILD_ARGS=(--overwrite "${GATEWAY_BUILD_ARGS[@]}")
fi

echo "[build] Building publisher, Gaudi extension, and simulator frontends"
"$PUBLISHER/scripts/setup_env.sh" --with-gaudi
"$PUBLISHER/scripts/build.sh" "${PUBLISHER_BUILD_ARGS[@]}"

if [[ "$SKIP_SIDECAR" == false ]]; then
    echo "[build] Building the online Gaudi sidecar inside Apptainer"
    "$PUBLISHER/extensions/gaudi/scripts/build_sidecar.sh" \
        --jobs "$JOBS" --shared-revision HEAD
fi

echo "[build] Building DQM gateway"
"$GATEWAY/scripts/setup_env.sh"
"$GATEWAY/scripts/build.sh" "${GATEWAY_BUILD_ARGS[@]}"

echo "[build] Installing locked frontend dependencies and production bundle"
npm --prefix "$FRONTEND" ci
npm --prefix "$FRONTEND" run build

echo "[build] Full DQM demo build complete."


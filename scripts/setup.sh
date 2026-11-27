#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
BUNDLE_ROOT=$(realpath "$SCRIPT_DIR/..")
ENV_FILE="$BUNDLE_ROOT/.env"
ENV_TEMPLATE="$BUNDLE_ROOT/.env.example"
RUNTIME_DIR="$BUNDLE_ROOT/.runtime"
PIONEER_SOURCE="$RUNTIME_DIR/pioneer"
PUBLISHER_ENV="$BUNDLE_ROOT/components/publisher/scripts/environment/.env.local"
SKIP_SUBMODULES=false
WORKING_TREE=false

show_help() {
    cat <<EOF
Usage: ./scripts/setup.sh [OPTIONS]

Prepare the pinned DQM demo source tree and validate host prerequisites.

Options:
  --working-tree      Copy current reco_testbeam working files; preserve component branches
  --skip-submodules   Do not initialize/update the pinned submodules
  -h, --help          Display this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --working-tree) WORKING_TREE=true; SKIP_SUBMODULES=true; shift ;;
        --skip-submodules) SKIP_SUBMODULES=true; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "[setup, ERROR] Unknown option: $1" >&2; show_help; exit 2 ;;
    esac
done

if [[ ! -f "$ENV_FILE" ]]; then
    cp "$ENV_TEMPLATE" "$ENV_FILE"
    echo "[setup] Created $ENV_FILE"
    echo "[setup] Edit MIDASSYS and PIONEER_GAUDI_IMAGE, then rerun setup."
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"
: "${MIDASSYS:?Set MIDASSYS in $ENV_FILE}"
: "${PIONEER_GAUDI_IMAGE:?Set PIONEER_GAUDI_IMAGE in $ENV_FILE}"

for command_name in git cmake c++ python3 node npm apptainer curl setsid; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "[setup, ERROR] Required command not found: $command_name" >&2
        exit 1
    fi
done
for required_path in \
    "$MIDASSYS/bin/odbedit" \
    "$MIDASSYS/bin/mhttpd" \
    "$MIDASSYS/include/midas.h" \
    "$MIDASSYS/lib/libmidas.a" \
    "$PIONEER_GAUDI_IMAGE"; do
    if [[ ! -e "$required_path" ]]; then
        echo "[setup, ERROR] Required path does not exist: $required_path" >&2
        exit 1
    fi
done

if [[ "$WORKING_TREE" == false ]]; then
    for component in publisher reco_testbeam; do
        directory="$BUNDLE_ROOT/components/$component"
        if [[ -e "$directory/.git" ]] && [[ -n "$(git -C "$directory" status --porcelain)" ]]; then
            echo "[setup, ERROR] $component has uncommitted changes. Use --working-tree to build them." >&2
            exit 1
        fi
    done
fi

if [[ "$SKIP_SUBMODULES" == false ]]; then
    git -C "$BUNDLE_ROOT" submodule sync
    # Deliberately omit --recursive. pioneer_main contains the complete
    # simulation as nested submodules, while this demo needs only the two
    # directly pinned online dependencies below.
    git -C "$BUNDLE_ROOT" submodule update --init --jobs "$(nproc)" \
        components/frontend \
        components/gateway \
        components/publisher \
        components/midas_receiver \
        components/pioneer_main \
        components/pioneer_shared \
        components/reco_testbeam
fi

for component in frontend gateway publisher midas_receiver pioneer_main pioneer_shared reco_testbeam; do
    if ! git -C "$BUNDLE_ROOT/components/$component" rev-parse --git-dir >/dev/null 2>&1; then
        echo "[setup, ERROR] Missing submodule: components/$component" >&2
        exit 1
    fi
done

# Construct only the source layout expected by the containerized online build.
# No MonteCarlo, DetResponse, Reco, geometry, or other PIONEER submodule is
# initialized on the host.
cmake -E remove_directory "$PIONEER_SOURCE"
cmake -E make_directory "$PIONEER_SOURCE"
# Materialize clean committed files so /simulation is self-contained inside
# Apptainer. shared remains a host-side Git link because build_sidecar archives
# its selected revision before entering the container.
git -C "$BUNDLE_ROOT/components/pioneer_main" archive HEAD CMakeLists.txt cmake \
    | tar -x -C "$PIONEER_SOURCE"
ln -s "$BUNDLE_ROOT/components/pioneer_shared" "$PIONEER_SOURCE/shared"
mkdir -p "$PIONEER_SOURCE/reco_testbeam"
if [[ "$WORKING_TREE" == true ]]; then
    python3 - "$BUNDLE_ROOT/components/reco_testbeam" "$PIONEER_SOURCE/reco_testbeam" <<'PY_COPY'
import os, shutil, subprocess, sys
from pathlib import Path
source, destination = map(Path, sys.argv[1:])
files = subprocess.check_output(['git', '-C', str(source), 'ls-files', '-z', '--cached', '--others', '--exclude-standard'])
for entry in set(files.split(b'\0')) - {b''}:
    relative = os.fsdecode(entry)
    original, target = source / relative, destination / relative
    if original.is_file() or original.is_symlink():
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(original, target, follow_symlinks=False)
print('[setup] Copied reco_testbeam working tree (including uncommitted changes).')
PY_COPY
else
    git -C "$BUNDLE_ROOT/components/reco_testbeam" archive HEAD \
        | tar -x -C "$PIONEER_SOURCE/reco_testbeam"
fi
# PIONEER's top-level BUILD_REC flag both enables Gaudi discovery and requests
# add_subdirectory(Reco). The online module needs the former but not the full
# reconstruction project, so satisfy the structural check with an empty,
# generated subproject.
cmake -E make_directory "$PIONEER_SOURCE/Reco"
cmake -E touch "$PIONEER_SOURCE/Reco/CMakeLists.txt"

mkdir -p "$(dirname "$PUBLISHER_ENV")"
{
    printf 'export MIDASSYS=%q\n' "$(realpath "$MIDASSYS")"
    printf 'export MIDAS_RECEIVER_SOURCE=%q\n' "$BUNDLE_ROOT/components/midas_receiver"
    printf 'export PIONEER_SOURCE_DIR=%q\n' "$PIONEER_SOURCE"
    printf 'export PIONEER_GAUDI_IMAGE=%q\n' "$(realpath "$PIONEER_GAUDI_IMAGE")"
    if [[ -n "${PIONEER_GAUDI_MIDAS_SOURCE:-}" ]]; then
        printf 'export PIONEER_GAUDI_MIDAS_SOURCE=%q\n' "$(realpath "$PIONEER_GAUDI_MIDAS_SOURCE")"
    fi
} > "$PUBLISHER_ENV"

echo "[setup] Environment validated."
echo "[setup] Minimal PIONEER source: $PIONEER_SOURCE"
echo "[setup] Publisher environment: $PUBLISHER_ENV"


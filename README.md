# PIONEER DQM demo bundle

This repository pins and orchestrates the complete local DQM demonstration:

```text
four MIDAS simulator frontends
              │
              ▼
     zmq_publisher + containerized Gaudi online pipeline
              │ ZeroMQ
              ▼
         dqm_gateway
              │ bounded HTTP views
              ▼
      MIDAS-hosted React dashboard
```

The bundle does not clone or build the complete PIONEER simulation. It pins
only the PIONEER top-level build files, `shared`, and `reco_testbeam`, then
constructs a minimal ignored source layout used inside the existing Gaudi
Apptainer image.

## Prerequisites

- Linux or WSL with CMake, a C++ compiler, Git, Python 3, curl, Node.js/npm,
  ZeroMQ/cppzmq, and Apptainer;
- an installed MIDAS tree containing `bin`, `include`, and `lib`;
- the PIONEER Gaudi Apptainer image.

If the image is not already present:

```sh
mkdir -p "$HOME/.local/share/pioneer/containers"
apptainer pull "$HOME/.local/share/pioneer/containers/pioneer-gaudi.sif" \
  docker://ghcr.io/pioneer-experiment/pioneer:latest-x86_64
```

## First setup

Clone the bundle itself; its setup command initializes only the explicitly
required submodules, not the nested full simulation:

```sh
git clone <DQM-bundle-repository-url>
cd DQM_bundle
cp .env.example .env
```

Edit `.env` with the two machine-specific absolute paths:

```sh
export MIDASSYS=/path/to/midas
export PIONEER_GAUDI_IMAGE=/path/to/pioneer-gaudi.sif
```

Then prepare and build everything:

```sh
./scripts/setup.sh
./scripts/build.sh
```

The first build downloads normal CMake/npm dependencies and builds the online
Gaudi module inside the container, so it takes longer than later incremental
builds. Use `./scripts/build.sh --clean` for a clean rebuild or
`./scripts/build.sh --skip-sidecar` when the sidecar is already current.

## Run the full demo

One command starts the isolated MIDAS experiment, all four detector
simulators, acquisition, publisher/Gaudi sidecar, gateway, and MIDAS webpage:

```sh
./scripts/run.sh
```

Open:

- DQM dashboard: <http://127.0.0.1:8080/DQM>
- MIDAS: <http://127.0.0.1:8080>
- gateway catalog: <http://127.0.0.1:8000/api/v1/catalog>

Press Ctrl-C once in the bundle terminal to stop the complete chain. Logs are
replaced on each launch under `.runtime/logs/`.

Useful local-demo overrides are discoverable through:

```sh
./scripts/run.sh --help
./scripts/run.sh --rate-hz 200 --payload-bytes 32768
```

The default disables the MIDAS hostlist for a local-only demonstration. Use
`--with-hostlist` on a configured DAQ network.

## Pinned components

All source dependencies are ordinary Git submodules under `components/`:

- `frontend` — React dashboard and MIDAS custom-page launcher;
- `gateway` — C++ HTTP/WebSocket DQM gateway;
- `publisher` — ZeroMQ publisher, Gaudi client, and detector simulators;
- `midas_receiver` — publisher MIDAS input dependency;
- `pioneer_main` — top-level PIONEER CMake structure only;
- `pioneer_shared` — Gaudi/shared types at the compatible online revision;
- `reco_testbeam` — online DQM Gaudi algorithms and products.

Submodule commits, rather than moving branches, define a reproducible bundle.
To update one component, check out and test the desired revision inside its
directory, then commit the changed gitlink in this repository.

## Individual processes

The bundle run script is the supported demonstration entry point. For
debugging, its four underlying commands remain the component-native ones
documented in each submodule: `run_midas_demo.py`, publisher `scripts/run.sh`,
gateway `scripts/run.sh`, and frontend `scripts/midas/launch.sh`.


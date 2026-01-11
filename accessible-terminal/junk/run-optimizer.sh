#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Default parameters
GENERATIONS=${1:-10000}
POPULATION=${2:-500000}

echo "Building and running optimizer: ${GENERATIONS} generations, ${POPULATION} population"

nix develop --command bash -c "
  nvcc -O3 -Wno-deprecated-gpu-targets -o color-optimizer color-optimizer.cu -lcurand && \
  ./color-optimizer -g ${GENERATIONS} -p ${POPULATION}
"

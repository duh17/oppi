#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Build first (benchmarks run against dist/)
npm run build 2>&1 | tail -1

# Run all bench files
for bench in bench/*.bench.mjs; do
  echo "--- $(basename "$bench") ---"
  node "$bench"
done

#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# Run benchmark suite via sim-pool
OUTPUT=$(./scripts/sim-pool.sh run -- \
    xcodebuild -project Oppi.xcodeproj -scheme Oppi test \
    -only-testing:'OppiTests/DiffBuilderPerfBench' \
    2>&1) || {
    echo "METRIC error=1"
    echo "$OUTPUT" | tail -30
    exit 1
}

# Extract METRIC lines from test output
echo "$OUTPUT" | grep '^METRIC ' || {
    echo "METRIC error=1"
    echo "No METRIC lines found in output"
    echo "$OUTPUT" | tail -20
    exit 1
}

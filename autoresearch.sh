#!/bin/bash
set -euo pipefail

SIM_POOL="/Users/chenda/workspace/oppi/ios/scripts/sim-pool.sh"
WORKTREE="/Users/chenda/workspace/oppi-autoresearch/autoresearch/insert-stability-20260321"
BENCH_OUTPUT="$WORKTREE/.bench-output.txt"

cd "$WORKTREE/ios"

# Regenerate project if source files changed
xcodegen generate 2>&1 | tail -1

# Build + test, capture full output
$SIM_POOL run -- xcodebuild \
    -project Oppi.xcodeproj \
    -scheme Oppi \
    test \
    -only-testing:'OppiTests/InsertStabilityBench/insert_stability_score()()' \
    2>&1 | tee "$BENCH_OUTPUT" | grep -E "^METRIC " || {
    echo "METRIC insert_stability_score=0"
    exit 1
}

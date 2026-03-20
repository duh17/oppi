#!/bin/bash
set -euo pipefail

WORKTREE="/Users/chenda/workspace/oppi-autoresearch/autoresearch/timeline-lifecycle-20260320"
BENCH_OUTPUT="$WORKTREE/.bench-output.txt"

if [ ! -f "$BENCH_OUTPUT" ]; then
    echo "No bench output found at $BENCH_OUTPUT"
    exit 1
fi

# Check all invariants pass
FAILURES=$(grep "^INVARIANT " "$BENCH_OUTPUT" | grep "FAIL" || true)

if [ -n "$FAILURES" ]; then
    echo "Invariant failures:"
    echo "$FAILURES"
    exit 1
fi

echo "All invariants pass"

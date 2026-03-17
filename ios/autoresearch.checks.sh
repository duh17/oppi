#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# Run correctness tests — syntax highlighter + code render strategy + render perf
./scripts/sim-pool.sh run -- \
    xcodebuild -project Oppi.xcodeproj -scheme Oppi test \
    -only-testing:'OppiTests/SyntaxHighlighterTests' \
    -only-testing:'OppiTests/ToolRowCodeRenderStrategyTests' \
    -only-testing:'OppiTests/RenderStrategyPerfTests' \
    -only-testing:'OppiTests/BatchHighlightBenchmarkTests' \
    -quiet 2>&1 | tail -20

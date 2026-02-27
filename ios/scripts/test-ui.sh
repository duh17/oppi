#!/usr/bin/env bash
set -euo pipefail

# ─── Oppi UI Test Runner ────────────────────────────────────────
#
# Runs UI tests on the iOS Simulator.
#
# Usage:
#   ios/scripts/test-ui.sh
#   ios/scripts/test-ui.sh --full-suite
#   ios/scripts/test-ui.sh --harness-only
#   ios/scripts/test-ui.sh --skip-generate
# ────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SKIP_GENERATE=0
TEST_SCOPE="full"

for arg in "$@"; do
  case "$arg" in
    --skip-generate) SKIP_GENERATE=1 ;;
    --full-suite) TEST_SCOPE="full" ;;
    --harness-only) TEST_SCOPE="harness" ;;
    -h|--help)
      echo "Usage: ios/scripts/test-ui.sh [--skip-generate] [--full-suite|--harness-only]"
      exit 0
      ;;
    *)
      echo "Unknown: $arg" >&2
      exit 1
      ;;
  esac
done

cd "$IOS_DIR"
[[ "$SKIP_GENERATE" -eq 0 ]] && xcodegen generate

if [[ "$TEST_SCOPE" == "harness" ]]; then
  TEST_FILTER=(-only-testing:OppiUITests/UIHangHarnessUITests)
else
  TEST_FILTER=(-only-testing:OppiUITests)
fi

xcodebuild test \
  -project Oppi.xcodeproj \
  -scheme Oppi \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' \
  "${TEST_FILTER[@]}"

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
  TEST_FILTER=(
    -only-testing:OppiUITests/UIHangHarnessUITests
    -only-testing:OppiUITests/UIMessageQueueHarnessUITests
  )
else
  TEST_FILTER=(-only-testing:OppiUITests)
fi

LOG_FILE="$(mktemp -t oppi-ui-tests.XXXXXX.log)"
trap 'rm -f "$LOG_FILE"' EXIT

set +e
xcodebuild test \
  -project Oppi.xcodeproj \
  -scheme Oppi \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' \
  "${TEST_FILTER[@]}" | tee "$LOG_FILE"
XCODE_STATUS=${PIPESTATUS[0]}
set -e

if [[ "$XCODE_STATUS" -ne 0 ]]; then
  exit "$XCODE_STATUS"
fi

EXECUTED_TESTS="$(grep -Eo 'Executed [0-9]+ tests' "$LOG_FILE" | awk '{print $2}' | sort -n | tail -n1 || true)"
if [[ -z "$EXECUTED_TESTS" || "$EXECUTED_TESTS" -eq 0 ]]; then
  echo "xcodebuild reported zero executed tests; failing to avoid false green." >&2
  exit 2
fi

if ! grep -q 'testSteeringQueueLifecycle' "$LOG_FILE"; then
  echo "Queue lifecycle UI test did not execute; expected testSteeringQueueLifecycle in output." >&2
  exit 3
fi

echo "UI tests executed: $EXECUTED_TESTS"

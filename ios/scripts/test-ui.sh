#!/usr/bin/env bash
set -euo pipefail

# ─── Oppi UI Test Runner ────────────────────────────────────────
#
# Runs UI tests on the iOS Simulator with a stable two-phase flow:
# build-for-testing -> test-without-building.
#
# Usage:
#   ios/scripts/test-ui.sh
#   ios/scripts/test-ui.sh --full-suite
#   ios/scripts/test-ui.sh --harness-only
#   ios/scripts/test-ui.sh --harness-only --stress
#   ios/scripts/test-ui.sh --skip-generate
#   ios/scripts/test-ui.sh --skip-build-for-testing
# ────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

SKIP_GENERATE=0
SKIP_BUILD_FOR_TESTING=0
TEST_SCOPE="full"
STRESS_MODE=0

for arg in "$@"; do
  case "$arg" in
    --skip-generate) SKIP_GENERATE=1 ;;
    --skip-build-for-testing) SKIP_BUILD_FOR_TESTING=1 ;;
    --full-suite) TEST_SCOPE="full" ;;
    --harness-only) TEST_SCOPE="harness" ;;
    --stress) STRESS_MODE=1 ;;
    -h|--help)
      echo "Usage: ios/scripts/test-ui.sh [--skip-generate] [--skip-build-for-testing] [--full-suite|--harness-only] [--stress]"
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

DESTINATION='platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro'
LOG_FILE="$(mktemp -t oppi-ui-tests.XXXXXX.log)"
trap 'rm -f "$LOG_FILE"' EXIT

run_xcodebuild() {
  set +e
  "$@" | tee -a "$LOG_FILE"
  local status=${PIPESTATUS[0]}
  set -e
  return "$status"
}

if [[ "$SKIP_BUILD_FOR_TESTING" -eq 0 ]]; then
  if ! run_xcodebuild xcodebuild build-for-testing \
    -project Oppi.xcodeproj \
    -scheme Oppi \
    -destination "$DESTINATION" \
    "${TEST_FILTER[@]}"; then
    exit 1
  fi
fi

TEST_CMD=(
  xcodebuild test-without-building
  -project Oppi.xcodeproj
  -scheme Oppi
  -destination "$DESTINATION"
  -parallel-testing-enabled NO
  -maximum-concurrent-test-simulator-destinations 1
  "${TEST_FILTER[@]}"
)

if [[ "$TEST_SCOPE" == "harness" ]]; then
  TEST_CMD+=(
    -retry-tests-on-failure
    -test-iterations 2
  )
fi

set +e
if [[ "$STRESS_MODE" -eq 1 ]]; then
  PI_UI_HANG_STRESS=1 run_xcodebuild "${TEST_CMD[@]}"
else
  run_xcodebuild "${TEST_CMD[@]}"
fi
XCODE_STATUS=$?
set -e

if [[ "$XCODE_STATUS" -ne 0 ]]; then
  exit "$XCODE_STATUS"
fi

EXECUTED_TESTS="$(grep -Eo 'Executed [0-9]+ tests' "$LOG_FILE" | awk '{print $2}' | sort -n | tail -n1 || true)"
if [[ -z "$EXECUTED_TESTS" || "$EXECUTED_TESTS" -eq 0 ]]; then
  echo "xcodebuild reported zero executed tests; failing to avoid false green." >&2
  exit 2
fi

if [[ "$TEST_SCOPE" == "harness" ]] && ! grep -q 'testSteeringQueueLifecycle' "$LOG_FILE"; then
  echo "Queue lifecycle UI test did not execute; expected testSteeringQueueLifecycle in output." >&2
  exit 3
fi

echo "UI tests executed: $EXECUTED_TESTS"

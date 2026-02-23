#!/usr/bin/env bash
set -euo pipefail

# ─── UI Hang Regression Tests ────────────────────────────────────
#
# Runs UI hang/reliability tests on the iOS Simulator.
#
# Usage:
#   ios/scripts/test-ui.sh
#   ios/scripts/test-ui.sh --skip-generate
# ──────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SKIP_GENERATE=0

for arg in "$@"; do
  case "$arg" in
    --skip-generate) SKIP_GENERATE=1 ;;
    -h|--help) sed -n '3,10p' "$0"; exit 0 ;;
    *) echo "Unknown: $arg" >&2; exit 1 ;;
  esac
done

cd "$IOS_DIR"
[[ "$SKIP_GENERATE" -eq 0 ]] && xcodegen generate

xcodebuild test \
  -project Oppi.xcodeproj \
  -scheme Oppi \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' \
  -only-testing:OppiUITests/UIHangHarnessUITests

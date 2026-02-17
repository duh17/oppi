#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

SCHEME="${PIOS_UI_RELIABILITY_SCHEME:-OppiUIReliability}"
DESTINATION="${PIOS_UI_RELIABILITY_DESTINATION:-platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro}"
ONLY_TESTING="${PIOS_UI_RELIABILITY_ONLY_TESTING:-OppiUITests/UIHangHarnessUITests}"
SKIP_GENERATE=0

usage() {
  cat <<'EOF'
Run iOS UI hang reliability regression tests.

Usage:
  ios/scripts/test-ui-reliability.sh [options]

Options:
  --skip-generate          Skip `xcodegen generate`
  --destination <value>    xcodebuild destination string (simulator only)
  --scheme <name>          Scheme name (default: OppiUIReliability)
  --only-testing <value>   xcodebuild -only-testing value
  -h, --help               Show help

Environment overrides:
  PIOS_UI_RELIABILITY_SCHEME
  PIOS_UI_RELIABILITY_DESTINATION
  PIOS_UI_RELIABILITY_ONLY_TESTING

Examples:
  ios/scripts/test-ui-reliability.sh
  ios/scripts/test-ui-reliability.sh --skip-generate
  ios/scripts/test-ui-reliability.sh --destination "platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-generate)
      SKIP_GENERATE=1
      shift
      ;;
    --destination)
      DESTINATION="$2"
      shift 2
      ;;
    --scheme)
      SCHEME="$2"
      shift 2
      ;;
    --only-testing)
      ONLY_TESTING="$2"
      shift 2
      ;;
    --device)
      echo "error: --device is not supported; UI hang harness is simulator-only." >&2
      exit 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$DESTINATION" != *"Simulator"* ]]; then
  echo "error: UI hang harness is simulator-only. Destination must target iOS Simulator." >&2
  exit 1
fi

cd "$IOS_DIR"

if [[ "$SKIP_GENERATE" -eq 0 ]]; then
  xcodegen generate
fi

xcodebuild -project Oppi.xcodeproj -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -only-testing:"$ONLY_TESTING" \
  test

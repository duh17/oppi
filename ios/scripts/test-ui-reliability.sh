#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

SCHEME="${PIOS_UI_RELIABILITY_SCHEME:-PiRemoteUIReliability}"
DESTINATION="${PIOS_UI_RELIABILITY_DESTINATION:-platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro}"
ONLY_TESTING="${PIOS_UI_RELIABILITY_ONLY_TESTING:-PiRemoteUITests/UIHangHarnessUITests}"
SKIP_GENERATE=0

usage() {
  cat <<'EOF'
Run iOS UI hang reliability regression tests.

Usage:
  ios/scripts/test-ui-reliability.sh [options]

Options:
  --skip-generate          Skip `xcodegen generate`
  --destination <value>    xcodebuild destination string
  --scheme <name>          Scheme name (default: PiRemoteUIReliability)
  --only-testing <value>   xcodebuild -only-testing value
  --device <udid>          Run on connected device (sets destination to platform=iOS,id=<udid>)
  -h, --help               Show help

Environment overrides:
  PIOS_UI_RELIABILITY_SCHEME
  PIOS_UI_RELIABILITY_DESTINATION
  PIOS_UI_RELIABILITY_ONLY_TESTING

Examples:
  ios/scripts/test-ui-reliability.sh
  ios/scripts/test-ui-reliability.sh --skip-generate
  ios/scripts/test-ui-reliability.sh --device 00000000-0000-0000-0000-000000000000
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
      DESTINATION="platform=iOS,id=$2"
      shift 2
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

cd "$IOS_DIR"

if [[ "$SKIP_GENERATE" -eq 0 ]]; then
  xcodegen generate
fi

xcodebuild -project PiRemote.xcodeproj -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -only-testing:"$ONLY_TESTING" \
  test

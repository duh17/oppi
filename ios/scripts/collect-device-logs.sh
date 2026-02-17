#!/usr/bin/env bash
set -euo pipefail

DEVICE_QUERY=""
LAST="15m"
SUBSYSTEM="${OPPI_BUNDLE_ID:-dev.chenda.Oppi}"
PROCESS_NAME="Oppi"
PREDICATE_OVERRIDE=""
OUTPUT_DIR="$HOME/Library/Logs/Oppi/device"
INCLUDE_DEBUG=0
USE_SUDO=1

usage() {
  cat <<'EOF'
Collect Oppi unified logs from a physical iPhone.

Usage:
  ios/scripts/collect-device-logs.sh [options]

Options:
  -d, --device <id|name|udid>  Device selector (optional; auto-detect paired booted iPhone)
      --last <duration>        Lookback window for log collect (default: 15m)
      --subsystem <name>       Subsystem filter (default: $OPPI_BUNDLE_ID or dev.chenda.Oppi)
      --process <name>         Process filter (default: Oppi)
      --predicate <expr>       Full NSPredicate override (takes precedence)
      --output-dir <path>      Output directory (default: ~/Library/Logs/Oppi/device)
      --include-debug          Include debug-level entries in rendered text output
      --no-sudo                Do not use sudo for `log collect` (requires root)
  -h, --help                   Show help

Examples:
  ios/scripts/collect-device-logs.sh --device 00008140-00161DAC26E3001C --last 30m
  ios/scripts/collect-device-logs.sh --include-debug --output-dir /tmp/piremote-device-logs
  ios/scripts/collect-device-logs.sh --predicate 'process == "Oppi" OR subsystem == "com.apple.runningboard"'
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: missing required command: $1" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--device)
      DEVICE_QUERY="${2:-}"
      shift 2
      ;;
    --last)
      LAST="${2:-}"
      shift 2
      ;;
    --subsystem)
      SUBSYSTEM="${2:-}"
      shift 2
      ;;
    --process)
      PROCESS_NAME="${2:-}"
      shift 2
      ;;
    --predicate)
      PREDICATE_OVERRIDE="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --include-debug)
      INCLUDE_DEBUG=1
      shift
      ;;
    --no-sudo)
      USE_SUDO=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_cmd xcrun
require_cmd jq
require_cmd log

DEVICE_JSON="$(mktemp -t piremote-devices)"
trap 'rm -f "$DEVICE_JSON"' EXIT
xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null

resolve_device_udid() {
  local query="$1"
  jq -r --arg q "$query" '
    .result.devices[]
    | select(.hardwareProperties.deviceType == "iPhone")
    | select(
        .hardwareProperties.udid == $q
        or .identifier == $q
        or .deviceProperties.name == $q
        or ((.connectionProperties.localHostnames // []) | index($q) != null)
        or ((.connectionProperties.potentialHostnames // []) | index($q) != null)
      )
    | .hardwareProperties.udid
  ' "$DEVICE_JSON" | head -n1
}

if [[ -n "$DEVICE_QUERY" ]]; then
  DEVICE_UDID="$(resolve_device_udid "$DEVICE_QUERY")"
else
  # Auto-detect: find any paired iPhone. bootState may be null over
  # network connections, so only require pairingState == "paired".
  DEVICE_UDID="$(jq -r '
    .result.devices[]
    | select(.hardwareProperties.deviceType == "iPhone")
    | select(.connectionProperties.pairingState == "paired")
    | .hardwareProperties.udid
  ' "$DEVICE_JSON" | head -n1)"
fi

if [[ -z "$DEVICE_UDID" ]]; then
  echo "error: no connected paired iPhone found." >&2
  echo "hint: run 'xcrun devicectl list devices' and pass --device <udid|name>." >&2
  exit 1
fi

DEVICE_NAME="$(jq -r --arg udid "$DEVICE_UDID" '
  .result.devices[]
  | select(.hardwareProperties.udid == $udid)
  | .deviceProperties.name
' "$DEVICE_JSON" | head -n1)"

mkdir -p "$OUTPUT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_PATH="$OUTPUT_DIR/piremote-device-${STAMP}.logarchive"
TEXT_PATH="$OUTPUT_DIR/piremote-device-${STAMP}.txt"

if [[ -n "$PREDICATE_OVERRIDE" ]]; then
  PREDICATE="$PREDICATE_OVERRIDE"
else
  PREDICATE_PARTS=()
  if [[ -n "$SUBSYSTEM" ]]; then
    PREDICATE_PARTS+=("subsystem == \"$SUBSYSTEM\"")
  fi
  if [[ -n "$PROCESS_NAME" ]]; then
    PREDICATE_PARTS+=("process == \"$PROCESS_NAME\"")
  fi

  if [[ ${#PREDICATE_PARTS[@]} -eq 0 ]]; then
    PREDICATE='process == "Oppi"'
  else
    PREDICATE="${PREDICATE_PARTS[0]}"
    for ((i = 1; i < ${#PREDICATE_PARTS[@]}; i++)); do
      PREDICATE+=" OR ${PREDICATE_PARTS[$i]}"
    done
  fi
fi

echo "==> Device: ${DEVICE_NAME:-unknown} ($DEVICE_UDID)"
echo "==> Last: $LAST"
echo "==> Predicate: $PREDICATE"
echo "==> Collecting archive: $ARCHIVE_PATH"

if [[ $USE_SUDO -eq 1 && $EUID -ne 0 ]]; then
  sudo log collect \
    --device-udid "$DEVICE_UDID" \
    --last "$LAST" \
    --predicate "$PREDICATE" \
    --output "$ARCHIVE_PATH"
else
  log collect \
    --device-udid "$DEVICE_UDID" \
    --last "$LAST" \
    --predicate "$PREDICATE" \
    --output "$ARCHIVE_PATH"
fi

echo "==> Rendering text log: $TEXT_PATH"
if [[ $INCLUDE_DEBUG -eq 1 ]]; then
  log show --archive "$ARCHIVE_PATH" --style compact --predicate "$PREDICATE" --info --debug > "$TEXT_PATH"
else
  log show --archive "$ARCHIVE_PATH" --style compact --predicate "$PREDICATE" --info > "$TEXT_PATH"
fi

echo "==> Done"
echo "    Archive: $ARCHIVE_PATH"
echo "    Text:    $TEXT_PATH"

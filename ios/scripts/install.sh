#!/usr/bin/env bash
set -euo pipefail

# ─── Install Oppi on iPhone ──────────────────────────────────────
#
# Build and install Oppi on a connected iPhone.
# Auto-detects the first paired device unless --device is given.
#
# Usage:
#   ios/scripts/install.sh                     # build + install
#   ios/scripts/install.sh --launch            # build + install + launch
#   ios/scripts/install.sh --release --launch  # release build + install + launch
#   ios/scripts/install.sh -d "Duh Ifone"      # target specific device
# ──────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SCHEME="Oppi"
CONFIGURATION="Debug"
DEVICE_QUERY=""
LAUNCH=0
SKIP_GENERATE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--device)    DEVICE_QUERY="${2:-}"; shift 2 ;;
    --launch)       LAUNCH=1; shift ;;
    --release)      CONFIGURATION="Release"; shift ;;
    --skip-generate) SKIP_GENERATE=1; shift ;;
    -h|--help)
      sed -n '3,13p' "$0"
      exit 0
      ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

# ─── Resolve device ──────────────────────────────────────────────

DEVICE_JSON="$(mktemp)"
trap 'rm -f "$DEVICE_JSON"' EXIT
xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null

if [[ -n "$DEVICE_QUERY" ]]; then
  DEVICE_UDID="$(jq -r --arg q "$DEVICE_QUERY" '
    .result.devices[]
    | select(.hardwareProperties.deviceType == "iPhone")
    | select(
        .hardwareProperties.udid == $q or .identifier == $q
        or .deviceProperties.name == $q
      )
    | .hardwareProperties.udid
  ' "$DEVICE_JSON" | head -1)"
else
  DEVICE_UDID="$(jq -r '
    .result.devices[]
    | select(.hardwareProperties.deviceType == "iPhone")
    | select(.connectionProperties.pairingState == "paired")
    | .hardwareProperties.udid
  ' "$DEVICE_JSON" | head -1)"
fi

if [[ -z "$DEVICE_UDID" ]]; then
  echo "error: no connected paired iPhone found." >&2
  echo "hint: xcrun devicectl list devices" >&2
  exit 1
fi

DEVICE_NAME="$(jq -r --arg u "$DEVICE_UDID" '
  .result.devices[] | select(.hardwareProperties.udid == $u) | .deviceProperties.name
' "$DEVICE_JSON" | head -1)"

echo "==> Device: ${DEVICE_NAME:-unknown} ($DEVICE_UDID)"
echo "==> Configuration: $CONFIGURATION"

# ─── Generate project ────────────────────────────────────────────

cd "$IOS_DIR"

if [[ "$SKIP_GENERATE" -eq 0 ]]; then
  xcodegen generate >/dev/null
fi

# ─── Resolve build paths ─────────────────────────────────────────

EXTRA_ARGS=()
[[ -n "${SENTRY_DSN:-}" ]] && EXTRA_ARGS+=("SENTRY_DSN=$SENTRY_DSN")

BUILD_SETTINGS="$(xcodebuild -project Oppi.xcodeproj \
  -scheme "$SCHEME" -configuration "$CONFIGURATION" \
  -destination "id=$DEVICE_UDID" \
  ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
  -showBuildSettings 2>/dev/null)"

TARGET_BUILD_DIR="$(echo "$BUILD_SETTINGS" | awk -F ' = ' '/ TARGET_BUILD_DIR = /{ print $2; exit }')"
WRAPPER_NAME="$(echo "$BUILD_SETTINGS" | awk -F ' = ' '/ WRAPPER_NAME = /{ print $2; exit }')"
BUNDLE_ID="$(echo "$BUILD_SETTINGS" | awk -F ' = ' '/ PRODUCT_BUNDLE_IDENTIFIER = /{ print $2; exit }')"
APP_PATH="$TARGET_BUILD_DIR/$WRAPPER_NAME"

# ─── Build ────────────────────────────────────────────────────────

echo "==> Building..."

BUILD_LOG="$(mktemp)"
if ! xcodebuild -project Oppi.xcodeproj \
  -scheme "$SCHEME" -configuration "$CONFIGURATION" \
  -destination "id=$DEVICE_UDID" \
  -allowProvisioningUpdates \
  ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
  build 2>&1 | tee "$BUILD_LOG" > /dev/null; then
  echo "Build failed." >&2
  tail -30 "$BUILD_LOG" >&2
  rm -f "$BUILD_LOG"
  exit 1
fi
rm -f "$BUILD_LOG"

# ─── Install ─────────────────────────────────────────────────────

echo "==> Installing..."
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH"

# ─── Launch ──────────────────────────────────────────────────────

if [[ "$LAUNCH" -eq 1 ]]; then
  echo "==> Launching..."
  xcrun devicectl device process launch --device "$DEVICE_UDID" --terminate-existing "$BUNDLE_ID"
fi

echo "==> Done"

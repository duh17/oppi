#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SCHEME="Oppi"
CONFIGURATION="Debug"
BUNDLE_ID="${OPPI_BUNDLE_ID:-dev.chenda.Oppi}"
DEVICE_QUERY=""
LAUNCH=0
CONSOLE=0
SKIP_GENERATE=0
DEBUG=0
LOGS_DIR=""
UNLOCK_KEYCHAIN=0
KEYCHAIN_PASSWORD_ENV="PI_KEYCHAIN_PASSWORD"
KEYCHAIN_PATH="$HOME/Library/Keychains/login.keychain-db"
SENTRY_DSN_FILE="${PIOS_SENTRY_DSN_FILE:-$HOME/.config/pios/sentry-dsn}"
RESOLVED_SENTRY_DSN=""
XCODEBUILD_EXTRA_ARGS=()

DEVICE_JSON=""
BUILD_LOG=""
INSTALL_LOG=""
LAUNCH_LOG=""
KEEP_TEMP_LOGS=0
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

usage() {
  cat <<'EOF'
Build and install Oppi on a paired iPhone.

Usage:
  ios/scripts/build-install.sh [options]

Options:
  -d, --device <id|name|udid>   Target device (optional; auto-detect first connected iPhone)
  -c, --configuration <name>    Build configuration (default: Debug)
      --launch                  Launch app after install
      --console                 Launch with `devicectl --console` (implies --launch)
      --skip-generate           Skip `xcodegen generate`
      --logs-dir <path>         Persist build/install/launch logs to a directory
      --debug                   Shell debug mode (`set -x`)
      --unlock-keychain         Unlock keychain for non-interactive SSH signing
      --keychain-password-env <name>
                                Env var containing keychain password (default: PI_KEYCHAIN_PASSWORD)
      --keychain-path <path>    Keychain path (default: ~/Library/Keychains/login.keychain-db)
      --sentry-dsn-file <path>  Local DSN file (default: ~/.config/pios/sentry-dsn)
  -h, --help                    Show this help

Sentry DSN precedence:
  1) SENTRY_DSN env var
  2) --sentry-dsn-file / PIOS_SENTRY_DSN_FILE / ~/.config/pios/sentry-dsn

Examples:
  ios/scripts/build-install.sh --device 00008140-00161DAC26E3001C --launch
  ios/scripts/build-install.sh --logs-dir ~/Library/Logs/Oppi --launch
  PI_KEYCHAIN_PASSWORD='***' ios/scripts/build-install.sh --unlock-keychain --launch
  SENTRY_DSN='https://...@o0.ingest.sentry.io/0' ios/scripts/build-install.sh --launch
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: missing required command: $1" >&2
    exit 1
  fi
}

new_log_file() {
  local name="$1"
  if [[ -n "$LOGS_DIR" ]]; then
    mkdir -p "$LOGS_DIR"
    printf '%s/%s-%s.log\n' "$LOGS_DIR" "$TIMESTAMP" "$name"
  else
    mktemp -t "piremote-${name}"
  fi
}

cleanup() {
  if [[ -n "$DEVICE_JSON" ]]; then
    rm -f "$DEVICE_JSON"
  fi

  if [[ $KEEP_TEMP_LOGS -eq 1 || -n "$LOGS_DIR" ]]; then
    return
  fi

  if [[ -n "$BUILD_LOG" ]]; then
    rm -f "$BUILD_LOG"
  fi

  if [[ -n "$INSTALL_LOG" ]]; then
    rm -f "$INSTALL_LOG"
  fi

  if [[ -n "$LAUNCH_LOG" ]]; then
    rm -f "$LAUNCH_LOG"
  fi
}
trap cleanup EXIT

run_and_tee() {
  local log_file="$1"
  shift

  set +e
  "$@" 2>&1 | tee "$log_file"
  local exit_code=${PIPESTATUS[0]}
  set -e
  return "$exit_code"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--device)
      DEVICE_QUERY="${2:-}"
      shift 2
      ;;
    -c|--configuration)
      CONFIGURATION="${2:-}"
      shift 2
      ;;
    --launch)
      LAUNCH=1
      shift
      ;;
    --console)
      CONSOLE=1
      LAUNCH=1
      shift
      ;;
    --skip-generate)
      SKIP_GENERATE=1
      shift
      ;;
    --logs-dir)
      LOGS_DIR="${2:-}"
      shift 2
      ;;
    --debug)
      DEBUG=1
      shift
      ;;
    --unlock-keychain)
      UNLOCK_KEYCHAIN=1
      shift
      ;;
    --keychain-password-env)
      KEYCHAIN_PASSWORD_ENV="${2:-}"
      shift 2
      ;;
    --keychain-path)
      KEYCHAIN_PATH="${2:-}"
      shift 2
      ;;
    --sentry-dsn-file)
      SENTRY_DSN_FILE="${2:-}"
      shift 2
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

if [[ $DEBUG -eq 1 ]]; then
  set -x
fi

if [[ -n "${SENTRY_DSN:-}" ]]; then
  RESOLVED_SENTRY_DSN="$SENTRY_DSN"
elif [[ -f "$SENTRY_DSN_FILE" ]]; then
  RESOLVED_SENTRY_DSN="$(awk 'NR==1 { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }' "$SENTRY_DSN_FILE")"
fi

if [[ -n "$RESOLVED_SENTRY_DSN" ]]; then
  XCODEBUILD_EXTRA_ARGS+=("SENTRY_DSN=$RESOLVED_SENTRY_DSN")
fi

require_cmd xcodebuild
require_cmd xcrun
require_cmd jq

if [[ $SKIP_GENERATE -eq 0 ]]; then
  require_cmd xcodegen
  (
    cd "$IOS_DIR"
    xcodegen generate >/dev/null
  )
fi

if [[ $UNLOCK_KEYCHAIN -eq 1 ]]; then
  if [[ ! -f "$KEYCHAIN_PATH" ]]; then
    echo "error: keychain not found: $KEYCHAIN_PATH" >&2
    exit 1
  fi

  if [[ -z "$KEYCHAIN_PASSWORD_ENV" ]]; then
    echo "error: keychain password env var name is empty" >&2
    exit 1
  fi

  KEYCHAIN_PASSWORD="${!KEYCHAIN_PASSWORD_ENV:-}"
  if [[ -z "$KEYCHAIN_PASSWORD" ]]; then
    echo "error: missing keychain password in env var: $KEYCHAIN_PASSWORD_ENV" >&2
    echo "hint: export $KEYCHAIN_PASSWORD_ENV='<your-login-password>'" >&2
    exit 1
  fi

  echo "==> Unlocking keychain for codesign"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
  unset KEYCHAIN_PASSWORD
fi

DEVICE_JSON="$(mktemp -t piremote-devices)"
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
  DEVICE_UDID="$(jq -r '
    .result.devices[]
    | select(.hardwareProperties.deviceType == "iPhone")
    | select(.connectionProperties.pairingState == "paired")
    | select(.deviceProperties.bootState == "booted")
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

echo "==> Device: ${DEVICE_NAME:-unknown} ($DEVICE_UDID)"
echo "==> Configuration: $CONFIGURATION"
if [[ -n "$RESOLVED_SENTRY_DSN" ]]; then
  if [[ -n "${SENTRY_DSN:-}" ]]; then
    echo "==> Sentry DSN: enabled (env)"
  else
    echo "==> Sentry DSN: enabled ($SENTRY_DSN_FILE)"
  fi
else
  echo "==> Sentry DSN: disabled"
fi

BUILD_SETTINGS="$(
  (
    cd "$IOS_DIR"
    xcodebuild -project Oppi.xcodeproj \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -destination "id=$DEVICE_UDID" \
      "${XCODEBUILD_EXTRA_ARGS[@]}" \
      -showBuildSettings
  ) 2>/dev/null
)"

TARGET_BUILD_DIR="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F ' = ' '/ TARGET_BUILD_DIR = / { print $2; exit }')"
WRAPPER_NAME="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F ' = ' '/ WRAPPER_NAME = / { print $2; exit }')"
APP_PATH="$TARGET_BUILD_DIR/$WRAPPER_NAME"

if [[ -z "$TARGET_BUILD_DIR" || -z "$WRAPPER_NAME" ]]; then
  echo "error: failed to resolve app build path from xcodebuild settings." >&2
  exit 1
fi

BUILD_LOG="$(new_log_file build)"
echo "==> Build log: $BUILD_LOG"
if ! (
  cd "$IOS_DIR"
  run_and_tee "$BUILD_LOG" \
    xcodebuild -project Oppi.xcodeproj \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -destination "id=$DEVICE_UDID" \
      -allowProvisioningUpdates \
      "${XCODEBUILD_EXTRA_ARGS[@]}" \
      build
); then
  KEEP_TEMP_LOGS=1

  if grep -q "errSecInternalComponent" "$BUILD_LOG"; then
    cat <<'EOF' >&2

codesign failed with errSecInternalComponent.
This usually means the SSH session cannot access signing keys.

Try one of these:
  1) Build once in Xcode GUI and click "Always Allow" for signing prompts.
  2) Provide keychain access in this script:
       PI_KEYCHAIN_PASSWORD='<login-password>' \
       ./ios/scripts/build-install.sh --unlock-keychain ...
  3) One-time key partition setup (manual):
       security set-key-partition-list -S apple-tool:,apple: -s -k '<login-password>' ~/Library/Keychains/login.keychain-db
EOF
  fi

  echo "build failed. log: $BUILD_LOG" >&2
  exit 65
fi

if [[ ! -d "$APP_PATH" ]]; then
  KEEP_TEMP_LOGS=1
  echo "error: built app not found: $APP_PATH" >&2
  echo "build log: $BUILD_LOG" >&2
  exit 1
fi

INSTALL_LOG="$(new_log_file install)"
echo "==> Install log: $INSTALL_LOG"
if ! run_and_tee "$INSTALL_LOG" xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH"; then
  KEEP_TEMP_LOGS=1
  echo "install failed. log: $INSTALL_LOG" >&2
  exit 1
fi

if [[ $LAUNCH -eq 1 ]]; then
  LAUNCH_LOG="$(new_log_file launch)"
  echo "==> Launch log: $LAUNCH_LOG"

  if [[ $CONSOLE -eq 1 ]]; then
    if ! run_and_tee "$LAUNCH_LOG" xcrun devicectl device process launch --device "$DEVICE_UDID" --terminate-existing --console "$BUNDLE_ID"; then
      KEEP_TEMP_LOGS=1
      echo "launch failed. log: $LAUNCH_LOG" >&2
      exit 1
    fi
  else
    if ! run_and_tee "$LAUNCH_LOG" xcrun devicectl device process launch --device "$DEVICE_UDID" --terminate-existing "$BUNDLE_ID"; then
      KEEP_TEMP_LOGS=1
      echo "warning: launch failed (device may be locked). log: $LAUNCH_LOG" >&2
      exit 1
    fi
  fi
fi

echo "==> Done"
if [[ -n "$LOGS_DIR" ]]; then
  echo "==> Logs directory: $LOGS_DIR"
fi

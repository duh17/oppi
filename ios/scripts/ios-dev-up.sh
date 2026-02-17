#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

PORT=7749
WAIT_SECONDS=20
RESTART_SERVER=1
NO_LAUNCH=0
DEBUG=0
FORWARD_ARGS=()
LAUNCHD_LABEL="com.oppi.oppi-server"
LOG_PATH="$HOME/.local/var/log/oppi-server.log"

usage() {
  cat <<'EOF'
Repeatable local iOS dev flow:
1) Ensure oppi-server server is running (launchd)
2) Build + install Oppi to iPhone

Usage:
  scripts/ios-dev-up.sh [options] [-- <build-install args>]

Options:
      --port <n>               server port readiness check (default: 7749)
      --wait <seconds>         wait timeout for server port (default: 20)
      --no-restart-server      skip server restart if already running
      --no-launch              do not force --launch for iOS app
      --debug                  shell debug mode (`set -x`)
  -h, --help                   show help

Any args after `--` are forwarded to ios/scripts/build-install.sh.
If no launch arg is provided, this script adds --launch by default.

Examples:
  scripts/ios-dev-up.sh
  scripts/ios-dev-up.sh -- --device 00008140-00161DAC26E3001C
  scripts/ios-dev-up.sh --no-launch -- --skip-generate
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: missing required command: $1" >&2
    exit 1
  fi
}

contains_arg() {
  local needle="$1"
  shift || true
  local arg
  for arg in "$@"; do
    [[ "$arg" == "$needle" ]] && return 0
  done
  return 1
}

restart_launchd_server() {
  if launchctl list "$LAUNCHD_LABEL" &>/dev/null; then
    launchctl stop "$LAUNCHD_LABEL" 2>/dev/null || true
    # KeepAlive will restart it automatically
    sleep 1
  else
    local plist="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
    if [[ -f "$plist" ]]; then
      launchctl load "$plist"
    else
      echo "error: launchd plist not found at $plist" >&2
      echo "  Run: ~/.config/dotfiles/scripts/oppi-server.sh" >&2
      exit 1
    fi
  fi
}

ensure_server_running() {
  if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    if [[ $RESTART_SERVER -eq 1 ]]; then
      restart_launchd_server
    fi
    return
  fi
  restart_launchd_server
}

wait_for_server() {
  local timeout="$1"
  local attempt=0
  while (( attempt < timeout )); do
    if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    ((attempt += 1))
  done
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)       PORT="${2:-}"; shift 2 ;;
    --wait)       WAIT_SECONDS="${2:-}"; shift 2 ;;
    --no-restart-server) RESTART_SERVER=0; shift ;;
    --no-launch)  NO_LAUNCH=1; shift ;;
    --debug)      DEBUG=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    --)           shift; FORWARD_ARGS+=("$@"); break ;;
    *)            echo "error: unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ $DEBUG -eq 1 ]] && set -x

require_cmd lsof

ensure_server_running

if [[ $RESTART_SERVER -eq 1 ]]; then
  echo "==> Server restarted (launchd: $LAUNCHD_LABEL)"
else
  echo "==> Server already running"
fi

if ! wait_for_server "$WAIT_SECONDS"; then
  echo "error: server did not start listening on port $PORT within ${WAIT_SECONDS}s" >&2
  echo "==> Recent server log:" >&2
  tail -20 "$LOG_PATH" >&2 || true
  exit 1
fi

echo "==> Server listening on :$PORT"

BUILD_ARGS=("${FORWARD_ARGS[@]}")
if [[ $NO_LAUNCH -eq 0 ]]; then
  if ! contains_arg "--launch" "${BUILD_ARGS[@]}" && ! contains_arg "--console" "${BUILD_ARGS[@]}"; then
    BUILD_ARGS+=("--launch")
  fi
fi

echo "==> Deploying iOS app"
"$ROOT_DIR/ios/scripts/build-install.sh" "${BUILD_ARGS[@]}"

echo "==> Done"
echo "==> Server logs: tail -f $LOG_PATH"

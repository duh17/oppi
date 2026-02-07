#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

TMUX_SESSION=""
WINDOW_NAME="pi-remote-server"
PORT=7749
WAIT_SECONDS=20
RESTART_SERVER=1
NO_LAUNCH=0
DEBUG=0
FORWARD_ARGS=()

usage() {
  cat <<'EOF'
Repeatable local iOS dev flow:
1) Start (or restart) pi-remote server in a background tmux window
2) Build + install PiRemote to iPhone

Usage:
  scripts/ios-dev-up.sh [options] [-- <build-install args>]

Options:
      --session <name>         tmux session (default: current session, else main/pi-ios)
      --window <name>          tmux window name (default: pi-remote-server)
      --port <n>               server port readiness check (default: 7749)
      --wait <seconds>         wait timeout for server port (default: 20)
      --no-restart-server      keep existing tmux window if it exists
      --no-launch              do not force --launch for iOS app
      --debug                  shell debug mode (`set -x`)
  -h, --help                   show help

Any args after `--` are forwarded to ios/scripts/build-install.sh.
If no launch arg is provided, this script adds --launch by default.

Examples:
  scripts/ios-dev-up.sh
  scripts/ios-dev-up.sh -- --device DEVICE_UDID
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
    if [[ "$arg" == "$needle" ]]; then
      return 0
    fi
  done

  return 1
}

resolve_session() {
  if [[ -n "$TMUX_SESSION" ]]; then
    echo "$TMUX_SESSION"
    return
  fi

  if [[ -n "${TMUX:-}" ]]; then
    tmux display-message -p '#S'
    return
  fi

  if tmux has-session -t main 2>/dev/null; then
    echo "main"
  else
    echo "pi-ios"
  fi
}

start_server_window() {
  local session="$1"
  local exists=0

  if tmux list-windows -t "$session" -F '#{window_name}' | grep -Fxq "$WINDOW_NAME"; then
    exists=1
  fi

  if [[ $exists -eq 1 && $RESTART_SERVER -eq 1 ]]; then
    tmux kill-window -t "$session:$WINDOW_NAME"
    exists=0
  fi

  if [[ $exists -eq 1 ]]; then
    tmux list-panes -t "$session:$WINDOW_NAME" -F '#{pane_id}' | head -n1
    return
  fi

  tmux new-window -d -P -F '#{pane_id}' \
    -t "$session" \
    -n "$WINDOW_NAME" \
    -c "$ROOT_DIR/pi-remote" \
    "npx tsx src/index.ts serve"
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
    --session)
      TMUX_SESSION="${2:-}"
      shift 2
      ;;
    --window)
      WINDOW_NAME="${2:-}"
      shift 2
      ;;
    --port)
      PORT="${2:-}"
      shift 2
      ;;
    --wait)
      WAIT_SECONDS="${2:-}"
      shift 2
      ;;
    --no-restart-server)
      RESTART_SERVER=0
      shift
      ;;
    --no-launch)
      NO_LAUNCH=1
      shift
      ;;
    --debug)
      DEBUG=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      FORWARD_ARGS+=("$@")
      break
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

require_cmd tmux
require_cmd lsof

SESSION="$(resolve_session)"
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux new-session -d -s "$SESSION" -n shell -c "$ROOT_DIR"
fi

PANE_ID="$(start_server_window "$SESSION")"

echo "==> Server window: ${SESSION}:${WINDOW_NAME} (pane ${PANE_ID})"
if [[ $RESTART_SERVER -eq 1 ]]; then
  echo "==> Server restarted"
else
  echo "==> Server window kept"
fi

if ! wait_for_server "$WAIT_SECONDS"; then
  echo "error: server did not start listening on port $PORT within ${WAIT_SECONDS}s" >&2
  echo "==> Recent tmux output (${PANE_ID}):" >&2
  tmux capture-pane -t "$PANE_ID" -p -S -120 >&2 || true
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
echo "==> Switch to server logs: tmux select-window -t ${SESSION}:${WINDOW_NAME}"

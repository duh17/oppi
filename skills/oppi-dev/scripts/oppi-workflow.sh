#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PIOS_ROOT="${PIOS_ROOT:-$HOME/workspace/oppi}"

usage() {
  cat <<'EOF'
Compose Oppi iOS + oppi-server debug workflows with one command hub.

Usage:
  oppi-workflow.sh <command> [args...]

Default lanes:
  simulator-proof  -> sim-test
  local-dev-loop   -> dev-up / deploy
  live-triage      -> live / session / lookup
  incident-capture -> capture / capture-direct

Commands:
  dev-up [-- ...]          Run repo scripts/ios-dev-up.sh (server + deploy loop)
  deploy [-- ...]          Run repo ios/scripts/build-install.sh
  sim-test [-- ...]        Run repo ios/scripts/test-ui-reliability.sh

  live <subcmd> [args...]  Run skill scripts/live-debug.sh (start/check/stop/status)
  session [args...]        Run skill scripts/debug-session.sh
  lookup [args...]         Run skill scripts/session-lookup.py
  capture [args...]        Run skill scripts/capture-session-pane.sh
  capture-direct [args...] Run repo scripts/capture-session.sh directly

  help                     Show this help

Tip:
  Use `oppi-workflow.sh <command> --help` for command-specific options.

Examples:
  oppi-workflow.sh dev-up -- --device <iphone-udid>
  oppi-workflow.sh sim-test --only-testing OppiUITests/UIHangHarnessUITests
  oppi-workflow.sh live start --device <iphone-udid>
  oppi-workflow.sh session latest
  oppi-workflow.sh capture --session <session-id> --last 25m
EOF
}

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "error: missing file: $path" >&2
    exit 1
  fi
}

require_exec() {
  local path="$1"
  require_file "$path"
  if [[ ! -x "$path" ]]; then
    echo "error: file is not executable: $path" >&2
    exit 1
  fi
}

run_repo_exec() {
  local rel="$1"
  shift || true
  local script="$PIOS_ROOT/$rel"
  require_exec "$script"
  exec "$script" "$@"
}

run_skill_exec() {
  local rel="$1"
  shift || true
  local script="$BASE_DIR/$rel"
  require_exec "$script"
  exec "$script" "$@"
}

run_skill_python() {
  local rel="$1"
  shift || true
  local script="$BASE_DIR/$rel"
  require_file "$script"
  exec python3 "$script" "$@"
}

cmd="${1:-help}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "$cmd" in
  dev-up)
    run_repo_exec "scripts/ios-dev-up.sh" "$@"
    ;;

  deploy)
    run_repo_exec "ios/scripts/build-install.sh" "$@"
    ;;

  sim-test)
    run_repo_exec "ios/scripts/test-ui-reliability.sh" "$@"
    ;;

  live)
    subcmd="${1:-status}"
    if [[ $# -gt 0 ]]; then
      shift
    fi
    run_skill_exec "scripts/live-debug.sh" "$subcmd" "$@"
    ;;

  session)
    run_skill_exec "scripts/debug-session.sh" "$@"
    ;;

  lookup)
    run_skill_python "scripts/session-lookup.py" "$@"
    ;;

  capture)
    run_skill_exec "scripts/capture-session-pane.sh" "$@"
    ;;

  capture-direct)
    run_repo_exec "scripts/capture-session.sh" "$@"
    ;;

  help|-h|--help)
    usage
    ;;

  *)
    echo "error: unknown command: $cmd" >&2
    usage
    exit 1
    ;;
esac

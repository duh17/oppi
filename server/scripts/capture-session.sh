#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
COLLECT_SCRIPT="$ROOT_DIR/ios/scripts/device-logs.sh"

SESSION_ID=""
DEVICE_QUERY=""
LAST="15m"
OUTPUT_DIR="$HOME/Library/Logs/Oppi/captures"
INCLUDE_DEBUG=0
INCLUDE_PERF=0
INCLUDE_LIFECYCLE=0
KEEP_ARCHIVE=0
NO_SUDO=0

usage() {
  cat <<'EOF'
Capture focused Oppi iOS logs for a session with minimal noise.

Usage:
  scripts/capture-session.sh --session <session-id> [options]

Options:
  -s, --session <id>         Session ID to focus on. If omitted, tries clipboard.
  -d, --device <id|name>     Device selector for log collection.
      --last <duration>      Lookback window (default: 15m)
      --output-dir <path>    Output directory (default: ~/Library/Logs/Oppi/captures)
      --include-debug        Include debug-level unified logs
      --include-perf         Include perf-heavy categories (Reducer/ChatView/Markdown)
      --include-lifecycle    Include RunningBoard/jetsam/crash lifecycle signals
      --keep-archive         Keep .logarchive in output bundle
      --no-sudo              Pass --no-sudo to collect-device-logs.sh
  -h, --help                 Show help

Examples:
  scripts/capture-session.sh --session t9iE9G1M --last 20m
  scripts/capture-session.sh --session t9iE9G1M --include-perf --include-debug
  scripts/capture-session.sh --session t9iE9G1M --include-lifecycle
  scripts/capture-session.sh --last 10m   # uses clipboard session id if valid
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
    -s|--session)
      SESSION_ID="${2:-}"
      shift 2
      ;;
    -d|--device)
      DEVICE_QUERY="${2:-}"
      shift 2
      ;;
    --last)
      LAST="${2:-}"
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
    --include-perf)
      INCLUDE_PERF=1
      shift
      ;;
    --include-lifecycle)
      INCLUDE_LIFECYCLE=1
      shift
      ;;
    --keep-archive)
      KEEP_ARCHIVE=1
      shift
      ;;
    --no-sudo)
      NO_SUDO=1
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

if [[ -z "$SESSION_ID" ]] && command -v pbpaste >/dev/null 2>&1; then
  CLIPBOARD_VALUE="$(pbpaste | tr -d '\r\n' | xargs || true)"
  if [[ "$CLIPBOARD_VALUE" =~ ^[A-Za-z0-9._:-]{6,80}$ ]]; then
    SESSION_ID="$CLIPBOARD_VALUE"
  fi
fi

if [[ -z "$SESSION_ID" ]]; then
  echo "error: session id required (pass --session or copy one to clipboard)." >&2
  exit 1
fi

require_cmd rg
require_cmd sort

if [[ ! -x "$COLLECT_SCRIPT" ]]; then
  echo "error: missing collect script: $COLLECT_SCRIPT" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d -t piremote-capture-session)"
trap 'rm -rf "$TMP_DIR"' EXIT

BASE_PREDICATE='subsystem == "dev.chenda.Oppi" OR process == "Oppi"'
LIFECYCLE_PREDICATE='subsystem BEGINSWITH "com.apple.runningboard" OR subsystem BEGINSWITH "com.apple.FrontBoard" OR subsystem BEGINSWITH "com.apple.ReportCrash" OR subsystem BEGINSWITH "com.apple.CrashReporter" OR process == "runningboardd" OR process == "SpringBoard" OR process == "ReportCrash" OR process == "assertiond" OR eventMessage CONTAINS[c] "jetsam" OR eventMessage CONTAINS[c] "watchdog" OR eventMessage CONTAINS[c] "killed" OR eventMessage CONTAINS[c] "termination"'

COLLECT_PREDICATE="$BASE_PREDICATE"
if [[ "$INCLUDE_LIFECYCLE" -eq 1 ]]; then
  COLLECT_PREDICATE="($BASE_PREDICATE) OR ($LIFECYCLE_PREDICATE)"
fi

COLLECT_ARGS=(
  --last "$LAST"
  --predicate "$COLLECT_PREDICATE"
  --output-dir "$TMP_DIR"
)

if [[ -n "$DEVICE_QUERY" ]]; then
  COLLECT_ARGS+=(--device "$DEVICE_QUERY")
fi
if [[ "$INCLUDE_DEBUG" -eq 1 ]]; then
  COLLECT_ARGS+=(--include-debug)
fi
if [[ "$NO_SUDO" -eq 1 ]]; then
  COLLECT_ARGS+=(--no-sudo)
fi

echo "==> Collecting device logs for session $SESSION_ID (window: $LAST)"
if [[ "$INCLUDE_LIFECYCLE" -eq 1 ]]; then
  echo "==> Lifecycle attribution enabled (RunningBoard/jetsam/crash signals)"
fi
"$COLLECT_SCRIPT" "${COLLECT_ARGS[@]}"

RAW_TEXT="$(ls -1t "$TMP_DIR"/piremote-device-*.txt 2>/dev/null | head -n1 || true)"
RAW_ARCHIVE="$(ls -1td "$TMP_DIR"/piremote-device-*.logarchive 2>/dev/null | head -n1 || true)"

if [[ -z "$RAW_TEXT" || ! -f "$RAW_TEXT" ]]; then
  echo "error: could not find collected text log in $TMP_DIR" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
SAFE_SESSION="${SESSION_ID//[^A-Za-z0-9_-]/_}"
STAMP="$(date +%Y%m%d-%H%M%S)"
CAPTURE_DIR="$OUTPUT_DIR/session-${SAFE_SESSION}-${STAMP}"
mkdir -p "$CAPTURE_DIR"

cp "$RAW_TEXT" "$CAPTURE_DIR/raw-app.log"

if [[ "$KEEP_ARCHIVE" -eq 1 && -n "$RAW_ARCHIVE" && -d "$RAW_ARCHIVE" ]]; then
  cp -R "$RAW_ARCHIVE" "$CAPTURE_DIR/"
fi

if [[ "$INCLUDE_LIFECYCLE" -eq 1 ]]; then
  LIFECYCLE_PATTERN='runningboard|frontboard|reportcrash|crashreport|jetsam|watchdog|terminated|termination|killed|exited \('
  rg -ni "$LIFECYCLE_PATTERN" "$CAPTURE_DIR/raw-app.log" > "$CAPTURE_DIR/lifecycle.log" || true
fi

CORE_CATEGORIES='Action|WebSocket|Connection|ChatSession'
if [[ "$INCLUDE_PERF" -eq 1 ]]; then
  CORE_CATEGORIES+='|Reducer|ChatView|Markdown'
fi
CORE_PATTERN="\\[dev\\.chenda\\.Oppi:(${CORE_CATEGORIES})\\]"

rg -n "$CORE_PATTERN" "$CAPTURE_DIR/raw-app.log" > "$CAPTURE_DIR/core.log" || true
rg -n -F "$SESSION_ID" "$CAPTURE_DIR/raw-app.log" > "$CAPTURE_DIR/session.log" || true
{
  rg -n -F "$SESSION_ID" "$CAPTURE_DIR/raw-app.log" || true
  rg -n "$CORE_PATTERN" "$CAPTURE_DIR/raw-app.log" || true
} | sort -t: -k1,1n -u > "$CAPTURE_DIR/focused.log"

cat > "$CAPTURE_DIR/meta.txt" <<EOF
session_id: $SESSION_ID
captured_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
lookback: $LAST
include_debug: $INCLUDE_DEBUG
include_perf: $INCLUDE_PERF
include_lifecycle: $INCLUDE_LIFECYCLE
source_predicate: $COLLECT_PREDICATE
source_subsystem: dev.chenda.Oppi
source_process: Oppi
raw_log: raw-app.log
focused_log: focused.log
core_log: core.log
session_log: session.log
lifecycle_log: lifecycle.log
EOF

echo "==> Capture complete"
echo "    Bundle:      $CAPTURE_DIR"
echo "    Focused log: $CAPTURE_DIR/focused.log"
echo "    Session log: $CAPTURE_DIR/session.log"
echo "    Core log:    $CAPTURE_DIR/core.log"
if [[ "$INCLUDE_LIFECYCLE" -eq 1 ]]; then
  echo "    Lifecycle:   $CAPTURE_DIR/lifecycle.log"
fi

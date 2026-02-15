#!/usr/bin/env bash
set -euo pipefail

# ─── Live Debug Session ──────────────────────────────────────────
#
# Orchestrates a live debug session for the Oppi iOS app.
# Combines device logs (USB), server logs (tmux), and session
# trace (REST API) into a single diagnostic workflow.
#
# Usage:
#   live-debug.sh start [--device <udid>]
#   live-debug.sh check [--lines N] [--grep pattern]
#   live-debug.sh stop
#   live-debug.sh status
# ──────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$HOME/workspace/oppi"

STATE_DIR="$HOME/.config/oppi-server/live-debug"
PID_FILE="$STATE_DIR/idevicesyslog.pid"
SESSION_FILE="$STATE_DIR/session.json"

LOG_DIR="$HOME/Library/Logs/Oppi/device"
DEVICE_LOG="$LOG_DIR/live.log"

SERVER_URL="${PI_REMOTE_URL:-http://localhost:7749}"
USERS_FILE="$HOME/.config/oppi-server/users.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

heading() { printf "\n${BOLD}${BLUE}── %s${NC}\n" "$1"; }
ok()      { printf "  ${GREEN}%s${NC}\n" "$1"; }
warn()    { printf "  ${YELLOW}%s${NC}\n" "$1"; }
err()     { printf "  ${RED}%s${NC}\n" "$1"; }
dim()     { printf "  ${DIM}%s${NC}\n" "$1"; }

# ─── Helpers ─────────────────────────────────────────────────────

get_token() {
  python3 -c "
import json
users = json.load(open('$USERS_FILE'))
for u in users:
    if u['name'] == 'Chen':
        print(u['token']); exit()
print(users[0]['token'])
" 2>/dev/null
}

auth() { curl -sf -H "Authorization: Bearer $(get_token)" "$@"; }

find_server_pane() {
  for win in $(tmux list-windows -t main -F '#{window_name}' 2>/dev/null || true); do
    if [[ "$win" == *"oppi-server"* || "$win" == *"server"* ]]; then
      echo "main:$win"
      return
    fi
  done
}

resolve_device_udid() {
  local query="${1:-}"
  local device_json
  device_json="$(mktemp -t piremote-devices)"
  trap 'rm -f "$device_json"' RETURN
  xcrun devicectl list devices --json-output "$device_json" >/dev/null 2>&1 || return 1

  if [[ -n "$query" ]]; then
    jq -r --arg q "$query" '
      .result.devices[]
      | select(.hardwareProperties.deviceType == "iPhone")
      | select(.hardwareProperties.udid == $q or .deviceProperties.name == $q)
      | .hardwareProperties.udid
    ' "$device_json" | head -n1
  else
    jq -r '
      .result.devices[]
      | select(.hardwareProperties.deviceType == "iPhone")
      | select(.connectionProperties.pairingState == "paired")
      | select(.deviceProperties.bootState == "booted")
      | .hardwareProperties.udid
    ' "$device_json" | head -n1
  fi
}

is_usb_connected() {
  system_profiler SPUSBDataType 2>/dev/null | grep -q "iPhone"
}

is_streaming() {
  [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

get_active_session_id() {
  # Try REST API first
  local sessions_json
  sessions_json=$(auth "$SERVER_URL/sessions" 2>/dev/null) || return 1
  python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
sessions = d.get('sessions', [])
# Find most recent active session
for s in sessions:
    if s.get('status') in ('ready', 'idle', 'busy'):
        print(s['id']); exit()
# Fall back to most recent
if sessions:
    print(sessions[0]['id'])
" <<< "$sessions_json"
}

# ─── start ───────────────────────────────────────────────────────

cmd_start() {
  local device_query=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--device) device_query="${2:-}"; shift 2 ;;
      *) echo "error: unknown argument: $1" >&2; exit 1 ;;
    esac
  done

  mkdir -p "$STATE_DIR" "$LOG_DIR"

  heading "Starting live debug session"

  # Resolve device
  local udid
  udid=$(resolve_device_udid "$device_query")
  if [[ -z "$udid" ]]; then
    warn "No connected iPhone found"
  else
    ok "Device: $udid"
  fi

  # Check server
  local server_pane
  server_pane=$(find_server_pane)
  if [[ -n "$server_pane" ]]; then
    ok "Server pane: $server_pane"
  else
    warn "No server tmux pane found"
  fi

  # Find active session
  local session_id
  session_id=$(get_active_session_id 2>/dev/null || echo "")
  if [[ -n "$session_id" ]]; then
    ok "Active session: $session_id"
  else
    warn "No active session (server may not be running)"
  fi

  # Save state
  python3 -c "
import json
state = {
    'udid': '${udid}',
    'server_pane': '${server_pane}',
    'session_id': '${session_id}',
    'device_log': '${DEVICE_LOG}'
}
with open('${SESSION_FILE}', 'w') as f:
    json.dump(state, f, indent=2)
"

  # Start device log streaming if USB connected
  if [[ -n "$udid" ]] && is_usb_connected; then
    # Kill existing stream
    if is_streaming; then
      kill "$(cat "$PID_FILE")" 2>/dev/null || true
    fi

    ok "USB detected — starting idevicesyslog"

    # Start in background, tee to file
    idevicesyslog -u "$udid" -p Oppi --no-colors > "$DEVICE_LOG" 2>&1 &
    echo $! > "$PID_FILE"

    ok "Device logs streaming to: $DEVICE_LOG"
  elif [[ -n "$udid" ]]; then
    warn "Device on WiFi — no device log streaming (USB required)"
    dim "Relying on server logs + session trace"
  fi

  heading "Log sources"
  if is_streaming; then
    ok "Device: tail -n 50 $DEVICE_LOG"
  else
    dim "Device: not available (WiFi only)"
  fi
  if [[ -n "$server_pane" ]]; then
    ok "Server: tmux capture-pane -t $server_pane -p -S -50"
  fi
  ok "Trace:  curl -s -H 'Authorization: Bearer ...' $SERVER_URL/sessions/<id>/trace"

  heading "Ready"
  echo "  Use 'live-debug.sh check' to inspect logs"
  echo "  Use 'live-debug.sh stop' to end session"
  echo ""
}

# ─── check ───────────────────────────────────────────────────────

cmd_check() {
  local lines=50
  local grep_pattern=""
  local device_only=0
  local server_only=0
  local trace_only=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--lines)       lines="${2:-50}"; shift 2 ;;
      -g|--grep)        grep_pattern="${2:-}"; shift 2 ;;
      --device-only)    device_only=1; shift ;;
      --server-only)    server_only=1; shift ;;
      --trace-only)     trace_only=1; shift ;;
      *) echo "error: unknown argument: $1" >&2; exit 1 ;;
    esac
  done

  # Load state
  local server_pane="" session_id=""
  if [[ -f "$SESSION_FILE" ]]; then
    server_pane=$(python3 -c "import json; print(json.load(open('$SESSION_FILE')).get('server_pane',''))" 2>/dev/null || true)
    session_id=$(python3 -c "import json; print(json.load(open('$SESSION_FILE')).get('session_id',''))" 2>/dev/null || true)
  fi

  # Refresh session ID if not stored
  if [[ -z "$session_id" ]]; then
    session_id=$(get_active_session_id 2>/dev/null || echo "")
  fi

  # Auto-detect server pane if not stored
  if [[ -z "$server_pane" ]]; then
    server_pane=$(find_server_pane)
  fi

  local show_all=1
  if [[ $device_only -eq 1 || $server_only -eq 1 || $trace_only -eq 1 ]]; then
    show_all=0
  fi

  # ─── Device logs ───────────────────────────────────────────

  if [[ $show_all -eq 1 || $device_only -eq 1 ]]; then
    heading "Device logs"
    if [[ -f "$DEVICE_LOG" ]] && is_streaming; then
      local device_lines
      if [[ -n "$grep_pattern" ]]; then
        device_lines=$(grep -i "$grep_pattern" "$DEVICE_LOG" | tail -n "$lines" || true)
      else
        device_lines=$(tail -n "$lines" "$DEVICE_LOG" || true)
      fi

      if [[ -n "$device_lines" ]]; then
        echo "$device_lines"
      else
        dim "(no matching device log entries)"
      fi
    elif [[ -f "$DEVICE_LOG" ]]; then
      # Log file exists but stream stopped — show what we have
      local device_lines
      device_lines=$(tail -n "$lines" "$DEVICE_LOG" 2>/dev/null || true)
      if [[ -n "$device_lines" ]]; then
        warn "(stream stopped — showing stale logs)"
        echo "$device_lines"
      else
        dim "(device log empty)"
      fi
    else
      dim "(no device log — USB streaming not active)"
    fi
  fi

  # ─── Server logs ───────────────────────────────────────────

  if [[ $show_all -eq 1 || $server_only -eq 1 ]]; then
    heading "Server logs"
    if [[ -n "$server_pane" ]]; then
      local server_lines
      if [[ -n "$grep_pattern" ]]; then
        server_lines=$(tmux capture-pane -t "$server_pane" -p -S - 2>/dev/null | grep -i "$grep_pattern" | tail -n "$lines" || true)
      else
        server_lines=$(tmux capture-pane -t "$server_pane" -p -S - 2>/dev/null | tail -n "$lines" || true)
      fi

      if [[ -n "$server_lines" ]]; then
        echo "$server_lines"
      else
        dim "(no matching server log entries)"
      fi
    else
      dim "(no server tmux pane found)"
    fi
  fi

  # ─── Session trace ────────────────────────────────────────

  if [[ $show_all -eq 1 || $trace_only -eq 1 ]]; then
    heading "Session trace (last 10 events)"
    if [[ -n "$session_id" ]]; then
      local session_json tmpfile
      tmpfile=$(mktemp -t piremote-trace)
      if auth "$SERVER_URL/sessions/$session_id" > "$tmpfile" 2>/dev/null; then
        python3 - "$tmpfile" "$grep_pattern" <<'PYEOF'
import json, sys

d = json.load(open(sys.argv[1]))
trace = d.get('trace', [])
if not trace:
    print('  \033[90m(no trace events)\033[0m')
    exit()

grep_pat = sys.argv[2].lower() if len(sys.argv) > 2 else ''

for e in trace[-10:]:
    ts = e.get('timestamp', '')[:19].replace('T', ' ')
    t = e['type']
    color = '\033[36m' if t == 'user' else '\033[32m' if t == 'assistant' else '\033[33m' if t in ('toolCall', 'toolResult') else '\033[90m'

    summary = ''
    if t == 'user':
        summary = (e.get('text', '') or '')[:80].replace('\n', ' ')
    elif t == 'assistant':
        summary = (e.get('text', '') or '')[:80].replace('\n', ' ')
    elif t == 'toolCall':
        tool = e.get('tool', '?')
        args_str = json.dumps(e.get('args', {}))[:60] if e.get('args') else ''
        summary = f'{tool} {args_str}'
    elif t == 'toolResult':
        output = (e.get('output', '') or '')[:60].replace('\n', ' ')
        if e.get('isError'):
            summary = f'\033[31m[ERROR]\033[33m {output}'
        else:
            summary = output

    line = f'{ts}  {t:12}  {summary}'
    if grep_pat and grep_pat not in line.lower():
        continue
    print(f'  {color}{line}\033[0m')
PYEOF
      else
        warn "Session $session_id — trace not available"
      fi
      rm -f "$tmpfile"
    else
      dim "(no active session)"
    fi
  fi

  echo ""
}

# ─── stop ────────────────────────────────────────────────────────

cmd_stop() {
  heading "Stopping live debug session"

  if is_streaming; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
    ok "Device log stream stopped"
  else
    dim "No device log stream running"
  fi

  if [[ -f "$SESSION_FILE" ]]; then
    rm -f "$SESSION_FILE"
    ok "Session state cleared"
  fi

  if [[ -f "$DEVICE_LOG" ]]; then
    local size
    size=$(du -h "$DEVICE_LOG" | cut -f1)
    dim "Device log preserved: $DEVICE_LOG ($size)"
  fi

  echo ""
}

# ─── status ──────────────────────────────────────────────────────

cmd_status() {
  heading "Live debug status"

  # Device log streaming
  if is_streaming; then
    local pid size
    pid=$(cat "$PID_FILE")
    size=$(du -h "$DEVICE_LOG" 2>/dev/null | cut -f1 || echo "?")
    ok "Device streaming: PID $pid ($size)"
  else
    dim "Device streaming: not active"
  fi

  # Server pane
  local server_pane
  server_pane=$(find_server_pane)
  if [[ -n "$server_pane" ]]; then
    ok "Server pane: $server_pane"
  else
    warn "Server pane: not found"
  fi

  # Server health
  if curl -sf "$SERVER_URL/health" >/dev/null 2>&1; then
    ok "Server: healthy"
  else
    warn "Server: not reachable"
  fi

  # Active session
  local session_id
  session_id=$(get_active_session_id 2>/dev/null || echo "")
  if [[ -n "$session_id" ]]; then
    ok "Active session: $session_id"
  else
    dim "Active session: none"
  fi

  # USB device
  if is_usb_connected; then
    ok "USB: connected"
  else
    dim "USB: not connected (WiFi only)"
  fi

  echo ""
}

# ─── Main ────────────────────────────────────────────────────────

SUBCOMMAND="${1:-}"
shift || true

case "$SUBCOMMAND" in
  start)  cmd_start "$@" ;;
  check)  cmd_check "$@" ;;
  stop)   cmd_stop "$@" ;;
  status) cmd_status "$@" ;;
  -h|--help|help|"")
    cat <<EOF
Live debug session for the Oppi iOS app.

Usage:
  live-debug.sh start [--device <udid>]   Start debug session
  live-debug.sh check [options]           Show recent logs
  live-debug.sh stop                      Stop debug session
  live-debug.sh status                    Show session status

check options:
  -n, --lines N          Lines per source (default: 50)
  -g, --grep <pattern>   Filter logs by pattern
  --device-only          Show only device logs
  --server-only          Show only server logs
  --trace-only           Show only session trace
EOF
    ;;
  *)
    echo "error: unknown subcommand: $SUBCOMMAND" >&2
    exit 1
    ;;
esac

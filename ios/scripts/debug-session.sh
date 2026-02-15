#!/usr/bin/env bash
set -euo pipefail

# ─── Debug Pi Remote Session ─────────────────────────────────────
#
# Quick diagnostic for a mobile session. Shows session metadata,
# recent trace events, pi process state, and gate status.
#
# Usage:
#   ios/scripts/debug-session.sh <session-id>
#   ios/scripts/debug-session.sh latest
#   ios/scripts/debug-session.sh          # interactive: pick from recent
# ──────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_URL="${PI_REMOTE_URL:-http://localhost:7749}"
USERS_FILE="$HOME/.config/oppi-server/users.json"
SESSIONS_DIR="$HOME/.config/oppi-server/sessions"

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
ok()      { printf "${GREEN}%s${NC}\n" "$1"; }
warn()    { printf "${YELLOW}%s${NC}\n" "$1"; }
err()     { printf "${RED}%s${NC}\n" "$1"; }
dim()     { printf "${DIM}%s${NC}\n" "$1"; }

# ─── Resolve auth token ─────────────────────────────────────────

TOKEN=$(uv run python -c "
import json
owner = json.load(open('$USERS_FILE'))
if isinstance(owner, dict) and isinstance(owner.get('token'), str):
    print(owner['token'])
" 2>/dev/null)

if [[ -z "$TOKEN" ]]; then
  err "Could not find auth token in $USERS_FILE"
  exit 1
fi

auth() { curl -sf -H "Authorization: Bearer $TOKEN" "$@"; }

# ─── Resolve session/workspace IDs ──────────────────────────────

SESSION_ID="${1:-}"
WORKSPACE_ID=""
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

if [[ "$SESSION_ID" == "latest" || -z "$SESSION_ID" ]]; then
  heading "Recent sessions"

  if [[ -d "$SESSIONS_DIR" ]]; then
    python3 - "$SESSIONS_DIR" "$TMPDIR_WORK/sessions-index.json" <<'PYEOF'
import datetime, glob, json, os, sys
sessions_dir, index_path = sys.argv[1], sys.argv[2]
rows = []
for path in glob.glob(os.path.join(sessions_dir, "*.json")):
    try:
        d = json.load(open(path))
    except Exception:
        continue
    s = d.get("session", d)
    sid = s.get("id") or os.path.splitext(os.path.basename(path))[0]
    wid = s.get("workspaceId") or ""
    if not sid:
        continue
    rows.append({
        "id": sid,
        "workspaceId": wid,
        "status": s.get("status", "?"),
        "messageCount": s.get("messageCount", 0),
        "cost": s.get("cost", 0),
        "lastActivity": s.get("lastActivity", 0),
        "workspaceName": s.get("workspaceName", "?"),
    })
rows.sort(key=lambda r: r.get("lastActivity", 0), reverse=True)
rows = rows[:8]
json.dump(rows, open(index_path, "w"))
for i, s in enumerate(rows, start=1):
    ts = datetime.datetime.fromtimestamp((s.get("lastActivity", 0) or 0)/1000).strftime('%m-%d %H:%M')
    status = s.get("status", "?")
    color = '\033[32m' if status in ('ready','idle') else '\033[33m' if status == 'busy' else '\033[90m'
    print(f"  {i}) {s['id']}  {color}{status:8}\033[0m  msgs={int(s.get('messageCount',0)):3d}  ${float(s.get('cost',0)):6.2f}  {ts}  {s.get('workspaceName','?')} ({s.get('workspaceId','?')})")
PYEOF

    if [[ "$SESSION_ID" == "latest" ]]; then
      SESSION_ID=$(python3 -c "import json; rows=json.load(open('$TMPDIR_WORK/sessions-index.json')); print(rows[0]['id'] if rows else '')")
      WORKSPACE_ID=$(python3 -c "import json; rows=json.load(open('$TMPDIR_WORK/sessions-index.json')); print(rows[0].get('workspaceId','') if rows else '')")
    else
      echo ""
      read -rp "Session ID or number [1]: " choice
      choice="${choice:-1}"
      if [[ "$choice" =~ ^[0-9]+$ && "$choice" -le 8 ]]; then
        SESSION_ID=$(python3 -c "import json; rows=json.load(open('$TMPDIR_WORK/sessions-index.json')); i=$((choice-1)); print(rows[i]['id'] if i < len(rows) else '')")
        WORKSPACE_ID=$(python3 -c "import json; rows=json.load(open('$TMPDIR_WORK/sessions-index.json')); i=$((choice-1)); print(rows[i].get('workspaceId','') if i < len(rows) else '')")
      else
        SESSION_ID="$choice"
      fi
    fi
  else
    err "Local sessions directory not found: $SESSIONS_DIR"
    read -rp "Session ID: " SESSION_ID
    [[ -z "$SESSION_ID" ]] && exit 0
  fi
fi

if [[ -z "$SESSION_ID" ]]; then
  err "No session selected."
  exit 1
fi

# Resolve workspace from local metadata first.
if [[ -z "$WORKSPACE_ID" ]]; then
  DISK_FILE="$SESSIONS_DIR/$SESSION_ID.json"
  if [[ -f "$DISK_FILE" ]]; then
    WORKSPACE_ID=$(uv run python -c "import json; d=json.load(open('$DISK_FILE')); s=d.get('session', d); print(s.get('workspaceId',''))" 2>/dev/null || true)
  fi
fi

# Fallback: discover workspace by querying workspaces + per-workspace sessions.
if [[ -z "$WORKSPACE_ID" ]]; then
  WORKSPACE_ID=$(uv run python - <<'PYEOF' "$SERVER_URL" "$TOKEN" "$SESSION_ID"
import json, sys, urllib.request
base, token, target = sys.argv[1], sys.argv[2], sys.argv[3]

def get(path):
    req = urllib.request.Request(f"{base}{path}", headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=5) as res:
        return json.load(res)

try:
    workspaces = get("/workspaces").get("workspaces", [])
    for ws in workspaces:
        wid = ws.get("id")
        if not wid:
            continue
        sessions = get(f"/workspaces/{wid}/sessions").get("sessions", [])
        if any(s.get("id") == target for s in sessions):
            print(wid)
            break
except Exception:
    pass
PYEOF
)
fi

if [[ -z "$WORKSPACE_ID" ]]; then
  err "Could not resolve workspace for session $SESSION_ID"
  exit 1
fi

printf "\n${BOLD}Session: ${CYAN}%s${NC}\n" "$SESSION_ID"
printf "${BOLD}Workspace: ${CYAN}%s${NC}\n" "$WORKSPACE_ID"

# ─── Session metadata ───────────────────────────────────────────

heading "Session metadata"

if auth "$SERVER_URL/workspaces/$WORKSPACE_ID/sessions/$SESSION_ID?view=full" > "$TMPDIR_WORK/session.json" 2>/dev/null; then
  python3 - "$TMPDIR_WORK/session.json" <<'PYEOF'
import json, sys, datetime
d = json.load(open(sys.argv[1]))
s = d.get('session', {})
created = datetime.datetime.fromtimestamp(s.get('createdAt',0)/1000).strftime('%Y-%m-%d %H:%M:%S')
last = datetime.datetime.fromtimestamp(s.get('lastActivity',0)/1000).strftime('%Y-%m-%d %H:%M:%S')
status = s.get('status','?')
color = '\033[32m' if status in ('ready','idle') else '\033[33m' if status == 'busy' else '\033[31m' if status == 'error' else '\033[90m'
print(f'  Status:     {color}{status}\033[0m')
print(f'  Runtime:    {s.get("runtime","?")}')
print(f'  Workspace:  {s.get("workspaceName","?")} ({s.get("workspaceId","?")})')
print(f'  Model:      {s.get("model","?")}')
print(f'  Messages:   {s.get("messageCount","?")}')
print(f'  Cost:       ${s.get("cost",0):.4f}')
ctx = s.get('contextTokens','?')
win = s.get('contextWindow','?')
if isinstance(ctx, int) and isinstance(win, int) and win > 0:
    pct = ctx / win * 100
    print(f'  Context:    {ctx:,}/{win:,} tokens ({pct:.0f}%)')
else:
    print(f'  Context:    {ctx}/{win} tokens')
print(f'  Created:    {created}')
print(f'  Last:       {last}')
pf = s.get('piSessionFile','')
if pf: print(f'  JSONL:      {pf}')
pid = s.get('piSessionId','')
if pid: print(f'  Pi UUID:    {pid}')
PYEOF
else
  DISK_FILE="$SESSIONS_DIR/$SESSION_ID.json"
  if [[ -f "$DISK_FILE" ]]; then
    dim "  (from disk — server unreachable)"
    python3 -c "
import json, datetime
d = json.load(open('$DISK_FILE'))
s = d.get('session', d)
print(f'  Status:   {s.get(\"status\",\"?\")}')
print(f'  Runtime:  {s.get(\"runtime\",\"?\")}')
print(f'  Messages: {s.get(\"messageCount\",\"?\")}')
print(f'  Model:    {s.get(\"model\",\"?\")}')
"
  else
    err "  Session not found"
    exit 1
  fi
fi

# ─── Pi process state ───────────────────────────────────────────

heading "Pi process"

found_pi=0
while IFS= read -r pid; do
  [[ -z "$pid" ]] && continue
  cmdline=$(ps -p "$pid" -o args= 2>/dev/null || true)
  rss=$(ps -p "$pid" -o rss= 2>/dev/null | awk '{printf "%.0fMB", $1/1024}')
  etime=$(ps -p "$pid" -o etime= 2>/dev/null | xargs)
  cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | xargs)
  state=$(ps -p "$pid" -o state= 2>/dev/null | xargs)

  if echo "$cmdline" | grep -q "$SESSION_ID" 2>/dev/null; then
    ok "  PID $pid — running (${etime}, ${rss}, ${cpu}% CPU, state=$state)"
    found_pi=1
  fi
done < <(pgrep -f "pi.*--mode rpc" 2>/dev/null || true)

if [[ "$found_pi" -eq 0 ]]; then
  # Show any rpc pi processes
  rpc_pids=$(pgrep -f "pi.*--mode rpc" 2>/dev/null || true)
  if [[ -n "$rpc_pids" ]]; then
    warn "  No pi process for $SESSION_ID"
    dim "  Other pi processes:"
    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      etime=$(ps -p "$pid" -o etime= 2>/dev/null | xargs)
      dim "    PID $pid (${etime})"
    done <<< "$rpc_pids"
  else
    warn "  No pi --mode rpc processes running"
  fi
fi

# ─── Trace summary ──────────────────────────────────────────────

heading "Trace summary"

if auth "$SERVER_URL/workspaces/$WORKSPACE_ID/sessions/$SESSION_ID?view=full" > "$TMPDIR_WORK/trace.json" 2>/dev/null; then
  python3 - "$TMPDIR_WORK/trace.json" <<'PYEOF'
import json, sys

d = json.load(open(sys.argv[1]))
trace = d.get('trace', [])
if not trace:
    print('  \033[90m(no trace events)\033[0m')
    exit()

types = {}
for e in trace:
    types[e['type']] = types.get(e['type'], 0) + 1
parts = [f'{t}={c}' for t, c in sorted(types.items())]
print(f'  Events: {len(trace)} ({", ".join(parts)})')

# Tools used
tools = set()
for e in trace:
    if e['type'] == 'toolCall':
        tools.add(e.get('tool', '?'))
if tools:
    print(f'  Tools:  {", ".join(sorted(tools))}')

# Error count
errors = sum(1 for e in trace if e.get('isError'))
if errors:
    print(f'  \033[31mErrors: {errors}\033[0m')

# Last 8 events
print()
print('  \033[1mLast 8 events:\033[0m')
for e in trace[-8:]:
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
    elif t == 'thinking':
        summary = (e.get('text', '') or '')[:60].replace('\n', ' ')

    print(f'  {color}{ts}  {t:12}  {summary}\033[0m')
PYEOF
else
  warn "  Trace not available from server"
  # Try JSONL directly
  JSONL_PATH=$(python3 -c "
import json
d = json.load(open('$SESSIONS_DIR/$SESSION_ID.json'))
s = d.get('session', d)
print(s.get('piSessionFile',''))
" 2>/dev/null || true)

  if [[ -n "$JSONL_PATH" && -f "$JSONL_PATH" ]]; then
    lines=$(wc -l < "$JSONL_PATH")
    size=$(du -h "$JSONL_PATH" | cut -f1)
    dim "  JSONL: $JSONL_PATH ($lines lines, $size)"
  fi
fi

# ─── Server log ──────────────────────────────────────────────────

heading "Server log (recent)"

SERVER_PANE=""
for win in $(tmux list-windows -t main -F '#{window_name}' 2>/dev/null || true); do
  if [[ "$win" == *"oppi-server"* || "$win" == *"server"* ]]; then
    SERVER_PANE="main:$win"
    break
  fi
done

if [[ -n "$SERVER_PANE" ]]; then
  matches=$(tmux capture-pane -t "$SERVER_PANE" -p -S - 2>/dev/null | grep -i "$SESSION_ID" | tail -8 || true)
  if [[ -n "$matches" ]]; then
    while IFS= read -r line; do
      dim "  $line"
    done <<< "$matches"
  else
    dim "  (no log lines for $SESSION_ID in tmux)"
  fi
else
  dim "  (no oppi-server tmux window found)"
fi

echo ""

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="/Users/chenda/workspace/oppi"
SESSION_ID=""
LAST="25m"
TMUX_SESSION=""
TMUX_WINDOW=""
DRY_RUN=0

usage() {
  cat <<'EOF'
Spawn a low-interruption tmux pane and run session log capture there.

Usage:
  capture-session-pane.sh --session <session-id> [options]

Options:
  -s, --session <id>         Session id for capture-session.sh (required)
      --last <duration>      Lookback window (default: 25m)
      --root <path>          Repo root containing scripts/capture-session.sh
                             (default: /Users/chenda/workspace/oppi)
      --tmux-session <name>  Override target tmux session
      --tmux-window <index>  Override target window index
      --dry-run              Print selected pane + command, do not execute
  -h, --help                 Show this help

Behavior (deterministic):
  1) Select target tmux session
     - current session if running inside tmux
     - else most recently active client session
     - else first listed session
  2) Select active window in that session
  3) Select smallest inactive pane in that window (or smallest pane if none inactive)
  4) Split that pane and run:
       cd <root> && ./scripts/capture-session.sh --session <id> --last <duration>
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
    --last)
      LAST="${2:-}"
      shift 2
      ;;
    --root)
      ROOT_DIR="${2:-}"
      shift 2
      ;;
    --tmux-session)
      TMUX_SESSION="${2:-}"
      shift 2
      ;;
    --tmux-window)
      TMUX_WINDOW="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
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

if [[ -z "$SESSION_ID" ]]; then
  echo "error: --session is required" >&2
  exit 1
fi

if [[ ! -d "$ROOT_DIR" ]]; then
  echo "error: root directory not found: $ROOT_DIR" >&2
  exit 1
fi

if [[ ! -x "$ROOT_DIR/scripts/capture-session.sh" ]]; then
  echo "error: missing executable: $ROOT_DIR/scripts/capture-session.sh" >&2
  exit 1
fi

require_cmd tmux
require_cmd awk
require_cmd sort

if ! tmux list-sessions >/dev/null 2>&1; then
  echo "error: tmux server not available" >&2
  exit 1
fi

if [[ -z "$TMUX_SESSION" && -n "${TMUX:-}" ]]; then
  TMUX_SESSION="$(tmux display-message -p '#S' 2>/dev/null || true)"
fi

if [[ -z "$TMUX_SESSION" ]]; then
  TMUX_SESSION="$({
    tmux list-clients -F '#{session_name}|#{client_activity}' 2>/dev/null \
      | sort -t '|' -k2,2nr \
      | awk -F '|' 'NR==1 { print $1 }'
  } || true)"
fi

if [[ -z "$TMUX_SESSION" ]]; then
  TMUX_SESSION="$(tmux list-sessions -F '#S' | head -n1 || true)"
fi

if [[ -z "$TMUX_SESSION" ]]; then
  echo "error: could not determine tmux session" >&2
  exit 1
fi

if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  echo "error: tmux session not found: $TMUX_SESSION" >&2
  exit 1
fi

if [[ -z "$TMUX_WINDOW" ]]; then
  TMUX_WINDOW="$({
    tmux list-windows -t "$TMUX_SESSION" -F '#{window_index}|#{window_active}' \
      | awk -F '|' '$2 == "1" { print $1; exit }'
  } || true)"
fi

if [[ -z "$TMUX_WINDOW" ]]; then
  TMUX_WINDOW="$(tmux list-windows -t "$TMUX_SESSION" -F '#{window_index}' | head -n1 || true)"
fi

if [[ -z "$TMUX_WINDOW" ]]; then
  echo "error: could not determine window in session $TMUX_SESSION" >&2
  exit 1
fi

pane_table="$(tmux list-panes -t "$TMUX_SESSION:$TMUX_WINDOW" -F '#{pane_id}|#{pane_index}|#{pane_active}|#{pane_width}|#{pane_height}')"

if [[ -z "$pane_table" ]]; then
  echo "error: no panes in $TMUX_SESSION:$TMUX_WINDOW" >&2
  exit 1
fi

anchor_line="$(printf '%s\n' "$pane_table" | awk -F '|' '
  BEGIN { foundInactive = 0; bestArea = -1; best = "" }
  {
    area = $4 * $5
    if ($3 == "0") {
      if (!foundInactive || area < bestArea) {
        foundInactive = 1
        bestArea = area
        best = $0
      }
    } else if (!foundInactive) {
      if (best == "" || area < bestArea) {
        bestArea = area
        best = $0
      }
    }
  }
  END { print best }
')"

if [[ -z "$anchor_line" ]]; then
  echo "error: failed to select anchor pane" >&2
  exit 1
fi

IFS='|' read -r anchor_pane anchor_index anchor_active anchor_width anchor_height <<< "$anchor_line"

split_flag="-v"
split_percent="35"
if (( anchor_height < 18 )); then
  split_flag="-h"
  split_percent="40"
fi

capture_cmd="cd \"$ROOT_DIR\" && ./scripts/capture-session.sh --session \"$SESSION_ID\" --last \"$LAST\""

if [[ "$DRY_RUN" -eq 1 ]]; then
  cat <<EOF
status=dry-run
session=$TMUX_SESSION
window=$TMUX_WINDOW
anchor=$anchor_pane
anchor_index=$anchor_index
anchor_active=$anchor_active
anchor_size=${anchor_width}x${anchor_height}
split_flag=$split_flag
split_percent=$split_percent
command=$capture_cmd
EOF
  exit 0
fi

new_pane="$(tmux split-window -d -t "$anchor_pane" "$split_flag" -p "$split_percent" -c "$ROOT_DIR" -P -F '#{pane_id}')"

tmux send-keys -t "$new_pane" -l -- "$capture_cmd"
tmux send-keys -t "$new_pane" Enter

cat <<EOF
status=started
session=$TMUX_SESSION
window=$TMUX_WINDOW
anchor=$anchor_pane
new_pane=$new_pane
switch=tmux select-pane -t $new_pane
command=$capture_cmd
note=If prompted, enter sudo password in the new pane.
EOF

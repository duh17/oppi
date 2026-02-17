#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="${PI_REMOTE_LOG_FILE:-$HOME/.local/var/log/oppi-server.log}"
MAX_MB="${PI_REMOTE_LOG_MAX_MB:-25}"
KEEP="${PI_REMOTE_LOG_KEEP:-10}"
COMPRESS=1
QUIET=0

usage() {
  cat <<'EOF'
Rotate oppi-server log file with copy+truncate semantics (launchd-friendly).

Usage:
  scripts/oppi-server-logrotate.sh [options]

Options:
      --file <path>     Log file to rotate (default: ~/.local/var/log/oppi-server.log)
      --max-mb <n>      Rotate when file is >= n MB (default: 25)
      --keep <n>        Keep latest n rotated archives (default: 10)
      --no-compress     Keep rotated archives uncompressed
      --quiet           Suppress normal output
  -h, --help            Show help

Environment overrides:
  PI_REMOTE_LOG_FILE
  PI_REMOTE_LOG_MAX_MB
  PI_REMOTE_LOG_KEEP
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

is_positive_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" > 0 ))
}

file_size_bytes() {
  local path="$1"
  local size

  if size=$(stat -f%z "$path" 2>/dev/null); then
    printf '%s' "$size"
    return
  fi

  stat -c%s "$path"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      LOG_FILE="${2:-}"
      shift 2
      ;;
    --max-mb)
      MAX_MB="${2:-}"
      shift 2
      ;;
    --keep)
      KEEP="${2:-}"
      shift 2
      ;;
    --no-compress)
      COMPRESS=0
      shift
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

is_positive_int "$MAX_MB" || die "--max-mb must be a positive integer"
is_positive_int "$KEEP" || die "--keep must be a positive integer"
[[ -n "$LOG_FILE" ]] || die "--file cannot be empty"

LOG_DIR="$(dirname -- "$LOG_FILE")"
LOG_BASE="$(basename -- "$LOG_FILE")"
LOCK_DIR="$LOG_DIR/.${LOG_BASE}.rotate.lock.d"

mkdir -p "$LOG_DIR"
[[ -f "$LOG_FILE" ]] || : > "$LOG_FILE"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  # Another rotation run is already in progress.
  exit 0
fi
trap 'rmdir "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT

SIZE_BYTES="$(file_size_bytes "$LOG_FILE")"
MAX_BYTES=$((MAX_MB * 1024 * 1024))

if (( SIZE_BYTES < MAX_BYTES )); then
  exit 0
fi

TS="$(date +"%Y%m%d-%H%M%S")"
ROTATED="$LOG_FILE.$TS"

cp "$LOG_FILE" "$ROTATED"
: > "$LOG_FILE"

if (( COMPRESS == 1 )); then
  gzip -f "$ROTATED"
  ROTATED="$ROTATED.gz"
fi

# Keep only the newest N archives (timestamp-prefixed names sort lexicographically).
shopt -s nullglob
ARCHIVES=("$LOG_FILE".[0-9]*)
shopt -u nullglob

if (( ${#ARCHIVES[@]} > KEEP )); then
  IFS=$'\n' SORTED=( $(printf '%s\n' "${ARCHIVES[@]}" | sort -r) )
  unset IFS
  for OLD in "${SORTED[@]:KEEP}"; do
    rm -f -- "$OLD"
  done
fi

if (( QUIET == 0 )); then
  NEW_SIZE="$(file_size_bytes "$LOG_FILE")"
  echo "rotated $LOG_FILE ($SIZE_BYTES bytes -> $NEW_SIZE bytes), archive=$ROTATED"
fi

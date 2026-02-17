#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

SSH_HOST="your-mac"
REMOTE_REPO="/path/to/pios"
LOCAL_LOG_DIR=""
WATCH=0
WATCH_INTERVAL=2
DEBUG=0
FORWARD_ARGS=()
WATCH_PATHS=(
  "ios/Oppi"
  "ios/Shared"
  "ios/OppiActivityExtension"
  "ios/project.yml"
)

usage() {
  cat <<'EOF'
Build + install Oppi on a remote Mac over SSH.

Usage:
  scripts/ios-deploy-ssh.sh [options] [-- <build-install args>]

Options:
      --host <ssh-host>           SSH host (default: your-mac)
      --repo <path>               Remote repo path (default: /path/to/pios)
      --local-log-dir <path>      Save local SSH output logs to directory
      --watch                     Watch iOS source files and auto-redeploy on change
      --watch-interval <seconds>  Poll interval for watch mode (default: 2)
      --watch-path <path>         Additional watch path (repeatable, repo-relative)
      --debug                     Shell debug mode (`set -x`)
  -h, --help                      Show help

Any additional args are forwarded to ios/scripts/build-install.sh on the remote host.

Examples:
  scripts/ios-deploy-ssh.sh --host your-mac -- --device 00008140-00161DAC26E3001C --launch
  scripts/ios-deploy-ssh.sh --local-log-dir ~/Library/Logs/Oppi -- --logs-dir ~/Library/Logs/Oppi --launch
  scripts/ios-deploy-ssh.sh --watch -- --skip-generate --launch
EOF
}

run_remote_once() {
  local remote_cmd="cd $(printf '%q' "$REMOTE_REPO") && ./ios/scripts/build-install.sh"
  for arg in "${FORWARD_ARGS[@]}"; do
    remote_cmd+=" $(printf '%q' "$arg")"
  done

  echo "==> SSH host: $SSH_HOST"
  echo "==> Remote cmd: $remote_cmd"

  local exit_code
  if [[ -n "$LOCAL_LOG_DIR" ]]; then
    mkdir -p "$LOCAL_LOG_DIR"
    local log_file="$LOCAL_LOG_DIR/ios-deploy-$(date +%Y%m%d-%H%M%S).log"
    echo "==> Local log: $log_file"

    set +e
    ssh "$SSH_HOST" "$remote_cmd" 2>&1 | tee "$log_file"
    exit_code=${PIPESTATUS[0]}
    set -e
  else
    set +e
    ssh "$SSH_HOST" "$remote_cmd"
    exit_code=$?
    set -e
  fi

  return "$exit_code"
}

watch_fingerprint() {
  local stat_lines=""
  local path

  for path in "${WATCH_PATHS[@]}"; do
    local abs="$ROOT_DIR/$path"
    if [[ -d "$abs" ]]; then
      local found
      found="$(find "$abs" -type f -print 2>/dev/null | LC_ALL=C sort || true)"
      if [[ -n "$found" ]]; then
        while IFS= read -r file; do
          [[ -z "$file" ]] && continue
          stat_lines+="$(stat -f '%m %N' "$file")"$'\n'
        done <<< "$found"
      fi
    elif [[ -f "$abs" ]]; then
      stat_lines+="$(stat -f '%m %N' "$abs")"$'\n'
    fi
  done

  if [[ -z "$stat_lines" ]]; then
    echo "none"
    return
  fi

  printf '%s' "$stat_lines" | shasum | awk '{print $1}'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      SSH_HOST="${2:-}"
      shift 2
      ;;
    --repo)
      REMOTE_REPO="${2:-}"
      shift 2
      ;;
    --local-log-dir)
      LOCAL_LOG_DIR="${2:-}"
      shift 2
      ;;
    --watch)
      WATCH=1
      shift
      ;;
    --watch-interval)
      WATCH_INTERVAL="${2:-}"
      shift 2
      ;;
    --watch-path)
      WATCH_PATHS+=("${2:-}")
      shift 2
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
      FORWARD_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ $DEBUG -eq 1 ]]; then
  set -x
fi

if [[ $WATCH -eq 0 ]]; then
  run_remote_once
  exit $?
fi

echo "==> Watch mode enabled"
echo "==> Interval: ${WATCH_INTERVAL}s"
echo "==> Paths: ${WATCH_PATHS[*]}"

last_fp="$(watch_fingerprint)"

if run_remote_once; then
  echo "==> Initial deploy succeeded"
else
  echo "==> Initial deploy failed (watch will continue)" >&2
fi

while true; do
  sleep "$WATCH_INTERVAL"
  next_fp="$(watch_fingerprint)"
  if [[ "$next_fp" == "$last_fp" ]]; then
    continue
  fi

  echo ""
  echo "==> Change detected, deploying..."
  if run_remote_once; then
    echo "==> Deploy succeeded"
    last_fp="$next_fp"
  else
    echo "==> Deploy failed (waiting for next change)" >&2
    last_fp="$next_fp"
  fi
done

#!/usr/bin/env bash
set -euo pipefail

# ─── Oppi Server Restart ─────────────────────────────────────────
#
# Restart the launchd-managed Oppi server.
#
# Usage:
#   scripts/server-restart.sh         # restart server
#   scripts/server-restart.sh --build # build server, then restart
# ──────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LAUNCHD_LABEL="dev.chenda.oppi"

DO_BUILD=false

for arg in "$@"; do
  case "$arg" in
    --build)      DO_BUILD=true ;;
    -h|--help)    sed -n '3,12p' "$0"; exit 0 ;;
    *)            echo "Unknown: $arg" >&2; exit 1 ;;
  esac
done

if $DO_BUILD; then
  echo "==> Building server..."
  cd "$ROOT_DIR/server"
  npm run build --silent
  echo "    Done."
fi

echo "==> Restarting server..."
launchctl kickstart -k "gui/$(id -u)/$LAUNCHD_LABEL"

sleep 2
for _ in $(seq 1 8); do
  curl -sf http://localhost:7749/health > /dev/null 2>&1 && {
    echo "    Server healthy."
    exit 0
  }
  sleep 1
done

echo "    Warning: health check failed after 10s"
exit 1

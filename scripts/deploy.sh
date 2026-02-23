#!/usr/bin/env bash
set -euo pipefail

# ─── Oppi Deploy ─────────────────────────────────────────────────
#
# Build server, install iOS app, restart server.
# Server restart is always last (kills active agent sessions).
#
# Usage:
#   scripts/deploy.sh                # build server + restart
#   scripts/deploy.sh --ios          # build server + install iOS + restart
#   scripts/deploy.sh --ios --launch # same + launch app after install
#   scripts/deploy.sh --no-restart   # build only, skip server restart
#   scripts/deploy.sh --restart-only # just restart server
# ──────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LAUNCHD_LABEL="dev.chenda.oppi"

DO_IOS=false
DO_LAUNCH=false
DO_BUILD=true
DO_RESTART=true

for arg in "$@"; do
  case "$arg" in
    --ios)          DO_IOS=true ;;
    --launch)       DO_LAUNCH=true ;;
    --no-restart)   DO_RESTART=false ;;
    --restart-only) DO_BUILD=false ;;
    -h|--help)      sed -n '3,14p' "$0"; exit 0 ;;
    *)              echo "Unknown: $arg" >&2; exit 1 ;;
  esac
done

# ─── Build server ────────────────────────────────────────────────

if $DO_BUILD; then
  echo "==> Building server..."
  cd "$ROOT_DIR/server"
  npm run build --silent
  echo "    Done."
fi

# ─── Install iOS (optional) ──────────────────────────────────────

if $DO_IOS; then
  INSTALL_ARGS=()
  $DO_LAUNCH && INSTALL_ARGS+=(--launch)
  echo "==> Installing iOS app..."
  bash "$ROOT_DIR/ios/scripts/install.sh" "${INSTALL_ARGS[@]}"
fi

# ─── Restart server (LAST — kills active sessions) ───────────────

if $DO_RESTART; then
  echo "==> Restarting server..."
  launchctl kickstart -k "gui/$(id -u)/$LAUNCHD_LABEL"
  # If running inside an oppi session, execution stops here.
  sleep 2
  for _ in $(seq 1 8); do
    curl -sf http://localhost:7749/health > /dev/null 2>&1 && { echo "    Server healthy."; exit 0; }
    sleep 1
  done
  echo "    Warning: health check failed after 10s"
  exit 1
fi

echo "==> Done."

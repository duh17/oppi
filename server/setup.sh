#!/usr/bin/env bash
#
# Oppi server setup — install deps, build, and start.
#
# Usage:
#   bash setup.sh              # install + build + start foreground
#   bash setup.sh --install    # source-link CLI and install background service (macOS launchd)
#
set -euo pipefail

cd "$(dirname "$0")"

# Node.js 22.19+ and npm run the server and install its dependencies from
# package-lock.json (the same tree CI and the published package use).
if ! command -v node &>/dev/null || ! command -v npm &>/dev/null; then
  echo "Error: Install Node.js 22.19+ (includes npm)."
  exit 1
fi

NODE_VERSION="$(node --version)"
NODE_SEMVER="${NODE_VERSION#v}"
NODE_MAJOR="${NODE_SEMVER%%.*}"
NODE_REST="${NODE_SEMVER#*.}"
NODE_MINOR="${NODE_REST%%.*}"

if [[ "$NODE_MAJOR" -lt 22 || ( "$NODE_MAJOR" -eq 22 && "$NODE_MINOR" -lt 19 ) ]]; then
  echo "Error: Node.js 22.19+ required (found $NODE_VERSION)."
  exit 1
fi
echo "Using Node.js $NODE_VERSION"

# Install + build. --ignore-scripts skips dependency install scripts (supply-chain
# hardening, also set in .npmrc); the build below runs the package's own steps.
echo "Installing dependencies..."
npm ci --ignore-scripts

# The package build also copies the bundled docs and durable package manifests;
# the server refuses to open its durable runtime without them.
echo "Building..."
npm run build

# Start
if [[ "${1:-}" == "--install" ]]; then
  echo "Linking the machine-wide oppi CLI to this source checkout..."
  npm link --ignore-scripts --no-audit --no-fund

  LINKED_CLI="$(command -v oppi || true)"
  if [[ -z "$LINKED_CLI" || "$(realpath "$LINKED_CLI")" != "$(realpath dist/src/cli.js)" ]]; then
    echo "Error: source-linked oppi CLI did not resolve to $(realpath dist/src/cli.js)."
    exit 1
  fi

  echo ""
  oppi server install
else
  echo ""
  node dist/src/cli.js serve "$@"
fi

#!/usr/bin/env bash
# Repo-root entry point. Agents often run ./scripts/sim-pool.sh from the
# checkout root; the real runner lives under clients/apple/scripts.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/clients/apple/scripts/sim-pool.sh" "$@"

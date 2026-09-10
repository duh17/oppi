#!/usr/bin/env bash
# Forwards leftover personal-skill callers to the checkout TypeScript runner.
# Does not set OPPI_SIM_POOL_COUNT=4, OPPI_SIM_POOL_KEEP_BOOTED=0,
# OPPI_SIM_POOL_FORCE_CLEAN_BOOT, or mismatch recreation.
set -euo pipefail

resolve_oppi_root() {
  if [[ -n "${OPPI_ROOT:-}" ]]; then
    printf '%s\n' "$OPPI_ROOT"
    return
  fi
  local git_root
  git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$git_root" && -d "$git_root/clients/apple" ]]; then
    printf '%s\n' "$git_root"
    return
  fi
  printf '%s\n' "${PIOS_ROOT:-$HOME/workspace/oppi}"
}

if [[ -n "${OPPI_SIM_POOL_REPO:-}" ]]; then
  runner="$OPPI_SIM_POOL_REPO"
else
  root="$(resolve_oppi_root)"
  runner="$root/clients/apple/scripts/sim-pool.sh"
  export OPPI_ROOT="$root"
fi

if [[ ! -e "$runner" ]]; then
  echo "error: sim-pool runner not found: $runner" >&2
  exit 1
fi
exec "$runner" "$@"

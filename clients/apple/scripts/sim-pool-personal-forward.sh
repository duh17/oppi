#!/usr/bin/env bash
# Staged personal-skill forwarding wrapper. NOT activated.
#
# Forwards to the repository runner with canonical warm defaults.
# Does not set OPPI_SIM_POOL_COUNT=4, OPPI_SIM_POOL_KEEP_BOOTED=0,
# OPPI_SIM_POOL_FORCE_CLEAN_BOOT, or mismatch recreation.
#
# Activation is unapproved. Do not install over the symlink target.
set -euo pipefail
if [[ -z "${OPPI_SIM_POOL_REPO:-}" ]]; then
  echo "error: set OPPI_SIM_POOL_REPO to clients/apple/scripts/sim-pool.sh in the Oppi checkout" >&2
  exit 1
fi
exec "$OPPI_SIM_POOL_REPO" "$@"

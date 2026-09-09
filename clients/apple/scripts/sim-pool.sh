#!/usr/bin/env bash
# Simulator pool entry. Implementation is sim-pool.ts (Bun).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/env bun "$SCRIPT_DIR/sim-pool.ts" "$@"

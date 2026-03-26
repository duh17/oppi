#!/usr/bin/env bash
# Simulator pool for parallel agent xcodebuild runs.
# Provides slot-based locking so multiple agents can build/test concurrently
# without simulator collisions.
#
# Usage:
#   ./sim-pool.sh run -- xcodebuild -project Oppi.xcodeproj -scheme Oppi build
#   ./sim-pool.sh run -- xcodebuild -project Oppi.xcodeproj -scheme Oppi test -only-testing:OppiTests
#
# The script auto-injects -destination and -derivedDataPath — do NOT pass your own.
# On build failure, prints a deduped error summary with the full log path.
#
# Environment:
#   OPPI_SIM_POOL_COUNT  Number of pool slots (default: 4)
#   OPPI_SIM_DEVICE_TYPE com.apple.CoreSimulator.SimDeviceType identifier (default: iPhone-16-Pro)
#   OPPI_SIM_RUNTIME     com.apple.CoreSimulator.SimRuntime identifier (auto-detected)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

POOL_COUNT="${OPPI_SIM_POOL_COUNT:-4}"
DEVICE_TYPE="${OPPI_SIM_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro}"
LOCK_DIR="/tmp/oppi-sim-pool"
BUILD_BASE="$APPLE_DIR/.build"

# ── Helpers ──

die() { echo "error: $*" >&2; exit 1; }

# Auto-detect latest iOS runtime
detect_runtime() {
  xcrun simctl list runtimes -j \
    | python3 -c "
import json, sys
runtimes = json.load(sys.stdin)['runtimes']
ios = [r for r in runtimes if r['platform'] == 'iOS' and r['isAvailable']]
if not ios:
    sys.exit(1)
print(ios[-1]['identifier'])
" 2>/dev/null || die "no available iOS runtime found"
}

# Create a pool simulator if it doesn't exist
ensure_sim() {
  local slot="$1"
  local name="Oppi-Pool-${slot}"
  local runtime="${OPPI_SIM_RUNTIME:-$(detect_runtime)}"

  # Check if it already exists
  local udid
  udid=$(xcrun simctl list devices -j \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime_devs in data['devices'].values():
    for d in runtime_devs:
        if d['name'] == '${name}' and d['isAvailable']:
            print(d['udid'])
            sys.exit(0)
sys.exit(1)
" 2>/dev/null) && { echo "$udid"; return 0; }

  # Create it
  echo "[sim-pool] Creating simulator: $name" >&2
  xcrun simctl create "$name" "$DEVICE_TYPE" "$runtime"
}

# Acquire a pool slot using mkdir-based atomic locking
acquire_slot() {
  mkdir -p "$LOCK_DIR"

  for slot in $(seq 0 $((POOL_COUNT - 1))); do
    local lock_path="$LOCK_DIR/slot-${slot}"
    # mkdir is atomic — first caller wins
    if mkdir "$lock_path" 2>/dev/null; then
      # Write our PID for stale lock detection
      echo $$ > "$lock_path/pid"
      echo "$slot"
      return 0
    fi

    # Check for stale lock (owner PID no longer running)
    if [[ -f "$lock_path/pid" ]]; then
      local owner_pid
      owner_pid=$(cat "$lock_path/pid" 2>/dev/null || echo "")
      if [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
        echo "[sim-pool] Reaping stale lock for slot $slot (PID $owner_pid dead)" >&2
        rm -rf "$lock_path"
        if mkdir "$lock_path" 2>/dev/null; then
          echo $$ > "$lock_path/pid"
          echo "$slot"
          return 0
        fi
      fi
    fi
  done

  die "all $POOL_COUNT simulator slots are busy"
}

release_slot() {
  local slot="$1"
  rm -rf "$LOCK_DIR/slot-${slot}"
}

# Print deduped build error summary
print_error_summary() {
  local log_file="$1"
  echo ""
  echo "========== BUILD FAILED =========="
  echo ""

  # Extract and deduplicate compiler/linker errors
  local errors
  errors=$(grep -E '^\S+:\d+:\d+: error:|^error:|ld: |clang: error:' "$log_file" 2>/dev/null | sort -u || true)

  if [[ -n "$errors" ]]; then
    local count
    count=$(echo "$errors" | wc -l | tr -d ' ')
    echo "Unique errors ($count):"
    echo "$errors"
  else
    echo "(no compiler/linker errors extracted — check full log)"
  fi

  echo ""
  echo "Full log: $log_file"
  echo "=================================="
}

# ── Main ──

usage() {
  cat <<'EOF'
Usage: sim-pool.sh run -- <xcodebuild args...>

Acquires a simulator pool slot, injects -destination and -derivedDataPath,
runs xcodebuild, and releases the slot on exit.

Do NOT pass -destination or -derivedDataPath — they are auto-injected.
EOF
  exit 1
}

[[ "${1:-}" == "run" ]] || usage
shift
[[ "${1:-}" == "--" ]] || usage
shift
[[ $# -gt 0 ]] || usage

# Reject manually passed -destination or -derivedDataPath
for arg in "$@"; do
  case "$arg" in
    -destination|-derivedDataPath)
      die "do not pass $arg — sim-pool.sh auto-injects it"
      ;;
  esac
done

# Acquire slot
SLOT=$(acquire_slot)
trap 'release_slot "$SLOT"' EXIT

echo "[sim-pool] Acquired slot $SLOT" >&2

# Ensure simulator exists
SIM_UDID=$(ensure_sim "$SLOT")
DERIVED_DATA="$BUILD_BASE/pool-${SLOT}"
mkdir -p "$DERIVED_DATA"

echo "[sim-pool] Simulator: Oppi-Pool-${SLOT} ($SIM_UDID)" >&2
echo "[sim-pool] DerivedData: $DERIVED_DATA" >&2

# Build log
LOG_DIR="$BUILD_BASE/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/pool-${SLOT}-$(date +%Y%m%d-%H%M%S).log"

# Run xcodebuild with injected destination and derived data path
set +e
"$@" \
  -destination "platform=iOS Simulator,id=$SIM_UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  2>&1 | tee "$LOG_FILE"
EXIT_CODE=${PIPESTATUS[0]}
set -e

if [[ $EXIT_CODE -ne 0 ]]; then
  print_error_summary "$LOG_FILE"
  exit $EXIT_CODE
fi

exit 0

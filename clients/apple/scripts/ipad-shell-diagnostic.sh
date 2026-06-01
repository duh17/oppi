#!/usr/bin/env bash
# Create/use a dedicated iPad simulator pool slot and run iPad shell diagnostics.
#
# This wrapper keeps using the shared oppi-dev sim-pool/e2e lanes, but reserves
# lower simulator-pool slots so sim-pool lands on a dedicated iPad slot instead
# of the default iPhone pool.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APPLE_DIR/../.." && pwd)"
SIM_POOL="${OPPI_SIM_POOL:-$HOME/.pi/agent/skills/oppi-dev/scripts/sim-pool.sh}"
OPPI_WORKFLOW="${OPPI_WORKFLOW:-$HOME/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh}"
LOCK_DIR="${OPPI_SIM_POOL_LOCK_DIR:-/tmp/oppi-sim-pool}"
IPAD_SLOT="${OPPI_IPAD_SIM_SLOT:-8}"
IPAD_SIM_NAME="Oppi-Pool-${IPAD_SLOT}"
ONLY_TESTING="${OPPI_IPAD_SHELL_ONLY_TESTING:-OppiE2ETests/IPadAdaptiveShellScreenshotE2ETests/testIPadMainAndChatTimelineScreenshots}"
RESERVED_LOCKS=()

usage() {
  cat <<'EOF'
Usage: ipad-shell-diagnostic.sh <command>

Commands:
  ensure      Create and boot the dedicated iPad simulator pool slot.
  build       Build Oppi on the dedicated iPad simulator via sim-pool.
  test-shell  Run the iPad adaptive shell E2E screenshot test via oppi-workflow sim-test.
  all         Run build, then test-shell.

Environment:
  OPPI_IPAD_SIM_SLOT       Dedicated sim-pool slot to use (default: 8)
  OPPI_IPAD_DEVICE_TYPE    Explicit iPad SimDeviceType identifier
  OPPI_SIM_RUNTIME         Explicit iOS SimRuntime identifier
  E2E_OMLX_URL             Model endpoint for test-shell (default: http://localhost:8400)

Artifacts from test-shell:
  /tmp/oppi-screenshots/ipad-main-workspace-home.png
  /tmp/oppi-screenshots/ipad-chat-timeline.png
  /tmp/oppi-screenshots/ipad-file-browser.png
  /tmp/oppi-screenshots/ipad-settings-detail.png
  /tmp/oppi-screenshots/ipad-server-detail.png
EOF
}

die() { echo "error: $*" >&2; exit 1; }

cleanup_reserved_locks() {
  local path pid
  for path in "${RESERVED_LOCKS[@]:-}"; do
    [[ -d "$path" ]] || continue
    pid="$(cat "$path/pid" 2>/dev/null || true)"
    if [[ "$pid" == "$$" ]]; then
      rm -rf "$path"
    fi
  done
}
trap cleanup_reserved_locks EXIT

require_exec() {
  local path="$1"
  [[ -x "$path" ]] || die "missing executable: $path"
}

detect_runtime() {
  xcrun simctl list runtimes -j | python3 -c '
import json, sys
runtimes = json.load(sys.stdin).get("runtimes", [])
ios = [r for r in runtimes if r.get("platform") == "iOS" and r.get("isAvailable")]
if not ios:
    raise SystemExit("no available iOS runtime found")
print(ios[-1]["identifier"])
'
}

resolve_ipad_device_type() {
  if [[ -n "${OPPI_IPAD_DEVICE_TYPE:-}" ]]; then
    printf '%s\n' "$OPPI_IPAD_DEVICE_TYPE"
    return 0
  fi

  xcrun simctl list devicetypes -j | python3 -c '
import json, sys
preferred = [
    "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB",
    "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB",
    "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M4",
    "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3",
    "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M2",
    "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-12-9-inch-6th-generation-8GB",
    "com.apple.CoreSimulator.SimDeviceType.iPad-10th-generation",
]
data = json.load(sys.stdin).get("devicetypes", [])
available = {d.get("identifier"): d for d in data if "iPad" in d.get("name", "")}
for identifier in preferred:
    if identifier in available:
        print(identifier)
        raise SystemExit(0)
for identifier in available:
    print(identifier)
    raise SystemExit(0)
raise SystemExit("no available iPad simulator device type found")
'
}

sim_info_json() {
  xcrun simctl list devices -j | python3 -c '
import json, sys
name = sys.argv[1]
data = json.load(sys.stdin)
for devices in data.get("devices", {}).values():
    for device in devices:
        if device.get("name") == name and device.get("isAvailable"):
            print(json.dumps(device))
            raise SystemExit(0)
raise SystemExit(1)
' "$IPAD_SIM_NAME"
}

ensure_ipad_simulator() {
  local desired_type="$1"
  local runtime="${OPPI_SIM_RUNTIME:-$(detect_runtime)}"
  local info udid existing_type

  if info="$(sim_info_json 2>/dev/null)"; then
    udid="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["udid"])' "$info")"
    existing_type="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("deviceTypeIdentifier", ""))' "$info")"
    if [[ "$existing_type" != com.apple.CoreSimulator.SimDeviceType.iPad* ]]; then
      die "$IPAD_SIM_NAME exists but is not an iPad ($existing_type). Set OPPI_IPAD_SIM_SLOT to a free slot or delete that simulator."
    fi
  else
    echo "[ipad-shell] Creating simulator: $IPAD_SIM_NAME ($desired_type)" >&2
    udid="$(xcrun simctl create "$IPAD_SIM_NAME" "$desired_type" "$runtime")"
  fi

  echo "$udid"
}

boot_ipad_simulator() {
  local udid="$1"
  echo "[ipad-shell] Simulator: $IPAD_SIM_NAME ($udid)" >&2
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b
  open -a Simulator --args -CurrentDeviceUDID "$udid" >/dev/null 2>&1 || true
}

reserve_lower_pool_slots() {
  mkdir -p "$LOCK_DIR"
  local slot path pid
  if (( IPAD_SLOT <= 0 )); then
    return 0
  fi
  for slot in $(seq 0 $((IPAD_SLOT - 1))); do
    path="$LOCK_DIR/slot-${slot}"
    if mkdir "$path" 2>/dev/null; then
      echo $$ > "$path/pid"
      RESERVED_LOCKS+=("$path")
      continue
    fi

    pid="$(cat "$path/pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      rm -rf "$path"
      if mkdir "$path" 2>/dev/null; then
        echo $$ > "$path/pid"
        RESERVED_LOCKS+=("$path")
      fi
    fi
  done
}

with_ipad_pool_env() {
  local device_type="$1"
  shift
  reserve_lower_pool_slots
  OPPI_SIM_POOL_COUNT="$((IPAD_SLOT + 1))" \
  OPPI_SIM_DEVICE_TYPE="$device_type" \
    "$@"
}

run_build() {
  local device_type="$1"
  ensure_ipad_simulator "$device_type" >/dev/null
  cd "$APPLE_DIR"
  with_ipad_pool_env "$device_type" "$SIM_POOL" run -- \
    xcodebuild -project Oppi.xcodeproj -scheme Oppi build
}

run_shell_test() {
  local device_type="$1"
  ensure_ipad_simulator "$device_type" >/dev/null
  with_ipad_pool_env "$device_type" "$OPPI_WORKFLOW" sim-test --native --only-testing "$ONLY_TESTING"

  echo "[ipad-shell] Expected screenshots:" >&2
  echo "  /tmp/oppi-screenshots/ipad-main-workspace-home.png" >&2
  echo "  /tmp/oppi-screenshots/ipad-chat-timeline.png" >&2
  echo "  /tmp/oppi-screenshots/ipad-file-browser.png" >&2
  echo "  /tmp/oppi-screenshots/ipad-settings-detail.png" >&2
  echo "  /tmp/oppi-screenshots/ipad-server-detail.png" >&2
}

main() {
  local command="${1:-test-shell}"
  if [[ "$command" == "-h" || "$command" == "--help" || "$command" == "help" ]]; then
    usage
    exit 0
  fi
  shift || true
  [[ $# -eq 0 ]] || die "unexpected arguments: $*"
  [[ "$IPAD_SLOT" =~ ^[0-9]+$ ]] || die "OPPI_IPAD_SIM_SLOT must be a number"
  require_exec "$SIM_POOL"
  require_exec "$OPPI_WORKFLOW"

  local device_type udid
  device_type="$(resolve_ipad_device_type)"

  case "$command" in
    ensure)
      udid="$(ensure_ipad_simulator "$device_type")"
      boot_ipad_simulator "$udid"
      ;;
    build)
      run_build "$device_type"
      ;;
    test-shell)
      run_shell_test "$device_type"
      ;;
    all)
      run_build "$device_type"
      cleanup_reserved_locks
      RESERVED_LOCKS=()
      run_shell_test "$device_type"
      ;;
    *)
      usage >&2
      die "unknown command: $command"
      ;;
  esac
}

main "$@"

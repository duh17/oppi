#!/usr/bin/env bash
# Shared iOS Simulator daemon slimming. Source this file; do not execute it.
#
# Source from sim-pool, ci-simulator, or sim-lab, or run: sim-slim.sh apply <udid>
#
# Requires: die (defined here when executed as apply)
# Optional: wait_for_boot_ready_with_retries — used after the slim reboot when present.
#
# Environment:
#   OPPI_SIM_SLIM        Set 0 to leave simulators stock (default: 1)
#   OPPI_SIM_POOL_SLIM   Compatibility alias used when OPPI_SIM_SLIM is unset

_SIM_SLIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIM_SLIM_LABELS_FILE="${SIM_SLIM_LABELS_FILE:-$_SIM_SLIM_DIR/sim-pool-slim-labels.txt}"

sim_slim_enabled() {
  [[ "${OPPI_SIM_SLIM:-${OPPI_SIM_POOL_SLIM:-1}}" == "1" ]]
}

sim_is_slim() {
  local udid="$1"
  local disabled
  disabled=$(xcrun simctl spawn "$udid" launchctl print-disabled system 2>/dev/null || true)
  # PosterBoard is the original marker. routined was added later; require
  # both so already-slim pool sims pick up the Watch/MDM label pass.
  grep -Eq '"com.apple.PosterBoard" => (disabled|true)' <<<"$disabled" \
    && grep -Eq '"com.apple.routined" => (disabled|true)' <<<"$disabled"
}

slim_disable_labels() {
  local udid="$1"
  local label
  local -a pids=()
  local labels_file="${SIM_SLIM_LABELS_FILE:-$_SIM_SLIM_DIR/sim-pool-slim-labels.txt}"

  [[ -f "$labels_file" ]] || die "missing slim label list: $labels_file"

  while IFS= read -r label || [[ -n "$label" ]]; do
    [[ -z "$label" || "$label" == \#* ]] && continue
    xcrun simctl spawn "$udid" launchctl disable "system/$label" >/dev/null 2>&1 &
    pids+=($!)
    if (( ${#pids[@]} >= 8 )); then
      wait "${pids[@]}" || true
      pids=()
    fi
  done < "$labels_file"
  if (( ${#pids[@]} > 0 )); then
    wait "${pids[@]}" || true
  fi
}

slim_wait_for_boot() {
  local udid="$1"
  if declare -F wait_for_boot_ready_with_retries >/dev/null; then
    wait_for_boot_ready_with_retries "$udid"
    return $?
  fi
  local timeout="${OPPI_SIM_POOL_BOOT_TIMEOUT:-120}"
  local retries="${OPPI_SIM_POOL_BOOT_RETRIES:-1}"
  local attempt=0 status=0
  while :; do
    python3 - "$udid" "$timeout" <<'PY'
import subprocess, sys
udid = sys.argv[1]
timeout = int(sys.argv[2])
try:
    subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True, timeout=timeout)
except subprocess.TimeoutExpired:
    sys.exit(124)
except subprocess.CalledProcessError as exc:
    sys.exit(exc.returncode)
PY
    status=$?
    if [[ "$status" -eq 0 ]]; then
      return 0
    fi
    if (( attempt >= retries )); then
      return "$status"
    fi
    attempt=$((attempt + 1))
  done
}

slim_simulator() {
  local udid="$1"

  sim_slim_enabled || return 0
  if sim_is_slim "$udid"; then
    echo "[sim-slim] Simulator $udid already slim" >&2
    return 0
  fi

  echo "[sim-slim] Slimming unused simulator daemons on $udid" >&2
  slim_disable_labels "$udid"
  echo "[sim-slim] Rebooting $udid to apply slim overrides" >&2
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  if ! slim_wait_for_boot "$udid"; then
    die "simulator $udid failed to reach boot-ready state after slimming"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "${1:-}" == "apply" ]]; then
    if ! declare -F die >/dev/null; then
      die() { echo "error: $*" >&2; exit 1; }
    fi
    udid="${2:-}"
    [[ -n "$udid" ]] || die "usage: sim-slim.sh apply <udid>"
    slim_simulator "$udid"
    exit 0
  fi
  echo "error: source sim-slim.sh from sim-pool, ci-simulator, or sim-lab, or run: sim-slim.sh apply <udid>" >&2
  exit 1
fi

#!/usr/bin/env bash
# Simulator pool for parallel agent xcodebuild runs.
# Provides slot-based locking so multiple agents can build/test concurrently
# without simulator collisions.
#
# Usage:
#   ./sim-pool.sh run -- xcodebuild -project Oppi.xcodeproj -scheme Oppi build
#   ./sim-pool.sh run -- xcodebuild -project Oppi.xcodeproj -scheme OppiUnitTests test -only-testing:OppiTests
#
# The script auto-injects -destination and -derivedDataPath — do NOT pass your own.
# On build failure, prints a deduped error summary with the full log path.
#
# Guardrail:
#   Unit tests must use the OppiUnitTests scheme. The full Oppi scheme also
#   builds UI/E2E/perf bundles, which looks like a hung unit-test run.
#
# Environment:
#   OPPI_SIM_POOL_COUNT              Number of pool slots to consider (default: 4)
#   OPPI_SIM_POOL_SLOT_START         First pool slot index to consider (default: 0; OPPI_SIM_POOL_SLOT_OFFSET alias)
#   OPPI_SIM_DEVICE_TYPE             com.apple.CoreSimulator.SimDeviceType identifier (default: iPhone-16-Pro)
#   OPPI_SIM_RUNTIME                 com.apple.CoreSimulator.SimRuntime identifier (auto-detected)
#   OPPI_SIM_POOL_WAIT               Max seconds to wait for a free slot (default: 60)
#   OPPI_SIM_POOL_BOOT_TIMEOUT       Max seconds to wait for simulator boot readiness (default: 120)
#   OPPI_SIM_POOL_SILENCE_TIMEOUT    Max seconds with no log growth before declaring a hang (default: 180)
#   OPPI_SIM_POOL_HEARTBEAT_INTERVAL Seconds between progress heartbeats (default: 60)
#   OPPI_SIM_POOL_HANG_RETRIES       Retry count after a silent hang with simulator reset (default: 1)
#   OPPI_SIM_POOL_KEEP_BOOTED        Keep pool simulator booted after run (default: 0)
#   OPPI_SIM_POOL_LOCK_DIR           Lock directory (default: /tmp/oppi-sim-pool)
#   OPPI_SIM_POOL_VIDEO_POLICY       Simulator video policy: off, on-failure, or always (default: off)
#   OPPI_SIM_POOL_RECORD_VIDEO       Legacy alias: 1/true means always, 0/false means off
#   OPPI_SIM_POOL_VIDEO_READY_TIMEOUT Seconds to wait for recordVideo readiness (default: 10)
#
# Retry behavior:
#   When xcodebuild receives -resultBundlePath, each retry writes to a distinct
#   sibling path (for example, Result-retry1.xcresult). xcodebuild refuses to
#   overwrite an existing result bundle, including a partial bundle left by a
#   killed hung attempt.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Detect repo root from CWD (supports git worktrees) or fall back to env/default.
# This is critical for autoresearch sessions running in worktrees —
# without it, DerivedData from different worktrees would collide.
if [[ -z "${OPPI_ROOT:-}" ]]; then
  _git_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -n "$_git_root" && -d "$_git_root/clients/apple" ]]; then
    OPPI_ROOT="$_git_root"
  else
    OPPI_ROOT="${PIOS_ROOT:-$HOME/workspace/oppi}"
  fi
fi
APPLE_DIR="$OPPI_ROOT/clients/apple"

POOL_COUNT="${OPPI_SIM_POOL_COUNT:-4}"
POOL_SLOT_START="${OPPI_SIM_POOL_SLOT_START:-${OPPI_SIM_POOL_SLOT_OFFSET:-0}}"
DEVICE_TYPE="${OPPI_SIM_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro}"
LOCK_DIR="${OPPI_SIM_POOL_LOCK_DIR:-/tmp/oppi-sim-pool}"
BUILD_BASE="$APPLE_DIR/.build"
BOOT_TIMEOUT="${OPPI_SIM_POOL_BOOT_TIMEOUT:-120}"
SILENCE_TIMEOUT="${OPPI_SIM_POOL_SILENCE_TIMEOUT:-180}"
HEARTBEAT_INTERVAL="${OPPI_SIM_POOL_HEARTBEAT_INTERVAL:-60}"
HANG_RETRIES="${OPPI_SIM_POOL_HANG_RETRIES:-1}"

# ── Helpers ──

die() { echo "error: $*" >&2; exit 1; }

validate_pool_config() {
  case "$POOL_COUNT" in
    ''|*[!0-9]*) die "invalid OPPI_SIM_POOL_COUNT '$POOL_COUNT' (expected positive integer)" ;;
  esac
  (( POOL_COUNT > 0 )) || die "invalid OPPI_SIM_POOL_COUNT '$POOL_COUNT' (expected positive integer)"

  case "$POOL_SLOT_START" in
    ''|*[!0-9]*) die "invalid OPPI_SIM_POOL_SLOT_START '$POOL_SLOT_START' (expected non-negative integer)" ;;
  esac
}

pool_slot_end() {
  echo $((POOL_SLOT_START + POOL_COUNT - 1))
}

pool_slot_range() {
  local end
  end="$(pool_slot_end)"
  if [[ "$POOL_SLOT_START" == "$end" ]]; then
    echo "$POOL_SLOT_START"
  else
    echo "${POOL_SLOT_START}-${end}"
  fi
}

now_epoch() {
  date +%s
}

iso8601_utc() {
  local epoch="$1"
  date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ'
}

file_mtime() {
  local path="$1"
  stat -f %m "$path" 2>/dev/null || echo 0
}

file_size_bytes() {
  local path="$1"
  stat -f %z "$path" 2>/dev/null || echo 0
}

normalize_video_policy() {
  local raw="${1:-off}"
  case "$raw" in
    1|true|TRUE|yes|YES|always)
      echo "always"
      ;;
    on-failure|on_failure|failure|fail|failed)
      echo "on-failure"
      ;;
    0|false|FALSE|no|NO|off|"")
      echo "off"
      ;;
    *)
      die "invalid simulator video policy '$raw' (expected off, on-failure, or always)"
      ;;
  esac
}

extract_flag_value() {
  local flag="$1"
  shift

  local previous=""
  for arg in "$@"; do
    if [[ "$previous" == "$flag" ]]; then
      printf '%s\n' "$arg"
      return 0
    fi
    previous="$arg"
  done

  return 1
}

result_bundle_path_for_attempt() {
  local path="$1"
  local attempt_index="$2"

  if (( attempt_index == 0 )); then
    printf '%s\n' "$path"
  elif [[ "$path" == *.xcresult ]]; then
    printf '%s-retry%d.xcresult\n' "${path%.xcresult}" "$attempt_index"
  else
    printf '%s-retry%d\n' "$path" "$attempt_index"
  fi
}

ATTEMPT_COMMAND=()
build_attempt_command() {
  local attempt_index="$1"
  shift

  ATTEMPT_COMMAND=()
  while (( $# > 0 )); do
    local arg="$1"
    shift

    if [[ "$arg" == "-resultBundlePath" ]]; then
      (( $# > 0 )) || die "-resultBundlePath requires a path"
      local original_path="$1"
      shift
      local attempt_path
      attempt_path="$(result_bundle_path_for_attempt "$original_path" "$attempt_index")"
      ATTEMPT_COMMAND+=("-resultBundlePath" "$attempt_path")
    elif [[ "$arg" == -resultBundlePath=* ]]; then
      local original_path="${arg#-resultBundlePath=}"
      local attempt_path
      attempt_path="$(result_bundle_path_for_attempt "$original_path" "$attempt_index")"
      ATTEMPT_COMMAND+=("-resultBundlePath=$attempt_path")
    else
      ATTEMPT_COMMAND+=("$arg")
    fi
  done
}

run_self_test() {
  local expected

  expected="/tmp/OppiTests.xcresult"
  [[ "$(result_bundle_path_for_attempt "$expected" 0)" == "$expected" ]] \
    || die "self-test: first attempt changed result bundle path"
  [[ "$(result_bundle_path_for_attempt "$expected" 1)" == "/tmp/OppiTests-retry1.xcresult" ]] \
    || die "self-test: retry result bundle path did not get a unique suffix"
  [[ "$(result_bundle_path_for_attempt "/tmp/result" 2)" == "/tmp/result-retry2" ]] \
    || die "self-test: extensionless retry result bundle path is incorrect"

  build_attempt_command 1 xcodebuild test -resultBundlePath "$expected" -scheme OppiUnitTests
  [[ "${ATTEMPT_COMMAND[0]}" == "xcodebuild" ]]
  [[ "${ATTEMPT_COMMAND[2]}" == "-resultBundlePath" ]]
  [[ "${ATTEMPT_COMMAND[3]}" == "/tmp/OppiTests-retry1.xcresult" ]]
  [[ "${ATTEMPT_COMMAND[5]}" == "OppiUnitTests" ]]

  build_attempt_command 2 xcodebuild test "-resultBundlePath=$expected"
  [[ "${ATTEMPT_COMMAND[2]}" == "-resultBundlePath=/tmp/OppiTests-retry2.xcresult" ]]

  echo "sim-pool retry result-bundle self-test passed."
}

has_only_testing_target() {
  local bundle="$1"
  shift

  for arg in "$@"; do
    case "$arg" in
      "-only-testing:${bundle}"|"-only-testing:${bundle}/"*)
        return 0
        ;;
    esac
  done

  return 1
}

validate_command_guardrails() {
  local scheme=""
  local is_test_action=0

  scheme=$(extract_flag_value "-scheme" "$@" 2>/dev/null || true)

  for arg in "$@"; do
    case "$arg" in
      test|build-for-testing|test-without-building)
        is_test_action=1
        ;;
    esac
  done

  if [[ "${OPPI_SIM_POOL_ALLOW_SLOW_UNIT_TEST_SCHEME:-}" != "1" ]] \
    && [[ "$is_test_action" -eq 1 ]] \
    && [[ "$scheme" == "Oppi" ]] \
    && has_only_testing_target "OppiTests" "$@"; then
    die "slow unit-test invocation detected: '-scheme Oppi' still builds OppiPerfTests/OppiUITests/OppiE2ETests. Use '-scheme OppiUnitTests' for OppiTests (override with OPPI_SIM_POOL_ALLOW_SLOW_UNIT_TEST_SCHEME=1)."
  fi
}

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

wait_for_boot_ready() {
  local udid="$1"

  python3 - "$udid" "$BOOT_TIMEOUT" <<'PY'
import subprocess
import sys

udid = sys.argv[1]
timeout = int(sys.argv[2])
try:
    subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True, timeout=timeout)
except subprocess.TimeoutExpired:
    sys.exit(124)
except subprocess.CalledProcessError as exc:
    sys.exit(exc.returncode)
PY
}

prepare_simulator() {
  local udid="$1"
  local mode="${2:-normal}"

  if [[ "$mode" == "recovery" ]]; then
    echo "[sim-pool] Recovery: shutting down + erasing simulator $udid" >&2
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    xcrun simctl erase "$udid" >/dev/null 2>&1 || true
  else
    echo "[sim-pool] Preparing clean simulator boot for $udid" >&2
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  fi

  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  if ! wait_for_boot_ready "$udid"; then
    die "simulator $udid failed to reach boot-ready state within ${BOOT_TIMEOUT}s"
  fi
}

kill_process_tree() {
  local root_pid="$1"
  local children

  children=$(pgrep -P "$root_pid" 2>/dev/null || true)
  if [[ -n "$children" ]]; then
    while IFS= read -r child_pid; do
      [[ -n "$child_pid" ]] || continue
      kill_process_tree "$child_pid"
    done <<<"$children"
  fi

  kill -TERM "$root_pid" 2>/dev/null || true
}

# Try to acquire a slot (single pass, no waiting)
try_acquire_slot() {
  mkdir -p "$LOCK_DIR"

  local slot_end
  slot_end="$(pool_slot_end)"

  for slot in $(seq "$POOL_SLOT_START" "$slot_end"); do
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

  return 1
}

# Acquire a pool slot, retrying with backoff if all slots are busy.
# Set OPPI_SIM_POOL_WAIT=N to wait up to N seconds (default: 60).
acquire_slot() {
  local wait_max="${OPPI_SIM_POOL_WAIT:-60}"
  local waited=0
  local interval=3

  local slot slot_range
  slot_range="$(pool_slot_range)"
  slot=$(try_acquire_slot) && { echo "$slot"; return 0; }

  echo "[sim-pool] All $POOL_COUNT slots (slots ${slot_range}) busy, waiting up to ${wait_max}s..." >&2
  while (( waited < wait_max )); do
    sleep "$interval"
    waited=$((waited + interval))
    slot=$(try_acquire_slot) && { echo "$slot"; return 0; }
  done

  die "all $POOL_COUNT simulator slots (slots ${slot_range}) are busy (waited ${waited}s)"
}

release_slot() {
  local slot="$1"
  rm -rf "$LOCK_DIR/slot-${slot}"
}

cleanup_run() {
  stop_video_recording
  if [[ -n "${SIM_UDID:-}" && "${OPPI_SIM_POOL_KEEP_BOOTED:-0}" != "1" ]]; then
    echo "[sim-pool] Shutting down pool simulator $SIM_UDID" >&2
    xcrun simctl shutdown "$SIM_UDID" >/dev/null 2>&1 || true
  fi
  release_slot "$SLOT"
}

run_periodic_maintenance() {
  local stamp_dir="/tmp/oppi-sim-pool-maintenance"
  local stamp_file="$stamp_dir/daily-$(date +%Y%m%d)"

  mkdir -p "$stamp_dir"
  if [[ -f "$stamp_file" ]]; then
    return 0
  fi

  : > "$stamp_file"
  echo "[sim-pool] Maintenance: pruning unavailable simulators + old test artifacts" >&2
  xcrun simctl delete unavailable >/dev/null 2>&1 || true
  find "$BUILD_BASE" -name "*.xcresult" -mtime +3 -exec rm -rf {} + 2>/dev/null || true
  find "$BUILD_BASE" -path "*/Logs/Test/*" -mtime +3 -exec rm -rf {} + 2>/dev/null || true
}

# Extract test failure details from xcresult bundle or log
extract_test_failures() {
  local log_file="$1"
  local derived_data="$2"

  # Try xcresult bundle first (richer data)
  local xcresult
  xcresult=$(find "$derived_data/Logs/Test" -name "*.xcresult" -maxdepth 1 2>/dev/null | sort -r | head -1)
  if [[ -n "$xcresult" ]]; then
    local failures
    failures=$(xcrun xcresulttool get test-results failures --path "$xcresult" 2>/dev/null || true)
    if [[ -n "$failures" && "$failures" != "[]" && "$failures" != *"No failures"* ]]; then
      echo "$failures"
      return 0
    fi
  fi

  # Fall back to log parsing
  grep -E 'failed\b.*-\[|Test Case .* failed|error:.*assert|#expect.* failed|Issue recorded|Expectation failed' "$log_file" 2>/dev/null | sort -u || true
}

# Print concise build/test summary
print_summary() {
  local log_file="$1"
  local exit_code="$2"
  local derived_data="$3"
  local started_at="$4"
  local ended_at="$5"
  local attempt_count="$6"
  local hang_detected="$7"
  local total_started_at="${8:-$started_at}"
  local total_ended_at="${9:-$ended_at}"
  local slot_wait_seconds="${10:-0}"
  local simulator_prepare_seconds="${11:-0}"

  local duration=$((ended_at - started_at))
  local total_duration=$((total_ended_at - total_started_at))
  local last_log_update_age=$((ended_at - $(file_mtime "$log_file")))
  local log_size
  log_size=$(file_size_bytes "$log_file")

  echo ""
  echo "Started: $(date -r "$total_started_at" '+%Y-%m-%d %H:%M:%S')"
  echo "Ended:   $(date -r "$total_ended_at" '+%Y-%m-%d %H:%M:%S')"
  if (( total_duration != duration )); then
    echo "Total elapsed: ${total_duration}s"
    echo "xcodebuild elapsed: ${duration}s"
    echo "Breakdown: slot wait ${slot_wait_seconds}s + simulator prep ${simulator_prepare_seconds}s + xcodebuild ${duration}s"
  else
    echo "Elapsed: ${duration}s"
  fi
  echo "Attempts: $attempt_count"
  echo "Log size: ${log_size} bytes"
  echo "Last log update age: ${last_log_update_age}s"

  if [[ "$hang_detected" == "1" ]]; then
    echo "Hang detection: triggered (no log growth for ${SILENCE_TIMEOUT}s)"
  fi

  echo ""
  if [[ $exit_code -eq 0 ]]; then
    echo "========== BUILD SUCCEEDED =========="
    # Show test counts if this was a test run.
    # Swift Testing uses "Test run with N tests ... passed/failed" format.
    # XCTest uses "Executed N tests" but reports 0 when Swift Testing handles them.
    # Prefer Swift Testing output; fall back to XCTest only if non-zero.
    local test_summary
    test_summary=$(grep -E '^\*\* TEST SUCCEEDED \*\*|Test run with [0-9]+ test|Suite .* passed after' "$log_file" 2>/dev/null | tail -5 || true)
    if [[ -z "$test_summary" ]]; then
      # Fall back to XCTest output, but skip "Executed 0 tests" lines
      test_summary=$(grep -E 'Executed [1-9][0-9]* test' "$log_file" 2>/dev/null | tail -5 || true)
    fi
    if [[ -n "$test_summary" ]]; then
      echo ""
      echo "$test_summary"
    fi
  else
    echo "========== BUILD FAILED =========="
    echo ""

    # Compiler/linker errors (deduped)
    local errors
    errors=$(grep -E '^\S+:\d+:\d+: error:|^error:|ld: |clang: error:' "$log_file" 2>/dev/null | sort -u || true)
    if [[ -n "$errors" ]]; then
      local count
      count=$(echo "$errors" | wc -l | tr -d ' ')
      echo "Compiler/linker errors ($count):"
      echo "$errors"
      echo ""
    fi

    # Test failures
    local test_failures
    test_failures=$(extract_test_failures "$log_file" "$derived_data")
    if [[ -n "$test_failures" ]]; then
      echo "Test failures:"
      echo "$test_failures"
      echo ""
    fi

    if [[ "$hang_detected" == "1" ]]; then
      echo "Likely simulator/test-launch hang: xcodebuild stopped producing log output before completion."
      echo ""
    fi

    # If neither found, hint at the log
    if [[ -z "$errors" && -z "$test_failures" && "$hang_detected" != "1" ]]; then
      echo "(no specific errors extracted — check full log)"
      echo ""
    fi
  fi

  echo "Full log: $log_file"
  if [[ -n "${FINAL_ARTIFACT_PATH:-}" ]]; then
    echo "Artifact: $FINAL_ARTIFACT_PATH"
  fi
  if [[ -n "${VIDEO_PATH:-}" && -f "$VIDEO_PATH" ]]; then
    echo "Video: $VIDEO_PATH"
  fi
  echo "======================================"
}

write_json_artifact() {
  local artifact_path="$1"
  local scope="$2"
  local started_at="$3"
  local ended_at="$4"
  local attempt_number="$5"
  local attempt_count="$6"
  local hang_detected="$7"
  local log_file="$8"
  local exit_code="$9"

  local elapsed_seconds=$((ended_at - started_at))
  local last_log_update_age=$((ended_at - $(file_mtime "$log_file")))

  python3 - "$artifact_path" "$scope" \
    "$(iso8601_utc "$started_at")" "$(iso8601_utc "$ended_at")" \
    "$started_at" "$ended_at" "$elapsed_seconds" \
    "$attempt_number" "$attempt_count" "$hang_detected" \
    "$SLOT" "$SIM_UDID" "$DERIVED_DATA" "$log_file" \
    "$last_log_update_age" "$exit_code" <<'PY'
import json
import os
import sys

(
    artifact_path,
    scope,
    started_at,
    ended_at,
    started_at_epoch,
    ended_at_epoch,
    elapsed_seconds,
    attempt_number,
    attempt_count,
    hang_detected,
    simulator_slot,
    simulator_udid,
    derived_data_path,
    log_path,
    last_log_update_age_seconds,
    exit_code,
) = sys.argv[1:]

payload = {
    "scope": scope,
    "started_at": started_at,
    "ended_at": ended_at,
    "started_at_epoch": int(started_at_epoch),
    "ended_at_epoch": int(ended_at_epoch),
    "elapsed_seconds": int(elapsed_seconds),
    "attempt_number": int(attempt_number),
    "attempt_count": int(attempt_count),
    "hang_detected": hang_detected == "1",
    "simulator_slot": int(simulator_slot),
    "simulator_udid": simulator_udid,
    "derived_data_path": derived_data_path,
    "log_path": log_path,
    "last_log_update_age_seconds": int(last_log_update_age_seconds),
    "exit_code": int(exit_code),
}

attempt_artifacts_json = os.environ.get("SIM_POOL_ATTEMPT_ARTIFACTS_JSON", "")
if scope == "final" and attempt_artifacts_json:
    payload["attempt_artifacts"] = json.loads(attempt_artifacts_json)

if scope == "final":
    def parse_int_env(name: str):
        value = os.environ.get(name)
        if value in (None, ""):
            return None
        try:
            return int(value)
        except ValueError:
            return None

    video_policy = os.environ.get("SIM_POOL_VIDEO_POLICY", "off")
    video_path = os.environ.get("SIM_POOL_VIDEO_PATH", "")
    video_retained = os.environ.get("SIM_POOL_VIDEO_RETAINED", "0") == "1"
    if video_retained and video_path:
        payload["video_path"] = video_path
    if video_policy != "off":
        video = {
            "policy": video_policy,
            "path": video_path or None,
            "retained": video_retained,
            "ready": os.environ.get("SIM_POOL_VIDEO_READY", "0") == "1",
        }
        for env_name, out_key in [
            ("SIM_POOL_VIDEO_LOG_PATH", "log_path"),
            ("SIM_POOL_VIDEO_DELETED_REASON", "deleted_reason"),
        ]:
            value = os.environ.get(env_name)
            if value:
                video[out_key] = value
        for env_name, out_key in [
            ("SIM_POOL_VIDEO_READY_AT_EPOCH", "ready_at_epoch"),
            ("SIM_POOL_VIDEO_STOP_STATUS", "stop_status"),
            ("SIM_POOL_VIDEO_SIZE_BYTES", "size_bytes"),
        ]:
            parsed = parse_int_env(env_name)
            if parsed is not None:
                video[out_key] = parsed
        payload["video_recording"] = video

    timing_breakdown = {}
    for env_name, out_key in [
        ("SIM_POOL_SLOT_WAIT_SECONDS", "slot_wait"),
        ("SIM_POOL_SIM_PREP_SECONDS", "simulator_prepare"),
        ("SIM_POOL_XCODEBUILD_SECONDS", "xcodebuild"),
        ("SIM_POOL_TOTAL_WALL_SECONDS", "total_wall"),
    ]:
        parsed = parse_int_env(env_name)
        if parsed is not None:
            timing_breakdown[out_key] = parsed
    if timing_breakdown:
        payload["timing_breakdown_seconds"] = timing_breakdown

    phase_epochs = {}
    for env_name, out_key in [
        ("SIM_POOL_RUN_START_EPOCH", "run_start"),
        ("SIM_POOL_RUN_END_EPOCH", "run_end"),
        ("SIM_POOL_SLOT_WAIT_START_EPOCH", "slot_wait_start"),
        ("SIM_POOL_SLOT_WAIT_END_EPOCH", "slot_wait_end"),
        ("SIM_POOL_SIM_PREP_START_EPOCH", "simulator_prepare_start"),
        ("SIM_POOL_SIM_PREP_END_EPOCH", "simulator_prepare_end"),
        ("SIM_POOL_XCODEBUILD_START_EPOCH", "xcodebuild_start"),
        ("SIM_POOL_XCODEBUILD_END_EPOCH", "xcodebuild_end"),
    ]:
        parsed = parse_int_env(env_name)
        if parsed is not None:
            phase_epochs[out_key] = parsed
    if phase_epochs:
        payload["timing_phase_epochs"] = phase_epochs

with open(artifact_path, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")
PY
}

ATTEMPT_EXIT_CODE=0
ATTEMPT_HANG_DETECTED=0
ATTEMPT_START_EPOCH=0
ATTEMPT_END_EPOCH=0
ATTEMPT_ARTIFACT_PATH=""
FINAL_ARTIFACT_PATH=""
ATTEMPT_ARTIFACTS_JSON='[]'
VIDEO_PID=""
VIDEO_PATH=""
VIDEO_LOG_PATH=""
VIDEO_POLICY="$(normalize_video_policy "${OPPI_SIM_POOL_VIDEO_POLICY:-${OPPI_SIM_POOL_RECORD_VIDEO:-off}}")"
VIDEO_READY=0
VIDEO_READY_AT_EPOCH=""
VIDEO_STOP_STATUS=""
VIDEO_RETAINED=0
VIDEO_DELETED_REASON=""
VIDEO_SIZE_BYTES=""

start_video_recording() {
  if [[ "$VIDEO_POLICY" == "off" ]]; then
    return 0
  fi

  local video_dir="${OPPI_SIM_POOL_VIDEO_DIR:-$BUILD_BASE/videos}"
  mkdir -p "$video_dir"
  local base_name="${OPPI_SIM_POOL_VIDEO_NAME:-pool-${SLOT}-$(date +%Y%m%d-%H%M%S)}"
  VIDEO_PATH="$video_dir/${base_name}.mp4"
  VIDEO_LOG_PATH="$video_dir/${base_name}.recordVideo.log"
  : > "$VIDEO_LOG_PATH"

  echo "[sim-pool] Recording simulator video ($VIDEO_POLICY): $VIDEO_PATH" >&2
  xcrun simctl io "$SIM_UDID" recordVideo --codec=h264 "$VIDEO_PATH" >/dev/null 2>"$VIDEO_LOG_PATH" &
  VIDEO_PID=$!

  local ready_timeout="${OPPI_SIM_POOL_VIDEO_READY_TIMEOUT:-10}"
  local deadline=$((SECONDS + ready_timeout))
  while (( SECONDS < deadline )); do
    if grep -q "Recording started" "$VIDEO_LOG_PATH" 2>/dev/null; then
      VIDEO_READY=1
      VIDEO_READY_AT_EPOCH=$(now_epoch)
      echo "[sim-pool] Simulator video recording is ready" >&2
      return 0
    fi
    if ! kill -0 "$VIDEO_PID" 2>/dev/null; then
      echo "[sim-pool] WARNING: simulator video recorder exited before readiness; log: $VIDEO_LOG_PATH" >&2
      wait "$VIDEO_PID" 2>/dev/null || true
      VIDEO_PID=""
      return 0
    fi
    sleep 0.2
  done

  echo "[sim-pool] WARNING: simulator video recorder did not report readiness within ${ready_timeout}s; continuing" >&2
}

stop_video_recording() {
  if [[ -z "${VIDEO_PID:-}" ]]; then
    return 0
  fi

  local wait_status=0
  kill -INT "$VIDEO_PID" 2>/dev/null || true
  wait "$VIDEO_PID" 2>/dev/null || wait_status=$?
  VIDEO_STOP_STATUS="$wait_status"
  VIDEO_PID=""

  if [[ -n "${VIDEO_PATH:-}" && -f "$VIDEO_PATH" ]]; then
    VIDEO_SIZE_BYTES=$(file_size_bytes "$VIDEO_PATH")
  fi
}

finalize_video_recording() {
  local exit_code="$1"
  local hang_detected="$2"

  if [[ "$VIDEO_POLICY" == "off" || -z "${VIDEO_PATH:-}" ]]; then
    return 0
  fi

  local should_keep=0
  if [[ "$VIDEO_POLICY" == "always" ]]; then
    should_keep=1
  elif [[ "$VIDEO_POLICY" == "on-failure" && ( "$exit_code" != "0" || "$hang_detected" == "1" ) ]]; then
    should_keep=1
  fi

  if [[ "$should_keep" == "1" && -f "$VIDEO_PATH" ]]; then
    VIDEO_RETAINED=1
    VIDEO_SIZE_BYTES=$(file_size_bytes "$VIDEO_PATH")
    echo "[sim-pool] Video saved: $VIDEO_PATH" >&2
    return 0
  fi

  VIDEO_RETAINED=0
  if [[ "$VIDEO_POLICY" == "on-failure" && "$exit_code" == "0" && "$hang_detected" != "1" ]]; then
    VIDEO_DELETED_REASON="passed"
  else
    VIDEO_DELETED_REASON="missing"
  fi
  if [[ -f "$VIDEO_PATH" ]]; then
    rm -f "$VIDEO_PATH"
  fi
  if [[ "$VIDEO_DELETED_REASON" == "passed" ]]; then
    echo "[sim-pool] Video discarded after passing run (policy: on-failure)" >&2
  fi
}

run_xcodebuild_attempt() {
  local log_file="$1"
  local artifact_path="$2"
  local attempt_number="$3"
  shift 3

  : > "$log_file"

  local start_epoch
  start_epoch=$(now_epoch)
  local last_progress_epoch="$start_epoch"
  local last_heartbeat_epoch="$start_epoch"
  local last_mtime=0
  local hung=0

  set +e
  "$@" \
    -destination "platform=iOS Simulator,id=$SIM_UDID" \
    -derivedDataPath "$DERIVED_DATA" \
    > "$log_file" 2>&1 &
  local xcode_pid=$!
  set -e

  while kill -0 "$xcode_pid" 2>/dev/null; do
    sleep 5

    local now
    now=$(now_epoch)
    local current_mtime
    current_mtime=$(file_mtime "$log_file")
    if (( current_mtime > last_mtime )); then
      last_mtime="$current_mtime"
      last_progress_epoch="$now"
    fi

    if (( HEARTBEAT_INTERVAL > 0 && now - last_heartbeat_epoch >= HEARTBEAT_INTERVAL )); then
      local elapsed=$((now - start_epoch))
      local idle=$((now - last_progress_epoch))
      local size
      size=$(file_size_bytes "$log_file")
      echo "[sim-pool] heartbeat: elapsed=${elapsed}s idle=${idle}s log=${size}B pid=$xcode_pid" >&2
      last_heartbeat_epoch="$now"
    fi

    if (( SILENCE_TIMEOUT > 0 && now - last_progress_epoch >= SILENCE_TIMEOUT )); then
      echo "[sim-pool] hang detected: no log growth for ${SILENCE_TIMEOUT}s (pid $xcode_pid)" >&2
      hung=1
      break
    fi
  done

  set +e
  if (( hung == 1 )); then
    kill_process_tree "$xcode_pid"
    sleep 5
    kill -KILL "$xcode_pid" 2>/dev/null || true
    pkill -P "$xcode_pid" 2>/dev/null || true
    wait "$xcode_pid"
    ATTEMPT_EXIT_CODE=$?
  else
    wait "$xcode_pid"
    ATTEMPT_EXIT_CODE=$?
  fi
  set -e

  local end_epoch
  end_epoch=$(now_epoch)

  write_json_artifact "$artifact_path" "attempt" "$start_epoch" "$end_epoch" "$attempt_number" "$attempt_number" "$hung" "$log_file" "$ATTEMPT_EXIT_CODE"

  ATTEMPT_HANG_DETECTED="$hung"
  ATTEMPT_START_EPOCH="$start_epoch"
  ATTEMPT_END_EPOCH="$end_epoch"
  ATTEMPT_ARTIFACT_PATH="$artifact_path"
}

# ── Main ──

usage() {
  cat <<'EOF'
Usage:
  sim-pool.sh run -- <xcodebuild args...>
  sim-pool.sh self-test
  sim-pool.sh status
  sim-pool.sh shutdown-idle

run acquires a simulator pool slot, injects -destination and -derivedDataPath,
runs xcodebuild, and releases the slot on exit.

status prints pool locks, pool devices, build-cache sizes, and recent run timing.
shutdown-idle shuts down Oppi-Pool simulators that do not have a live lock.

Do NOT pass -destination or -derivedDataPath — they are auto-injected.
Use '-scheme OppiUnitTests' for OppiTests unit-test runs.

Pool selection:
  OPPI_SIM_POOL_COUNT=N       Number of slots to consider from the start slot.
  OPPI_SIM_POOL_SLOT_START=N  First slot index to consider; default 0.
  OPPI_SIM_DEVICE_TYPE=TYPE   Device type used when creating a missing slot.

Example iPad lane:
  OPPI_SIM_POOL_SLOT_START=4 OPPI_SIM_POOL_COUNT=1 \
  OPPI_SIM_DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M2 \
    sim-pool.sh run -- xcodebuild -project Oppi.xcodeproj -scheme Oppi test -only-testing:OppiE2ETests
EOF
  exit 1
}

live_locked_slots() {
  mkdir -p "$LOCK_DIR"
  local slot path pid
  for path in "$LOCK_DIR"/slot-*; do
    [[ -d "$path" ]] || continue
    slot="${path##*/slot-}"
    pid="$(cat "$path/pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "$slot"
    fi
  done
}

print_status() {
  echo "Pool count: $POOL_COUNT"
  echo "Pool slot start: $POOL_SLOT_START"
  echo "Pool slot range: $(pool_slot_range)"
  echo "Lock dir: $LOCK_DIR"
  echo "Build base: $BUILD_BASE"
  echo ""
  echo "Locks:"
  mkdir -p "$LOCK_DIR"
  local found_lock=0 path slot pid state
  for path in "$LOCK_DIR"/slot-*; do
    [[ -d "$path" ]] || continue
    found_lock=1
    slot="${path##*/slot-}"
    pid="$(cat "$path/pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then state="live"; else state="stale"; fi
    printf '  slot-%s pid=%s %s\n' "$slot" "${pid:-?}" "$state"
  done
  [[ "$found_lock" == "1" ]] || echo "  none"

  echo ""
  echo "Pool and booted simulators:"
  local locked_csv
  locked_csv="$(live_locked_slots | paste -sd, -)"
  local devices_json
  devices_json="$(mktemp -t oppi-sim-devices.XXXXXX.json)"
  xcrun simctl list devices -j > "$devices_json"
  python3 - "$locked_csv" "$devices_json" <<'PY'
import json, re, sys
locked = {int(s) for s in sys.argv[1].split(',') if s.isdigit()}
with open(sys.argv[2], encoding='utf-8') as f:
    data = json.load(f)
rows = []
for runtime, devices in data.get('devices', {}).items():
    for device in devices:
        name = device.get('name', '')
        state = device.get('state', '')
        is_pool = name.startswith('Oppi-Pool-')
        if not is_pool and state != 'Booted':
            continue
        slot = None
        m = re.match(r'Oppi-Pool-(\d+)$', name)
        if m:
            slot = int(m.group(1))
        rows.append((slot if slot is not None else 9999, name, state, device.get('udid', ''), device.get('deviceTypeIdentifier', ''), runtime.rsplit('.', 1)[-1], slot in locked if slot is not None else False))
for _, name, state, udid, dtype, runtime, locked in sorted(rows):
    marker = 'locked' if locked else 'idle'
    print(f'  {name:18} {state:8} {marker:6} {runtime:8} {dtype.rsplit(".", 1)[-1]} {udid}')
PY
  rm -f "$devices_json"

  echo ""
  echo "Build-cache sizes:"
  du -sh "$BUILD_BASE"/pool-* "$BUILD_BASE/logs" 2>/dev/null | sort -h || true

  echo ""
  echo "Recent summaries:"
  if [[ -d "$BUILD_BASE/logs" ]]; then
    python3 - "$BUILD_BASE/logs" <<'PY'
import glob, json, os, statistics, sys
log_dir = sys.argv[1]
rows = []
for path in glob.glob(os.path.join(log_dir, '*.summary.json')):
    try:
        with open(path, encoding='utf-8') as f:
            data = json.load(f)
        rows.append((os.path.getmtime(path), os.path.basename(path), data))
    except Exception:
        pass
rows.sort(reverse=True)
recent = rows[:50]
if not recent:
    print('  none')
    raise SystemExit
by_slot = {}
for _, _, data in recent:
    by_slot.setdefault(data.get('simulator_slot'), []).append(data)
for slot, items in sorted(by_slot.items(), key=lambda item: (item[0] is None, item[0])):
    walls = [d.get('timing_breakdown_seconds', {}).get('total_wall', d.get('elapsed_seconds', 0)) for d in items]
    print(f'  slot {slot}: runs={len(items)} fails={sum(1 for d in items if d.get("exit_code"))} hangs={sum(1 for d in items if d.get("hang_detected"))} avg_wall={statistics.mean(walls):.1f}s')
for _, name, data in rows[:8]:
    timing = data.get('timing_breakdown_seconds', {})
    print(f'    {name}: slot={data.get("simulator_slot")} exit={data.get("exit_code")} wall={timing.get("total_wall")}s prep={timing.get("simulator_prepare")}s')
PY
  fi
}

shutdown_idle() {
  local locked_csv
  locked_csv="$(live_locked_slots | paste -sd, -)"
  local devices_json
  devices_json="$(mktemp -t oppi-sim-devices.XXXXXX.json)"
  xcrun simctl list devices -j > "$devices_json"
  python3 - "$locked_csv" "$devices_json" <<'PY' | while IFS= read -r udid; do
import json, re, sys
locked = {int(s) for s in sys.argv[1].split(',') if s.isdigit()}
with open(sys.argv[2], encoding='utf-8') as f:
    data = json.load(f)
for devices in data.get('devices', {}).values():
    for device in devices:
        name = device.get('name', '')
        if device.get('state') != 'Booted':
            continue
        m = re.match(r'Oppi-Pool-(\d+)$', name)
        if not m:
            continue
        if int(m.group(1)) not in locked:
            print(device['udid'])
PY
    echo "[sim-pool] Shutting down idle simulator $udid" >&2
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  done
  rm -f "$devices_json"
}

case "${1:-}" in
  self-test)
    run_self_test
    exit 0
    ;;
  status)
    validate_pool_config
    print_status
    exit 0
    ;;
  shutdown-idle)
    validate_pool_config
    shutdown_idle
    exit 0
    ;;
  run)
    shift
    ;;
  *)
    usage
    ;;
esac

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

validate_command_guardrails "$@"
validate_pool_config

RUN_START_EPOCH=$(now_epoch)
SLOT_WAIT_START_EPOCH="$RUN_START_EPOCH"

# Acquire slot
SLOT=$(acquire_slot)
SLOT_WAIT_END_EPOCH=$(now_epoch)
SLOT_WAIT_SECONDS=$((SLOT_WAIT_END_EPOCH - SLOT_WAIT_START_EPOCH))
trap 'cleanup_run' EXIT

echo "[sim-pool] Acquired slot $SLOT" >&2

SIM_PREP_START_EPOCH=$(now_epoch)
SIMULATOR_PREP_SECONDS=0

# Ensure simulator exists
SIM_UDID=$(ensure_sim "$SLOT")
DERIVED_DATA="$BUILD_BASE/pool-${SLOT}"
mkdir -p "$DERIVED_DATA"

echo "[sim-pool] Simulator: Oppi-Pool-${SLOT} ($SIM_UDID)" >&2
echo "[sim-pool] DerivedData: $DERIVED_DATA" >&2

run_periodic_maintenance
SIM_PREP_STEP_START_EPOCH=$(now_epoch)
prepare_simulator "$SIM_UDID" normal
SIM_PREP_STEP_END_EPOCH=$(now_epoch)
SIMULATOR_PREP_SECONDS=$((SIMULATOR_PREP_SECONDS + SIM_PREP_STEP_END_EPOCH - SIM_PREP_STEP_START_EPOCH))
SIM_PREP_END_EPOCH=$(now_epoch)

# Build log — all output goes to file, only summary to stdout
LOG_DIR="$BUILD_BASE/logs"
mkdir -p "$LOG_DIR"
BASE_LOG_FILE="$LOG_DIR/pool-${SLOT}-$(date +%Y%m%d-%H%M%S).log"
BASE_ARTIFACT_FILE="${BASE_LOG_FILE%.log}.json"
FINAL_ARTIFACT_PATH="${BASE_LOG_FILE%.log}.summary.json"
LOG_FILE="$BASE_LOG_FILE"

# Prune logs older than 3 days (non-blocking, best-effort)
find "$LOG_DIR" \( -name "pool-*.log" -o -name "pool-*.json" -o -name "pool-*.summary.json" \) -mtime +3 -delete 2>/dev/null &

echo "[sim-pool] Log: $LOG_FILE" >&2
start_video_recording

TOTAL_START_EPOCH=$(now_epoch)
ATTEMPT=0
ATTEMPTS_USED=0
EXIT_CODE=0
FINAL_HANG_DETECTED=0

while :; do
  ATTEMPTS_USED=$((ATTEMPT + 1))
  ATTEMPT_ARTIFACT_FILE="$BASE_ARTIFACT_FILE"
  if (( ATTEMPT > 0 )); then
    LOG_FILE="${BASE_LOG_FILE%.log}-retry${ATTEMPT}.log"
    ATTEMPT_ARTIFACT_FILE="${BASE_ARTIFACT_FILE%.json}-retry${ATTEMPT}.json"
    echo "[sim-pool] Retry ${ATTEMPTS_USED}/$((HANG_RETRIES + 1)) — log: $LOG_FILE" >&2
    SIM_PREP_STEP_START_EPOCH=$(now_epoch)
    prepare_simulator "$SIM_UDID" recovery
    SIM_PREP_STEP_END_EPOCH=$(now_epoch)
    SIMULATOR_PREP_SECONDS=$((SIMULATOR_PREP_SECONDS + SIM_PREP_STEP_END_EPOCH - SIM_PREP_STEP_START_EPOCH))
    SIM_PREP_END_EPOCH="$SIM_PREP_STEP_END_EPOCH"
  fi

  build_attempt_command "$ATTEMPT" "$@"
  if (( ATTEMPT > 0 )); then
    RETRY_RESULT_BUNDLE="$(extract_flag_value "-resultBundlePath" "${ATTEMPT_COMMAND[@]}" 2>/dev/null || true)"
    if [[ -n "$RETRY_RESULT_BUNDLE" ]]; then
      echo "[sim-pool] Retry result bundle: $RETRY_RESULT_BUNDLE" >&2
    fi
  fi
  run_xcodebuild_attempt "$LOG_FILE" "$ATTEMPT_ARTIFACT_FILE" "$ATTEMPTS_USED" "${ATTEMPT_COMMAND[@]}"
  EXIT_CODE="$ATTEMPT_EXIT_CODE"
  ATTEMPT_ARTIFACTS_JSON=$(python3 - "$ATTEMPT_ARTIFACTS_JSON" "$ATTEMPT_ARTIFACT_PATH" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
payload.append(sys.argv[2])
print(json.dumps(payload))
PY
)

  if (( ATTEMPT_HANG_DETECTED == 1 )); then
    FINAL_HANG_DETECTED=1
    if (( ATTEMPT < HANG_RETRIES )); then
      echo "[sim-pool] Retrying after simulator hang recovery..." >&2
      ATTEMPT=$((ATTEMPT + 1))
      continue
    fi
  fi

  break
done

TOTAL_END_EPOCH=$(now_epoch)
XCODEBUILD_SECONDS=$((TOTAL_END_EPOCH - TOTAL_START_EPOCH))
RUN_END_EPOCH=$(now_epoch)
TOTAL_WALL_SECONDS=$((RUN_END_EPOCH - RUN_START_EPOCH))
stop_video_recording
finalize_video_recording "$EXIT_CODE" "$FINAL_HANG_DETECTED"

SIM_POOL_ATTEMPT_ARTIFACTS_JSON="$ATTEMPT_ARTIFACTS_JSON" \
SIM_POOL_SLOT_WAIT_SECONDS="$SLOT_WAIT_SECONDS" \
SIM_POOL_SIM_PREP_SECONDS="$SIMULATOR_PREP_SECONDS" \
SIM_POOL_XCODEBUILD_SECONDS="$XCODEBUILD_SECONDS" \
SIM_POOL_TOTAL_WALL_SECONDS="$TOTAL_WALL_SECONDS" \
SIM_POOL_RUN_START_EPOCH="$RUN_START_EPOCH" \
SIM_POOL_RUN_END_EPOCH="$RUN_END_EPOCH" \
SIM_POOL_SLOT_WAIT_START_EPOCH="$SLOT_WAIT_START_EPOCH" \
SIM_POOL_SLOT_WAIT_END_EPOCH="$SLOT_WAIT_END_EPOCH" \
SIM_POOL_SIM_PREP_START_EPOCH="$SIM_PREP_START_EPOCH" \
SIM_POOL_SIM_PREP_END_EPOCH="$SIM_PREP_END_EPOCH" \
SIM_POOL_XCODEBUILD_START_EPOCH="$TOTAL_START_EPOCH" \
SIM_POOL_XCODEBUILD_END_EPOCH="$TOTAL_END_EPOCH" \
SIM_POOL_VIDEO_POLICY="$VIDEO_POLICY" \
SIM_POOL_VIDEO_PATH="$VIDEO_PATH" \
SIM_POOL_VIDEO_LOG_PATH="$VIDEO_LOG_PATH" \
SIM_POOL_VIDEO_READY="$VIDEO_READY" \
SIM_POOL_VIDEO_READY_AT_EPOCH="$VIDEO_READY_AT_EPOCH" \
SIM_POOL_VIDEO_STOP_STATUS="$VIDEO_STOP_STATUS" \
SIM_POOL_VIDEO_RETAINED="$VIDEO_RETAINED" \
SIM_POOL_VIDEO_DELETED_REASON="$VIDEO_DELETED_REASON" \
SIM_POOL_VIDEO_SIZE_BYTES="$VIDEO_SIZE_BYTES" \
  write_json_artifact "$FINAL_ARTIFACT_PATH" "final" "$TOTAL_START_EPOCH" "$TOTAL_END_EPOCH" "$ATTEMPTS_USED" "$ATTEMPTS_USED" "$FINAL_HANG_DETECTED" "$LOG_FILE" "$EXIT_CODE"

echo "[sim-pool] Artifact: $FINAL_ARTIFACT_PATH" >&2

# Prune simulator caches that accumulate per-build and never self-clean.
# containermanagerd: grows with every app install (~1-2 GB/day under heavy use)
# coresymbolicationd: caches dSYMs from every build (~500 MB/day)
# These regenerate on next use in seconds — safe to remove.
SIM_CACHE_DIR="$HOME/Library/Developer/CoreSimulator/Devices/$SIM_UDID/data/Library/Caches"
rm -rf "$SIM_CACHE_DIR/com.apple.containermanagerd" "$SIM_CACHE_DIR/com.apple.coresymbolicationd" 2>/dev/null &

print_summary "$LOG_FILE" "$EXIT_CODE" "$DERIVED_DATA" "$TOTAL_START_EPOCH" "$TOTAL_END_EPOCH" "$ATTEMPTS_USED" "$FINAL_HANG_DETECTED" "$RUN_START_EPOCH" "$RUN_END_EPOCH" "$SLOT_WAIT_SECONDS" "$SIMULATOR_PREP_SECONDS"
exit $EXIT_CODE

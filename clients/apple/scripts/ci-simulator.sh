#!/usr/bin/env bash
# Run one xcodebuild command on an existing simulator from a CI runner image.
# Unlike sim-pool.sh, this script never creates, erases, or locks simulators.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${OPPI_ROOT:-${PIOS_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)}}"
APPLE_DIR="$REPO_ROOT/clients/apple"
BUILD_BASE="$APPLE_DIR/.build"
LOG_DIR="$BUILD_BASE/logs"
DEVICE_NAME="${OPPI_CI_SIM_DEVICE_NAME:-iPhone 17 Pro}"
BOOT_TIMEOUT="${OPPI_CI_SIM_BOOT_TIMEOUT:-150}"
# Two reboot retries allow three bounded readiness waits without an overall budget.
BOOT_RETRIES=2
SILENCE_TIMEOUT="${OPPI_CI_SIM_SILENCE_TIMEOUT:-180}"
HANG_RETRIES="${OPPI_CI_SIM_HANG_RETRIES:-1}"
POLL_INTERVAL="${OPPI_CI_SIM_POLL_INTERVAL:-5}"
TERMINATION_GRACE="${OPPI_CI_SIM_TERMINATION_GRACE:-5}"
CONTROL_TIMEOUT="${OPPI_CI_SIM_CONTROL_TIMEOUT:-30}"
RETRY_DEADLINE="${OPPI_CI_SIM_RETRY_DEADLINE:-0}"
DERIVED_DATA="${OPPI_CI_DERIVED_DATA_PATH:-$BUILD_BASE/ci}"
SIM_UDID=""
BOOTED_BY_SCRIPT=0
BOOT_WAIT_ATTEMPTS=0
BOOT_READY=0
COMMAND_PID=""
ATTEMPT_COMMAND=()
ATTEMPT_STATUS=0
ATTEMPT_HUNG=0

usage() {
  cat <<'EOF'
Usage:
  ci-simulator.sh run -- xcodebuild <args...>
  ci-simulator.sh self-test

The run command selects an existing simulator whose runtime matches the active
Xcode iOS Simulator SDK. It never creates or erases a simulator.

Environment:
  OPPI_CI_SIM_DEVICE_NAME       Existing device name (default: iPhone 17 Pro)
  OPPI_CI_SIM_RUNTIME           Exact CoreSimulator runtime identifier
  OPPI_CI_SIM_BOOT_TIMEOUT      Boot-readiness timeout in seconds (default: 150)
  OPPI_CI_SIM_SILENCE_TIMEOUT   Log-silence timeout in seconds (default: 180)
  OPPI_CI_SIM_HANG_RETRIES      Reboot-and-retry count after silence (default: 1)
  OPPI_CI_SIM_POLL_INTERVAL     Seconds between process checks (default: 5)
  OPPI_CI_SIM_TERMINATION_GRACE Seconds before hung process groups get KILL (default: 5)
  OPPI_CI_SIM_CONTROL_TIMEOUT  Timeout for simulator boot/shutdown commands (default: 30)
  OPPI_CI_SIM_RETRY_DEADLINE   Skip retry after this elapsed run time; 0 disables (default: 0)
  OPPI_CI_DERIVED_DATA_PATH     DerivedData path (default: clients/apple/.build/ci)
EOF
  exit 1
}

die() {
  echo "error: $*" >&2
  exit 1
}

runtime_for_active_xcode() {
  local sdk_version
  sdk_version="$(xcrun --sdk iphonesimulator --show-sdk-version)"
  [[ -n "$sdk_version" ]] || die "active Xcode did not report an iOS Simulator SDK version"
  printf 'com.apple.CoreSimulator.SimRuntime.iOS-%s\n' "${sdk_version//./-}"
}

select_existing_simulator() {
  local devices_json="$1"
  local runtime="$2"
  local device_name="$3"

  python3 - "$devices_json" "$runtime" "$device_name" <<'PY'
import json
import sys

path, runtime, device_name = sys.argv[1:]
with open(path, encoding="utf-8") as file:
    payload = json.load(file)

for device in payload.get("devices", {}).get(runtime, []):
    if device.get("name") != device_name:
        continue
    if device.get("isAvailable") is False:
        continue
    udid = device.get("udid")
    if udid:
        print(f"{udid}\t{device.get('state', 'Unknown')}")
        raise SystemExit(0)

raise SystemExit(1)
PY
}

print_available_ios_simulators() {
  local devices_json="$1"

  python3 - "$devices_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    payload = json.load(file)

for runtime, devices in sorted(payload.get("devices", {}).items()):
    if ".iOS-" not in runtime:
        continue
    print(runtime)
    for device in devices:
        if device.get("isAvailable") is False:
            continue
        print(f"  {device.get('name', '?')} ({device.get('state', '?')}) {device.get('udid', '?')}")
PY
}

result_bundle_path_for_attempt() {
  local path="$1"
  local attempt="$2"

  if (( attempt == 0 )); then
    printf '%s\n' "$path"
  elif [[ "$path" == *.xcresult ]]; then
    printf '%s-retry%d.xcresult\n' "${path%.xcresult}" "$attempt"
  else
    printf '%s-retry%d\n' "$path" "$attempt"
  fi
}

build_attempt_command() {
  local attempt="$1"
  shift

  ATTEMPT_COMMAND=()
  while (( $# > 0 )); do
    local argument="$1"
    shift
    if [[ "$argument" == "-resultBundlePath" ]]; then
      (( $# > 0 )) || die "-resultBundlePath requires a path"
      ATTEMPT_COMMAND+=(
        "-resultBundlePath"
        "$(result_bundle_path_for_attempt "$1" "$attempt")"
      )
      shift
    elif [[ "$argument" == -resultBundlePath=* ]]; then
      ATTEMPT_COMMAND+=(
        "-resultBundlePath=$(result_bundle_path_for_attempt "${argument#*=}" "$attempt")"
      )
    else
      ATTEMPT_COMMAND+=("$argument")
    fi
  done
}

extract_compiler_linker_errors() {
  local log_file="$1"
  grep -E '^([^:]+):[0-9]+:[0-9]+: (fatal )?error:|^[[:space:]]*(error:|clang: error:|swiftc: error:|ld: )' \
    "$log_file" 2>/dev/null | sort -u || true
}

extract_build_timing_summary() {
  local log_file="$1"
  awk '
    /^Build Timing Summary$/ { capturing = 1; print; next }
    capturing && NF > 0 { print; saw_row = 1; next }
    capturing && saw_row { exit }
  ' "$log_file" 2>/dev/null || true
}

extract_test_failures() {
  local log_file="$1"
  grep -E 'failed\b.*-\[|Test Case .* failed|error:.*assert|#expect.* failed|Issue recorded|Expectation failed' \
    "$log_file" 2>/dev/null | sort -u || true
}

retry_deadline_allows() {
  local elapsed="$1"
  (( RETRY_DEADLINE == 0 || elapsed < RETRY_DEADLINE ))
}

print_failure_diagnostics() {
  local log_file="$1"
  local errors test_failures build_timing
  errors="$(extract_compiler_linker_errors "$log_file")"
  test_failures="$(extract_test_failures "$log_file")"
  build_timing="$(extract_build_timing_summary "$log_file")"

  [[ -z "$errors" ]] || printf '\nCompiler/linker errors:\n%s\n' "$errors" >&2
  [[ -z "$test_failures" ]] || printf '\nTest failures:\n%s\n' "$test_failures" >&2
  [[ -z "$build_timing" ]] || printf '\n%s\n' "$build_timing" >&2
}

run_simctl_bounded() {
  local timeout="$1"
  shift

  python3 - "$timeout" "$@" <<'PY'
import subprocess
import sys

try:
    subprocess.run(
        ["xcrun", "simctl", *sys.argv[2:]],
        check=True,
        timeout=int(sys.argv[1]),
    )
except subprocess.TimeoutExpired:
    sys.exit(124)
except subprocess.CalledProcessError as error:
    sys.exit(error.returncode)
PY
}

wait_for_boot_ready() {
  local udid="$1"

  python3 - "$udid" "$BOOT_TIMEOUT" <<'PY'
import subprocess
import sys

udid = sys.argv[1]
timeout = int(sys.argv[2])
try:
    subprocess.run(
        ["xcrun", "simctl", "bootstatus", udid, "-b"],
        check=True,
        timeout=timeout,
    )
except subprocess.TimeoutExpired:
    sys.exit(124)
except subprocess.CalledProcessError as error:
    sys.exit(error.returncode)
PY
}

wait_for_boot_ready_with_retries() {
  local udid="$1"
  local attempt=0
  local status=0
  local total_waits=$((BOOT_RETRIES + 1))

  while (( attempt < total_waits )); do
    attempt=$((attempt + 1))
    BOOT_WAIT_ATTEMPTS="$attempt"
    echo "[ci-simulator] Boot-readiness wait ${attempt}/${total_waits} (timeout ${BOOT_TIMEOUT}s)" >&2
    if wait_for_boot_ready "$udid"; then
      BOOT_READY=1
      echo "[ci-simulator] Simulator $udid reached boot-ready state on wait ${attempt}/${total_waits}" >&2
      return 0
    else
      status=$?
    fi

    if (( attempt < total_waits )); then
      echo "[ci-simulator] Boot-readiness wait ${attempt}/${total_waits} failed (status ${status}); rebooting existing simulator before wait $((attempt + 1))/${total_waits}" >&2
      reboot_existing_simulator
    fi
  done

  BOOT_READY=0
  echo "[ci-simulator] Simulator $udid failed boot readiness after ${BOOT_WAIT_ATTEMPTS}/${total_waits} waits of ${BOOT_TIMEOUT}s (last status ${status})" >&2
  return "$status"
}

run_self_test() {
  local fixture selected result_bundle self_test_dir=""
  fixture="$(mktemp -t oppi-ci-simulator.XXXXXX.json)"
  trap 'rm -f "$fixture"; rm -rf "${self_test_dir:-}"' RETURN

  cat > "$fixture" <<'JSON'
{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
      {"name": "iPhone 17 Pro", "udid": "OLDER", "state": "Shutdown", "isAvailable": true}
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
      {"name": "iPhone 17 Pro", "udid": "UNAVAILABLE", "state": "Shutdown", "isAvailable": false},
      {"name": "iPhone 17 Pro", "udid": "EXPECTED", "state": "Shutdown", "isAvailable": true},
      {"name": "iPhone 17", "udid": "WRONG-NAME", "state": "Shutdown", "isAvailable": true}
    ]
  }
}
JSON

  selected="$(select_existing_simulator \
    "$fixture" \
    "com.apple.CoreSimulator.SimRuntime.iOS-26-5" \
    "iPhone 17 Pro")" \
    || die "self-test: failed to select the exact available simulator"
  [[ "$selected" == $'EXPECTED\tShutdown' ]] \
    || die "self-test: selected the wrong simulator: $selected"

  if select_existing_simulator \
    "$fixture" \
    "com.apple.CoreSimulator.SimRuntime.iOS-26-5" \
    "iPhone Air" >/dev/null; then
    die "self-test: missing simulator unexpectedly matched"
  fi

  result_bundle="/tmp/OppiTests.xcresult"
  [[ "$(result_bundle_path_for_attempt "$result_bundle" 0)" == "$result_bundle" ]] \
    || die "self-test: first attempt changed the result bundle path"
  [[ "$(result_bundle_path_for_attempt "$result_bundle" 1)" == "/tmp/OppiTests-retry1.xcresult" ]] \
    || die "self-test: retry result bundle path is not unique"
  build_attempt_command 1 xcodebuild test -resultBundlePath "$result_bundle"
  [[ "${ATTEMPT_COMMAND[3]}" == "/tmp/OppiTests-retry1.xcresult" ]] \
    || die "self-test: retry command did not use its unique result bundle"
  (RETRY_DEADLINE=0; retry_deadline_allows 999) \
    || die "self-test: disabled retry deadline rejected a retry"
  (RETRY_DEADLINE=10; retry_deadline_allows 9) \
    || die "self-test: retry was rejected before its deadline"
  if (RETRY_DEADLINE=10; retry_deadline_allows 10); then
    die "self-test: retry was allowed at its deadline"
  fi

  local diagnostic_log diagnostics process_script process_log process_pids root_pid child_pid
  diagnostic_log="$(mktemp -t oppi-ci-diagnostics.XXXXXX.log)"
  cat > "$diagnostic_log" <<'LOG'
/Users/runner/work/oppi/Foo.swift:12:7: error: cannot find 'missing' in scope
Test Case '-[OppiTests.Foo testBar]' failed (0.01 seconds)
Build Timing Summary

SwiftCompile (3 tasks) | 42.000 seconds

LOG
  diagnostics="$(
    extract_compiler_linker_errors "$diagnostic_log"
    extract_test_failures "$diagnostic_log"
    extract_build_timing_summary "$diagnostic_log"
  )"
  [[ "$diagnostics" == *"cannot find 'missing' in scope"* ]] \
    || die "self-test: compiler diagnostic was not extracted"
  [[ "$diagnostics" == *"testBar"* ]] \
    || die "self-test: test failure was not extracted"
  [[ "$diagnostics" == *"SwiftCompile (3 tasks) | 42.000 seconds"* ]] \
    || die "self-test: build timing was not extracted"
  rm -f "$diagnostic_log"

  process_script="$(mktemp -t oppi-ci-process-group.XXXXXX.sh)"
  process_log="$(mktemp -t oppi-ci-process-group.XXXXXX.log)"
  process_pids="$(mktemp -t oppi-ci-process-group.XXXXXX.pids)"
  cat > "$process_script" <<'SH'
#!/usr/bin/env bash
trap '' TERM
(trap '' TERM; while :; do sleep 1; done) &
echo "$$ $!" > "$1"
while :; do sleep 1; done
SH
  chmod +x "$process_script"
  start_process_group "$process_log" "$process_script" "$process_pids"
  for _ in {1..50}; do
    [[ -s "$process_pids" ]] && break
    sleep 0.1
  done
  [[ -s "$process_pids" ]] || die "self-test: process-group fixture did not start"
  read -r root_pid child_pid < "$process_pids"
  TERMINATION_GRACE=1
  stop_process_group "$COMMAND_PID" \
    || die "self-test: process group survived bounded TERM/KILL cleanup"
  kill -0 "$root_pid" 2>/dev/null \
    && die "self-test: TERM-resistant root survived cleanup"
  kill -0 "$child_pid" 2>/dev/null \
    && die "self-test: TERM-resistant child survived cleanup"
  rm -f "$process_script" "$process_log" "$process_pids"
  COMMAND_PID=""

  local fake_bin xcrun_calls attempt_file argument_log lifecycle_log summary_file
  local lifecycle_bootstatus_file recovery_root recovery_calls recovery_bootstatus
  local recovery_attempt recovery_arguments recovery_log recovery_summary
  local exhausted_root exhausted_calls exhausted_bootstatus exhausted_attempt
  local exhausted_arguments exhausted_log exhausted_summary exhausted_status
  self_test_dir="$(mktemp -d -t oppi-ci-lifecycle.XXXXXX)"
  fake_bin="$self_test_dir/bin"
  xcrun_calls="$self_test_dir/xcrun.calls"
  attempt_file="$self_test_dir/attempt"
  argument_log="$self_test_dir/arguments.log"
  lifecycle_bootstatus_file="$self_test_dir/lifecycle.bootstatus"
  lifecycle_log="$self_test_dir/lifecycle.log"
  recovery_root="$self_test_dir/recovery"
  recovery_calls="$self_test_dir/recovery.xcrun.calls"
  recovery_bootstatus="$self_test_dir/recovery.bootstatus"
  recovery_attempt="$self_test_dir/recovery.attempt"
  recovery_arguments="$self_test_dir/recovery.arguments.log"
  recovery_log="$self_test_dir/recovery.log"
  exhausted_root="$self_test_dir/exhausted"
  exhausted_calls="$self_test_dir/exhausted.xcrun.calls"
  exhausted_bootstatus="$self_test_dir/exhausted.bootstatus"
  exhausted_attempt="$self_test_dir/exhausted.attempt"
  exhausted_arguments="$self_test_dir/exhausted.arguments.log"
  exhausted_log="$self_test_dir/exhausted.log"
  mkdir -p \
    "$fake_bin" \
    "$self_test_dir/clients/apple" \
    "$recovery_root/clients/apple" \
    "$exhausted_root/clients/apple"

  cat > "$fake_bin/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$OPPI_CI_SELF_TEST_XCRUN_CALLS"
case "$*" in
  "--sdk iphonesimulator --show-sdk-version")
    echo "26.5"
    ;;
  "simctl list devices available -j")
    cat "$OPPI_CI_SELF_TEST_DEVICES_JSON"
    ;;
  "simctl boot EXPECTED"|"simctl shutdown EXPECTED")
    ;;
  "simctl bootstatus EXPECTED -b")
    bootstatus_attempt=0
    [[ ! -f "$OPPI_CI_SELF_TEST_BOOTSTATUS_FILE" ]] \
      || bootstatus_attempt="$(cat "$OPPI_CI_SELF_TEST_BOOTSTATUS_FILE")"
    bootstatus_attempt=$((bootstatus_attempt + 1))
    echo "$bootstatus_attempt" > "$OPPI_CI_SELF_TEST_BOOTSTATUS_FILE"
    echo "bootstatus fixture: wait $bootstatus_attempt"
    if (( bootstatus_attempt <= OPPI_CI_SELF_TEST_BOOTSTATUS_FAILURES )); then
      echo "bootstatus fixture: not ready" >&2
      exit 75
    fi
    echo "bootstatus fixture: ready"
    ;;
  *)
    echo "unexpected xcrun call: $*" >&2
    exit 1
    ;;
esac
SH
  cat > "$fake_bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
attempt=0
[[ ! -f "$OPPI_CI_SELF_TEST_ATTEMPT_FILE" ]] \
  || attempt="$(cat "$OPPI_CI_SELF_TEST_ATTEMPT_FILE")"
attempt=$((attempt + 1))
echo "$attempt" > "$OPPI_CI_SELF_TEST_ATTEMPT_FILE"
printf '%s\n' "$*" >> "$OPPI_CI_SELF_TEST_ARGUMENT_LOG"
if [[ "${OPPI_CI_SELF_TEST_HANG_FIRST:-1}" == "1" && "$attempt" == "1" ]]; then
  trap '' TERM
  while :; do sleep 1; done
fi
echo "Test run with 1 test in 1 suite passed after 0.001 seconds."
echo "** TEST SUCCEEDED **"
SH
  chmod +x "$fake_bin/xcrun" "$fake_bin/xcodebuild"

  export PATH="$fake_bin:$PATH"
  export OPPI_CI_SIM_RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-5"
  export OPPI_CI_SIM_BOOT_TIMEOUT=1 OPPI_CI_SIM_CONTROL_TIMEOUT=1
  export OPPI_CI_SIM_SILENCE_TIMEOUT=1 OPPI_CI_SIM_POLL_INTERVAL=1
  export OPPI_CI_SIM_TERMINATION_GRACE=1

  assert_xcrun_calls() {
    local calls_file="$1"
    shift
    local actual expected
    actual="$(cat "$calls_file")"
    expected="$(printf '%s\n' "$@")"
    [[ "$actual" == "$expected" ]] || {
      printf 'actual simulator calls: %s\nexpected simulator calls: %s\n' "$actual" "$expected" >&2
      return 1
    }
  }

  assert_no_simulator_mutation() {
    local calls_file="$1"
    if grep -Eq 'simctl (create|erase)' "$calls_file"; then
      die "self-test: simulator lifecycle created or erased a simulator"
    fi
  }

  run_fake_runner() {
    local root="$1" calls_file="$2" bootstatus_file="$3" bootstatus_failures="$4"
    local attempt_file_path="$5" argument_log_path="$6" log_file="$7"
    local hang_first="$8" hang_retries="$9"

    OPPI_ROOT="$root" \
    OPPI_CI_SELF_TEST_XCRUN_CALLS="$calls_file" \
    OPPI_CI_SELF_TEST_DEVICES_JSON="$fixture" \
    OPPI_CI_SELF_TEST_BOOTSTATUS_FILE="$bootstatus_file" \
    OPPI_CI_SELF_TEST_BOOTSTATUS_FAILURES="$bootstatus_failures" \
    OPPI_CI_SELF_TEST_ATTEMPT_FILE="$attempt_file_path" \
    OPPI_CI_SELF_TEST_ARGUMENT_LOG="$argument_log_path" \
    OPPI_CI_SELF_TEST_HANG_FIRST="$hang_first" \
    OPPI_CI_SIM_HANG_RETRIES="$hang_retries" \
      "$SCRIPT_DIR/ci-simulator.sh" run -- "$fake_bin/xcodebuild" test \
        -resultBundlePath "$root/OppiTests.xcresult" > "$log_file" 2>&1
  }

  assert_summary() {
    local summary_path="$1" phase="$2" waits="$3" ready="$4" exit_mode="$5"
    python3 - "$summary_path" "$phase" "$waits" "$ready" "$exit_mode" <<'PY'
import json
import os
import sys

path, phase, waits, ready, exit_mode = sys.argv[1:]
with open(path, encoding="utf-8") as file:
    summary = json.load(file)
assert summary["simulator_udid"] == "EXPECTED"
assert summary["runtime"] == "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
assert summary["initial_state"] == "Shutdown"
assert summary["boot_wait_attempts"] == int(waits)
assert summary["boot_wait_timeout_seconds"] == 1
assert summary["boot_ready"] == (ready == "true")
assert summary["phase"] == phase
assert summary["xcodebuild_started"] == (phase == "xcodebuild")
assert summary["started_at_epoch"] <= summary["ended_at_epoch"]
assert summary["elapsed_seconds"] >= 0
if exit_mode == "success":
    assert summary["exit_code"] == 0
    assert summary["attempt_count"] == 1
else:
    assert summary["exit_code"] != 0
    assert summary["attempt_count"] == 0
    assert summary["hang_detected"] is False
    assert summary["log_path"].endswith("-boot-readiness.log")
    assert os.path.isfile(summary["log_path"])
    assert os.path.getsize(summary["log_path"]) == 0
PY
  }

  run_fake_runner \
    "$recovery_root" "$recovery_calls" "$recovery_bootstatus" 1 \
    "$recovery_attempt" "$recovery_arguments" "$recovery_log" 0 0 \
    || { cat "$recovery_log" >&2; die "self-test: top-level boot recovery failed"; }
  assert_xcrun_calls "$recovery_calls" \
    "simctl list devices available -j" "simctl boot EXPECTED" \
    "simctl bootstatus EXPECTED -b" "simctl shutdown EXPECTED" \
    "simctl boot EXPECTED" "simctl bootstatus EXPECTED -b" \
    "simctl shutdown EXPECTED" \
    || die "self-test: top-level recovery simulator operation order/count changed"
  assert_no_simulator_mutation "$recovery_calls"
  [[ "$(cat "$recovery_attempt")" == "1" ]] \
    || die "self-test: top-level recovery did not proceed to xcodebuild"
  recovery_summary="$(printf '%s\n' "$recovery_root"/clients/apple/.build/logs/*.summary.json)"
  assert_summary "$recovery_summary" xcodebuild 2 true success \
    || die "self-test: top-level recovery summary was incomplete"

  if run_fake_runner \
    "$exhausted_root" "$exhausted_calls" "$exhausted_bootstatus" 3 \
    "$exhausted_attempt" "$exhausted_arguments" "$exhausted_log" 0 0; then
    die "self-test: exhausted top-level boot readiness unexpectedly succeeded"
  else
    exhausted_status=$?
  fi
  [[ "$exhausted_status" -ne 0 ]] \
    || die "self-test: exhausted top-level boot readiness returned success"
  [[ ! -e "$exhausted_attempt" && ! -e "$exhausted_arguments" ]] \
    || die "self-test: exhausted boot readiness started xcodebuild"
  assert_xcrun_calls "$exhausted_calls" \
    "simctl list devices available -j" "simctl boot EXPECTED" \
    "simctl bootstatus EXPECTED -b" "simctl shutdown EXPECTED" \
    "simctl boot EXPECTED" "simctl bootstatus EXPECTED -b" \
    "simctl shutdown EXPECTED" "simctl boot EXPECTED" \
    "simctl bootstatus EXPECTED -b" "simctl shutdown EXPECTED" \
    || die "self-test: exhausted boot readiness simulator operation order/count changed"
  assert_no_simulator_mutation "$exhausted_calls"
  grep -q 'Boot-readiness wait 3/3' "$exhausted_log" \
    || die "self-test: exhausted boot diagnostics omitted the final wait"
  grep -q 'bootstatus fixture: not ready' "$exhausted_log" \
    || die "self-test: exhausted boot diagnostics omitted bootstatus output"
  grep -q 'failed boot readiness after 3/3 waits of 1s' "$exhausted_log" \
    || die "self-test: exhausted boot diagnostics omitted the bounded failure"
  grep -q 'Summary:' "$exhausted_log" \
    || die "self-test: exhausted boot diagnostics omitted the summary path"
  exhausted_summary="$(printf '%s\n' "$exhausted_root"/clients/apple/.build/logs/*.summary.json)"
  assert_summary "$exhausted_summary" boot-readiness 3 false failure \
    || die "self-test: exhausted boot summary was incomplete"

  run_fake_runner \
    "$self_test_dir" "$xcrun_calls" "$lifecycle_bootstatus_file" 0 \
    "$attempt_file" "$argument_log" "$lifecycle_log" 1 1 \
    || { cat "$lifecycle_log" >&2; die "self-test: bounded hang retry failed"; }

  [[ "$(cat "$attempt_file")" == "2" ]] \
    || die "self-test: lifecycle used the wrong attempt count"
  grep -q 'OppiTests-retry1.xcresult' "$argument_log" \
    || die "self-test: lifecycle retry did not use a distinct result bundle"
  if grep -Eq 'simctl (create|erase)' "$xcrun_calls"; then
    die "self-test: lifecycle created or erased a simulator"
  fi
  grep -q 'bootstatus fixture: ready' "$lifecycle_log" \
    || die "self-test: bootstatus output was not preserved"
  grep -q 'Boot readiness: 1/3 waits, 1s each, ready=1' "$lifecycle_log" \
    || die "self-test: boot readiness summary was not reviewable"
  [[ "$(grep -c '^simctl boot EXPECTED$' "$xcrun_calls")" == "2" ]] \
    || die "self-test: lifecycle did not boot the same simulator twice"
  [[ "$(grep -c '^simctl shutdown EXPECTED$' "$xcrun_calls")" == "2" ]] \
    || die "self-test: lifecycle did not reboot and clean up the same simulator"
  summary_file="$(printf '%s\n' "$self_test_dir"/clients/apple/.build/logs/*.summary.json)"
  python3 - "$summary_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    summary = json.load(file)
assert summary["simulator_udid"] == "EXPECTED"
assert summary["attempt_count"] == 2
assert summary["hang_detected"] is True
assert summary["boot_wait_attempts"] == 1
assert summary["boot_wait_timeout_seconds"] == 1
assert summary["boot_ready"] is True
assert summary["exit_code"] == 0
PY

  echo "ci-simulator self-test passed."
}

process_is_running() {
  local pid="$1"
  local state

  kill -0 "$pid" 2>/dev/null || return 1
  state="$(ps -o state= -p "$pid" 2>/dev/null | tr -d ' ')"
  [[ -n "$state" && "$state" != Z* ]]
}

process_group_is_running() {
  local group_id="$1"
  kill -0 -- "-$group_id" 2>/dev/null
}

start_process_group() {
  local log_file="$1"
  shift

  python3 -c '
import os
import sys

os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])
' "$@" > "$log_file" 2>&1 &
  COMMAND_PID=$!
}

stop_process_group() {
  local group_id="$1"
  local deadline=$((SECONDS + TERMINATION_GRACE))

  kill -TERM -- "-$group_id" 2>/dev/null || true
  while process_group_is_running "$group_id" && (( SECONDS < deadline )); do
    sleep 0.2
  done
  if process_group_is_running "$group_id"; then
    kill -KILL -- "-$group_id" 2>/dev/null || true
  fi

  deadline=$((SECONDS + TERMINATION_GRACE))
  while process_is_running "$group_id" && (( SECONDS < deadline )); do
    sleep 0.1
  done
  if process_is_running "$group_id"; then
    echo "error: process group leader $group_id survived TERM and KILL" >&2
    return 1
  fi

  # A dead or zombie group leader is safe to reap without an unbounded wait.
  set +e
  wait "$group_id" 2>/dev/null
  ATTEMPT_STATUS=$?
  set -e

  while process_group_is_running "$group_id" && (( SECONDS < deadline )); do
    sleep 0.1
  done
  if process_group_is_running "$group_id"; then
    echo "error: process group $group_id survived TERM and KILL" >&2
    return 1
  fi
}

run_command_attempt() {
  local log_file="$1"
  shift
  local started_at now last_heartbeat last_progress current_mtime

  : > "$log_file"
  started_at="$(date +%s)"
  last_heartbeat="$started_at"
  last_progress="$started_at"
  current_mtime=0
  ATTEMPT_HUNG=0

  start_process_group "$log_file" "$@" \
    -destination "platform=iOS Simulator,id=$SIM_UDID" \
    -derivedDataPath "$DERIVED_DATA"

  while process_is_running "$COMMAND_PID"; do
    sleep "$POLL_INTERVAL"
    if ! process_is_running "$COMMAND_PID"; then
      break
    fi
    now="$(date +%s)"
    current_mtime="$(stat -f %m "$log_file" 2>/dev/null || echo 0)"
    if (( current_mtime > last_progress )); then
      last_progress="$current_mtime"
    fi
    if (( now - last_heartbeat >= 60 )); then
      local log_size
      log_size="$(stat -f %z "$log_file" 2>/dev/null || echo 0)"
      echo "[ci-simulator] heartbeat: elapsed=$((now - started_at))s idle=$((now - last_progress))s log=${log_size}B pid=$COMMAND_PID" >&2
      last_heartbeat="$now"
    fi
    if (( SILENCE_TIMEOUT > 0 && now - last_progress >= SILENCE_TIMEOUT )); then
      echo "[ci-simulator] hang detected: no log growth for ${SILENCE_TIMEOUT}s" >&2
      ATTEMPT_HUNG=1
      stop_process_group "$COMMAND_PID" \
        || die "hung xcodebuild process group could not be terminated"
      break
    fi
  done

  if (( ATTEMPT_HUNG == 0 )); then
    set +e
    wait "$COMMAND_PID"
    ATTEMPT_STATUS=$?
    set -e
  fi
  COMMAND_PID=""
}

reboot_existing_simulator() {
  echo "[ci-simulator] Rebooting existing simulator $SIM_UDID without erasing it" >&2
  run_simctl_bounded "$CONTROL_TIMEOUT" shutdown "$SIM_UDID" >/dev/null 2>&1 \
    || die "existing simulator $SIM_UDID failed to shut down within ${CONTROL_TIMEOUT}s"
  run_simctl_bounded "$CONTROL_TIMEOUT" boot "$SIM_UDID" >/dev/null 2>&1 \
    || die "existing simulator $SIM_UDID failed to start reboot within ${CONTROL_TIMEOUT}s"
}

restart_existing_simulator() {
  reboot_existing_simulator
  wait_for_boot_ready "$SIM_UDID" \
    || die "existing simulator $SIM_UDID failed to reboot within ${BOOT_TIMEOUT}s"
}

cleanup() {
  if [[ -n "$COMMAND_PID" ]] && process_group_is_running "$COMMAND_PID"; then
    stop_process_group "$COMMAND_PID" || true
  fi
  if [[ "$BOOTED_BY_SCRIPT" == "1" && -n "$SIM_UDID" ]]; then
    echo "[ci-simulator] Shutting down simulator $SIM_UDID" >&2
    run_simctl_bounded "$CONTROL_TIMEOUT" shutdown "$SIM_UDID" >/dev/null 2>&1 || true
  fi
}

write_summary() {
  local path="$1"
  local runtime="$2"
  local state="$3"
  local log_file="$4"
  local started_at="$5"
  local ended_at="$6"
  local exit_code="$7"
  local attempt_count="$8"
  local hang_detected="$9"
  local boot_wait_attempts="${10}"
  local boot_wait_timeout="${11}"
  local boot_ready="${12}"
  local phase="${13}"

  python3 - "$path" "$runtime" "$DEVICE_NAME" "$SIM_UDID" "$state" \
    "$DERIVED_DATA" "$log_file" "$started_at" "$ended_at" "$exit_code" \
    "$attempt_count" "$hang_detected" "$boot_wait_attempts" "$boot_wait_timeout" "$boot_ready" "$phase" <<'PY'
import json
import sys

(
    path,
    runtime,
    device_name,
    udid,
    initial_state,
    derived_data,
    log_file,
    started_at,
    ended_at,
    exit_code,
    attempt_count,
    hang_detected,
    boot_wait_attempts,
    boot_wait_timeout,
    boot_ready,
    phase,
) = sys.argv[1:]

payload = {
    "scope": "ci-simulator",
    "runtime": runtime,
    "device_name": device_name,
    "simulator_udid": udid,
    "initial_state": initial_state,
    "derived_data_path": derived_data,
    "log_path": log_file,
    "started_at_epoch": int(started_at),
    "ended_at_epoch": int(ended_at),
    "elapsed_seconds": int(ended_at) - int(started_at),
    "attempt_count": int(attempt_count),
    "hang_detected": hang_detected == "1",
    "boot_wait_attempts": int(boot_wait_attempts),
    "boot_wait_timeout_seconds": int(boot_wait_timeout),
    "boot_ready": boot_ready == "1",
    "phase": phase,
    "xcodebuild_started": phase == "xcodebuild",
    "exit_code": int(exit_code),
}
with open(path, "w", encoding="utf-8") as file:
    json.dump(payload, file, indent=2)
    file.write("\n")
PY
}

case "${1:-}" in
  self-test)
    [[ $# -eq 1 ]] || usage
    run_self_test
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
[[ "$(basename -- "$1")" == "xcodebuild" ]] \
  || die "run requires xcodebuild as the command"

case "$BOOT_TIMEOUT" in
  ''|*[!0-9]*) die "invalid OPPI_CI_SIM_BOOT_TIMEOUT '$BOOT_TIMEOUT' (expected positive integer)" ;;
esac
(( BOOT_TIMEOUT > 0 )) \
  || die "invalid OPPI_CI_SIM_BOOT_TIMEOUT '$BOOT_TIMEOUT' (expected positive integer)"
for setting in SILENCE_TIMEOUT HANG_RETRIES; do
  value="${!setting}"
  case "$value" in
    ''|*[!0-9]*) die "invalid OPPI_CI_SIM_${setting} '$value' (expected non-negative integer)" ;;
  esac
done
for setting in POLL_INTERVAL TERMINATION_GRACE CONTROL_TIMEOUT; do
  value="${!setting}"
  case "$value" in
    ''|*[!0-9]*) die "invalid OPPI_CI_SIM_${setting} '$value' (expected positive integer)" ;;
  esac
  (( value > 0 )) \
    || die "invalid OPPI_CI_SIM_${setting} '$value' (expected positive integer)"
done
case "$RETRY_DEADLINE" in
  ''|*[!0-9]*) die "invalid OPPI_CI_SIM_RETRY_DEADLINE '$RETRY_DEADLINE' (expected non-negative integer)" ;;
esac

for argument in "$@"; do
  case "$argument" in
    -destination|-derivedDataPath|-destination=*|-derivedDataPath=*)
      die "do not pass ${argument%%=*}; ci-simulator.sh selects an existing destination and DerivedData path"
      ;;
  esac
done

RUNTIME="${OPPI_CI_SIM_RUNTIME:-$(runtime_for_active_xcode)}"
DEVICES_JSON="$(mktemp -t oppi-ci-simulators.XXXXXX.json)"
trap 'rm -f "$DEVICES_JSON"; cleanup' EXIT
xcrun simctl list devices available -j > "$DEVICES_JSON"

if ! SELECTION="$(select_existing_simulator "$DEVICES_JSON" "$RUNTIME" "$DEVICE_NAME")"; then
  echo "No existing '$DEVICE_NAME' simulator is available for $RUNTIME." >&2
  echo "Available iOS simulators:" >&2
  print_available_ios_simulators "$DEVICES_JSON" >&2
  exit 2
fi

IFS=$'\t' read -r SIM_UDID INITIAL_STATE <<< "$SELECTION"
echo "[ci-simulator] Using existing $DEVICE_NAME on $RUNTIME ($SIM_UDID, $INITIAL_STATE)" >&2

mkdir -p "$LOG_DIR" "$DERIVED_DATA"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BASE_LOG_FILE="$LOG_DIR/ci-$TIMESTAMP.log"
SUMMARY_FILE="$LOG_DIR/ci-$TIMESTAMP.summary.json"
LOG_FILE="${BASE_LOG_FILE%.log}-boot-readiness.log"
: > "$LOG_FILE"
STARTED_AT="$(date +%s)"
ATTEMPT=0
COMMAND_STATUS=0
FINAL_HUNG=0

case "$INITIAL_STATE" in
  Booted|Booting)
    ;;
  Shutdown)
    run_simctl_bounded "$CONTROL_TIMEOUT" boot "$SIM_UDID" >/dev/null 2>&1 \
      || die "existing simulator $SIM_UDID failed to start boot within ${CONTROL_TIMEOUT}s"
    BOOTED_BY_SCRIPT=1
    ;;
  *)
    die "existing simulator $SIM_UDID has unsupported state '$INITIAL_STATE'"
    ;;
esac
if wait_for_boot_ready_with_retries "$SIM_UDID"; then
  :
else
  COMMAND_STATUS=$?
  ENDED_AT="$(date +%s)"
  write_summary \
    "$SUMMARY_FILE" "$RUNTIME" "$INITIAL_STATE" "$LOG_FILE" \
    "$STARTED_AT" "$ENDED_AT" "$COMMAND_STATUS" 0 0 \
    "$BOOT_WAIT_ATTEMPTS" "$BOOT_TIMEOUT" "$BOOT_READY" "boot-readiness"
  echo "[ci-simulator] Summary: $SUMMARY_FILE" >&2
  echo "[ci-simulator] Boot readiness: ${BOOT_WAIT_ATTEMPTS}/$((BOOT_RETRIES + 1)) waits, ${BOOT_TIMEOUT}s each, ready=${BOOT_READY}" >&2
  echo "[ci-simulator] Boot readiness failed before xcodebuild started; empty log: $LOG_FILE" >&2
  die "existing simulator $SIM_UDID failed to reach boot-ready state after ${BOOT_WAIT_ATTEMPTS}/$((BOOT_RETRIES + 1)) readiness waits of ${BOOT_TIMEOUT}s"
fi

echo "[ci-simulator] DerivedData: $DERIVED_DATA" >&2

while :; do
  LOG_FILE="$BASE_LOG_FILE"
  if (( ATTEMPT > 0 )); then
    LOG_FILE="${BASE_LOG_FILE%.log}-retry${ATTEMPT}.log"
  fi
  echo "[ci-simulator] Attempt $((ATTEMPT + 1))/$((HANG_RETRIES + 1)) log: $LOG_FILE" >&2

  build_attempt_command "$ATTEMPT" "$@"
  run_command_attempt "$LOG_FILE" "${ATTEMPT_COMMAND[@]}"
  COMMAND_STATUS="$ATTEMPT_STATUS"
  if (( ATTEMPT_HUNG == 1 )); then
    FINAL_HUNG=1
  fi

  if (( ATTEMPT_HUNG == 1 && ATTEMPT < HANG_RETRIES )); then
    elapsed_before_retry=$(($(date +%s) - STARTED_AT))
    if ! retry_deadline_allows "$elapsed_before_retry"; then
      echo "[ci-simulator] Retry skipped: elapsed ${elapsed_before_retry}s reached the ${RETRY_DEADLINE}s retry deadline" >&2
    else
      ATTEMPT=$((ATTEMPT + 1))
      restart_existing_simulator
      continue
    fi
  fi
  break
done

ENDED_AT="$(date +%s)"
write_summary \
  "$SUMMARY_FILE" "$RUNTIME" "$INITIAL_STATE" "$LOG_FILE" \
  "$STARTED_AT" "$ENDED_AT" "$COMMAND_STATUS" "$((ATTEMPT + 1))" "$FINAL_HUNG" \
  "$BOOT_WAIT_ATTEMPTS" "$BOOT_TIMEOUT" "$BOOT_READY" "xcodebuild"

echo "[ci-simulator] Summary: $SUMMARY_FILE" >&2
echo "[ci-simulator] Boot readiness: ${BOOT_WAIT_ATTEMPTS}/$((BOOT_RETRIES + 1)) waits, ${BOOT_TIMEOUT}s each, ready=${BOOT_READY}" >&2
if [[ "$COMMAND_STATUS" -eq 0 ]]; then
  echo "========== CI BUILD SUCCEEDED =========="
  grep -E '^\*\* (TEST|TEST BUILD) SUCCEEDED \*\*|Test run with [0-9]+ tests' "$LOG_FILE" \
    | tail -10 || true
else
  echo "========== CI BUILD FAILED (status $COMMAND_STATUS, hang=$FINAL_HUNG) ==========" >&2
  print_failure_diagnostics "$LOG_FILE"
  echo "Last 200 log lines:" >&2
  tail -200 "$LOG_FILE" >&2
fi

exit "$COMMAND_STATUS"

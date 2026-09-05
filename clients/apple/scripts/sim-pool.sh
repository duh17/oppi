#!/usr/bin/env bash
# Simulator pool for parallel agent xcodebuild runs.
# Provides slot-based locking so multiple agents can build/test concurrently
# without simulator collisions.
#
# Usage:
#   ./sim-pool.sh run -- xcodebuild -project Oppi.xcodeproj -scheme Oppi build
#   ./sim-pool.sh run -- xcodebuild -project Oppi.xcodeproj -scheme OppiUnitTests test -only-testing:OppiTests
#   ./sim-pool.sh prune-cache
#   ./sim-pool.sh prune-cache --apply
#   From the repo root: ./scripts/sim-pool.sh ...  or  clients/apple/scripts/sim-pool.sh ...
#
# The script auto-injects -destination and -derivedDataPath — do NOT pass your own.
# On build failure, prints a deduped error summary with the full log path.
#
# Guardrail:
#   Unit tests must use the OppiUnitTests scheme. The full Oppi scheme also
#   builds UI/E2E/perf bundles, which looks like a hung unit-test run.
#
# Environment:
#   OPPI_SIM_POOL_COUNT              Number of pool slots to consider (default: 8)
#   OPPI_SIM_POOL_SLOT_START         First pool slot index to consider (default: 0; OPPI_SIM_POOL_SLOT_OFFSET alias)
#   OPPI_SIM_DEVICE_TYPE             com.apple.CoreSimulator.SimDeviceType identifier (default: iPhone-16-Pro)
#   OPPI_SIM_RUNTIME                 com.apple.CoreSimulator.SimRuntime identifier (auto-detected)
#   OPPI_SIM_POOL_WAIT               Max seconds to wait for a free slot (default: 60)
#   OPPI_SIM_POOL_BOOT_TIMEOUT       Seconds per simulator boot-readiness wait (default: 120)
#   OPPI_SIM_POOL_BOOT_RETRIES       Additional readiness waits before failing (default: 1)
#   OPPI_SIM_POOL_SILENCE_TIMEOUT    Max seconds with no log/DerivedData growth before declaring a hang (default: 180)
#   OPPI_SIM_POOL_HEARTBEAT_INTERVAL Seconds between progress heartbeats (default: 60)
#   OPPI_SIM_POOL_HANG_RETRIES       Retry count after a silent hang with simulator reset (default: 1)
#   OPPI_SIM_POOL_KEEP_BOOTED        Keep pool simulator booted after run (default: 1)
#   OPPI_SIM_POOL_FORCE_CLEAN_BOOT   Recycle the simulator even if it is already booted (default: 0)
#   OPPI_SIM_SLIM                    Disable unused simulator daemons after boot (default: 1)
#   OPPI_SIM_POOL_SLIM               Compatibility alias for OPPI_SIM_SLIM
#   OPPI_SIM_POOL_INDEX_STORE        Set 1 to keep compiler index store enabled (default: 0, injects COMPILER_INDEX_STORE_ENABLE=NO)
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
OPPI_ROOT_FROM_ENV=0
if [[ -n "${OPPI_ROOT:-}" ]]; then
  OPPI_ROOT_FROM_ENV=1
else
  _git_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -n "$_git_root" && -d "$_git_root/clients/apple" ]]; then
    OPPI_ROOT="$_git_root"
  else
    OPPI_ROOT="${PIOS_ROOT:-$HOME/workspace/oppi}"
  fi
fi
APPLE_DIR="$OPPI_ROOT/clients/apple"

POOL_COUNT="${OPPI_SIM_POOL_COUNT:-8}"
POOL_SLOT_START="${OPPI_SIM_POOL_SLOT_START:-${OPPI_SIM_POOL_SLOT_OFFSET:-0}}"
DEVICE_TYPE="${OPPI_SIM_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro}"
LOCK_DIR="${OPPI_SIM_POOL_LOCK_DIR:-/tmp/oppi-sim-pool}"
BUILD_BASE="$APPLE_DIR/.build"
BOOT_TIMEOUT="${OPPI_SIM_POOL_BOOT_TIMEOUT:-120}"
BOOT_RETRIES="${OPPI_SIM_POOL_BOOT_RETRIES:-1}"
SILENCE_TIMEOUT="${OPPI_SIM_POOL_SILENCE_TIMEOUT:-180}"
HEARTBEAT_INTERVAL="${OPPI_SIM_POOL_HEARTBEAT_INTERVAL:-60}"
HANG_RETRIES="${OPPI_SIM_POOL_HANG_RETRIES:-1}"

# ── Helpers ──

die() { echo "error: $*" >&2; exit 1; }
# shellcheck source=sim-slim.sh
source "$SCRIPT_DIR/sim-slim.sh"

validate_pool_config() {
  case "$POOL_COUNT" in
    ''|*[!0-9]*) die "invalid OPPI_SIM_POOL_COUNT '$POOL_COUNT' (expected positive integer)" ;;
  esac
  (( POOL_COUNT > 0 )) || die "invalid OPPI_SIM_POOL_COUNT '$POOL_COUNT' (expected positive integer)"

  case "$POOL_SLOT_START" in
    ''|*[!0-9]*) die "invalid OPPI_SIM_POOL_SLOT_START '$POOL_SLOT_START' (expected non-negative integer)" ;;
  esac

  case "$BOOT_RETRIES" in
    ''|*[!0-9]*) die "invalid OPPI_SIM_POOL_BOOT_RETRIES '$BOOT_RETRIES' (expected non-negative integer)" ;;
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

max_mtime() {
  local latest=0 mtime path
  for path in "$@"; do
    [[ -e "$path" ]] || continue
    mtime=$(file_mtime "$path")
    if (( mtime > latest )); then
      latest="$mtime"
    fi
  done
  echo "$latest"
}

progress_mtime() {
  local log_file="$1"
  local derived_data="${2:-}"
  if [[ -n "$derived_data" ]]; then
    max_mtime "$log_file" "$derived_data/Build" "$derived_data/Index.noindex" "$derived_data/ModuleCache.noindex"
  else
    file_mtime "$log_file"
  fi
}

command_has_build_setting() {
  local key="$1"
  shift
  local arg
  for arg in "$@"; do
    case "$arg" in
      "${key}="*) return 0 ;;
    esac
  done
  return 1
}

# Fills APPLY_POOL_SETTINGS with extra xcodebuild settings for pool runs.
apply_pool_build_settings() {
  APPLY_POOL_SETTINGS=()
  if [[ "${OPPI_SIM_POOL_INDEX_STORE:-0}" == "1" ]]; then
    return 0
  fi
  if command_has_build_setting COMPILER_INDEX_STORE_ENABLE "$@"; then
    return 0
  fi
  APPLY_POOL_SETTINGS+=(COMPILER_INDEX_STORE_ENABLE=NO)
}

simulator_state() {
  local udid="$1"
  xcrun simctl list devices -j | python3 -c "
import json, sys
udid = sys.argv[1]
data = json.load(sys.stdin)
for devices in data.get('devices', {}).values():
    for device in devices:
        if device.get('udid') == udid:
            print(device.get('state', ''))
            raise SystemExit(0)
" "$udid"
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

extract_compiler_linker_errors() {
  local log_file="$1"
  grep -E '^([^:]+):[0-9]+:[0-9]+: (fatal )?error:|^[[:space:]]*(error:|clang: error:|swiftc: error:|ld: )' "$log_file" 2>/dev/null | sort -u || true
}

extract_build_timing_summary() {
  local log_file="$1"
  awk '
    /^Build Timing Summary$/ { capturing = 1; print; next }
    capturing && NF > 0 { print; saw_row = 1; next }
    capturing && saw_row { exit }
  ' "$log_file" 2>/dev/null || true
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

  local fixture errors diagnostic build_timing
  fixture="$(mktemp -t oppi-sim-pool-errors.XXXXXX.log)"
  cat > "$fixture" <<'EOF'
--- xcodebuild: WARNING: Using the first of multiple matching destinations:
2026-08-01 10:19:05.934244+0000 Oppi[46329:117234] [LoadSession] full rebuild: 2 events → 2 items
/Users/runner/work/oppi/Foo.swift:12:7: error: cannot find 'missing' in scope
Sources/parser.c:8:2: error: expected expression
error: emit-module command failed with exit code 1
clang: error: linker command failed with exit code 1
ld: symbol(s) not found for architecture arm64
swiftc: error: unexpected input file

Build Timing Summary

SwiftCompile (33 tasks) | 1084.000 seconds
Ld (8 tasks) | 12.000 seconds

Test Suite 'All tests' started.
EOF
  errors="$(extract_compiler_linker_errors "$fixture")"
  build_timing="$(extract_build_timing_summary "$fixture")"
  rm -f "$fixture"

  [[ "$build_timing" == *"SwiftCompile (33 tasks) | 1084.000 seconds"* ]] \
    || die "self-test: Xcode build timing summary was not extracted"
  [[ "$build_timing" != *"Test Suite"* ]] \
    || die "self-test: build timing extraction included test output"
  [[ "$errors" != *"xcodebuild:"* ]] \
    || die "self-test: xcodebuild application text was classified as a linker error"
  [[ "$errors" != *"rebuild:"* ]] \
    || die "self-test: rebuild application log was classified as a linker error"
  for diagnostic in \
    "/Users/runner/work/oppi/Foo.swift:12:7: error: cannot find 'missing' in scope" \
    "Sources/parser.c:8:2: error: expected expression" \
    "error: emit-module command failed with exit code 1" \
    "clang: error: linker command failed with exit code 1" \
    "ld: symbol(s) not found for architecture arm64" \
    "swiftc: error: unexpected input file"; do
    grep -Fqx "$diagnostic" <<<"$errors" \
      || die "self-test: real compiler/linker diagnostic was not classified: $diagnostic"
  done

  if (BOOT_RETRIES="invalid"; validate_pool_config) >/dev/null 2>&1; then
    die "self-test: invalid boot retry count was accepted"
  fi

  (
    local boot_wait_attempts=0
    BOOT_RETRIES=1
    wait_for_boot_ready() {
      boot_wait_attempts=$((boot_wait_attempts + 1))
      (( boot_wait_attempts >= 2 ))
    }
    wait_for_boot_ready_with_retries "self-test-udid" \
      || die "self-test: simulator readiness did not recover on the bounded retry"
    [[ "$boot_wait_attempts" -eq 2 ]] \
      || die "self-test: simulator readiness retry used $boot_wait_attempts attempts instead of 2"

    boot_wait_attempts=0
    wait_for_boot_ready() {
      boot_wait_attempts=$((boot_wait_attempts + 1))
      return 124
    }
    if wait_for_boot_ready_with_retries "self-test-udid"; then
      die "self-test: exhausted simulator readiness waits reported success"
    fi
    [[ "$boot_wait_attempts" -eq 2 ]] \
      || die "self-test: exhausted simulator readiness used $boot_wait_attempts attempts instead of 2"
  )

  local progress_dir log_file derived_dir
  progress_dir="$(mktemp -d -t oppi-sim-pool-progress.XXXXXX)"
  log_file="$progress_dir/build.log"
  derived_dir="$progress_dir/derived"
  mkdir -p "$derived_dir/Build"
  : > "$log_file"
  sleep 1
  : > "$derived_dir/Build/stamp"
  [[ "$(progress_mtime "$log_file" "$derived_dir")" -ge "$(file_mtime "$derived_dir/Build")" ]] \
    || die "self-test: hang progress did not observe DerivedData mtime"
  rm -rf "$progress_dir"

  (
    local boot_calls=0 shutdown_calls=0 slim_calls=0
    simulator_state() { echo Booted; }
    wait_for_boot_ready_with_retries() { return 0; }
    slim_simulator() { slim_calls=$((slim_calls + 1)); }
    xcrun() {
      case "$1 $2" in
        "simctl shutdown") shutdown_calls=$((shutdown_calls + 1)) ;;
        "simctl boot") boot_calls=$((boot_calls + 1)) ;;
      esac
    }
    prepare_simulator "self-test-udid" normal
    [[ "$boot_calls" -eq 0 && "$shutdown_calls" -eq 0 && "$slim_calls" -eq 1 ]] \
      || die "self-test: already-booted simulator was recycled (boot=$boot_calls shutdown=$shutdown_calls slim=$slim_calls)"
  )

  (
    local boot_calls=0 shutdown_calls=0 slim_calls=0
    OPPI_SIM_POOL_FORCE_CLEAN_BOOT=1
    simulator_state() { echo Booted; }
    wait_for_boot_ready_with_retries() { return 0; }
    slim_simulator() { slim_calls=$((slim_calls + 1)); }
    xcrun() {
      case "$1 $2" in
        "simctl shutdown") shutdown_calls=$((shutdown_calls + 1)) ;;
        "simctl boot") boot_calls=$((boot_calls + 1)) ;;
      esac
    }
    prepare_simulator "self-test-udid" normal
    [[ "$boot_calls" -eq 1 && "$shutdown_calls" -eq 1 && "$slim_calls" -eq 1 ]] \
      || die "self-test: FORCE_CLEAN_BOOT did not recycle (boot=$boot_calls shutdown=$shutdown_calls slim=$slim_calls)"
  )

  grep -qx 'com.apple.PosterBoard' "$SCRIPT_DIR/sim-pool-slim-labels.txt" \
    || die "self-test: slim label list is missing PosterBoard"
  for keep_label in \
    com.apple.chronod \
    com.apple.liveactivitiesd \
    com.apple.corespeechd \
    com.apple.voiced \
    com.apple.assetsd \
    com.apple.apsd \
    com.apple.swcd \
    com.apple.mobileassetd; do
    if grep -qx "$keep_label" "$SCRIPT_DIR/sim-pool-slim-labels.txt"; then
      die "self-test: slim label list disables kept daemon $keep_label"
    fi
  done

  (
    local spawn_calls=0
    OPPI_SIM_POOL_SLIM=0
    xcrun() { spawn_calls=$((spawn_calls + 1)); }
    slim_simulator "self-test-udid"
    [[ "$spawn_calls" -eq 0 ]] \
      || die "self-test: OPPI_SIM_POOL_SLIM=0 still spawned launchctl"
  )

  (
    local disable_calls=0 shutdown_calls=0 boot_calls=0
    wait_for_boot_ready_with_retries() { return 0; }
    xcrun() {
      case "$*" in
        "simctl spawn self-test-udid launchctl print-disabled system")
          printf '%s\n' '"com.apple.PosterBoard" => disabled'
          ;;
        *"launchctl disable "*)
          disable_calls=$((disable_calls + 1))
          ;;
        "simctl shutdown self-test-udid") shutdown_calls=$((shutdown_calls + 1)) ;;
        "simctl boot self-test-udid") boot_calls=$((boot_calls + 1)) ;;
      esac
    }
    slim_simulator "self-test-udid"
    [[ "$disable_calls" -eq 0 && "$shutdown_calls" -eq 0 && "$boot_calls" -eq 0 ]] \
      || die "self-test: already-slim simulator was reconfigured (disable=$disable_calls shutdown=$shutdown_calls boot=$boot_calls)"
  )

  (
    local disable_file shutdown_calls=0 boot_calls=0 disable_calls=0
    disable_file=$(mktemp -t oppi-sim-pool-slim-disable.XXXXXX)
    wait_for_boot_ready_with_retries() { return 0; }
    xcrun() {
      case "$*" in
        "simctl spawn self-test-udid launchctl print-disabled system")
          printf '%s\n' '"com.apple.PosterBoard" => enabled'
          ;;
        *"launchctl disable "*)
          printf '%s\n' "$*" >> "$disable_file"
          ;;
        "simctl shutdown self-test-udid") shutdown_calls=$((shutdown_calls + 1)) ;;
        "simctl boot self-test-udid") boot_calls=$((boot_calls + 1)) ;;
      esac
    }
    slim_simulator "self-test-udid"
    disable_calls=$(wc -l < "$disable_file" | tr -d ' ')
    rm -f "$disable_file"
    [[ "$disable_calls" -gt 0 && "$shutdown_calls" -eq 1 && "$boot_calls" -eq 1 ]] \
      || die "self-test: stock simulator was not slimmed (disable=$disable_calls shutdown=$shutdown_calls boot=$boot_calls)"
  )

  (
    unset OPPI_SIM_POOL_INDEX_STORE || true
    apply_pool_build_settings xcodebuild test
    [[ "${APPLY_POOL_SETTINGS[*]}" == "COMPILER_INDEX_STORE_ENABLE=NO" ]] \
      || die "self-test: default pool settings did not disable index store"

    apply_pool_build_settings xcodebuild test COMPILER_INDEX_STORE_ENABLE=YES
    [[ "${#APPLY_POOL_SETTINGS[@]}" -eq 0 ]] \
      || die "self-test: explicit COMPILER_INDEX_STORE_ENABLE was overridden"

    OPPI_SIM_POOL_INDEX_STORE=1
    apply_pool_build_settings xcodebuild test
    [[ "${#APPLY_POOL_SETTINGS[@]}" -eq 0 ]] \
      || die "self-test: OPPI_SIM_POOL_INDEX_STORE=1 still injected index-store disable"
  )

  unset OPPI_SIM_POOL_ALLOW_SLOW_UNIT_TEST_SCHEME || true
  normalize_command_args xcodebuild -project Oppi.xcodeproj -scheme Oppi test -only-testing:OppiTests/Foo
  [[ "${NORMALIZED_ARGS[*]}" == *"-scheme OppiUnitTests"* ]] \
    || die "self-test: OppiTests-only Oppi scheme was not rewritten to OppiUnitTests"
  normalize_command_args xcodebuild -scheme Oppi test -only-testing:OppiE2ETests/Foo
  [[ "${NORMALIZED_ARGS[*]}" == *"-scheme Oppi "* || "${NORMALIZED_ARGS[*]}" == *"-scheme Oppi" ]] \
    || die "self-test: E2E Oppi scheme was rewritten"
  [[ "${NORMALIZED_ARGS[*]}" != *OppiUnitTests* ]] \
    || die "self-test: E2E run was rewritten to OppiUnitTests"
  normalize_command_args xcodebuild -scheme Oppi test -only-testing:OppiTests/Foo -only-testing:OppiUITests/Bar
  [[ "${NORMALIZED_ARGS[*]}" != *OppiUnitTests* ]] \
    || die "self-test: mixed OppiTests/UI scheme was rewritten"
  OPPI_SIM_POOL_ALLOW_SLOW_UNIT_TEST_SCHEME=1
  normalize_command_args xcodebuild -scheme Oppi test -only-testing:OppiTests/Foo
  [[ "${NORMALIZED_ARGS[*]}" != *OppiUnitTests* ]] \
    || die "self-test: ALLOW_SLOW override still rewrote the scheme"
  unset OPPI_SIM_POOL_ALLOW_SLOW_UNIT_TEST_SCHEME || true

  run_prune_cache_self_test

  echo "sim-pool self-test passed."
}

run_prune_cache_self_test() {
  local script="$SCRIPT_DIR/sim-pool.sh"

  init_prune_fixture() {
    local root="$1"
    git init -q "$root"
    mkdir -p "$root/clients/apple"
  }

  run_prune_cli() {
    env -u OPPI_ROOT -u PIOS_ROOT \
      OPPI_SIM_POOL_LOCK_DIR="$LOCK_DIR" \
      "$script" prune-cache "$@"
  }

  (
    local fixture lock_dir
    fixture="$(mktemp -d -t oppi-sim-pool-prune-dry.XXXXXX)"
    lock_dir="$(mktemp -d -t oppi-sim-pool-prune-dry-locks.XXXXXX)"
    trap 'rm -rf "$fixture" "$lock_dir"' EXIT
    init_prune_fixture "$fixture"
    mkdir -p "$fixture/clients/apple/.build/pool-0/DerivedData"
    mkdir -p "$fixture/clients/apple/.build/logs"
    echo cache > "$fixture/clients/apple/.build/pool-0/DerivedData/x"
    echo keep > "$fixture/clients/apple/.build/logs/summary.json"
    LOCK_DIR="$lock_dir"
    cd "$fixture"
    run_prune_cli >/dev/null \
      || die "self-test: dry-run prune-cache failed"
    [[ -d "$fixture/clients/apple/.build/pool-0/DerivedData" ]] \
      || die "self-test: dry-run deleted pool-0"
    [[ -f "$fixture/clients/apple/.build/logs/summary.json" ]] \
      || die "self-test: dry-run removed logs"
    [[ -z "$(find "$lock_dir" -mindepth 1 -maxdepth 1 2>/dev/null)" ]] \
      || die "self-test: dry-run created slot locks"
  )

  (
    local fixture lock_dir build
    fixture="$(mktemp -d -t oppi-sim-pool-prune-apply.XXXXXX)"
    lock_dir="$(mktemp -d -t oppi-sim-pool-prune-apply-locks.XXXXXX)"
    trap 'rm -rf "$fixture" "$lock_dir"' EXIT
    init_prune_fixture "$fixture"
    build="$fixture/clients/apple/.build"
    mkdir -p "$build/pool-0/DerivedData" "$build/pool-12/DerivedData" "$build/pool-foo"
    mkdir -p "$build/logs" "$build/videos" "$build/mac-tests" "$build/mac-debug" "$build/pre-push-mac" "$build/ci"
    echo cache0 > "$build/pool-0/DerivedData/x"
    echo cache12 > "$build/pool-12/DerivedData/x"
    echo keep-foo > "$build/pool-foo/keep"
    echo log > "$build/logs/summary.json"
    echo vid > "$build/videos/clip.mp4"
    echo mac > "$build/mac-tests/x"
    echo macd > "$build/mac-debug/x"
    echo prep > "$build/pre-push-mac/x"
    echo ci > "$build/ci/x"
    echo file > "$build/pool-3"
    LOCK_DIR="$lock_dir"
    cd "$fixture"
    run_prune_cli --apply >/dev/null \
      || die "self-test: apply prune-cache failed"
    [[ ! -e "$build/pool-0" ]] || die "self-test: apply left pool-0"
    [[ ! -e "$build/pool-12" ]] || die "self-test: apply left pool-12 outside the default slot range"
    [[ -f "$build/pool-foo/keep" ]] || die "self-test: apply deleted nonnumeric pool-foo"
    [[ -f "$build/logs/summary.json" ]] || die "self-test: apply deleted logs"
    [[ -f "$build/videos/clip.mp4" ]] || die "self-test: apply deleted videos"
    [[ -f "$build/mac-tests/x" ]] || die "self-test: apply deleted mac-tests"
    [[ -f "$build/mac-debug/x" ]] || die "self-test: apply deleted mac-debug"
    [[ -f "$build/pre-push-mac/x" ]] || die "self-test: apply deleted pre-push-mac"
    [[ -f "$build/ci/x" ]] || die "self-test: apply deleted ci"
    [[ -f "$build/pool-3" ]] || die "self-test: apply deleted non-directory pool-3"
    [[ -z "$(find "$lock_dir" -mindepth 1 -maxdepth 1 2>/dev/null)" ]] \
      || die "self-test: apply left slot locks behind"
  )

  (
    local fixture lock_dir
    fixture="$(mktemp -d -t oppi-sim-pool-prune-missing.XXXXXX)"
    lock_dir="$(mktemp -d -t oppi-sim-pool-prune-missing-locks.XXXXXX)"
    trap 'rm -rf "$fixture" "$lock_dir"' EXIT
    init_prune_fixture "$fixture"
    LOCK_DIR="$lock_dir"
    cd "$fixture"
    run_prune_cli --apply >/dev/null \
      || die "self-test: missing .build was not harmless"
    mkdir -p "$fixture/clients/apple/.build"
    run_prune_cli --apply >/dev/null \
      || die "self-test: empty .build was not harmless"
    [[ -d "$fixture/clients/apple/.build" ]] \
      || die "self-test: missing-dir apply removed .build"
  )

  (
    local parent fixture sibling lock_dir
    parent="$(mktemp -d -t oppi-sim-pool-prune-sib.XXXXXX)"
    lock_dir="$(mktemp -d -t oppi-sim-pool-prune-sib-locks.XXXXXX)"
    fixture="$parent/tree-a"
    sibling="$parent/tree-b"
    trap 'rm -rf "$parent" "$lock_dir"' EXIT
    mkdir -p "$fixture" "$sibling"
    init_prune_fixture "$fixture"
    init_prune_fixture "$sibling"
    mkdir -p "$fixture/clients/apple/.build/pool-0" "$sibling/clients/apple/.build/pool-0"
    echo a > "$fixture/clients/apple/.build/pool-0/x"
    echo b > "$sibling/clients/apple/.build/pool-0/x"
    LOCK_DIR="$lock_dir"
    cd "$fixture"
    run_prune_cli --apply >/dev/null \
      || die "self-test: sibling prune-cache failed"
    [[ ! -e "$fixture/clients/apple/.build/pool-0" ]] \
      || die "self-test: apply did not delete this checkout's pool-0"
    [[ -f "$sibling/clients/apple/.build/pool-0/x" ]] \
      || die "self-test: apply deleted a sibling worktree pool dir"
  )

  (
    local fixture lock_dir build real status=0
    fixture="$(mktemp -d -t oppi-sim-pool-prune-symlink-root.XXXXXX)"
    lock_dir="$(mktemp -d -t oppi-sim-pool-prune-symlink-root-locks.XXXXXX)"
    trap 'rm -rf "$fixture" "$lock_dir"' EXIT
    init_prune_fixture "$fixture"
    build="$fixture/clients/apple/.build"
    real="$fixture/real-build"
    rm -rf "$build"
    mkdir -p "$real/pool-0"
    echo cache > "$real/pool-0/x"
    ln -s "$real" "$build"
    LOCK_DIR="$lock_dir"
    cd "$fixture"
    run_prune_cli --apply >/dev/null || status=$?
    [[ "$status" -ne 0 ]] || die "self-test: symlinked cleanup root was accepted"
    [[ -f "$real/pool-0/x" ]] || die "self-test: symlinked cleanup root deleted the target"
  )

  (
    local fixture lock_dir build outside
    fixture="$(mktemp -d -t oppi-sim-pool-prune-symlink-target.XXXXXX)"
    lock_dir="$(mktemp -d -t oppi-sim-pool-prune-symlink-target-locks.XXXXXX)"
    trap 'rm -rf "$fixture" "$lock_dir"' EXIT
    init_prune_fixture "$fixture"
    build="$fixture/clients/apple/.build"
    outside="$fixture/outside-pool"
    mkdir -p "$outside" "$build/pool-1"
    echo keep > "$outside/x"
    echo gone > "$build/pool-1/x"
    ln -s "$outside" "$build/pool-0"
    LOCK_DIR="$lock_dir"
    cd "$fixture"
    run_prune_cli --apply >/dev/null \
      || die "self-test: symlink target skip failed the prune"
    [[ -L "$build/pool-0" ]] || die "self-test: pool-0 symlink was removed"
    [[ -f "$outside/x" ]] || die "self-test: symlink pool dir deleted its target"
    [[ ! -e "$build/pool-1" ]] || die "self-test: apply left a numeric pool dir after skipping a symlink"
  )

  (
    local fixture lock_dir status=0
    fixture="$(mktemp -d -t oppi-sim-pool-prune-oppi-root.XXXXXX)"
    lock_dir="$(mktemp -d -t oppi-sim-pool-prune-oppi-root-locks.XXXXXX)"
    trap 'rm -rf "$fixture" "$lock_dir"' EXIT
    init_prune_fixture "$fixture"
    mkdir -p "$fixture/clients/apple/.build/pool-0"
    echo cache > "$fixture/clients/apple/.build/pool-0/x"
    cd "$fixture"
    env PIOS_ROOT="" OPPI_ROOT="/tmp/oppi-prune-cache-other" \
      OPPI_SIM_POOL_LOCK_DIR="$lock_dir" \
      "$script" prune-cache --apply >/dev/null || status=$?
    [[ "$status" -ne 0 ]] || die "self-test: conflicting OPPI_ROOT was accepted"
    [[ -f "$fixture/clients/apple/.build/pool-0/x" ]] \
      || die "self-test: conflicting OPPI_ROOT still deleted pool dirs"
  )

  (
    local fixture lock_dir build
    fixture="$(mktemp -d -t oppi-sim-pool-prune-live-lock.XXXXXX)"
    lock_dir="$(mktemp -d -t oppi-sim-pool-prune-live-lock-locks.XXXXXX)"
    trap 'rm -rf "$fixture" "$lock_dir"' EXIT
    init_prune_fixture "$fixture"
    build="$fixture/clients/apple/.build"
    mkdir -p "$build/pool-0" "$build/pool-1"
    echo live > "$build/pool-0/x"
    echo idle > "$build/pool-1/x"
    mkdir -p "$lock_dir/slot-0"
    echo $$ > "$lock_dir/slot-0/pid"
    LOCK_DIR="$lock_dir"
    cd "$fixture"
    run_prune_cli --apply >/dev/null \
      || die "self-test: live lock skip failed the prune"
    [[ -f "$build/pool-0/x" ]] || die "self-test: live lock did not prevent pool-0 deletion"
    [[ ! -e "$build/pool-1" ]] || die "self-test: apply left an unlocked pool dir"
    [[ -f "$lock_dir/slot-0/pid" ]] || die "self-test: live lock was removed"
    [[ ! -e "$lock_dir/slot-1" ]] || die "self-test: apply left a lock for a deleted slot"
  )

  (
    local fixture lock_dir build
    fixture="$(mktemp -d -t oppi-sim-pool-prune-ambiguous.XXXXXX)"
    lock_dir="$(mktemp -d -t oppi-sim-pool-prune-ambiguous-locks.XXXXXX)"
    trap 'rm -rf "$fixture" "$lock_dir"' EXIT
    init_prune_fixture "$fixture"
    build="$fixture/clients/apple/.build"
    mkdir -p "$build/pool-0" "$build/pool-1" "$build/pool-2"
    echo a > "$build/pool-0/x"
    echo b > "$build/pool-1/x"
    echo c > "$build/pool-2/x"
    mkdir -p "$lock_dir/slot-0" "$lock_dir/slot-1"
    echo 'not-a-pid' > "$lock_dir/slot-1/pid"
    LOCK_DIR="$lock_dir"
    cd "$fixture"
    run_prune_cli --apply >/dev/null \
      || die "self-test: ambiguous lock skip failed the prune"
    [[ -f "$build/pool-0/x" ]] || die "self-test: lock without pid was treated as idle"
    [[ -f "$build/pool-1/x" ]] || die "self-test: nonnumeric lock pid was treated as idle"
    [[ ! -e "$build/pool-2" ]] || die "self-test: apply left an unambiguous idle pool dir"
  )

  (
    local fixture lock_dir build status=0
    fixture="$(mktemp -d -t oppi-sim-pool-prune-lock-fail.XXXXXX)"
    lock_dir="$(mktemp -d -t oppi-sim-pool-prune-lock-fail-locks.XXXXXX)"
    trap 'chflags -R nouchg "$fixture" 2>/dev/null || true; rm -rf "$fixture" "$lock_dir"' EXIT
    init_prune_fixture "$fixture"
    build="$fixture/clients/apple/.build"
    mkdir -p "$build/pool-0"
    echo cache > "$build/pool-0/x"
    chflags uchg "$build/pool-0"
    LOCK_DIR="$lock_dir"
    cd "$fixture"
    run_prune_cli --apply >/dev/null || status=$?
    chflags nouchg "$build/pool-0"
    [[ "$status" -ne 0 ]] || die "self-test: immutable pool dir deletion was reported as success"
    [[ -f "$build/pool-0/x" ]] || die "self-test: immutable pool dir was deleted"
    [[ -z "$(find "$lock_dir" -mindepth 1 -maxdepth 1 2>/dev/null)" ]] \
      || die "self-test: slot lock was not released after deletion failure"
  )

  unset -f init_prune_fixture run_prune_cli
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

only_testing_targets_are() {
  local bundle="$1"
  local saw=0
  shift

  for arg in "$@"; do
    case "$arg" in
      "-only-testing:${bundle}"|"-only-testing:${bundle}/"*)
        saw=1
        ;;
      -only-testing:*)
        return 1
        ;;
    esac
  done

  [[ "$saw" -eq 1 ]]
}

rewrite_scheme_in_args() {
  local old_scheme="$1"
  local new_scheme="$2"
  local previous=""
  local arg
  shift 2
  REWRITTEN_ARGS=()
  for arg in "$@"; do
    if [[ "$previous" == "-scheme" && "$arg" == "$old_scheme" ]]; then
      REWRITTEN_ARGS+=("$new_scheme")
    else
      REWRITTEN_ARGS+=("$arg")
    fi
    previous="$arg"
  done
}

ensure_apple_cwd() {
  if [[ ! -f "Oppi.xcodeproj/project.pbxproj" && -f "$SCRIPT_DIR/../Oppi.xcodeproj/project.pbxproj" ]]; then
    cd "$SCRIPT_DIR/.."
    echo "[sim-pool] Using Apple checkout $PWD" >&2
  fi
}

normalize_command_args() {
  local scheme=""
  local is_test_action=0
  local arg
  NORMALIZED_ARGS=("$@")
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
    && only_testing_targets_are "OppiTests" "$@"; then
    echo "[sim-pool] Rewriting -scheme Oppi -> OppiUnitTests for OppiTests-only run" >&2
    rewrite_scheme_in_args Oppi OppiUnitTests "$@"
    NORMALIZED_ARGS=("${REWRITTEN_ARGS[@]}")
  fi
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
    && only_testing_targets_are "OppiTests" "$@"; then
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

wait_for_boot_ready_with_retries() {
  local udid="$1"
  local attempt=0
  local status=0

  while :; do
    if wait_for_boot_ready "$udid"; then
      return 0
    else
      status=$?
    fi

    if (( attempt >= BOOT_RETRIES )); then
      return "$status"
    fi

    attempt=$((attempt + 1))
    echo "[sim-pool] Simulator is still starting after ${BOOT_TIMEOUT}s; continuing readiness wait $((attempt + 1))/$((BOOT_RETRIES + 1))" >&2
  done
}

prepare_simulator() {
  local udid="$1"
  local mode="${2:-normal}"

  if [[ "$mode" == "recovery" ]]; then
    echo "[sim-pool] Recovery: shutting down + erasing simulator $udid" >&2
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    xcrun simctl erase "$udid" >/dev/null 2>&1 || true
  elif [[ "${OPPI_SIM_POOL_FORCE_CLEAN_BOOT:-0}" == "1" ]]; then
    echo "[sim-pool] Preparing clean simulator boot for $udid" >&2
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  elif [[ "$(simulator_state "$udid")" == "Booted" ]]; then
    echo "[sim-pool] Reusing already-booted simulator $udid" >&2
    if wait_for_boot_ready_with_retries "$udid"; then
      slim_simulator "$udid"
      return 0
    fi
    echo "[sim-pool] Booted simulator was not ready; recycling $udid" >&2
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  else
    echo "[sim-pool] Preparing simulator boot for $udid" >&2
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  fi

  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  if ! wait_for_boot_ready_with_retries "$udid"; then
    die "simulator $udid failed to reach boot-ready state after $((BOOT_RETRIES + 1)) readiness waits of ${BOOT_TIMEOUT}s"
  fi
  slim_simulator "$udid"
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

canonical_path() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

try:
    print(Path(sys.argv[1]).resolve(strict=False))
except OSError:
    sys.exit(1)
PY
}

is_numeric_pool_name() {
  local base="$1"
  local slot="${base#pool-}"
  [[ "$base" == pool-* ]] || return 1
  case "$slot" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

try_acquire_prune_slot() {
  local slot="$1"
  local lock_path="$LOCK_DIR/slot-${slot}"
  mkdir -p "$LOCK_DIR" || return 1

  if mkdir "$lock_path" 2>/dev/null; then
    if ! echo $$ > "$lock_path/pid"; then
      rm -rf "$lock_path"
      return 1
    fi
    return 0
  fi

  local pid=""
  if [[ -f "$lock_path/pid" ]]; then
    pid="$(cat "$lock_path/pid" 2>/dev/null || true)"
  fi
  pid="${pid//$'\n'/}"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac

  if kill -0 "$pid" 2>/dev/null; then
    return 1
  fi

  echo "[sim-pool] prune-cache: reaping stale lock for slot $slot (PID $pid dead)" >&2
  rm -rf "$lock_path"
  if mkdir "$lock_path" 2>/dev/null; then
    if ! echo $$ > "$lock_path/pid"; then
      rm -rf "$lock_path"
      return 1
    fi
    return 0
  fi
  return 1
}

resolve_prune_cache_root() {
  local git_root
  git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$git_root" ]] || die "prune-cache requires a Git checkout"
  [[ -d "$git_root/clients/apple" ]] || die "prune-cache: checkout is missing clients/apple"

  if [[ "${OPPI_ROOT_FROM_ENV:-0}" == "1" ]]; then
    local env_canon git_canon
    env_canon="$(canonical_path "$OPPI_ROOT")" || die "prune-cache: OPPI_ROOT is not resolvable"
    git_canon="$(canonical_path "$git_root")" || die "prune-cache: git checkout is not resolvable"
    if [[ "$env_canon" != "$git_canon" ]]; then
      die "prune-cache: OPPI_ROOT '$OPPI_ROOT' does not match Git checkout '$git_root'"
    fi
  fi

  PRUNE_CHECKOUT="$git_root"
  PRUNE_APPLE_DIR="$git_root/clients/apple"
  PRUNE_BUILD_BASE="$PRUNE_APPLE_DIR/.build"
}

prune_cache() {
  local apply=0
  case "${1:-}" in
    "")
      ;;
    --apply)
      apply=1
      [[ -z "${2:-}" ]] || die "usage: sim-pool.sh prune-cache [--apply]"
      ;;
    *)
      die "usage: sim-pool.sh prune-cache [--apply]"
      ;;
  esac

  resolve_prune_cache_root

  if [[ -L "$PRUNE_CHECKOUT" || -L "$PRUNE_APPLE_DIR" || -L "$PRUNE_BUILD_BASE" ]]; then
    die "prune-cache: refusing symlinked cleanup root"
  fi

  if [[ ! -e "$PRUNE_BUILD_BASE" ]]; then
    echo "[sim-pool] prune-cache: no $PRUNE_BUILD_BASE" >&2
    return 0
  fi
  if [[ ! -d "$PRUNE_BUILD_BASE" ]]; then
    die "prune-cache: cleanup root is not a directory: $PRUNE_BUILD_BASE"
  fi

  if (( apply == 0 )); then
    echo "[sim-pool] prune-cache: dry-run (pass --apply to delete numeric pool dirs; next build recompiles)" >&2
  fi

  local path base slot parent status=0
  for path in "$PRUNE_BUILD_BASE"/pool-*; do
    [[ -e "$path" ]] || continue
    base="${path##*/}"
    is_numeric_pool_name "$base" || continue
    parent="$(dirname "$path")"
    [[ "$parent" == "$PRUNE_BUILD_BASE" ]] || continue
    slot="${base#pool-}"

    if [[ -L "$path" ]]; then
      echo "[sim-pool] prune-cache: skipping symlinked $path" >&2
      continue
    fi
    if [[ ! -d "$path" ]]; then
      echo "[sim-pool] prune-cache: skipping non-directory $path" >&2
      continue
    fi

    if (( apply == 0 )); then
      echo "[sim-pool] prune-cache: would delete $path" >&2
      continue
    fi

    if ! try_acquire_prune_slot "$slot"; then
      echo "[sim-pool] prune-cache: skipping busy or ambiguous slot $slot" >&2
      continue
    fi

    echo "[sim-pool] prune-cache: deleting $path" >&2
    if rm -rf "$path" && [[ ! -e "$path" ]]; then
      release_slot "$slot"
      continue
    fi

    echo "[sim-pool] prune-cache: failed to delete $path" >&2
    release_slot "$slot"
    status=1
  done

  return "$status"
}

cleanup_run() {
  stop_video_recording
  if [[ -n "${SIM_UDID:-}" && "${OPPI_SIM_POOL_KEEP_BOOTED:-1}" != "1" ]]; then
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

  local build_timing_summary
  build_timing_summary=$(extract_build_timing_summary "$log_file")
  if [[ -n "$build_timing_summary" ]]; then
    echo ""
    echo "$build_timing_summary"
  fi

  if [[ "$hang_detected" == "1" ]]; then
    echo "Hang detection: triggered (no log or DerivedData growth for ${SILENCE_TIMEOUT}s)"
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
    errors=$(extract_compiler_linker_errors "$log_file")
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

  apply_pool_build_settings "$@"

  set +e
  if [[ "${#APPLY_POOL_SETTINGS[@]}" -gt 0 ]]; then
    "$@" \
      "${APPLY_POOL_SETTINGS[@]}" \
      -destination "platform=iOS Simulator,id=$SIM_UDID" \
      -derivedDataPath "$DERIVED_DATA" \
      > "$log_file" 2>&1 &
  else
    "$@" \
      -destination "platform=iOS Simulator,id=$SIM_UDID" \
      -derivedDataPath "$DERIVED_DATA" \
      > "$log_file" 2>&1 &
  fi
  local xcode_pid=$!
  set -e

  while kill -0 "$xcode_pid" 2>/dev/null; do
    sleep 5

    local now
    now=$(now_epoch)
    local current_mtime
    current_mtime=$(progress_mtime "$log_file" "${DERIVED_DATA:-}")
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
      echo "[sim-pool] hang detected: no log or DerivedData growth for ${SILENCE_TIMEOUT}s (pid $xcode_pid)" >&2
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
  sim-pool.sh prune-cache [--apply]

run acquires a simulator pool slot, injects -destination and -derivedDataPath,
runs xcodebuild, and releases the slot on exit. An already-booted pool
simulator is reused unless OPPI_SIM_POOL_FORCE_CLEAN_BOOT=1. Pool simulators
stay booted after a run unless OPPI_SIM_POOL_KEEP_BOOTED=0. Unused simulator
daemons are disabled unless OPPI_SIM_SLIM=0. Compiler index store is
disabled unless OPPI_SIM_POOL_INDEX_STORE=1 or the command already sets
COMPILER_INDEX_STORE_ENABLE.

status prints pool locks, pool devices, build-cache sizes, and recent run timing.
shutdown-idle shuts down Oppi-Pool simulators that do not have a live lock.
prune-cache dry-runs deletion of this checkout's numeric clients/apple/.build/pool-*
directories. Pass --apply to delete them. Live or ambiguous slot locks are skipped.
The next simulator build in that tree recompiles DerivedData from scratch.

Do NOT pass -destination or -derivedDataPath — they are auto-injected.
Use '-scheme OppiUnitTests' for OppiTests unit-test runs.

Pool selection:
  OPPI_SIM_POOL_COUNT=N       Number of slots to consider from the start slot.
  OPPI_SIM_POOL_SLOT_START=N  First slot index to consider; default 0.
  OPPI_SIM_DEVICE_TYPE=TYPE   Device type used when creating a missing slot.

Example iPad lane:
  OPPI_SIM_POOL_SLOT_START=8 OPPI_SIM_POOL_COUNT=1 \
  OPPI_SIM_DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB \
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
  prune-cache)
    shift
    prune_cache "$@"
    exit $?
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

ensure_apple_cwd
normalize_command_args "$@"
set -- "${NORMALIZED_ARGS[@]}"

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

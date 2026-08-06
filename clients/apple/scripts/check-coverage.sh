#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${OPPI_ROOT:-${PIOS_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)}}"
IOS_DIR="$REPO_ROOT/clients/apple"

PACKAGE_CACHE_ROOT="${OPPI_SWIFT_PACKAGE_CACHE_ROOT:-}"
SIMULATOR_RUNNER="${OPPI_SIMULATOR_RUNNER:-local}"

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

package_cache_is_safe_to_reset() {
  [[ -n "$PACKAGE_CACHE_ROOT" ]] || return 1

  local candidate ios_build runner_temp
  candidate="$(canonical_path "$PACKAGE_CACHE_ROOT")" || return 1
  ios_build="$(canonical_path "$IOS_DIR/.build")" || return 1
  if [[ "$candidate" == "$ios_build/"* ]]; then
    return 0
  fi

  [[ -n "${RUNNER_TEMP:-}" ]] || return 1
  runner_temp="$(canonical_path "$RUNNER_TEMP")" || return 1
  [[ "$candidate" == "$runner_temp/"* ]]
}

validate_simulator_runner() {
  local runner_script
  case "$SIMULATOR_RUNNER" in
    local)
      runner_script="$SCRIPT_DIR/sim-pool.sh"
      ;;
    ci)
      runner_script="$SCRIPT_DIR/ci-simulator.sh"
      ;;
    *)
      echo "Unknown OPPI_SIMULATOR_RUNNER '$SIMULATOR_RUNNER' (expected local or ci)." >&2
      return 8
      ;;
  esac

  if [[ ! -r "$runner_script" ]]; then
    echo "Simulator runner script is missing or unreadable: $runner_script" >&2
    return 8
  fi
}

run_self_test() {
  if ! (PACKAGE_CACHE_ROOT="$IOS_DIR/.build/swiftpm-cache"; RUNNER_TEMP=""; package_cache_is_safe_to_reset); then
    echo "self-test: rejected a cache below the Apple .build directory" >&2
    return 1
  fi
  if (PACKAGE_CACHE_ROOT="$IOS_DIR/.build"; RUNNER_TEMP=""; package_cache_is_safe_to_reset); then
    echo "self-test: accepted the Apple .build directory itself" >&2
    return 1
  fi
  if (PACKAGE_CACHE_ROOT="$IOS_DIR/.build/../Oppi"; RUNNER_TEMP=""; package_cache_is_safe_to_reset); then
    echo "self-test: accepted traversal outside the Apple .build directory" >&2
    return 1
  fi

  local runner_root="/tmp/oppi-check-coverage-self-test-root"
  if ! (PACKAGE_CACHE_ROOT="$runner_root/swiftpm-cache"; RUNNER_TEMP="$runner_root"; package_cache_is_safe_to_reset); then
    echo "self-test: rejected a cache below RUNNER_TEMP" >&2
    return 1
  fi
  if (PACKAGE_CACHE_ROOT="$runner_root/../oppi-check-coverage-outside"; RUNNER_TEMP="$runner_root"; package_cache_is_safe_to_reset); then
    echo "self-test: accepted traversal outside RUNNER_TEMP" >&2
    return 1
  fi
  if (SIMULATOR_RUNNER="invalid"; validate_simulator_runner) >/dev/null 2>&1; then
    echo "self-test: accepted an unknown simulator runner" >&2
    return 1
  fi

  echo "check-coverage self-test passed."
}

case "${1:-}" in
  self-test)
    [[ $# -eq 1 ]] || { echo "usage: check-coverage.sh [self-test]" >&2; exit 1; }
    run_self_test
    exit 0
    ;;
  "")
    ;;
  *)
    echo "usage: check-coverage.sh [self-test]" >&2
    exit 1
    ;;
esac

validate_simulator_runner || exit $?

RESULT_DIR="$IOS_DIR/build/coverage"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_JSON="$(mktemp -t oppi-coverage-report.XXXXXX.json)"

mkdir -p "$RESULT_DIR"
RUN_DIR="$(mktemp -d "$RESULT_DIR/OppiTests-$TIMESTAMP-XXXXXX")"
RESULT_BUNDLE="$RUN_DIR/OppiTests.xcresult"
COVERAGE_START_SECONDS=$SECONDS
PACKAGE_FLAGS=()

if [[ -n "$PACKAGE_CACHE_ROOT" ]]; then
  PACKAGE_FLAGS=(
    -packageCachePath "$PACKAGE_CACHE_ROOT/cache"
    -clonedSourcePackagesDirPath "$PACKAGE_CACHE_ROOT/source-packages"
    -onlyUsePackageVersionsFromResolvedFile
  )
fi

cleanup() {
  rm -f "$REPORT_JSON"
}
trap cleanup EXIT

find_run_result_bundle() {
  python3 - "$RUN_DIR" <<'PY'
import pathlib
import sys

run_dir = pathlib.Path(sys.argv[1])
bundles = [path for path in run_dir.glob("*.xcresult") if path.is_dir()]
if bundles:
    print(max(bundles, key=lambda path: path.stat().st_mtime))
PY
}

resolve_swift_packages() {
  xcodebuild -resolvePackageDependencies \
    -project Oppi.xcodeproj \
    -scheme OppiUnitTests \
    "${PACKAGE_FLAGS[@]}"
}

run_coverage_tests() {
  local runner_command=()
  if [[ "$SIMULATOR_RUNNER" == "ci" ]]; then
    runner_command=(bash "$SCRIPT_DIR/ci-simulator.sh" run --)
  else
    runner_command=(bash "$SCRIPT_DIR/sim-pool.sh" run --)
  fi

  "${runner_command[@]}" xcodebuild test \
    -project Oppi.xcodeproj \
    -scheme OppiUnitTests \
    -only-testing:OppiTests \
    -enableCodeCoverage YES \
    -showBuildTimingSummary \
    -resultBundlePath "$RESULT_BUNDLE" \
    "${PACKAGE_FLAGS[@]}"
}

cd "$IOS_DIR"
if [[ -n "$PACKAGE_CACHE_ROOT" ]]; then
  mkdir -p "$PACKAGE_CACHE_ROOT/cache" "$PACKAGE_CACHE_ROOT/source-packages"
  echo "Validating the bounded Swift package cache (restored=${OPPI_SWIFT_PACKAGE_CACHE_HIT:-unknown})..."
  PACKAGE_START_SECONDS=$SECONDS
  set +e
  resolve_swift_packages
  PACKAGE_STATUS=$?
  set -e

  if [[ "$PACKAGE_STATUS" -ne 0 ]]; then
    if ! package_cache_is_safe_to_reset; then
      echo "Swift package cache validation failed, and refusing to reset unsafe path: $PACKAGE_CACHE_ROOT" >&2
      exit 7
    fi
    echo "Swift package cache validation failed; retrying from an empty package cache." >&2
    rm -rf "$PACKAGE_CACHE_ROOT"
    mkdir -p "$PACKAGE_CACHE_ROOT/cache" "$PACKAGE_CACHE_ROOT/source-packages"
    if ! resolve_swift_packages; then
      echo "Swift package resolution failed after a clean retry." >&2
      exit 7
    fi
  fi
  echo "Swift package resolution elapsed: $((SECONDS - PACKAGE_START_SECONDS))s"
fi

echo "Running Oppi unit tests with code coverage enabled ($SIMULATOR_RUNNER simulator runner)..."
TEST_START_SECONDS=$SECONDS
set +e
run_coverage_tests
TEST_STATUS=$?
set -e
TEST_ELAPSED_SECONDS=$((SECONDS - TEST_START_SECONDS))
echo "Coverage build and test elapsed: ${TEST_ELAPSED_SECONDS}s"

if [[ "$TEST_STATUS" -ne 0 ]]; then
  echo "iOS coverage collection failed: the simulator test command exited with status $TEST_STATUS." >&2
  echo "No coverage threshold comparison was performed." >&2
  exit 3
fi

XCRESULT_BUNDLE="$(find_run_result_bundle)"
if [[ -z "$XCRESULT_BUNDLE" ]]; then
  echo "iOS coverage collection failed: no .xcresult bundle was produced in $RUN_DIR." >&2
  echo "No coverage threshold comparison was performed." >&2
  exit 4
fi

echo "Using xcresult bundle: $XCRESULT_BUNDLE"
REPORT_START_SECONDS=$SECONDS
if ! xcrun xccov view --report --json "$XCRESULT_BUNDLE" > "$REPORT_JSON"; then
  echo "iOS coverage collection failed: xccov could not read $XCRESULT_BUNDLE." >&2
  echo "No coverage threshold comparison was performed." >&2
  exit 5
fi
echo "Coverage report extraction elapsed: $((SECONDS - REPORT_START_SECONDS))s"

ANALYSIS_START_SECONDS=$SECONDS
set +e
node --input-type=module - "$REPORT_JSON" <<'NODE'
import { readFileSync } from "node:fs";

const reportPath = process.argv[2];
const report = JSON.parse(readFileSync(reportPath, "utf8"));

const layers = [
  { name: "Core/Runtime", prefix: "Oppi/Core/Runtime/", type: "logic", threshold: 90 },
  { name: "Core/Formatting", prefix: "Oppi/Core/Formatting/", type: "logic", threshold: 85 },
  { name: "Core/Models", prefix: "Oppi/Core/Models/", type: "logic", threshold: 75 },
  { name: "Core/Networking", prefix: "Oppi/Core/Networking/", type: "logic", threshold: 70 },
  { name: "Features/Chat/Timeline", prefix: "Oppi/Features/Chat/Timeline/", type: "logic", threshold: 75 },
  { name: "Features/Chat/Output", prefix: "Oppi/Features/Chat/Output/", type: "logic", threshold: 70 },
  { name: "Features/Chat/Session", prefix: "Oppi/Features/Chat/Session/", type: "logic", threshold: 70 },

  { name: "Core/Views", prefix: "Oppi/Core/Views/", type: "ui" },
  { name: "Features/Chat/Composer", prefix: "Oppi/Features/Chat/Composer/", type: "ui" },
  { name: "Features/Chat/Support", prefix: "Oppi/Features/Chat/Support/", type: "ui" },
  { name: "Features/Workspaces", prefix: "Oppi/Features/Workspaces/", type: "ui" },
  { name: "Features/Onboarding", prefix: "Oppi/Features/Onboarding/", type: "ui" },
  { name: "Features/Permissions", prefix: "Oppi/Features/Permissions/", type: "ui" },
  { name: "Features/Settings", prefix: "Oppi/Features/Settings/", type: "ui" },
  { name: "Features/Sessions", prefix: "Oppi/Features/Sessions/", type: "ui" },
  { name: "Features/Skills", prefix: "Oppi/Features/Skills/", type: "ui" },
  { name: "Features/Servers", prefix: "Oppi/Features/Servers/", type: "ui" },

  { name: "Core/Services", prefix: "Oppi/Core/Services/", type: "stretch", threshold: 65 },
  { name: "Core/Theme", prefix: "Oppi/Core/Theme/", type: "stretch", threshold: 60 },
  { name: "App", prefix: "Oppi/App/", type: "stretch", threshold: 50 },
];

const stats = new Map(
  layers.map((layer) => [
    layer.name,
    { executable: 0, covered: 0, files: 0 },
  ]),
);

const targets = Array.isArray(report.targets) ? report.targets : [];

for (const target of targets) {
  const files = Array.isArray(target.files) ? target.files : [];
  for (const file of files) {
    const path = String(file.path ?? "").replace(/\\/g, "/");
    const layer = layers.find((candidate) => path.includes(candidate.prefix));
    if (!layer) {
      continue;
    }

    const executable = Number(file.executableLines ?? 0);
    const covered = file.coveredLines !== undefined
      ? Number(file.coveredLines)
      : executable * Number(file.lineCoverage ?? 0);

    const bucket = stats.get(layer.name);
    if (!bucket) {
      continue;
    }

    bucket.executable += executable;
    bucket.covered += covered;
    bucket.files += 1;
  }
}

const percent = (covered, executable) => {
  if (executable <= 0) {
    return 0;
  }
  return (covered / executable) * 100;
};

const pad = (value, width) => String(value).padEnd(width, " ");

const headers = [
  ["Layer", 28],
  ["Type", 9],
  ["Coverage", 10],
  ["Lines", 8],
  ["Threshold", 10],
  ["Status", 12],
];

console.log("\niOS coverage by layer (unit tests only)");
console.log(headers.map(([title, width]) => pad(title, width)).join(" "));
console.log(headers.map(([, width]) => "-".repeat(width)).join(" "));

let failedLogicLayers = 0;

for (const layer of layers) {
  const bucket = stats.get(layer.name) ?? { executable: 0, covered: 0, files: 0 };
  const layerCoverage = percent(bucket.covered, bucket.executable);
  const coverageText = `${layerCoverage.toFixed(1)}%`;
  const linesText = String(Math.round(bucket.executable));

  let thresholdText = "-";
  let statusText = "INFO";

  if (layer.type === "logic") {
    thresholdText = `${layer.threshold}%`;
    if (bucket.executable === 0) {
      statusText = "FAIL (no data)";
      failedLogicLayers += 1;
    } else if (layerCoverage < layer.threshold) {
      statusText = "FAIL";
      failedLogicLayers += 1;
    } else {
      statusText = "PASS";
    }
  } else if (layer.type === "stretch") {
    thresholdText = `${layer.threshold}%`;
    statusText = "STRETCH";
  }

  console.log(
    [
      [layer.name, 28],
      [layer.type, 9],
      [coverageText, 10],
      [linesText, 8],
      [thresholdText, 10],
      [statusText, 12],
    ].map(([value, width]) => pad(value, width)).join(" "),
  );
}

console.log("\nLogic layers are enforced. UI and stretch layers are informational only.");

if (failedLogicLayers > 0) {
  console.error(`Coverage gate failed: ${failedLogicLayers} logic layer(s) below threshold.`);
  process.exit(2);
}

console.log("Coverage gate passed.");
NODE
ANALYSIS_STATUS=$?
set -e
echo "Coverage analysis elapsed: $((SECONDS - ANALYSIS_START_SECONDS))s"
echo "Coverage lane script elapsed: $((SECONDS - COVERAGE_START_SECONDS))s"

case "$ANALYSIS_STATUS" in
  0)
    exit 0
    ;;
  2)
    exit 2
    ;;
  *)
    echo "iOS coverage analysis failed with status $ANALYSIS_STATUS." >&2
    echo "No reliable coverage threshold result is available." >&2
    exit 6
    ;;
esac

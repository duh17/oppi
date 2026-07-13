#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${OPPI_ROOT:-${PIOS_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)}}"
IOS_DIR="$REPO_ROOT/clients/apple"

RESULT_DIR="$IOS_DIR/build/coverage"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_JSON="$(mktemp -t oppi-coverage-report.XXXXXX.json)"

mkdir -p "$RESULT_DIR"
RUN_DIR="$(mktemp -d "$RESULT_DIR/OppiTests-$TIMESTAMP-XXXXXX")"
RESULT_BUNDLE="$RUN_DIR/OppiTests.xcresult"

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

echo "Running Oppi unit tests with code coverage enabled..."
cd "$IOS_DIR"
set +e
bash "$SCRIPT_DIR/sim-pool.sh" run -- xcodebuild test \
  -project Oppi.xcodeproj \
  -scheme OppiUnitTests \
  -only-testing:OppiTests \
  -enableCodeCoverage YES \
  -resultBundlePath "$RESULT_BUNDLE"
TEST_STATUS=$?
set -e

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
if ! xcrun xccov view --report --json "$XCRESULT_BUNDLE" > "$REPORT_JSON"; then
  echo "iOS coverage collection failed: xccov could not read $XCRESULT_BUNDLE." >&2
  echo "No coverage threshold comparison was performed." >&2
  exit 5
fi

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

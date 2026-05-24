#!/usr/bin/env bun

import { spawnSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

const errors = [];

function readJson(url) {
  return JSON.parse(readFileSync(url, "utf8"));
}

function check(condition, message) {
  if (!condition) errors.push(message);
}

function serverStepsFor(steps) {
  return Array.isArray(steps) ? steps : steps.server ?? [];
}

function isE2EStep(step) {
  return step === "test:e2e" || (step.startsWith("test:e2e:") && step !== "test:e2e:clean");
}

const policyUrl = new URL("../testing-policy.json", import.meta.url);
const policy = readJson(policyUrl);

const packageJsonUrl = new URL("../package.json", import.meta.url);
const packageJson = readJson(packageJsonUrl);
const serverRoot = fileURLToPath(new URL("..", import.meta.url));

const canonicalRunner = "bun scripts/testing-gates.ts";
const gateRunnerUrl = new URL("testing-gates.ts", import.meta.url);
const allowedAppleSteps = new Set([
  "xcodebuild -scheme Oppi build",
  "xcodebuild -scheme OppiUnitTests test -only-testing:OppiTests",
]);

function checkGateE2EStepDryRun(gate, step) {
  const result = spawnSync(process.execPath, ["scripts/testing-gates.ts", gate, "--platform", "server"], {
    cwd: serverRoot,
    env: { ...process.env, TEST_GATE_DRY_RUN: "1", TEST_GATE_ONLY: step },
    encoding: "utf8",
  });
  const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;

  check(
    result.status === 0,
    `Gate '${gate}' E2E dry-run for '${step}' failed: ${result.error?.message ?? output.trim()}`,
  );
  check(
    output.includes(`E2E_STRICT=1 npm run ${step}`),
    `Gate '${gate}' E2E step '${step}' must run with E2E_STRICT=1`,
  );
}

// 1. Gate runner must exist and package scripts must call it.
check(existsSync(gateRunnerUrl), "canonical gate runner missing: server/scripts/testing-gates.ts");
check(
  packageJson.scripts["test:gate:pr-fast"] === `${canonicalRunner} pr-fast`,
  "package.json script test:gate:pr-fast drifted from canonical runner",
);
check(
  packageJson.scripts["test:gate:nightly-deep"] === `${canonicalRunner} nightly-deep`,
  "package.json script test:gate:nightly-deep drifted from canonical runner",
);

// 2. Every server gate step must have a corresponding npm script; every Apple
// gate step must be one the runner knows how to translate to sim-pool.
for (const [gate, steps] of Object.entries(policy.gates)) {
  for (const step of serverStepsFor(steps)) {
    check(
      step in packageJson.scripts,
      Array.isArray(steps)
        ? `Gate '${gate}' references step '${step}' but no npm script exists in package.json`
        : `Gate '${gate}' references server step '${step}' but no npm script exists in package.json`,
    );
    if (isE2EStep(step)) checkGateE2EStepDryRun(gate, step);
  }

  if (Array.isArray(steps)) continue;

  for (const step of steps.apple ?? []) {
    check(
      allowedAppleSteps.has(step),
      `Gate '${gate}' references unsupported Apple step '${step}'`,
    );
  }
}

// 3. Canonical docs must reference policy-as-code, coverage gate, and PR gate.
const docsReadmePath = new URL("../../docs/testing/README.md", import.meta.url);
check(existsSync(docsReadmePath), "canonical testing docs missing: docs/testing/README.md");
if (existsSync(docsReadmePath)) {
  const testingReadme = readFileSync(docsReadmePath, "utf8");
  check(
    testingReadme.includes("server/testing-policy.json"),
    "testing docs must reference server/testing-policy.json",
  );
  check(
    testingReadme.includes("npm run test:gate:pr-fast"),
    "testing docs missing PR gate command",
  );
  check(testingReadme.includes("test:coverage"), "testing docs missing coverage gate step");
}

if (errors.length > 0) {
  console.error("Testing policy coherence FAILED:");
  for (const err of errors) {
    console.error(`  - ${err}`);
  }
  process.exit(1);
}

console.log("Testing policy coherence check passed.");

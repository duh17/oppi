#!/usr/bin/env bun

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

type GateSpec = string[] | { server?: string[]; apple?: string[] };

type TestingPolicy = {
  gates: Record<string, GateSpec>;
};

type PackageJson = {
  scripts?: Record<string, string>;
};

export type TestingPolicyCheckOptions = {
  serverRoot?: string;
  repoRoot?: string;
};

export type TestingPolicyCheckResult = {
  ok: boolean;
  errors: string[];
};

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const canonicalRunner = "bun scripts/testing-gates.ts";
const allowedAppleSteps = new Set([
  "xcodebuild -scheme Oppi build",
  "xcodebuild -scheme OppiUnitTests test -only-testing:OppiTests",
]);

function readJson<T>(filePath: string): T {
  return JSON.parse(readFileSync(filePath, "utf8")) as T;
}

function serverStepsFor(steps: GateSpec): string[] {
  return Array.isArray(steps) ? steps : (steps.server ?? []);
}

function isE2EStep(step: string): boolean {
  return step === "test:e2e" || (step.startsWith("test:e2e:") && step !== "test:e2e:clean");
}

function checkGateE2EStepDryRun(serverRoot: string, gate: string, step: string): string[] {
  const errors: string[] = [];
  const result = spawnSync(
    process.execPath,
    ["scripts/testing-gates.ts", gate, "--platform", "server"],
    {
      cwd: serverRoot,
      env: { ...process.env, TEST_GATE_DRY_RUN: "1", TEST_GATE_ONLY: step },
      encoding: "utf8",
    },
  );
  const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;

  if (result.status !== 0) {
    errors.push(
      `Gate '${gate}' E2E dry-run for '${step}' failed: ${result.error?.message ?? output.trim()}`,
    );
  }
  if (!output.includes(`E2E_STRICT=1 npm run ${step}`)) {
    errors.push(`Gate '${gate}' E2E step '${step}' must run with E2E_STRICT=1`);
  }
  return errors;
}

export function checkTestingPolicy(
  options: TestingPolicyCheckOptions = {},
): TestingPolicyCheckResult {
  const errors: string[] = [];
  const check = (condition: boolean, message: string) => {
    if (!condition) errors.push(message);
  };

  const serverRoot = path.resolve(
    options.serverRoot ?? process.env.TESTING_POLICY_SERVER_ROOT ?? path.resolve(scriptDir, ".."),
  );
  const repoRoot = path.resolve(
    options.repoRoot ?? process.env.TESTING_POLICY_REPO_ROOT ?? path.resolve(serverRoot, ".."),
  );

  const policyPath = path.join(serverRoot, "testing-policy.json");
  const packageJsonPath = path.join(serverRoot, "package.json");
  const gateRunnerPath = path.join(serverRoot, "scripts", "testing-gates.ts");
  const docsReadmePath = path.join(repoRoot, "docs", "testing", "README.md");

  const policy = readJson<TestingPolicy>(policyPath);
  const packageJson = readJson<PackageJson>(packageJsonPath);
  const scripts = packageJson.scripts ?? {};

  // 1. Gate runner must exist and package scripts must call it.
  check(
    existsSync(gateRunnerPath),
    "canonical gate runner missing: server/scripts/testing-gates.ts",
  );
  check(
    scripts["test:gate:pr-fast"] === `${canonicalRunner} pr-fast`,
    "package.json script test:gate:pr-fast drifted from canonical runner",
  );
  check(
    scripts["test:gate:nightly-deep"] === `${canonicalRunner} nightly-deep`,
    "package.json script test:gate:nightly-deep drifted from canonical runner",
  );

  // 2. Every server gate step must have a corresponding npm script; every Apple
  // gate step must be one the runner knows how to translate to sim-pool.
  for (const [gate, steps] of Object.entries(policy.gates)) {
    for (const step of serverStepsFor(steps)) {
      check(
        step in scripts,
        Array.isArray(steps)
          ? `Gate '${gate}' references step '${step}' but no npm script exists in package.json`
          : `Gate '${gate}' references server step '${step}' but no npm script exists in package.json`,
      );
      if (isE2EStep(step)) errors.push(...checkGateE2EStepDryRun(serverRoot, gate, step));
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

  return { ok: errors.length === 0, errors };
}

function main(): void {
  const result = checkTestingPolicy();
  if (!result.ok) {
    console.error("Testing policy coherence FAILED:");
    for (const err of result.errors) {
      console.error(`  - ${err}`);
    }
    process.exit(1);
  }

  console.log("Testing policy coherence check passed.");
}

const entrypoint = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : "";
if (import.meta.url === entrypoint) {
  main();
}

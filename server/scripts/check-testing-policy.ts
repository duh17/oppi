#!/usr/bin/env bun

import { readFileSync, existsSync } from "node:fs";

const errors = [];

function readJson(url) {
  return JSON.parse(readFileSync(url, "utf8"));
}

function check(condition, message) {
  if (!condition) errors.push(message);
}

const policyUrl = new URL("../testing-policy.json", import.meta.url);
const policy = readJson(policyUrl);

const packageJsonUrl = new URL("../package.json", import.meta.url);
const packageJson = readJson(packageJsonUrl);

// 1. Gate scripts must call the canonical runner
check(
  packageJson.scripts["test:gate:pr-fast"] === "bun scripts/testing-gates.ts pr-fast",
  "package.json script test:gate:pr-fast drifted from canonical runner",
);
check(
  packageJson.scripts["test:gate:nightly-deep"] === "bun scripts/testing-gates.ts nightly-deep",
  "package.json script test:gate:nightly-deep drifted from canonical runner",
);

// 2. Every gate step must have a corresponding npm script
for (const [gate, steps] of Object.entries(policy.gates)) {
  // Gates can be arrays (flat) or objects (keyed by platform)
  const stepList = Array.isArray(steps)
    ? steps
    : Object.values(steps).flat().filter((s) => typeof s === "string" && !s.startsWith("xcodebuild"));
  for (const step of stepList) {
    check(
      step in packageJson.scripts,
      `Gate '${gate}' references step '${step}' but no npm script exists in package.json`,
    );
  }
}

// 3. Docs reference (optional — warn only if exists)
const docsReadmePath = new URL("../../.internal/testing/README.md", import.meta.url);
if (existsSync(docsReadmePath)) {
  const testingReadme = readFileSync(docsReadmePath, "utf8");
  check(
    testingReadme.includes("testing-policy.json"),
    "testing README must reference testing-policy.json",
  );
  check(
    testingReadme.includes("npm run test:gate:pr-fast"),
    "testing README missing PR gate command",
  );
}

if (errors.length > 0) {
  console.error("Testing policy coherence FAILED:");
  for (const err of errors) {
    console.error(`  - ${err}`);
  }
  process.exit(1);
}

console.log("Testing policy coherence check passed.");

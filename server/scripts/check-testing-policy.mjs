#!/usr/bin/env node

import { readFileSync } from "node:fs";

function readJson(url) {
  return JSON.parse(readFileSync(url, "utf8"));
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

const policyUrl = new URL("../testing-policy.json", import.meta.url);
const policy = readJson(policyUrl);

const packageJsonUrl = new URL("../package.json", import.meta.url);
const packageJson = readJson(packageJsonUrl);

const prWorkflow = readFileSync(new URL("../../.github/workflows/pr-fast-gate.yml", import.meta.url), "utf8");
const nightlyWorkflow = readFileSync(
  new URL("../../.github/workflows/nightly-deep-gate.yml", import.meta.url),
  "utf8",
);
const testingReadme = readFileSync(new URL("../../docs/testing/README.md", import.meta.url), "utf8");

assert(
  packageJson.scripts["test:gate:pr-fast"] === "node ./scripts/testing-gates.mjs pr-fast",
  "package.json script test:gate:pr-fast drifted from canonical runner",
);
assert(
  packageJson.scripts["test:gate:nightly-deep"] === "node ./scripts/testing-gates.mjs nightly-deep",
  "package.json script test:gate:nightly-deep drifted from canonical runner",
);

assert(
  prWorkflow.includes(policy.ci.prWorkflow.command),
  `PR workflow missing canonical command: ${policy.ci.prWorkflow.command}`,
);
assert(
  nightlyWorkflow.includes(policy.ci.nightlyWorkflow.command),
  `Nightly workflow missing canonical command: ${policy.ci.nightlyWorkflow.command}`,
);

assert(
  testingReadme.includes("server/testing-policy.json"),
  "docs/testing/README.md must declare server/testing-policy.json as policy source",
);
assert(
  testingReadme.includes("npm run test:gate:pr-fast"),
  "docs/testing/README.md missing PR gate command",
);
assert(
  testingReadme.includes("npm run test:gate:nightly-deep"),
  "docs/testing/README.md missing nightly gate command",
);

console.log("Testing policy coherence check passed.");

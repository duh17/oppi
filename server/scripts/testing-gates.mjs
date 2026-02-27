#!/usr/bin/env node

import { spawnSync } from "node:child_process";

const gates = {
  "pr-fast": ["check", "test"],
  "nightly-deep": [
    "check",
    "test",
    "test:e2e:linux",
    "test:e2e:lmstudio:contract",
  ],
};

const gateName = process.argv[2] ?? "pr-fast";
const fromStep = process.env.TEST_GATE_FROM;
const onlyStep = process.env.TEST_GATE_ONLY;

if (!(gateName in gates)) {
  const available = Object.keys(gates).join(", ");
  console.error(`Unknown test gate '${gateName}'. Available: ${available}`);
  process.exit(1);
}

const allSteps = gates[gateName];

if (onlyStep && !allSteps.includes(onlyStep)) {
  console.error(
    `Unknown step '${onlyStep}' for gate '${gateName}'. Available: ${allSteps.join(", ")}`,
  );
  process.exit(1);
}

if (fromStep && !allSteps.includes(fromStep)) {
  console.error(
    `Unknown TEST_GATE_FROM step '${fromStep}' for gate '${gateName}'. Available: ${allSteps.join(", ")}`,
  );
  process.exit(1);
}

const selectedSteps = allSteps.filter((step) => {
  if (onlyStep) {
    return step === onlyStep;
  }

  if (fromStep) {
    return allSteps.indexOf(step) >= allSteps.indexOf(fromStep);
  }

  return true;
});

if (selectedSteps.length === 0) {
  console.error(
    `No steps selected for gate '${gateName}' (TEST_GATE_FROM='${fromStep ?? ""}', TEST_GATE_ONLY='${onlyStep ?? ""}').`,
  );
  process.exit(1);
}

console.log(`Running server test gate '${gateName}'`);
console.log(`Steps: ${selectedSteps.join(" -> ")}`);

for (const step of selectedSteps) {
  console.log(`\n==> npm run ${step}`);
  const result = spawnSync("npm", ["run", step], {
    stdio: "inherit",
    shell: process.platform === "win32",
  });

  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

console.log(`\nGate '${gateName}' completed successfully.`);

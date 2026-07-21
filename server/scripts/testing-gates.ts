#!/usr/bin/env bun

import { existsSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

type GateSpec = string[] | Record<string, string[]>;

type TestingPolicy = {
  version: number;
  gates: Record<string, GateSpec>;
};

type RunStep = {
  label: string;
  command: string[];
  cwd: string;
  env?: Record<string, string>;
};

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const serverRoot = path.resolve(scriptDir, "..");
const repoRoot = path.resolve(serverRoot, "..");
const appleRoot = path.join(repoRoot, "clients", "apple");

function readJson<T>(filePath: string): T {
  return JSON.parse(readFileSync(filePath, "utf8")) as T;
}

function usage(): never {
  const policy = readJson<TestingPolicy>(path.join(serverRoot, "testing-policy.json"));
  const gates = Object.keys(policy.gates).sort().join(" | ");
  console.error(`Usage: bun scripts/testing-gates.ts <${gates}> [--platform server|apple|all]`);
  process.exit(2);
}

function parseArgs(argv: string[]): { gateName: string; platform: "server" | "apple" | "all" } {
  if (argv.length === 0) usage();

  const gateName = argv[0];
  let platform = (process.env.TEST_GATE_PLATFORM ?? "all") as "server" | "apple" | "all";

  for (let index = 1; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--platform") {
      const next = argv[index + 1];
      if (next !== "server" && next !== "apple" && next !== "all") {
        throw new Error(`Invalid --platform value: ${next ?? "(missing)"}`);
      }
      platform = next;
      index += 1;
      continue;
    }

    throw new Error(`Unknown argument: ${token}`);
  }

  return { gateName, platform };
}

function isE2EStep(step: string): boolean {
  return step === "test:e2e" || (step.startsWith("test:e2e:") && step !== "test:e2e:clean");
}

function npmStep(step: string): RunStep {
  const env = isE2EStep(step) ? { E2E_STRICT: "1" } : undefined;
  return {
    label: step,
    command: ["npm", "run", step],
    cwd: serverRoot,
    ...(env ? { env } : {}),
  };
}

function appleStep(step: string): RunStep {
  const simPool = path.join(appleRoot, "scripts", "sim-pool.sh");
  if (!existsSync(simPool)) {
    throw new Error(`Apple gate requires simulator pool script at ${simPool}`);
  }

  if (step === "xcodebuild -scheme Oppi build") {
    return {
      label: `apple:${step}`,
      command: [
        "bash",
        simPool,
        "run",
        "--",
        "xcodebuild",
        "-project",
        "Oppi.xcodeproj",
        "-scheme",
        "Oppi",
        "build",
      ],
      cwd: appleRoot,
    };
  }

  if (step === "./scripts/check-coverage.sh") {
    return {
      label: `apple:${step}`,
      command: ["bash", "./scripts/check-coverage.sh"],
      cwd: appleRoot,
    };
  }

  if (step === "xcodebuild -scheme OppiUnitTests test -only-testing:OppiTests") {
    return {
      label: `apple:${step}`,
      command: [
        "bash",
        simPool,
        "run",
        "--",
        "xcodebuild",
        "-project",
        "Oppi.xcodeproj",
        "-scheme",
        "OppiUnitTests",
        "test",
        "-only-testing:OppiTests",
      ],
      cwd: appleRoot,
    };
  }

  throw new Error(`Unsupported apple gate step: ${step}`);
}

function collectSteps(gate: GateSpec, platform: "server" | "apple" | "all"): RunStep[] {
  if (Array.isArray(gate)) {
    if (platform === "apple") return [];
    return gate.map(npmStep);
  }

  const steps: RunStep[] = [];
  if (platform === "server" || platform === "all") {
    for (const step of gate.server ?? []) steps.push(npmStep(step));
  }
  if (platform === "apple" || platform === "all") {
    for (const step of gate.apple ?? []) steps.push(appleStep(step));
  }
  return steps;
}

function filterSteps(steps: RunStep[]): RunStep[] {
  const only = process.env.TEST_GATE_ONLY;
  if (only) {
    return steps.filter((step) => step.label === only || step.label.endsWith(`:${only}`));
  }

  const from = process.env.TEST_GATE_FROM;
  if (!from) return steps;

  const index = steps.findIndex((step) => step.label === from || step.label.endsWith(`:${from}`));
  if (index < 0) {
    throw new Error(`TEST_GATE_FROM step not found: ${from}`);
  }
  return steps.slice(index);
}

function shellQuote(value: string): string {
  if (/^[a-zA-Z0-9_/:=.,@%+-]+$/.test(value)) return value;
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

function runStep(step: RunStep): void {
  const commandForLog = [
    ...Object.entries(step.env ?? {}).map(([key, value]) => `${key}=${value}`),
    ...step.command,
  ];

  console.log(`\n[test-gate] ${step.label}`);
  console.log(`[test-gate] cwd: ${path.relative(repoRoot, step.cwd) || "."}`);
  console.log(`[test-gate] cmd: ${commandForLog.map(shellQuote).join(" ")}`);

  if (process.env.TEST_GATE_DRY_RUN === "1") return;

  const result = spawnSync(step.command[0]!, step.command.slice(1), {
    cwd: step.cwd,
    stdio: "inherit",
    env: { ...process.env, ...step.env },
  });

  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

try {
  const { gateName, platform } = parseArgs(process.argv.slice(2));
  const policy = readJson<TestingPolicy>(path.join(serverRoot, "testing-policy.json"));
  const gate = policy.gates[gateName];
  if (!gate) {
    console.error(`Unknown gate: ${gateName}`);
    usage();
  }

  const steps = filterSteps(collectSteps(gate, platform));
  if (steps.length === 0) {
    throw new Error(`Gate '${gateName}' has no runnable steps for platform '${platform}'`);
  }

  console.log(
    `[test-gate] running '${gateName}' (${steps.length} step${steps.length === 1 ? "" : "s"})`,
  );
  for (const step of steps) runStep(step);
  console.log(`\n[test-gate] '${gateName}' passed`);
} catch (error) {
  console.error(`[test-gate] failed: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
}

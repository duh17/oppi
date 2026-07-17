#!/usr/bin/env bun

import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const serverDir = join(import.meta.dirname, "..");
const composeFile = join(import.meta.dirname, "docker-compose.iroh-isolated.yml");
const projectName = `oppi-iroh-isolated-${process.pid}`;
const artifactDir = join("/tmp", `${projectName}-artifacts`);
mkdirSync(artifactDir, { recursive: true });

function compose(args: string[], capture = false): ReturnType<typeof spawnSync> {
  return spawnSync(
    "docker",
    ["compose", "--project-name", projectName, "-f", composeFile, ...args],
    {
      cwd: serverDir,
      encoding: "utf8",
      stdio: capture ? "pipe" : "inherit",
      env: process.env,
    },
  );
}

let exitCode = 1;
try {
  const run = compose([
    "up",
    "--build",
    "--abort-on-container-exit",
    "--exit-code-from",
    "iroh-client",
  ]);
  exitCode = run.status ?? 1;

  const logs = compose(["logs", "--no-color"], true);
  await Bun.write(join(artifactDir, "compose.log"), `${logs.stdout ?? ""}${logs.stderr ?? ""}`);
  if (logs.stdout) process.stdout.write(logs.stdout);
  if (logs.stderr) process.stderr.write(logs.stderr);
} finally {
  compose(["down", "--volumes", "--remove-orphans", "--timeout", "10"]);
}

console.log(`[iroh-isolated-e2e] artifacts: ${artifactDir}`);
if (exitCode !== 0) {
  console.error(`[iroh-isolated-e2e] failed with exit code ${exitCode}`);
  process.exit(exitCode);
}
console.log("[iroh-isolated-e2e] passed (non-skippable assertion harness)");

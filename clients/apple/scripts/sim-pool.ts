#!/usr/bin/env bun
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  commandPruneCache,
  commandRun,
  commandShutdownIdle,
  commandStatus,
  loadConfig,
  PoolError,
  usage,
} from "./sim-pool-ops";

const scriptDir = dirname(fileURLToPath(import.meta.url));

function selfTest(): number {
  const repoRoot = join(scriptDir, "..", "..", "..");
  const files = [
    "./clients/apple/scripts/sim-pool-lock.test.ts",
    "./clients/apple/scripts/sim-pool-supervise.test.ts",
    "./clients/apple/scripts/sim-pool-simctl.test.ts",
    "./clients/apple/scripts/sim-pool-ops.test.ts",
    "./clients/apple/scripts/sim-pool-cli.test.ts",
    "./clients/apple/scripts/sim-pool-shutdown.test.ts",
    "./clients/apple/scripts/sim-pool-prune.test.ts",
    "./clients/apple/scripts/sim-pool-cutover.test.ts",
  ];
  for (const path of files) {
    if (!existsSync(join(repoRoot, path))) {
      process.stderr.write(`error: required test missing: ${path}\n`);
      return 1;
    }
  }
  const test = spawnSync("bun", ["test", ...files], { cwd: repoRoot, stdio: "inherit" });
  const tsconfig = join(scriptDir, "tsconfig.json");
  if (!existsSync(tsconfig)) {
    process.stderr.write("error: missing clients/apple/scripts/tsconfig.json\n");
    return 1;
  }
  const typesNode = join(repoRoot, "server/node_modules/@types/node");
  if (!existsSync(typesNode)) {
    process.stderr.write(
      "error: typecheck needs server/node_modules/@types/node (npm --prefix server install, existing package.json dependency)\n",
    );
    return 1;
  }
  const tsc = spawnSync("tsc", ["--noEmit", "-p", tsconfig], { stdio: "inherit" });
  return test.status === 0 && tsc.status === 0 ? 0 : 1;
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  const command = argv[0];
  if (!command) {
    usage();
  }
  if (command === "self-test") {
    process.exit(selfTest());
  }
  const config = loadConfig(process.env, process.cwd(), scriptDir);
  try {
    switch (command) {
      case "run":
        process.exit(await commandRun(config, argv.slice(1)));
        break;
      case "status":
        process.exit(commandStatus(config));
        break;
      case "shutdown-idle":
        process.exit(await commandShutdownIdle(config));
        break;
      case "prune-cache":
        process.exit(commandPruneCache(config, argv.slice(1)));
        break;
      default:
        usage();
    }
  } catch (error) {
    if (error instanceof PoolError) {
      process.stderr.write(`error: ${error.message}\n`);
      process.exit(1);
    }
    throw error;
  }
}

if (import.meta.main) {
  void main();
}

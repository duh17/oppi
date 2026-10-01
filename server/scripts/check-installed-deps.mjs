#!/usr/bin/env node
// Fail fast when installed direct dependencies differ from package-lock.json.
// A worktree rebased onto a newer main keeps its old node_modules, and the
// resulting type errors point at the code instead of the install.
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const serverRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const lock = JSON.parse(readFileSync(join(serverRoot, "package-lock.json"), "utf8"));
const root = lock.packages[""];
const direct = Object.keys({ ...root.dependencies, ...root.devDependencies });

if (!existsSync(join(serverRoot, "node_modules"))) {
  console.error("No dependencies installed in server/. Run `npm ci` in server/ and retry.");
  process.exit(1);
}

const mismatches = [];
for (const name of direct) {
  const locked = lock.packages[`node_modules/${name}`];
  if (!locked) continue;
  const manifest = join(serverRoot, "node_modules", name, "package.json");
  if (!existsSync(manifest)) {
    if (!locked.optional) mismatches.push(`${name}: not installed, lock ${locked.version}`);
    continue;
  }
  const installed = JSON.parse(readFileSync(manifest, "utf8")).version;
  if (installed !== locked.version) {
    mismatches.push(`${name}: installed ${installed}, lock ${locked.version}`);
  }
}

if (mismatches.length > 0) {
  console.error("Installed dependencies do not match server/package-lock.json:");
  for (const line of mismatches) console.error(`  ${line}`);
  console.error("Run `npm ci` in server/ and retry.");
  process.exit(1);
}

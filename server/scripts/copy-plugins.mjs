#!/usr/bin/env node
// Complete Oppi's plugins in the build. tsc emits each plugin's JavaScript under dist/plugins/;
// this copies what tsc does not: the built-in root's package.json (its `chord.plugins` list is the
// built-ins' order), every plugin's package.json, and the TypeScript of each Pi package (one whose
// package.json declares `pi.extensions`), because Pi loads a classic entry's TypeScript itself.
// A facet file (`server.ts`) is never copied: tsc emits `server.js`, and a folder with both would
// have two facets. The build fails when a listed built-in has no `server.js` afterwards, a Pi
// package misses a declared entry, or a built-in fails to load (check-built-plugins.mjs).
import { spawnSync } from "node:child_process";
import { cpSync, existsSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const serverRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const buildRoot = process.env.OPPI_BUILD_DIR
  ? resolve(process.env.OPPI_BUILD_DIR)
  : join(serverRoot, "dist");
const source = join(serverRoot, "plugins");
const target = join(buildRoot, "plugins");

const FACET = /^server\.(ts|tsx|js|mjs)$/;
const SKIPPED = (name) =>
  name === "node_modules" || name.startsWith(".") || name.endsWith(".test.ts");

const readJson = (path) => JSON.parse(readFileSync(path, "utf8"));
const problems = [];

cpSync(join(source, "package.json"), join(target, "package.json"));
// Bun applies the nearest tsconfig.json's `paths` when it imports a file, and a build inside the
// checkout (server/dist) would find server/tsconfig.json, which maps `oppi/v1` to src/oppi-v1.ts.
// The plugin host hands plugins its own `oppi/v1`, but jiti imports a built plugin natively
// first, so a plugin would get a second `oppi/v1` (and Chord) from the sources. This one has no
// paths: `oppi/v1` does not resolve, and jiti falls back to its loader, as it does under Node.
writeFileSync(join(target, "tsconfig.json"), "{}\n");
for (const name of readdirSync(source)) {
  const dir = join(source, name);
  if (!statSync(dir).isDirectory()) continue;
  const manifest = join(dir, "package.json");
  if (!existsSync(manifest)) {
    problems.push(`${name}: no package.json`);
    continue;
  }
  const pi = readJson(manifest).pi?.extensions;
  cpSync(dir, join(target, name), {
    recursive: true,
    dereference: true,
    // A Pi package ships its sources; any other plugin only its manifest.
    filter: (path) => {
      const file = path.slice(dir.length + 1);
      if (file === "") return true;
      const base = file.split("/").at(-1);
      if (SKIPPED(base) || (!file.includes("/") && FACET.test(base))) return false;
      return pi !== undefined || file === "package.json";
    },
  });
  for (const entry of pi ?? []) {
    if (!existsSync(join(target, name, entry))) problems.push(`${name}: missing ${entry}`);
  }
}
for (const listed of readJson(join(source, "package.json")).chord.plugins) {
  const built = join(target, listed);
  if (!existsSync(join(built, "server.js"))) problems.push(`${listed}: no server.js in ${built}`);
  if (existsSync(join(built, "server.ts")))
    problems.push(`${listed}: server.ts copied beside server.js`);
}
if (problems.length > 0) {
  console.error(`copy-plugins: ${problems.join("; ")}`);
  process.exit(1);
}

// Load the built-ins under this runtime and, where installed, the other one the server runs on.
const check = join(serverRoot, "scripts", "check-built-plugins.mjs");
for (const runtime of [process.execPath, process.versions.bun ? "node" : "bun"]) {
  const run = spawnSync(runtime, [check, buildRoot], { encoding: "utf8" });
  if (run.error?.code === "ENOENT" && runtime !== process.execPath) continue;
  if (run.status !== 0) {
    // Its output is the server log of the load, kept for a failure.
    console.error(run.stdout, run.stderr, run.error ?? "");
    console.error(`copy-plugins: built-in plugins fail to load under ${runtime}`);
    process.exit(1);
  }
  console.error(run.stderr.trim().split("\n").at(-1));
}

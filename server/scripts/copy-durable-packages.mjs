#!/usr/bin/env node
// Copy the package.json of each bundled durable package into the build. tsc emits the entries'
// JavaScript under extensions/durable/<name>/; the loader reads each manifest's `oppi.durable`
// next to it. Symlinked manifests (shared with pi-extensions/) are copied as files.
import { copyFileSync, existsSync, mkdirSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const serverRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const buildRoot = process.env.OPPI_BUILD_DIR
  ? resolve(process.env.OPPI_BUILD_DIR)
  : join(serverRoot, "dist");
const source = join(serverRoot, "extensions", "durable");
const target = join(buildRoot, "extensions", "durable");

for (const entry of readdirSync(source, { withFileTypes: true })) {
  const manifest = join(source, entry.name, "package.json");
  if (!entry.isDirectory() || !existsSync(manifest)) continue;
  mkdirSync(join(target, entry.name), { recursive: true });
  // copyFileSync reads through a symlink, so a shared manifest lands as a file.
  copyFileSync(manifest, join(target, entry.name, "package.json"));
}

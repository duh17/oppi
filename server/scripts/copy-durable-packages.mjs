#!/usr/bin/env node
// Copy the package.json of each bundled durable package into the build. tsc emits the entries'
// JavaScript under extensions/durable/<name>/; the loader reads each manifest's `oppi.durable`
// next to it. Every directory under extensions/durable is a bundled package, whether it is a
// directory or a symlink to one; symlinked manifests (shared with pi-extensions/) are copied as
// files. The build fails when any package's manifest is missing from it afterwards: the server
// refuses to open its durable runtime without every built-in.
import { copyFileSync, existsSync, mkdirSync, readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const serverRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const buildRoot = process.env.OPPI_BUILD_DIR
  ? resolve(process.env.OPPI_BUILD_DIR)
  : join(serverRoot, "dist");
const source = join(serverRoot, "extensions", "durable");
const target = join(buildRoot, "extensions", "durable");

// statSync follows symlinks, so a symlinked package directory counts like a real one. A dangling
// link may have been a package, so it fails the build too.
const dangling = [];
const packages = readdirSync(source).filter((name) => {
  const stats = statSync(join(source, name), { throwIfNoEntry: false });
  if (!stats) dangling.push(name);
  return stats?.isDirectory() === true;
});
const missing = [...dangling];
for (const name of packages) {
  const manifest = join(source, name, "package.json");
  if (existsSync(manifest)) {
    mkdirSync(join(target, name), { recursive: true });
    // copyFileSync reads through a symlink, so a shared manifest lands as a file.
    copyFileSync(manifest, join(target, name, "package.json"));
  }
  if (!existsSync(join(target, name, "package.json"))) missing.push(name);
}
if (missing.length > 0) {
  console.error(
    `copy-durable-packages: no package.json in ${target} for bundled durable packages (or a dangling link in ${source}): ${missing.join(", ")}`,
  );
  process.exit(1);
}

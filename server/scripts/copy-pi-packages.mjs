#!/usr/bin/env node
// Copy Oppi's Pi packages into the build as source files. A directory under extensions/pi is a
// complete Pi package (package.json plus the files its `pi.extensions` entries name) that a user
// links into ~/.pi/agent/extensions/; the files are symlinks to pi-extensions/<name>/ in the
// repo, copied through as real files. Pi loads their TypeScript itself, so tsc's JavaScript
// beside them is not what Pi runs. The build fails when a package's manifest or any file it
// declares is missing afterwards.
import { cpSync, existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const serverRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const buildRoot = process.env.OPPI_BUILD_DIR
  ? resolve(process.env.OPPI_BUILD_DIR)
  : join(serverRoot, "dist");
const source = join(serverRoot, "extensions", "pi");
const target = join(buildRoot, "extensions", "pi");

const problems = [];
for (const name of readdirSync(source)) {
  // statSync follows symlinks, so a dangling link is a problem and a linked directory counts.
  const stats = statSync(join(source, name), { throwIfNoEntry: false });
  if (!stats) {
    problems.push(`${name}: dangling link`);
    continue;
  }
  if (!stats.isDirectory()) continue;
  cpSync(join(source, name), join(target, name), { recursive: true, dereference: true });
  const manifest = join(target, name, "package.json");
  if (!existsSync(manifest)) {
    problems.push(`${name}: no package.json`);
    continue;
  }
  const { files = [] } = JSON.parse(readFileSync(manifest, "utf8"));
  for (const file of files) {
    if (!existsSync(join(target, name, file))) problems.push(`${name}: missing ${file}`);
  }
}
if (problems.length > 0) {
  console.error(`copy-pi-packages: ${problems.join("; ")}`);
  process.exit(1);
}

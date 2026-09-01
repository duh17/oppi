#!/usr/bin/env node
import { cpSync, existsSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const serverRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = resolve(serverRoot, "..");
// Public user docs only. Contributor architecture, telemetry, and testing live in repo-root dev/.
const sourceDocs = join(repoRoot, "docs");
const buildRoot = process.env.OPPI_BUILD_DIR
  ? resolve(process.env.OPPI_BUILD_DIR)
  : join(serverRoot, "dist");
const targetDocs = join(buildRoot, "docs", "oppi");

if (!existsSync(sourceDocs)) {
  console.warn(`Oppi docs source directory not found: ${sourceDocs}`);
  process.exit(0);
}

rmSync(targetDocs, { recursive: true, force: true });
copyMarkdownDocs(sourceDocs, targetDocs);

function copyMarkdownDocs(sourceDir, targetDir) {
  for (const entry of readdirSync(sourceDir, { withFileTypes: true })) {
    if (entry.name.startsWith(".")) continue;

    const sourcePath = join(sourceDir, entry.name);
    const targetPath = join(targetDir, entry.name);

    if (entry.isDirectory()) {
      copyMarkdownDocs(sourcePath, targetPath);
      continue;
    }

    if (!entry.isFile() || !entry.name.toLowerCase().endsWith(".md")) {
      continue;
    }

    mkdirSync(dirname(targetPath), { recursive: true });
    cpSync(sourcePath, targetPath);
  }
}

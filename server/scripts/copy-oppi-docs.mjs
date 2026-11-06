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

const PUBLIC_DOC_EXTENSIONS = new Set([".md", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".mp4"]);

// docs/demo holds the README screenshots and clips (~95% of the npm tarball). Agents
// read only the markdown, and nothing at runtime opens the media, so it stays in the repo.
const EXCLUDED_TOP_LEVEL_DIRS = new Set(["demo"]);

rmSync(targetDocs, { recursive: true, force: true });
copyPublicDocs(sourceDocs, targetDocs);

function copyPublicDocs(sourceDir, targetDir) {
  for (const entry of readdirSync(sourceDir, { withFileTypes: true })) {
    if (entry.name.startsWith(".")) continue;

    const sourcePath = join(sourceDir, entry.name);
    const targetPath = join(targetDir, entry.name);

    if (entry.isDirectory()) {
      if (sourceDir === sourceDocs && EXCLUDED_TOP_LEVEL_DIRS.has(entry.name)) continue;
      copyPublicDocs(sourcePath, targetPath);
      continue;
    }

    const dot = entry.name.lastIndexOf(".");
    const extension = dot >= 0 ? entry.name.slice(dot).toLowerCase() : "";
    if (!entry.isFile() || !PUBLIC_DOC_EXTENSIONS.has(extension)) {
      continue;
    }

    mkdirSync(dirname(targetPath), { recursive: true });
    cpSync(sourcePath, targetPath);
  }
}

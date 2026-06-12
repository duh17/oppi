#!/usr/bin/env node
import { cpSync, existsSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const serverRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = resolve(serverRoot, "..");
const sourceDocs = join(repoRoot, "docs");
const targetDocs = join(serverRoot, "dist", "docs", "oppi");

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

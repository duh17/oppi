#!/usr/bin/env node
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";
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
rewriteExcludedImageLinks(targetDocs);

// Docs link their screenshots with relative paths (`demo/x.png`) so GitHub and the
// in-app reader's workspace reads both render them. The bundle leaves the media out,
// so a link to an excluded file becomes its absolute raw GitHub URL here; the app
// then shows its normal remote-image prompt instead of a broken image.
function rewriteExcludedImageLinks(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      rewriteExcludedImageLinks(path);
      continue;
    }
    if (!entry.name.endsWith(".md")) continue;
    const text = readFileSync(path, "utf8");
    const rewritten = text.replace(/(!\[[^\]]*\]\()([^)\s]+)(\))/g, (whole, open, reference, close) => {
      if (/^[a-z][a-z0-9+.-]*:/i.test(reference) || reference.startsWith("/")) return whole;
      const target = resolve(dirname(path), reference);
      const fromDocs = relative(targetDocs, target);
      if (fromDocs.startsWith("..") || existsSync(target) || !existsSync(join(sourceDocs, fromDocs))) return whole;
      return `${open}${rawDocsBase()}/${fromDocs.split(sep).join("/")}${close}`;
    });
    if (rewritten !== text) writeFileSync(path, rewritten);
  }
}

// https://raw.githubusercontent.com/<owner>/<repo>/main/docs, from package.json's repository URL.
function rawDocsBase() {
  const { repository } = JSON.parse(readFileSync(join(serverRoot, "package.json"), "utf8"));
  const url = typeof repository === "string" ? repository : repository.url;
  const match = /github\.com[/:]([^/]+\/[^/]+?)(?:\.git)?$/.exec(url);
  if (!match) throw new Error(`Cannot derive a GitHub raw URL from repository ${url}`);
  return `https://raw.githubusercontent.com/${match[1]}/main/docs`;
}

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

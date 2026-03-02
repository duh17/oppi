#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { basename, dirname, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, "../..");
const docsDir = join(repoRoot, "docs");
const staleThresholdDays = 60;

function walkMarkdownFiles(dir) {
  const files = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const fullPath = join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...walkMarkdownFiles(fullPath));
      continue;
    }
    if (entry.isFile() && entry.name.endsWith(".md")) {
      files.push(fullPath);
    }
  }
  return files;
}

function listRootMarkdownFiles() {
  return readdirSync(repoRoot, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith(".md"))
    .map((entry) => join(repoRoot, entry.name));
}

function relativeToRepo(absolutePath) {
  return absolutePath.slice(repoRoot.length + 1);
}

function normalizeLinkTarget(raw) {
  const trimmed = raw.trim();

  if (!trimmed) return "";

  if (trimmed.startsWith("<")) {
    const end = trimmed.indexOf(">");
    return end > 0 ? trimmed.slice(1, end) : "";
  }

  const titleSeparatorIndex = trimmed.search(/\s/);
  return titleSeparatorIndex === -1 ? trimmed : trimmed.slice(0, titleSeparatorIndex);
}

function isExternalLink(target) {
  if (!target) return true;
  if (target.startsWith("#")) return true;
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(target)) return true;
  return false;
}

function resolveLinkPath(sourceFile, target) {
  const withoutFragment = target.split("#")[0]?.split("?")[0] ?? "";
  if (!withoutFragment) return null;
  if (withoutFragment.includes("<") || withoutFragment.includes(">")) return null;

  const candidate = withoutFragment.startsWith("/")
    ? join(repoRoot, withoutFragment.slice(1))
    : resolve(dirname(sourceFile), withoutFragment);

  if (existsSync(candidate)) return candidate;

  if (!extname(candidate)) {
    const markdownCandidate = `${candidate}.md`;
    if (existsSync(markdownCandidate)) return markdownCandidate;

    const readmeCandidate = join(candidate, "README.md");
    if (existsSync(readmeCandidate)) return readmeCandidate;
  }

  return candidate;
}

function findBrokenLinks(markdownFiles) {
  const broken = [];
  const markdownLinkRegex = /!?\[[^\]]*\]\(([^)]+)\)/g;

  for (const file of markdownFiles) {
    const content = readFileSync(file, "utf8");
    for (const match of content.matchAll(markdownLinkRegex)) {
      const rawTarget = match[1] ?? "";
      const target = normalizeLinkTarget(rawTarget);

      if (isExternalLink(target)) continue;

      const resolved = resolveLinkPath(file, target);
      if (resolved === null) continue;
      if (!existsSync(resolved)) {
        broken.push({
          file: relativeToRepo(file),
          target,
          resolved: relativeToRepo(resolved),
        });
      }
    }
  }

  return broken;
}

function findDuplicateFilenames(docsMarkdownFiles) {
  const byName = new Map();

  for (const file of docsMarkdownFiles) {
    const name = basename(file);
    if (name === "README.md") continue;

    const rel = relativeToRepo(file);
    const existing = byName.get(name) ?? [];
    existing.push(rel);
    byName.set(name, existing);
  }

  return [...byName.entries()]
    .filter(([, paths]) => paths.length > 1)
    .map(([name, paths]) => ({ name, paths: paths.sort() }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

function lastCommitUnixSeconds(relativePath) {
  try {
    const out = execFileSync("git", ["log", "-1", "--format=%ct", "--", relativePath], {
      cwd: repoRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (!out) return null;
    const parsed = Number.parseInt(out, 10);
    return Number.isFinite(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function findStaleDocs(markdownFiles) {
  const nowSeconds = Math.floor(Date.now() / 1000);
  const stale = [];

  for (const file of markdownFiles) {
    const rel = relativeToRepo(file);
    const lastCommit = lastCommitUnixSeconds(rel);
    if (lastCommit === null) continue;

    const ageDays = Math.floor((nowSeconds - lastCommit) / 86_400);
    if (ageDays >= staleThresholdDays) {
      stale.push({ file: rel, ageDays });
    }
  }

  return stale.sort((a, b) => b.ageDays - a.ageDays);
}

const docsMarkdownFiles = walkMarkdownFiles(docsDir);
const rootMarkdownFiles = listRootMarkdownFiles();
const markdownFilesToValidate = [...docsMarkdownFiles, ...rootMarkdownFiles];

const brokenLinks = findBrokenLinks(markdownFilesToValidate);
const duplicateFilenames = findDuplicateFilenames(docsMarkdownFiles);
const staleDocs = findStaleDocs([...docsMarkdownFiles, ...rootMarkdownFiles]);

if (brokenLinks.length > 0) {
  console.error("Broken markdown links:");
  for (const link of brokenLinks) {
    console.error(`  - ${link.file} -> ${link.target} (missing: ${link.resolved})`);
  }
}

if (duplicateFilenames.length > 0) {
  console.error("Duplicate markdown filenames in docs/:");
  for (const duplicate of duplicateFilenames) {
    console.error(`  - ${duplicate.name}`);
    for (const path of duplicate.paths) {
      console.error(`      • ${path}`);
    }
  }
}

if (staleDocs.length > 0) {
  console.warn(`Stale docs (>= ${staleThresholdDays} days since last git update):`);
  for (const doc of staleDocs) {
    console.warn(`  - ${doc.file} (${doc.ageDays} days)`);
  }
}

if (brokenLinks.length > 0 || duplicateFilenames.length > 0) {
  process.exit(1);
}

console.log("Doc freshness check passed.");

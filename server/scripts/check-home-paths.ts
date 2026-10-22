#!/usr/bin/env bun

// Home path guard: tracked source and configuration must not record an absolute
// home directory (`/Users/<name>`). The 2026-10 macOS home rename
// (chenda -> duh on both Macs) stranded every live file that had kept the old
// home: container snapshots would not boot, Oppi sessions would not resume,
// LaunchAgents ran scripts that exported the vanished HOME. None of it failed
// where the path was written, so nothing caught it until runtime.
//
// Write `$HOME`, `~`, or a path relative to a known root instead. Neutral
// example names are allowed; a real account name is not. Tests, fixtures, and
// documentation are out of scope: they carry example homes on purpose.

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export type HomePathViolation = {
  file: string;
  line: number;
  text: string;
};

/**
 * Home names that never belong to a real account on these machines. They are
 * placeholders in comments, samples, and preview fixtures. Add a name only when
 * it is unmistakably fictional; `duh`, `chenda`, and any other real account
 * must fail so the stale path is rewritten, not allowlisted.
 */
export const NEUTRAL_HOME_NAMES: ReadonlySet<string> = new Set([
  "alice",
  "example",
  "foo",
  "me",
  "preview",
  "runner",
  "testuser",
]);

// `/Users/<name>` where <name> can be a real short name. `<` in docs and `...`
// in prose do not match, because the name needs at least one letter or digit.
const HOME_PATH = /\/Users\/([A-Za-z0-9._-]+)/g;

function hasAccountShape(name: string): boolean {
  return /[A-Za-z0-9_-]/.test(name);
}

/**
 * Paths whose absolute example homes are data, not configuration: docs,
 * reports, and every test or fixture target.
 */
export function isExemptPath(file: string): boolean {
  if (file.startsWith(".internal/")) return true;
  if (file.startsWith("docs/") || file.startsWith("dev/") || file.startsWith("server/docs/")) {
    return true;
  }
  if (file.endsWith(".md")) return true;
  if (/(^|\/)(tests?|Tests?|e2e|__tests__|fixtures?|Fixtures?)\//.test(file)) return true;
  if (/(^|\/)[A-Za-z]*Tests?\//.test(file)) return true;
  if (/\.(test|spec|bench)\.[cm]?[jt]sx?$/.test(file)) return true;
  if (/\.test\.sh$/.test(file)) return true;
  if (file.startsWith("server/bench/")) return true;
  return false;
}

export function findHomePathViolations(file: string, content: string): HomePathViolation[] {
  const violations: HomePathViolation[] = [];
  const lines = content.split("\n");
  for (const [index, line] of lines.entries()) {
    for (const match of line.matchAll(HOME_PATH)) {
      const name = match[1];
      if (!hasAccountShape(name)) continue;
      if (NEUTRAL_HOME_NAMES.has(name)) continue;
      violations.push({ file, line: index + 1, text: match[0] });
    }
  }
  return violations;
}

function listTrackedFiles(repoRoot: string): string[] {
  const output = execFileSync("git", ["ls-files", "-z"], { cwd: repoRoot, encoding: "utf8" });
  return output.split("\0").filter(Boolean);
}

function looksBinary(content: Buffer): boolean {
  return content.subarray(0, 8000).includes(0);
}

export function scanTrackedFiles(repoRoot: string): HomePathViolation[] {
  const violations: HomePathViolation[] = [];
  for (const file of listTrackedFiles(repoRoot)) {
    if (isExemptPath(file)) continue;
    const absolutePath = path.join(repoRoot, file);
    if (!existsSync(absolutePath)) continue;
    const content = readFileSync(absolutePath);
    if (looksBinary(content)) continue;
    violations.push(...findHomePathViolations(file, content.toString("utf8")));
  }
  return violations;
}

function run(): void {
  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  const repoRoot = path.resolve(scriptDir, "../..");
  const violations = scanTrackedFiles(repoRoot);

  if (violations.length === 0) {
    console.log("Home path checks passed.");
    return;
  }

  console.error("Home path check failed: absolute home directories in tracked files.");
  for (const violation of violations) {
    console.error(`- ${violation.file}:${violation.line} ${violation.text}`);
  }
  console.error(
    "A home rename strands every absolute home path it wrote. Use $HOME, ~, or a relative path, " +
      "or keep the example under a test, fixture, or doc path.",
  );
  process.exit(1);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  run();
}

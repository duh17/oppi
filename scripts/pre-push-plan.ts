#!/usr/bin/env bun

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";

export type ServerGateMode = "none" | "changed" | "full";
export type AppleGateMode = "none" | "unit" | "all";

export type PrePushPlan = {
  server: ServerGateMode;
  apple: AppleGateMode;
  harness: boolean;
  /** A `dev/` doc, its budgets, or their guard changed: the hook runs scripts/dev-docs-guard.ts. */
  docs: boolean;
  changedPaths: string[];
};

const gatePolicyPaths = new Set([
  ".gitignore",
  ".githooks/pre-push",
  "scripts/pre-push-plan.ts",
  "scripts/pre-push-plan.test.ts",
  "scripts/heavy.sh",
  "scripts/heavy.test.ts",
  "dev/testing/README.md",
  "scripts/dev-docs-guard.ts",
  "scripts/dev-docs-guard.test.ts",
]);

function affectsDevDocs(path: string): boolean {
  return (path.startsWith("dev/") && path.endsWith(".md"))
    || path === "dev/doc-budgets.json"
    || path === "scripts/dev-docs-guard.ts";
}

// Gate code that is also executable product-adjacent tooling: its own tests run in the hook's
// self-test (harness), and it keeps the lanes of an unclassified path (no `continue` below).
const harnessTestedPaths = new Set([
  "scripts/batch-gate.ts",
  "scripts/batch-gate.test.ts",
  "scripts/batch-gate-health.test.ts",
  "scripts/gate-report.ts",
  "scripts/gate-report.test.ts",
]);

function strongerServer(lhs: ServerGateMode, rhs: ServerGateMode): ServerGateMode {
  const rank: Record<ServerGateMode, number> = { none: 0, changed: 1, full: 2 };
  return rank[rhs] > rank[lhs] ? rhs : lhs;
}

function strongerApple(lhs: AppleGateMode, rhs: AppleGateMode): AppleGateMode {
  const rank: Record<AppleGateMode, number> = { none: 0, unit: 1, all: 2 };
  return rank[rhs] > rank[lhs] ? rhs : lhs;
}

function isDocumentation(path: string): boolean {
  return path === "LICENSE"
    || path === "SECURITY.md"
    || path === "CHANGELOG.md"
    || path === "README.md"
    || path.startsWith("docs/")
    || path.startsWith("dev/")
    || path.endsWith(".md");
}

function serverMode(path: string): ServerGateMode {
  if (!path.startsWith("server/")) return "none";
  if (
    path === "server/package.json"
    || path === "server/package-lock.json"
    // The Bun the server's Bun lane (pre-push `server-bun`) expects.
    || path === "server/.bun-version"
    || path.startsWith("server/scripts/")
    || path.startsWith("server/e2e/")
    // The plugin host evaluates server/plugins at runtime (jiti), outside Vitest's import graph,
    // so `vitest --changed` would miss the suites that load a changed plugin through the host.
    || path.startsWith("server/plugins/")
    || /^server\/(vitest|tsconfig|eslint|prettier|knip)/.test(path)
  ) {
    return "full";
  }
  return "changed";
}

function appleMode(path: string): AppleGateMode {
  if (!path.startsWith("clients/apple/")) return "none";
  if (
    path.startsWith("clients/apple/OppiUITests/")
    || path.startsWith("clients/apple/OppiE2ETests/")
    || path.startsWith("clients/apple/OppiPerfTests/")
    || path.startsWith("clients/apple/scripts/")
    || path.endsWith("/project.yml")
    || path.endsWith("Package.resolved")
    || path.includes("Extension/")
  ) {
    return "all";
  }
  return "unit";
}

export function planForPaths(inputPaths: Iterable<string>): PrePushPlan {
  const changedPaths = [...new Set([...inputPaths].filter(Boolean))].sort();
  let server: ServerGateMode = "none";
  let apple: AppleGateMode = "none";
  let harness = false;
  let docs = false;

  for (const path of changedPaths) {
    if (affectsDevDocs(path)) docs = true;
    if (harnessTestedPaths.has(path)) harness = true;

    if (gatePolicyPaths.has(path) || path.startsWith(".github/workflows/")) {
      harness = true;
      if (!path.startsWith("server/")) continue;
    }

    const protocolBoundary = path.startsWith("protocol/")
      || path === "server/src/types/protocol.ts"
      || path === "server/src/types/session.ts"
      || path === "server/src/types/icon.ts"
      || path === "server/src/types/git.ts"
      || path === "server/src/types/shared.ts"
      || path === "server/src/thinking-levels.ts"
      || path.startsWith("clients/apple/OppiCore/Models/");
    if (protocolBoundary) {
      server = "full";
      apple = strongerApple(apple, "unit");
      continue;
    }

    const crossPlatformGuard = path === "server/scripts/check-architecture-boundaries.ts"
      || path === "server/scripts/architecture-layer-rules.mjs"
      || path === "scripts/theme-surface-guard.ts";
    if (crossPlatformGuard) {
      server = strongerServer(server, "full");
      apple = strongerApple(apple, "unit");
      continue;
    }

    // The guard reads app and test sources and runs in the Apple lane (see run_apple_gate).
    if (path === "scripts/ax-id-guard.ts" || path === "scripts/ax-id-baseline.json") {
      apple = strongerApple(apple, "unit");
      continue;
    }

    // The ratchet reads the Apple lane's build log; its script and test run in the hook's self-test.
    if (path.startsWith("scripts/apple-warnings")) {
      apple = strongerApple(apple, "unit");
      if (path.endsWith(".ts")) harness = true;
      continue;
    }

    // The guard reads iOS app sources and runs with the architecture check.
    if (path === "scripts/document-edit-guard.ts") {
      apple = strongerApple(apple, "unit");
      continue;
    }

    const pathServerMode = serverMode(path);
    if (pathServerMode !== "none") {
      server = strongerServer(server, pathServerMode);
      continue;
    }

    const pathAppleMode = appleMode(path);
    if (pathAppleMode !== "none") {
      apple = strongerApple(apple, pathAppleMode);
      continue;
    }

    if (isDocumentation(path)) continue;

    // Unknown executable/configuration surfaces fail closed.
    server = "full";
    apple = strongerApple(apple, "unit");
  }

  return { server, apple, harness, docs, changedPaths };
}

/**
 * Inputs the Release build reads differently from the Debug build the Apple lane runs (project.yml
 * `configs: Release`, Base.xcconfig): build settings and package pins, entitlements and plists
 * (Release sets OPPI_TELEMETRY_MODE), and the Xcode and XcodeGen pins and generator.
 */
function releaseSettingsPath(path: string): boolean {
  return path === "clients/apple/project.yml"
    || path === "clients/apple/Package.resolved"
    || path === "clients/apple/scripts/xcode-toolchain.txt"
    || path === "clients/apple/scripts/xcodegen-version.txt"
    || path === "clients/apple/scripts/generate-project.sh"
    || (path.startsWith("clients/apple/") && /\.(xcconfig|entitlements|plist)$/.test(path));
}

/** Folders under clients/apple whose sources never build into the Release app: the test targets and scripts. */
const notInReleaseApp = ["OppiTests/", "OppiUITests/", "OppiE2ETests/", "OppiPerfTests/", "QAVerificationSupport/", "scripts/"];

/**
 * 1-based lines of `text` inside an `#if` ... `#endif` chain any of whose conditions names DEBUG
 * (`#if DEBUG`, `#if !DEBUG`, `#elseif DEBUG && ...`), directives included: one side of such a chain
 * compiles only in Debug, the other only in Release. A chain nested in one is inside it.
 */
export function debugConditionLines(text: string): Set<number> {
  const lines = text.split("\n");
  const open: { start: number; debug: boolean }[] = [];
  const inside = new Set<number>();
  lines.forEach((line, index) => {
    const directive = /^[ \t]*#(if|elseif|else|endif)\b(.*)$/.exec(line);
    if (!directive) return;
    const names = /\bDEBUG\b/.test(directive[2]);
    if (directive[1] === "if") open.push({ start: index + 1, debug: names });
    else if (directive[1] === "elseif" && open.length > 0) open[open.length - 1].debug ||= names;
    else if (directive[1] === "endif") {
      const chain = open.pop();
      if (chain?.debug) for (let at = chain.start; at <= index + 1; at += 1) inside.add(at);
    }
  });
  return inside;
}

/** One hunk of `git diff -U0`: the lines it removes from the old file and adds to the new one (start, count). */
export type Hunk = { oldStart: number; oldCount: number; newStart: number; newCount: number };

export function parseHunks(diff: string): Hunk[] {
  return [...diff.matchAll(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/gm)].map((m) => ({
    oldStart: Number(m[1]), oldCount: m[2] === undefined ? 1 : Number(m[2]),
    newStart: Number(m[3]), newCount: m[4] === undefined ? 1 : Number(m[4]),
  }));
}

/** Whether a hunk removes a line inside a DEBUG chain of `before` or adds one inside a DEBUG chain of `after`. */
export function touchesDebugCondition(change: { before: string; after: string; hunks: Hunk[] }): boolean {
  const before = debugConditionLines(change.before);
  const after = debugConditionLines(change.after);
  const hits = (lines: Set<number>, start: number, count: number) => {
    for (let at = start; at < start + count; at += 1) if (lines.has(at)) return true;
    return false;
  };
  return change.hunks.some((hunk) => hits(before, hunk.oldStart, hunk.oldCount) || hits(after, hunk.newStart, hunk.newCount));
}

/** A changed file in one pushed range: its text before and after (empty when absent) and its `-U0` hunks. */
export type FileChange = { before: string; after: string; hunks: Hunk[] };

/**
 * Why a push needs the Release device-SDK compile (`ios-release`), or null when Release compiles it as
 * Debug does, so the Debug build already proves it. Release differs from Debug in its build settings
 * (`releaseSettingsPath`), in the sources it excludes (OppiDebugHarness, so an added, deleted, or
 * moved harness file changes what Release sees), and in code under a DEBUG condition: app source
 * counts when a hunk in any pushed range (`changes`) adds or removes a line inside a DEBUG chain, or
 * when its change cannot be read. `addedOrDeleted` comes from `git diff --no-renames --diff-filter=AD`.
 * The night's test-rot run compiles Release at main every night, the backstop for a break this rule
 * does not see (shared code that names a DEBUG-only symbol without touching a DEBUG chain).
 */
export function releaseCompileReason(
  changed: Iterable<string>,
  addedOrDeleted: ReadonlySet<string>,
  changes: (path: string) => FileChange[] | undefined,
): string | null {
  // A rename lists only its new path among the changed ones; addedOrDeleted has both.
  for (const path of new Set([...changed, ...addedOrDeleted])) {
    if (!path.startsWith("clients/apple/")) continue;
    if (releaseSettingsPath(path)) return `${path} is a Release build input`;
    const inApp = path.slice("clients/apple/".length);
    if (notInReleaseApp.some((folder) => inApp.startsWith(folder))) continue;
    if (inApp.startsWith("OppiDebugHarness/")) {
      if (addedOrDeleted.has(path)) return `${path} moved in or out of the harness Release excludes`;
      continue;
    }
    if (!/\.(swift|h|m|mm)$/.test(path)) continue;
    const fileChanges = changes(path);
    if (fileChanges === undefined) return `${path} could not be read`;
    if (fileChanges.some(touchesDebugCondition)) return `${path} changes code under a DEBUG condition`;
  }
  return null;
}

const git = (args: string[]) => spawnSync("git", args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });

/** The change to `path` in each pushed `<base>:<tip>` range; undefined when a diff fails. */
function changesIn(ranges: string[][]): (path: string) => FileChange[] | undefined {
  return (path) => {
    const out: FileChange[] = [];
    for (const [base, tip] of ranges) {
      const diff = git(["diff", "-U0", "--no-color", "--no-ext-diff", "--no-renames", base, tip, "--", path]);
      if (diff.status !== 0) return undefined;
      const hunks = parseHunks(diff.stdout);
      if (hunks.length === 0) continue;
      // A side the file is absent from reads as empty: it has no DEBUG chain.
      const at = (rev: string) => { const show = git(["show", `${rev}:${path}`]); return show.status === 0 ? show.stdout : ""; };
      out.push({ before: at(base), after: at(tip), hunks });
    }
    return out;
  };
}

function addedOrDeletedIn(ranges: string[][]): Set<string> {
  const paths = new Set<string>();
  for (const [base, tip] of ranges) {
    const diff = git(["diff", "--no-renames", "--name-only", "-z", "--diff-filter=AD", base, tip]);
    if (diff.status !== 0) throw new Error(`git diff ${base} ${tip} failed: ${diff.stderr}`);
    for (const path of diff.stdout.split("\0")) if (path) paths.add(path);
  }
  return paths;
}

function usage(): never {
  console.error(
    "Usage: scripts/pre-push-plan.ts (--paths-file <path> | --paths0-file <path>) [--ranges '<base>:<tip>...'] [--format shell|json]",
    "\n  --ranges: the pushed ranges; with them the plan decides APPLE_RELEASE (releaseCompileReason), without them every Apple plan compiles Release.",
  );
  process.exit(2);
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const textFileIndex = args.indexOf("--paths-file");
  const zeroFileIndex = args.indexOf("--paths0-file");
  const fileIndex = textFileIndex >= 0 ? textFileIndex : zeroFileIndex;
  if (fileIndex < 0 || !args[fileIndex + 1]) usage();
  const formatIndex = args.indexOf("--format");
  const format = formatIndex >= 0 ? args[formatIndex + 1] : "json";
  if (format !== "json" && format !== "shell") usage();

  const separator = zeroFileIndex >= 0 ? "\0" : "\n";
  const paths = readFileSync(args[fileIndex + 1]!, "utf8").split(separator).filter(Boolean);
  const plan = planForPaths(paths);
  const rangesIndex = args.indexOf("--ranges");
  const ranges = rangesIndex >= 0 ? (args[rangesIndex + 1] ?? "").split(/\s+/).filter(Boolean).map((range) => range.split(":")) : undefined;
  if (ranges?.some((range) => range.length !== 2 || !range[0] || !range[1])) usage();
  const releaseWhy = plan.apple === "none"
    ? null
    : ranges === undefined
      ? "no pushed ranges to check"
      : releaseCompileReason(plan.changedPaths, addedOrDeletedIn(ranges), changesIn(ranges));
  if (format === "json") {
    console.log(JSON.stringify({ ...plan, appleRelease: releaseWhy }, null, 2));
  } else {
    console.log(`SERVER_MODE=${plan.server}`);
    console.log(`APPLE_MODE=${plan.apple}`);
    console.log(`HARNESS_CHANGED=${plan.harness ? 1 : 0}`);
    console.log(`DOCS_CHANGED=${plan.docs ? 1 : 0}`);
    console.log(`CHANGED_COUNT=${plan.changedPaths.length}`);
    console.log(`APPLE_RELEASE=${releaseWhy === null ? 0 : 1}`);
    // Last: the hook reads the rest of the line as the reason.
    if (releaseWhy !== null) console.log(`APPLE_RELEASE_WHY=${releaseWhy}`);
  }
}

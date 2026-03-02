#!/usr/bin/env node

/**
 * Run mechanical review checks, then dispatch an AI review session
 * if warnings or failures are found.
 *
 * Usage:
 *   node scripts/review-dispatch.mjs [--commits N] [--staged] [--force]
 *
 * --force: dispatch review session even if all checks pass
 */

import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, "../..");

// Pass through args to ai-review.mjs
const args = process.argv.slice(2);
const force = args.includes("--force");
const reviewArgs = args.filter((a) => a !== "--force");

// Run mechanical review
console.log("Running mechanical review checks...\n");

let reviewOutput;
try {
  reviewOutput = execFileSync("node", [resolve(scriptDir, "ai-review.mjs"), ...reviewArgs], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: ["inherit", "pipe", "pipe"],
  });
} catch (error) {
  reviewOutput = error.stdout || "";
}

// Parse the JSON summary from output
const summaryMatch = reviewOutput.match(/=== AI Review Summary ===\n([\s\S]*?)\n\n=== AI Review Prompt ===/);
const promptMatch = reviewOutput.match(/=== AI Review Prompt ===\n([\s\S]*)/);

if (!summaryMatch || !promptMatch) {
  console.error("Failed to parse ai-review output");
  console.error(reviewOutput);
  process.exit(1);
}

const summary = JSON.parse(summaryMatch[1]);
const reviewPrompt = promptMatch[1];

console.log(`Status: ${summary.status.toUpperCase()}`);
console.log(`Files: ${summary.changedFileCount}`);
for (const check of summary.checks) {
  const icon = check.status === "pass" ? "ok" : check.status === "warn" ? "!!" : "XX";
  console.log(`  [${icon}] ${check.id}: ${check.reason}`);
}

if (summary.status === "pass" && !force) {
  console.log("\nAll checks passed. No review session needed.");
  console.log("Use --force to dispatch a review session anyway.");
  process.exit(0);
}

// Dispatch review session
console.log("\nDispatching review session...");

const localDispatchPath = resolve(repoRoot, "server/skills/agent-sessions/scripts/agent-sessions.mjs");
const homeDispatchPath = resolve(process.env.HOME ?? "", ".claude/skills/agent-sessions/scripts/agent-sessions.mjs");
const dispatchPath = existsSync(localDispatchPath) ? localDispatchPath : homeDispatchPath;

if (!existsSync(dispatchPath)) {
  console.error("Dispatch script not found. Expected one of:");
  console.error(`  - ${localDispatchPath}`);
  console.error(`  - ${homeDispatchPath}`);
  process.exit(1);
}

const prompt = `You are a code reviewer for the Oppi project.

The mechanical pre-checks have already run. Your job is to review the actual diff for:
1. Correctness — bugs, logic errors, missing edge cases
2. Architecture compliance — do changes follow ARCHITECTURE.md dependency rules?
3. Golden principles — are docs/golden-principles.md invariants respected?
4. Protocol discipline — if protocol files changed, are both sides updated?
5. Test coverage — are new behaviors tested?
6. Documentation — are docs updated to reflect changes?

Here is the mechanical review output and full diff:

${reviewPrompt}

Provide a structured review with:
- Summary (1-2 sentences)
- Issues found (if any), with file:line references
- Verdict: PASS / WARN / FAIL`;

try {
  const result = execFileSync(
    "node",
    [
      dispatchPath,
      "dispatch",
      "--workspace",
      "oppi",
      "--name",
      "ai-review",
      "--model",
      "openai-codex/gpt-5.3-codex",
      "--thinking",
      "high",
      "--prompt",
      prompt,
      "--json",
    ],
    {
      cwd: repoRoot,
      encoding: "utf8",
      stdio: ["inherit", "pipe", "pipe"],
    },
  );
  const parsed = JSON.parse(result);
  console.log(`Review session dispatched: ${parsed.sessionId}`);
} catch (error) {
  console.error("Failed to dispatch review session:", error.message);
  process.exit(1);
}

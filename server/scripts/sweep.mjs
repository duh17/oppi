#!/usr/bin/env node

/**
 * Codebase GC sweep — runs all quality passes and outputs a markdown report.
 *
 * Usage:
 *   node scripts/sweep.mjs           # full sweep
 *   node scripts/sweep.mjs --quick   # server-only (skip periphery)
 */

import { execSync, spawnSync } from "node:child_process";
import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { resolve, basename, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = fileURLToPath(new URL(".", import.meta.url));
const serverRoot = resolve(__dirname, "..");
const repoRoot = resolve(serverRoot, "..");
const iosRoot = resolve(repoRoot, "ios");

const quick = process.argv.includes("--quick");

const sections = [];
let exitCode = 0;

// ── Pass 1: Dead TS code (knip) ──

{
  const result = spawnSync("npx", ["knip"], { cwd: serverRoot, encoding: "utf8" });
  if (result.status === 0) {
    sections.push("### Dead TS code (knip)\n\nClean — no unused exports or types.");
  } else {
    const lines = (result.stdout + result.stderr).trim().split("\n");
    sections.push(
      `### Dead TS code (knip)\n\n${lines.length} finding(s):\n\n\`\`\`\n${lines.join("\n")}\n\`\`\``,
    );
    exitCode = 1;
  }
}

// ── Pass 2: Dead Swift code (periphery) ──

if (!quick) {
  const peripheryScript = resolve(iosRoot, "scripts/dead-code.sh");
  if (existsSync(peripheryScript)) {
    try {
      const output = execSync(`bash scripts/dead-code.sh --summary`, {
        cwd: iosRoot,
        encoding: "utf8",
        timeout: 300_000,
      }).trim();
      sections.push(`### Dead Swift code (periphery)\n\n${output}`);
    } catch (e) {
      sections.push(`### Dead Swift code (periphery)\n\nFailed: ${e.message}`);
    }
  } else {
    sections.push("### Dead Swift code (periphery)\n\nSkipped — script not found.");
  }
} else {
  sections.push("### Dead Swift code (periphery)\n\nSkipped (--quick mode).");
}

// ── Pass 3: Coverage snapshot ──

{
  const coverageSummaryPath = resolve(serverRoot, "coverage/coverage-summary.json");
  if (existsSync(coverageSummaryPath)) {
    try {
      const summary = JSON.parse(readFileSync(coverageSummaryPath, "utf8"));
      const total = summary.total;
      const fmt = (pct) => `${pct.toFixed(1)}%`;
      sections.push(
        [
          "### Server coverage snapshot",
          "",
          `| Metric | Value |`,
          `|--------|-------|`,
          `| Statements | ${fmt(total.statements.pct)} |`,
          `| Branches | ${fmt(total.branches.pct)} |`,
          `| Functions | ${fmt(total.functions.pct)} |`,
          `| Lines | ${fmt(total.lines.pct)} |`,
          "",
          "_Run `npm run test:coverage` to regenerate._",
        ].join("\n"),
      );
    } catch {
      sections.push("### Server coverage snapshot\n\nFailed to parse coverage-summary.json.");
    }
  } else {
    sections.push(
      "### Server coverage snapshot\n\nNo coverage data. Run `npm run test:coverage` first.",
    );
  }
}

// ── Pass 4: File size budget ──

{
  const SERVER_BUDGET = 500;
  const IOS_BUDGET = 800;
  const violations = [];

  // Server .ts files (non-test)
  const findFiles = (dir, ext, exclude) => {
    const results = [];
    const walk = (d) => {
      for (const entry of readdirSync(d, { withFileTypes: true })) {
        const full = join(d, entry.name);
        if (entry.isDirectory() && entry.name !== "node_modules" && entry.name !== "dist") {
          walk(full);
        } else if (entry.isFile() && entry.name.endsWith(ext) && !exclude(entry.name)) {
          results.push(full);
        }
      }
    };
    walk(dir);
    return results;
  };

  const serverFiles = findFiles(resolve(serverRoot, "src"), ".ts", (n) => n.endsWith(".test.ts"));
  for (const f of serverFiles) {
    const lines = readFileSync(f, "utf8").split("\n").length;
    if (lines > SERVER_BUDGET) {
      violations.push(`- \`${relative(repoRoot, f)}\`: ${lines} lines (budget: ${SERVER_BUDGET})`);
    }
  }

  const iosFiles = findFiles(resolve(iosRoot, "Oppi"), ".swift", () => false);
  for (const f of iosFiles) {
    const lines = readFileSync(f, "utf8").split("\n").length;
    if (lines > IOS_BUDGET) {
      violations.push(`- \`${relative(repoRoot, f)}\`: ${lines} lines (budget: ${IOS_BUDGET})`);
    }
  }

  if (violations.length === 0) {
    sections.push("### File size budget\n\nAll files within budget.");
  } else {
    sections.push(
      `### File size budget\n\n${violations.length} file(s) over budget:\n\n${violations.join("\n")}`,
    );
  }
}

// ── Pass 5: TODO staleness ──

{
  const todosDir = resolve(repoRoot, ".pi/todos");
  if (existsSync(todosDir)) {
    const now = Date.now();
    const DAY_MS = 86_400_000;
    const STALE_DAYS = 14;
    let open = 0;
    let stale = 0;
    let oldest = null;
    const staleItems = [];

    for (const file of readdirSync(todosDir)) {
      if (!file.endsWith(".md")) continue;
      const content = readFileSync(join(todosDir, file), "utf8");

      // TODO files have JSON header followed by markdown body
      let meta;
      try {
        const jsonEnd = content.indexOf("\n}");
        if (jsonEnd === -1) continue;
        meta = JSON.parse(content.slice(0, jsonEnd + 2));
      } catch {
        continue;
      }

      const status = meta.status;
      if (status === "closed" || status === "done" || status === "cancelled") continue;

      open++;
      if (meta.created_at) {
        const created = new Date(meta.created_at);
        const ageDays = Math.floor((now - created.getTime()) / DAY_MS);
        if (!oldest || ageDays > oldest) oldest = ageDays;
        if (ageDays >= STALE_DAYS) {
          stale++;
          staleItems.push(`- TODO-${file.replace(".md", "")} (${ageDays}d): ${meta.title || file}`);
        }
      }
    }

    const lines = [
      `### TODO health`,
      "",
      `| Metric | Value |`,
      `|--------|-------|`,
      `| Open | ${open} |`,
      `| Stale (>${STALE_DAYS}d) | ${stale} |`,
      `| Oldest | ${oldest ?? 0}d |`,
    ];

    if (staleItems.length > 0) {
      lines.push("", "Stale items:", "", ...staleItems);
    }

    sections.push(lines.join("\n"));
  } else {
    sections.push("### TODO health\n\nNo .pi/todos directory found.");
  }
}

// ── Output ──

const date = new Date().toISOString().split("T")[0];
const report = [`## Sweep Report — ${date}`, "", ...sections].join("\n\n");

console.log(report);

if (exitCode !== 0) {
  console.log("\nSweep found issues that need attention.");
}

process.exit(exitCode);

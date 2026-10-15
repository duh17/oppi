#!/usr/bin/env bun
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { stripSwiftCommentsAndStrings } from "../server/scripts/architecture-layer-rules.mjs";

/**
 * UIKit-first ownership ratchet for the iOS app target (clients/apple/Oppi).
 *
 * UIKit owns iOS app structure, modal presentation, and new views. SwiftUI
 * app-structure constructs may remain in existing screens, but their per-file
 * counts can only go down. A file's count for a construct fails the guard when
 * it exceeds uikit-structure-baseline.json (files absent from the baseline have
 * baseline 0). Decreases pass. Policy: dev/architecture-client.md,
 * "UIKit and SwiftUI ownership".
 *
 * Comments and string literals are stripped before matching.
 *
 *   bun scripts/uikit-structure-guard.ts            check against the baseline
 *   bun scripts/uikit-structure-guard.ts --update   rewrite the baseline from
 *                                                   current source (deliberate
 *                                                   regeneration only)
 */

type Construct = { name: string; pattern: RegExp };
type Counts = Record<string, number>;
type Baseline = Record<string, Counts>;
type Hit = { file: string; line: number; construct: string };

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const scanRoot = join(repoRoot, "clients/apple/Oppi");
const baselinePath = join(repoRoot, "scripts/uikit-structure-baseline.json");
const guide = "dev/architecture-client.md, section \"UIKit and SwiftUI ownership\"";

const constructs: Construct[] = [
  { name: "NavigationStack", pattern: /\bNavigationStack\b/g },
  { name: "NavigationSplitView", pattern: /\bNavigationSplitView\b/g },
  { name: "NavigationLink", pattern: /\bNavigationLink\b/g },
  { name: ".navigationDestination(", pattern: /\.navigationDestination\s*\(/g },
  { name: ".sheet(", pattern: /\.sheet\s*\(/g },
  { name: ".fullScreenCover(", pattern: /\.fullScreenCover\s*\(/g },
  { name: ".popover(", pattern: /\.popover\s*\(/g },
  { name: ".inspector(", pattern: /\.inspector\s*\(/g },
  { name: "UIHostingController(", pattern: /\bUIHostingController\s*(?:<[^>(]*>)?\s*\(/g },
  { name: "import SwiftUI", pattern: /^[ \t]*(?:@\w+[ \t]+)*import[ \t]+SwiftUI\b/gm },
];

function walkSwiftFiles(root: string): string[] {
  if (!existsSync(root)) return [];
  const files: string[] = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) {
      files.push(...walkSwiftFiles(path));
    } else if (entry.isFile() && entry.name.endsWith(".swift")) {
      files.push(path);
    }
  }
  return files;
}

function scan(): Hit[] {
  const hits: Hit[] = [];
  for (const absFile of walkSwiftFiles(scanRoot)) {
    const file = relative(repoRoot, absFile);
    const stripped = stripSwiftCommentsAndStrings(readFileSync(absFile, "utf8"));
    for (const { name, pattern } of constructs) {
      for (const match of stripped.matchAll(pattern)) {
        const start = match.index + (match[0].length - match[0].trimStart().length);
        const line = stripped.slice(0, start).split("\n").length;
        hits.push({ file, line, construct: name });
      }
    }
  }
  return hits;
}

function countByFile(hits: Hit[]): Baseline {
  const result: Baseline = {};
  for (const hit of hits) {
    const counts = (result[hit.file] ??= {});
    counts[hit.construct] = (counts[hit.construct] ?? 0) + 1;
  }
  // Stable ordering keeps baseline diffs reviewable.
  const sorted: Baseline = {};
  for (const file of Object.keys(result).sort()) {
    const counts: Counts = {};
    for (const { name } of constructs) {
      if (result[file][name]) counts[name] = result[file][name];
    }
    sorted[file] = counts;
  }
  return sorted;
}

function loadBaseline(): Baseline {
  if (!existsSync(baselinePath)) {
    console.error(`UIKit structure guard: missing baseline ${relative(repoRoot, baselinePath)}.`);
    process.exit(1);
  }
  return JSON.parse(readFileSync(baselinePath, "utf8")).files as Baseline;
}

const hits = scan();

if (process.argv.includes("--update")) {
  const files = countByFile(hits);
  writeFileSync(baselinePath, `${JSON.stringify({ version: 1, files }, null, 2)}\n`);
  console.log(`UIKit structure guard: baseline rewritten (${Object.keys(files).length} files).`);
  process.exit(0);
}

const baseline = loadBaseline();
const current = countByFile(hits);
const failures: string[] = [];

for (const [file, counts] of Object.entries(current)) {
  for (const [construct, count] of Object.entries(counts)) {
    const allowed = baseline[file]?.[construct] ?? 0;
    if (count <= allowed) continue;
    failures.push(`- ${file}: ${construct} count ${count} exceeds baseline ${allowed}`);
    for (const hit of hits) {
      if (hit.file === file && hit.construct === construct) {
        failures.push(`    ${file}:${hit.line}: ${construct}`);
      }
    }
  }
}

if (failures.length === 0) {
  console.log("UIKit structure guard: PASS — no SwiftUI structure constructs above baseline.");
  process.exit(0);
}

console.log("UIKit structure guard: FAIL — SwiftUI structure constructs exceed the ratchet baseline.\n");
for (const line of failures) console.log(line);
console.log(`
UIKit owns iOS app structure, modal presentation, and new views. New screens and
views are UIKit view controllers/views; present modals through UIKit (uiKitSheet
until the AppNavigation router exists). See ${guide}.
Existing SwiftUI screens change only when a trigger (crash/bug in the screen,
substantive rewrite, router migration) moves them; name the trigger in the commit.
Raising the baseline needs Chen's approval. Lowering it after a migration is
expected: run \`bun scripts/uikit-structure-guard.ts --update\` and commit the
reduced baseline with the migration. After a rename or move, --update is fine when
the baseline diff only moves entries.`);
process.exit(1);

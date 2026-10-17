#!/usr/bin/env bun
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { stripSwiftCommentsAndStrings } from "../server/scripts/architecture-layer-rules.mjs";

/**
 * UIKit-first ownership guard for the iOS app target (clients/apple/Oppi).
 *
 * UIKit owns iOS app structure, modal presentation, and new views. Two rules:
 *
 *  - Navigation and presentation constructs (NavigationStack, .sheet(, ...)
 *    and UIHostingController( are disallowed in every file, debug previews and
 *    harnesses included. The only exceptions are the commented entries in
 *    `allowed` below.
 *  - `import SwiftUI` is a ratchet: a file's count fails the guard when it
 *    exceeds uikit-structure-baseline.json (files absent from the baseline
 *    have baseline 0). Decreases pass.
 *
 * Policy: dev/architecture-client.md, "UIKit and SwiftUI ownership".
 * Comments and string literals are stripped before matching.
 *
 *   bun scripts/uikit-structure-guard.ts            check against the baseline
 *   bun scripts/uikit-structure-guard.ts --update   rewrite the baseline from
 *                                                   current source (deliberate
 *                                                   regeneration only)
 */

type Construct = { name: string; pattern: RegExp; disallowed: boolean };
type Counts = Record<string, number>;
type Baseline = Record<string, Counts>;
type Hit = { file: string; line: number; construct: string };

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const scanRoot = join(repoRoot, "clients/apple/Oppi");
const baselinePath = join(repoRoot, "scripts/uikit-structure-baseline.json");
const guide = "dev/architecture-client.md, section \"UIKit and SwiftUI ownership\"";

const constructs: Construct[] = [
  { name: "NavigationStack", pattern: /\bNavigationStack\b/g, disallowed: true },
  { name: "NavigationSplitView", pattern: /\bNavigationSplitView\b/g, disallowed: true },
  { name: "NavigationLink", pattern: /\bNavigationLink\b/g, disallowed: true },
  { name: ".navigationDestination(", pattern: /\.navigationDestination\s*\(/g, disallowed: true },
  { name: ".sheet(", pattern: /\.sheet\s*\(/g, disallowed: true },
  { name: ".fullScreenCover(", pattern: /\.fullScreenCover\s*\(/g, disallowed: true },
  { name: ".popover(", pattern: /\.popover\s*\(/g, disallowed: true },
  { name: ".inspector(", pattern: /\.inspector\s*\(/g, disallowed: true },
  { name: "UIHostingController(", pattern: /\bUIHostingController\s*(?:<[^>(]*>)?\s*\(/g, disallowed: true },
  { name: "import SwiftUI", pattern: /^[ \t]*(?:@\w+[ \t]+)*import[ \t]+SwiftUI\b/gm, disallowed: false },
];

/**
 * Disallowed constructs that may stay, per file: the construct and how many
 * uses. Every entry needs a reason; an entry nobody needs is deleted.
 */
const allowed: { file: string; construct: string; count: number; reason: string }[] = [
  // Removed by S7a: these sheets stop owning a NavigationStack once every
  // caller presents them through the router. The entries stay valid after that
  // (an allowance above the actual count passes) and are deleted with it.
  ...[
    "clients/apple/Oppi/Features/Chat/Composer/ExpandedComposerView.swift",
    "clients/apple/Oppi/Features/Chat/ReviewComments/ReviewCommentStashSheet.swift",
    "clients/apple/Oppi/Features/Chat/Support/ModelPickerSheet.swift",
    "clients/apple/Oppi/Features/Icons/IconPickerView.swift",
    "clients/apple/Oppi/Features/Workspaces/WorkspaceCreateView.swift",
  ].map((file) => ({ file, construct: "NavigationStack", count: 1, reason: "removed by S7a" })),
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

const ratcheted = new Set(constructs.filter((c) => !c.disallowed).map((c) => c.name));
const hits = scan();

if (process.argv.includes("--update")) {
  const files = countByFile(hits.filter((hit) => ratcheted.has(hit.construct)));
  writeFileSync(baselinePath, `${JSON.stringify({ version: 1, files }, null, 2)}\n`);
  console.log(`UIKit structure guard: baseline rewritten (${Object.keys(files).length} files).`);
  process.exit(0);
}

const baseline = loadBaseline();
const current = countByFile(hits);
const failures: string[] = [];

for (const [file, counts] of Object.entries(current)) {
  for (const [construct, count] of Object.entries(counts)) {
    const limit = ratcheted.has(construct)
      ? (baseline[file]?.[construct] ?? 0)
      : (allowed.find((entry) => entry.file === file && entry.construct === construct)?.count ?? 0);
    if (count <= limit) continue;
    const rule = ratcheted.has(construct) ? "baseline" : "allowed";
    failures.push(`- ${file}: ${construct} count ${count} exceeds ${rule} ${limit}`);
    for (const hit of hits) {
      if (hit.file === file && hit.construct === construct) {
        failures.push(`    ${file}:${hit.line}: ${construct}`);
      }
    }
  }
}

if (failures.length === 0) {
  console.log("UIKit structure guard: PASS — no disallowed SwiftUI structure constructs, import SwiftUI within baseline.");
  process.exit(0);
}

console.log("UIKit structure guard: FAIL — SwiftUI structure constructs the guard disallows or the import baseline exceeds.\n");
for (const line of failures) console.log(line);
console.log(`
UIKit owns iOS app structure, modal presentation, and new views, previews and
harnesses included. Present and push through the router (routerModal,
ScreenNavigator present/push/finish; previews host with RouterPreviewStack or
RouterPreviewNavigation) and host SwiftUI only through HostFactory. See ${guide}.
NavigationStack, NavigationSplitView, NavigationLink, .navigationDestination(,
.sheet(, .fullScreenCover(, .popover(, .inspector(, and UIHostingController(
have no baseline: an exception needs Chen's approval and a commented entry in
the guard's allowed list. A new \`import SwiftUI\` raises that file's baseline,
which also needs approval; \`bun scripts/uikit-structure-guard.ts --update\`
lowers it after a migration. After a rename or move, --update is fine when the
baseline diff only moves entries.`);
process.exit(1);

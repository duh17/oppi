#!/usr/bin/env bun
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

type Hit = {
  file: string;
  line: number;
  text: string;
};

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const scanRoots = [
  join(repoRoot, "clients/apple/Oppi/Features/Chat/Timeline"),
  join(repoRoot, "clients/apple/Oppi/Features/Chat/Session"),
];

const allowedFiles = new Set([
  // Low-level primitive for UIKit self-sizing correction.
  "clients/apple/Oppi/Features/Chat/Timeline/AnchoredCollectionView.swift",
  // Centralized outer timeline offset correction API.
  "clients/apple/Oppi/Features/Chat/Timeline/Collection/TimelineOffsetController.swift",
  // Inner timeline/tool scroll views. These do not own outer timeline offset.
  "clients/apple/Oppi/Features/Chat/Timeline/Tool/ToolTimelineRowHelpers.swift",
  "clients/apple/Oppi/Features/Chat/Timeline/Tool/BashToolRowView.swift",
  "clients/apple/Oppi/Features/Chat/Timeline/Tool/ToolTimelineRowContent.swift",
  "clients/apple/Oppi/Features/Chat/Timeline/Rows/ThinkingTimelineRowContent.swift",
  "clients/apple/Oppi/Features/Chat/Timeline/Rows/UserTimelineRowContent.swift",
]);

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

function isOffsetMutation(line: string): boolean {
  const trimmed = line.trim();
  return /\b(collectionView|scrollView)\.contentOffset\.y\s*=/.test(trimmed)
    || /\b(collectionView|scrollView)\.setContentOffset\s*\(/.test(trimmed)
    || /\bsetContentOffset\s*\(/.test(trimmed);
}

const hits: Hit[] = [];

for (const absFile of scanRoots.flatMap(walkSwiftFiles)) {
  const file = relative(repoRoot, absFile);
  if (allowedFiles.has(file)) continue;

  const lines = readFileSync(absFile, "utf8").split(/\r?\n/);
  for (const [index, line] of lines.entries()) {
    if (!isOffsetMutation(line)) continue;
    hits.push({ file, line: index + 1, text: line.trim() });
  }
}

if (hits.length === 0) {
  console.log("Scroll offset guard: PASS — no direct outer timeline offset writes.");
  process.exit(0);
}

console.log("Scroll offset guard: FAIL — direct outer timeline offset writes found.\n");
for (const hit of hits) {
  console.log(`- ${hit.file}:${hit.line}: ${hit.text}`);
}
console.log("\nRoute outer timeline offset changes through TimelineOffsetController.");
process.exit(1);

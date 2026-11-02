#!/usr/bin/env bun
/**
 * Keeps contributor docs (`dev/**`) to the standard in dev/README.md, "What belongs in dev/":
 * owners, boundaries, invariants, entry points, and for testing docs commands and gotchas;
 * never feature behaviour, flows, or slice narratives. Two mechanical limits hold the line:
 *
 *  - a word budget per doc, in `dev/doc-budgets.json` (set at the doc's rewritten size plus about
 *    15%; every `dev/**` Markdown file needs an entry, and an entry needs its file). A generated
 *    region (`<!-- name:begin … -->` to `<!-- name:end -->`, such as telemetry.md's event tables)
 *    does not count: it grows with its source, not with prose;
 *  - a maximum paragraph length (`maxParagraphChars`), measured per paragraph and per list item.
 *    Tables and fenced code are not paragraphs.
 *
 *   bun scripts/dev-docs-guard.ts            check every dev/ doc
 *
 * The pre-push hook runs it whenever a `dev/**` Markdown file or the budget file changes.
 */
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

type Budgets = { reason: string; maxParagraphChars: number; words: Record<string, number> };
export type LongParagraph = { line: number; chars: number };

const budgetsPath = "dev/doc-budgets.json";
const standard = "dev/README.md, section \"What belongs in dev/\"";

/** Whitespace-separated words, as `wc -w` counts them, outside generated regions. */
export function countWords(text: string): number {
  const prose = text.replace(/<!-- ([\w-]+):begin\b[^>]*-->[\s\S]*?<!-- \1:end -->/g, "");
  return prose.split(/\s+/).filter(Boolean).length;
}

/** Paragraphs and list items longer than `max` characters, with the line each starts on. */
export function longParagraphs(text: string, max: number): LongParagraph[] {
  const hits: LongParagraph[] = [];
  let fence: string | null = null;
  let start = 0;
  let parts: string[] = [];
  const flush = () => {
    const chars = parts.join(" ").length;
    if (chars > max) hits.push({ line: start, chars });
    parts = [];
  };
  for (const [index, raw] of text.split(/\r?\n/).entries()) {
    const line = raw.trim();
    const fenceMark = /^(```|~~~)/.exec(line)?.[1];
    if (fence) {
      if (fenceMark === fence) fence = null;
      continue;
    }
    if (fenceMark) {
      flush();
      fence = fenceMark;
      continue;
    }
    if (line === "" || line.startsWith("|")) {
      flush();
      continue;
    }
    // A heading or list item starts a paragraph of its own; any other line continues the current one.
    if (parts.length === 0 || /^(#{1,6}\s|[-*+]\s|\d+[.)]\s)/.test(line)) {
      flush();
      start = index + 1;
    }
    parts.push(line);
  }
  flush();
  return hits;
}

function markdownFiles(dir: string): string[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return markdownFiles(path);
    return entry.isFile() && entry.name.endsWith(".md") ? [path] : [];
  });
}

/** Every failure under `root`, one message each; empty when the docs meet the standard. */
export function checkDocs(root: string): string[] {
  const budgets = JSON.parse(readFileSync(join(root, budgetsPath), "utf8")) as Budgets;
  const failures: string[] = [];
  const docs = markdownFiles(join(root, "dev")).map((path) => relative(root, path)).sort();
  for (const doc of docs) {
    const text = readFileSync(join(root, doc), "utf8");
    const budget = budgets.words[doc];
    const words = countWords(text);
    if (budget === undefined) {
      failures.push(`${doc}: no budget in ${budgetsPath} (${words} words). Add one at its size plus about 15%, with the reason.`);
    } else if (words > budget) {
      failures.push(`${doc}: ${words} words, budget ${budget}. Move behaviour, flows, and history into code comments and tests (${standard}), or raise the budget in ${budgetsPath} with a reason.`);
    }
    for (const hit of longParagraphs(text, budgets.maxParagraphChars)) {
      failures.push(`${doc}:${hit.line}: paragraph of ${hit.chars} characters, limit ${budgets.maxParagraphChars}. Split it into rules of a sentence or two each (${standard}).`);
    }
  }
  for (const doc of Object.keys(budgets.words).sort()) {
    if (!docs.includes(doc)) failures.push(`${budgetsPath}: budget for ${doc}, which does not exist. Remove the entry.`);
  }
  return failures;
}

if (import.meta.main) {
  const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
  const failures = checkDocs(repoRoot);
  if (failures.length === 0) {
    console.log("Dev docs guard: PASS — every dev/ doc within its word budget and paragraph limit.");
    process.exit(0);
  }
  console.log("Dev docs guard: FAIL\n");
  for (const failure of failures) console.log(`- ${failure}`);
  console.log(`\nStandard: ${standard}.`);
  process.exit(1);
}

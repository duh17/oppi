/**
 * Review diff benchmark: line diff + word spans for the shapes that reach the
 * commit, workspace, and session diff views.
 *
 * Cases (deterministic, generated in-process):
 *   prose_rewrite        CHANGELOG-style trim: long paragraphs, a block of 131
 *                        removed lines replaced by 92 new ones, plus word edits.
 *   code_edit            3,000-line source file with scattered small edits.
 *   long_line_edit       200 lines of ~2,000 characters, one word edited in 50.
 *   unrelated_rewrite    2,000 lines fully replaced.
 *   repetitive_shuffle   4,000 lines from a 12-line vocabulary (worst case for
 *                        line matching; exercises the work cap).
 *
 * Every case is checked before it is timed: context + removed must rebuild the
 * old text and context + added the new text, or the benchmark exits non-zero.
 *
 * METRIC lines (stdout):
 *   <case>_line_avg_us   computeDiffLines
 *   <case>_word_avg_us   buildDiffHunks (pairing, word spans, hunks)
 *   <case>_spans         word highlight spans sent to the client
 *   <case>_payload_bytes JSON bytes of the hunks
 *   total_avg_us
 */

import { computeDiffLines, type DiffLine } from "../src/diff-core.js";
import { buildDiffHunks } from "../src/workspace-review-diff.js";

const WARMUP_ITERATIONS = 3;
const BENCH_ITERATIONS = 15;

function seededRandom(seed: number): () => number {
  let state = seed;
  return () => {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    return state / 0x7fffffff;
  };
}

const VOCABULARY = [
  "session",
  "server",
  "client",
  "durable",
  "workspace",
  "diff",
  "review",
  "opens",
  "the",
  "a",
  "with",
  "no",
  "longer",
  "shows",
  "file",
  "changes",
  "commit",
  "line",
  "worktree",
  "extension",
  "approval",
  "device",
  "theme",
  "timeline",
  "reload",
];

function sentence(random: () => number, words: number): string {
  return Array.from(
    { length: words },
    () => VOCABULARY[Math.floor(random() * VOCABULARY.length)]!,
  ).join(" ");
}

function editOneWord(random: () => number, text: string): string {
  const words = text.split(" ");
  const index = Math.floor(random() * words.length);
  words[index] = `${words[index]}ed`;
  return words.join(" ");
}

type Case = { name: string; oldText: string; newText: string };

function proseRewrite(): Case {
  const random = seededRandom(1);
  const paragraph = () => `- **Client:** ${sentence(random, 40 + Math.floor(random() * 260))}.`;
  const oldLines: string[] = [];
  for (let index = 0; index < 700; index += 1) {
    oldLines.push(index % 40 === 0 ? `## [0.${index / 40}.0]` : index % 7 === 0 ? "" : paragraph());
  }
  const newLines = [...oldLines];
  newLines.splice(160, 131, ...Array.from({ length: 92 }, paragraph));
  for (let edit = 0; edit < 10; edit += 1) {
    const index = 320 + edit * 20;
    if (newLines[index]) newLines[index] = editOneWord(random, newLines[index]!);
  }
  return {
    name: "prose_rewrite",
    oldText: `${oldLines.join("\n")}\n`,
    newText: `${newLines.join("\n")}\n`,
  };
}

function codeEdit(): Case {
  const random = seededRandom(2);
  const oldLines = Array.from({ length: 3_000 }, (_, index) =>
    index % 9 === 0
      ? "}"
      : `    let value${index} = compute(${index}, flag: true) // ${sentence(random, 3)}`,
  );
  const newLines = [...oldLines];
  for (let edit = 0; edit < 40; edit += 1) {
    const index = 50 + edit * 70;
    newLines[index] = newLines[index]!.replace("compute", "computeFast");
  }
  for (let edit = 0; edit < 10; edit += 1) {
    newLines.splice(100 + edit * 250, 0, `    log("inserted ${edit}")`);
    newLines.splice(200 + edit * 250, 1);
  }
  return {
    name: "code_edit",
    oldText: `${oldLines.join("\n")}\n`,
    newText: `${newLines.join("\n")}\n`,
  };
}

function longLineEdit(): Case {
  const random = seededRandom(3);
  const oldLines = Array.from({ length: 200 }, () => sentence(random, 300));
  const newLines = oldLines.map((text, index) =>
    index % 4 === 0 ? editOneWord(random, text) : text,
  );
  return {
    name: "long_line_edit",
    oldText: `${oldLines.join("\n")}\n`,
    newText: `${newLines.join("\n")}\n`,
  };
}

function unrelatedRewrite(): Case {
  const random = seededRandom(4);
  const oldLines = Array.from(
    { length: 2_000 },
    (_, index) => `old ${index} ${sentence(random, 8)}`,
  );
  const newLines = Array.from(
    { length: 2_000 },
    (_, index) => `new ${index} ${sentence(random, 8)}`,
  );
  return {
    name: "unrelated_rewrite",
    oldText: `${oldLines.join("\n")}\n`,
    newText: `${newLines.join("\n")}\n`,
  };
}

function repetitiveShuffle(): Case {
  const random = seededRandom(5);
  const pool = [
    "}",
    "",
    "  return value",
    "  }",
    "{",
    "  if (ok) {",
    "    break",
    "  else",
    "//",
    "  x += 1",
    "  y -= 1",
    "end",
  ];
  const pick = () => pool[Math.floor(random() * pool.length)]!;
  const oldLines = Array.from({ length: 4_000 }, pick);
  const newLines = Array.from({ length: 4_000 }, pick);
  return {
    name: "repetitive_shuffle",
    oldText: `${oldLines.join("\n")}\n`,
    newText: `${newLines.join("\n")}\n`,
  };
}

function rebuild(lines: DiffLine[], drop: DiffLine["kind"]): string {
  return lines
    .filter((line) => line.kind !== drop)
    .map((line) => `${line.text}\n`)
    .join("");
}

function averageUs(run: () => void): number {
  for (let index = 0; index < WARMUP_ITERATIONS; index += 1) run();
  const started = process.hrtime.bigint();
  for (let index = 0; index < BENCH_ITERATIONS; index += 1) run();
  return Number(process.hrtime.bigint() - started) / 1_000 / BENCH_ITERATIONS;
}

const cases = [proseRewrite(), codeEdit(), longLineEdit(), unrelatedRewrite(), repetitiveShuffle()];
let total = 0;
const rows: string[] = [];

for (const benchCase of cases) {
  const flat = computeDiffLines(benchCase.oldText, benchCase.newText);
  if (
    rebuild(flat, "added") !== benchCase.oldText ||
    rebuild(flat, "removed") !== benchCase.newText
  ) {
    console.error(`[review-diff] ${benchCase.name}: diff does not rebuild both texts`);
    process.exit(1);
  }
  const hunks = buildDiffHunks(flat);
  let spans = 0;
  for (const hunk of hunks) for (const line of hunk.lines) spans += line.spans?.length ?? 0;
  const payloadBytes = Buffer.byteLength(JSON.stringify(hunks));
  const changed = flat.filter((line) => line.kind !== "context").length;

  const lineUs = averageUs(() => computeDiffLines(benchCase.oldText, benchCase.newText));
  const wordUs = averageUs(() => buildDiffHunks(flat));
  total += lineUs + wordUs;

  console.log(`METRIC ${benchCase.name}_line_avg_us=${lineUs.toFixed(1)}`);
  console.log(`METRIC ${benchCase.name}_word_avg_us=${wordUs.toFixed(1)}`);
  console.log(`METRIC ${benchCase.name}_spans=${spans}`);
  console.log(`METRIC ${benchCase.name}_payload_bytes=${payloadBytes}`);
  rows.push(
    `${benchCase.name.padEnd(20)} line ${(lineUs / 1_000).toFixed(2).padStart(8)} ms  word ${(wordUs / 1_000).toFixed(2).padStart(8)} ms  changed ${String(changed).padStart(5)}  spans ${String(spans).padStart(6)}  payload ${String(payloadBytes).padStart(8)} B`,
  );
}

console.log(`METRIC total_avg_us=${total.toFixed(1)}`);
console.error(rows.join("\n"));

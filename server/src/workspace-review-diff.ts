import { readFile, realpath, stat } from "node:fs/promises";
import { resolve } from "node:path";

import { execGit, type GitTrust } from "./git-safe.js";
import { isPathWithinRoot, resolveHomePath } from "./git-utils.js";
import {
  computeDiffLines,
  computeLineDiffStatsFromLines,
  type DiffLine as FlatDiffLine,
} from "./diff-core.js";
import { matchSequences } from "./sequence-diff.js";
import type {
  WorkspaceReviewDiffHunk,
  WorkspaceReviewDiffLine,
  WorkspaceReviewDiffResponse,
  WorkspaceReviewDiffSpan,
} from "./types.js";

const GIT_TIMEOUT_MS = 5000;
const MAX_REVIEW_TEXT_BYTES = 256 * 1024;
const HUNK_CONTEXT_LINES = 3;
/**
 * A removed and an added line are the same line edited only when at least half
 * of their combined non-whitespace text is shared. Below that, word spans mark
 * almost every token of two unrelated lines, which is noise, not a word diff.
 */
const WORD_PAIR_MIN_SIMILARITY = 0.5;
/** How many added lines past the previous pair a removed line may look for its edit. */
const WORD_PAIR_LOOKAHEAD = 8;
/** Token-matching work for one diff; past it, remaining lines stay line-level. */
const WORD_DIFF_MAX_COST = 4_000_000;
/** Most changed places per side for a positional pair that is not similar. */
const WORD_FALLBACK_MAX_REGIONS = 3;
/** Work cap for one positional pair: a few dozen token edits, never a paragraph rewrite. */
const WORD_FALLBACK_MAX_COST = 4_096;

export class WorkspaceReviewDiffError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "WorkspaceReviewDiffError";
  }
}

type ReadTextResult = {
  text: string;
  exists: boolean;
};

type MutableReviewLine = WorkspaceReviewDiffLine;

type Token = {
  value: string;
  start: number;
  end: number;
  /** Whitespace run: matched for spans, ignored for line similarity. */
  space: boolean;
};

function bufferLooksBinary(buffer: Buffer): boolean {
  return buffer.includes(0);
}

async function gitBuffer(trust: GitTrust, cwd: string, args: string[]): Promise<Buffer | null> {
  const { error, stdout } = await execGit(trust, cwd, args, { timeout: GIT_TIMEOUT_MS });
  if (error) return null;
  return Buffer.isBuffer(stdout) ? stdout : Buffer.from(String(stdout), "utf8");
}

async function readHeadText(
  repoDir: string,
  trust: GitTrust,
  reqPath: string,
): Promise<ReadTextResult> {
  const resolved = resolveHomePath(repoDir);
  const stdout = await gitBuffer(trust, resolved, ["show", `HEAD:${reqPath}`]);

  if (stdout === null) {
    return { text: "", exists: false };
  }

  if (stdout.byteLength > MAX_REVIEW_TEXT_BYTES) {
    throw new WorkspaceReviewDiffError(413, "File too large for review.");
  }

  if (bufferLooksBinary(stdout)) {
    throw new WorkspaceReviewDiffError(422, "Binary files are not supported in review yet.");
  }

  return {
    text: stdout.toString("utf8"),
    exists: true,
  };
}

async function readCurrentText(repoDir: string, reqPath: string): Promise<ReadTextResult> {
  const resolvedRepoDir = resolveHomePath(repoDir);
  const target = resolve(resolvedRepoDir, reqPath);

  try {
    const resolvedRoot = await realpath(resolvedRepoDir);
    const resolvedTarget = await realpath(target);
    if (!isPathWithinRoot(resolvedTarget, resolvedRoot)) {
      throw new WorkspaceReviewDiffError(403, "Path escapes workspace root.");
    }

    const fileStat = await stat(resolvedTarget);
    if (!fileStat.isFile()) {
      return { text: "", exists: false };
    }

    if (fileStat.size > MAX_REVIEW_TEXT_BYTES) {
      throw new WorkspaceReviewDiffError(413, "File too large for review.");
    }

    const buffer = await readFile(resolvedTarget);
    if (bufferLooksBinary(buffer)) {
      throw new WorkspaceReviewDiffError(422, "Binary files are not supported in review yet.");
    }

    return {
      text: buffer.toString("utf8"),
      exists: true,
    };
  } catch (error) {
    if (error instanceof WorkspaceReviewDiffError) {
      throw error;
    }
    return { text: "", exists: false };
  }
}

function numberDiffLines(lines: FlatDiffLine[]): MutableReviewLine[] {
  let oldLine = 1;
  let newLine = 1;

  return lines.map((line) => {
    switch (line.kind) {
      case "context": {
        const numbered: MutableReviewLine = {
          kind: "context",
          text: line.text,
          oldLine,
          newLine,
        };
        oldLine += 1;
        newLine += 1;
        return numbered;
      }
      case "removed": {
        const numbered: MutableReviewLine = {
          kind: "removed",
          text: line.text,
          oldLine,
          newLine: null,
        };
        oldLine += 1;
        return numbered;
      }
      case "added": {
        const numbered: MutableReviewLine = {
          kind: "added",
          text: line.text,
          oldLine: null,
          newLine,
        };
        newLine += 1;
        return numbered;
      }
    }
  });
}

function tokenize(text: string): Token[] {
  if (!text) return [];

  const tokens: Token[] = [];
  const regex = /(\s+)|[\p{L}\p{N}_]+|[^\s\p{L}\p{N}_]+/gu;
  let match: RegExpExecArray | null;

  while ((match = regex.exec(text)) !== null) {
    tokens.push({
      value: match[0],
      start: match.index,
      end: match.index + match[0].length,
      space: match[1] !== undefined,
    });
  }

  if (tokens.length === 0) {
    return [{ value: text, start: 0, end: text.length, space: false }];
  }

  return tokens;
}

function mergeSpans(spans: WorkspaceReviewDiffSpan[]): WorkspaceReviewDiffSpan[] {
  if (spans.length <= 1) return spans;

  const first = spans[0];
  if (!first) {
    return [];
  }

  const merged: WorkspaceReviewDiffSpan[] = [{ ...first }];
  for (let index = 1; index < spans.length; index += 1) {
    const span = spans[index];
    const last = merged[merged.length - 1];
    if (!span || !last) {
      continue;
    }

    if (last.end >= span.start) {
      last.end = Math.max(last.end, span.end);
    } else {
      merged.push({ ...span });
    }
  }

  return merged;
}

/** Tokenized line text, interned for the integer sequence matcher. */
type WordLine = {
  tokens: Token[];
  ids: Int32Array;
  /** Non-whitespace characters per token (0 for whitespace runs). */
  weights: Int32Array;
  /** Sum of `weights`. */
  contentChars: number;
  /** Ids of the non-whitespace tokens, for the shared-text bound. */
  contentIds: number[];
};

/** Shared token table, scratch counts, and work budget for one diff. */
type WordDiffContext = {
  ids: Map<string, number>;
  /** Per-token-id scratch counts for the shared-text bound; all zero between calls. */
  counts: Int32Array;
  remainingCost: number;
};

function wordLine(text: string, context: WordDiffContext): WordLine {
  const tokens = tokenize(text);
  const ids = new Int32Array(tokens.length);
  const weights = new Int32Array(tokens.length);
  const contentIds: number[] = [];
  let contentChars = 0;
  tokens.forEach((token, index) => {
    let id = context.ids.get(token.value);
    if (id === undefined) {
      id = context.ids.size;
      context.ids.set(token.value, id);
    }
    ids[index] = id;
    if (token.space) return;
    weights[index] = token.end - token.start;
    contentChars += token.end - token.start;
    contentIds.push(id);
  });
  return { tokens, ids, weights, contentChars, contentIds };
}

function unmatchedSpans(tokens: Token[], matched: Uint8Array): WorkspaceReviewDiffSpan[] {
  const spans: WorkspaceReviewDiffSpan[] = [];
  tokens.forEach((token, index) => {
    if (!matched[index]) spans.push({ start: token.start, end: token.end, kind: "changed" });
  });
  return mergeSpans(spans);
}

/**
 * Shared non-whitespace characters if order did not matter (multiset
 * intersection of tokens). A common subsequence can never share more, so a
 * pair that fails the threshold here cannot pass it after exact matching.
 */
function sharedContentUpperBound(
  oldLine: WordLine,
  newLine: WordLine,
  context: WordDiffContext,
): number {
  if (context.counts.length < context.ids.size) {
    context.counts = new Int32Array(Math.max(context.ids.size, context.counts.length * 2));
  }
  // A token id always has the same text, so its weight is its length.
  const counts = context.counts;
  for (const id of oldLine.contentIds) counts[id] = (counts[id] ?? 0) + 1;
  let shared = 0;
  newLine.tokens.forEach((token, index) => {
    const id = newLine.ids[index] ?? -1;
    const available = counts[id] ?? 0;
    if (token.space || available === 0) return;
    counts[id] = available - 1;
    shared += token.end - token.start;
  });
  for (const id of oldLine.contentIds) counts[id] = 0;
  return shared;
}

/**
 * Word spans for a removed/added pair, or null when the lines are not the same
 * line edited. Spans mark exactly the tokens outside a longest common token
 * subsequence (minimal word edit). Pairs whose shared non-whitespace text is
 * under `WORD_PAIR_MIN_SIMILARITY` are unrelated rewrites and stay line-level.
 */
function similarLineWordSpans(
  oldLine: WordLine,
  newLine: WordLine,
  context: WordDiffContext,
): WordSpans | null {
  const totalContent = oldLine.contentChars + newLine.contentChars;
  // Upper bound: at most the shorter side can be shared.
  if (
    totalContent > 0 &&
    (2 * Math.min(oldLine.contentChars, newLine.contentChars)) / totalContent <
      WORD_PAIR_MIN_SIMILARITY
  ) {
    return null;
  }
  if (context.remainingCost <= 0) return null;
  if (
    totalContent > 0 &&
    (2 * sharedContentUpperBound(oldLine, newLine, context)) / totalContent <
      WORD_PAIR_MIN_SIMILARITY
  ) {
    return null;
  }

  const match = matchSequences(oldLine.ids, newLine.ids, context.remainingCost);
  context.remainingCost -= match.cost;
  if (!match.exact) return null;

  let sharedContent = 0;
  oldLine.weights.forEach((weight, index) => {
    if (match.oldMatched[index]) sharedContent += weight;
  });
  if (totalContent > 0 && (2 * sharedContent) / totalContent < WORD_PAIR_MIN_SIMILARITY) {
    return null;
  }

  return {
    old: unmatchedSpans(oldLine.tokens, match.oldMatched),
    new: unmatchedSpans(newLine.tokens, match.newMatched),
  };
}

type WordSpans = { old: WorkspaceReviewDiffSpan[]; new: WorkspaceReviewDiffSpan[] };

/**
 * Word spans for a positional pair that failed the similarity test, kept only
 * when the exact word diff changes at most `WORD_FALLBACK_MAX_REGIONS` places
 * per side. Short edits such as `foo()` -> `bar()` or `let a = b` -> `var a = c`
 * share little text yet read best with words marked; unrelated paragraphs
 * change dozens of places (or exceed the small work cap) and stay line-level.
 */
function fewChangeWordSpans(
  oldLine: WordLine,
  newLine: WordLine,
  context: WordDiffContext,
): WordSpans | null {
  if (context.remainingCost <= 0) return null;
  const match = matchSequences(
    oldLine.ids,
    newLine.ids,
    Math.min(WORD_FALLBACK_MAX_COST, context.remainingCost),
  );
  context.remainingCost -= match.cost;
  if (!match.exact) return null;
  const spans = {
    old: unmatchedSpans(oldLine.tokens, match.oldMatched),
    new: unmatchedSpans(newLine.tokens, match.newMatched),
  };
  if (
    spans.old.length > WORD_FALLBACK_MAX_REGIONS ||
    spans.new.length > WORD_FALLBACK_MAX_REGIONS
  ) {
    return null;
  }
  return spans;
}

function applySpans(
  removedLine: MutableReviewLine,
  addedLine: MutableReviewLine,
  spans: WordSpans,
): void {
  if (spans.old.length > 0) removedLine.spans = spans.old;
  if (spans.new.length > 0) addedLine.spans = spans.new;
}

/**
 * Apply word spans to already-numbered hunks.
 * Does not renumber lines or load file text.
 */
export function applyWordSpansToNumberedHunks(
  hunks: WorkspaceReviewDiffHunk[],
): WorkspaceReviewDiffHunk[] {
  const context = newWordDiffContext();
  for (const hunk of hunks) {
    applyWordLevelHighlights(hunk.lines, context);
  }
  return hunks;
}

function newWordDiffContext(): WordDiffContext {
  return { ids: new Map(), counts: new Int32Array(256), remainingCost: WORD_DIFF_MAX_COST };
}

/**
 * Word spans within each change block, in two passes that keep both sides in
 * order:
 * 1. Each removed line pairs with the first similar added line at or after the
 *    previous pair (within `WORD_PAIR_LOOKAHEAD`).
 * 2. Lines left between two pairs pair by position when the word diff stays
 *    small (`fewChangeWordSpans`).
 * Lines that pair with nothing stay line-level.
 */
function applyWordLevelHighlights(lines: MutableReviewLine[], context: WordDiffContext): void {
  let index = 0;

  while (index < lines.length) {
    if (lines[index]?.kind === "context") {
      index += 1;
      continue;
    }

    const removed: MutableReviewLine[] = [];
    const added: MutableReviewLine[] = [];
    let cursor = index;

    while (cursor < lines.length && lines[cursor]?.kind !== "context") {
      const line = lines[cursor];
      if (!line) {
        break;
      }
      if (line.kind === "removed") removed.push(line);
      if (line.kind === "added") added.push(line);
      cursor += 1;
    }

    if (removed.length > 0 && added.length > 0) {
      const removedWords = removed.map((line) => wordLine(line.text, context));
      const addedWords = added.map((line) => wordLine(line.text, context));
      const pairs: Array<[number, number]> = [];
      let nextAdded = 0;
      removedWords.forEach((oldWords, removedIndex) => {
        const searchEnd = Math.min(added.length, nextAdded + WORD_PAIR_LOOKAHEAD);
        for (let candidate = nextAdded; candidate < searchEnd; candidate += 1) {
          const newWords = addedWords[candidate];
          const removedLine = removed[removedIndex];
          const addedLine = added[candidate];
          if (!newWords || !removedLine || !addedLine) return;
          const spans = similarLineWordSpans(oldWords, newWords, context);
          if (!spans) continue;
          applySpans(removedLine, addedLine, spans);
          pairs.push([removedIndex, candidate]);
          nextAdded = candidate + 1;
          return;
        }
      });

      let previousRemoved = -1;
      let previousAdded = -1;
      for (const [pairRemoved, pairAdded] of [...pairs, [removed.length, added.length]]) {
        const gap = Math.min(pairRemoved - previousRemoved, pairAdded - previousAdded) - 1;
        for (let offset = 1; offset <= gap; offset += 1) {
          const removedLine = removed[previousRemoved + offset];
          const addedLine = added[previousAdded + offset];
          const oldWords = removedWords[previousRemoved + offset];
          const newWords = addedWords[previousAdded + offset];
          if (!removedLine || !addedLine || !oldWords || !newWords) break;
          const spans = fewChangeWordSpans(oldWords, newWords, context);
          if (spans) applySpans(removedLine, addedLine, spans);
        }
        previousRemoved = pairRemoved;
        previousAdded = pairAdded;
      }
    }

    index = cursor;
  }
}

function buildHunks(lines: MutableReviewLine[]): WorkspaceReviewDiffHunk[] {
  const changeWindows: Array<{ start: number; end: number }> = [];
  let index = 0;

  while (index < lines.length) {
    if (lines[index]?.kind === "context") {
      index += 1;
      continue;
    }

    let end = index;
    while (end + 1 < lines.length && lines[end + 1]?.kind !== "context") {
      end += 1;
    }

    changeWindows.push({
      start: Math.max(0, index - HUNK_CONTEXT_LINES),
      end: Math.min(lines.length - 1, end + HUNK_CONTEXT_LINES),
    });
    index = end + 1;
  }

  if (changeWindows.length === 0) {
    return [];
  }

  const firstWindow = changeWindows[0];
  if (!firstWindow) {
    return [];
  }

  const mergedWindows: Array<{ start: number; end: number }> = [{ ...firstWindow }];
  for (let windowIndex = 1; windowIndex < changeWindows.length; windowIndex += 1) {
    const next = changeWindows[windowIndex];
    const current = mergedWindows[mergedWindows.length - 1];
    if (!next || !current) {
      continue;
    }

    if (next.start <= current.end + 1) {
      current.end = Math.max(current.end, next.end);
    } else {
      mergedWindows.push({ ...next });
    }
  }

  return mergedWindows.map((window) => {
    const slice = lines.slice(window.start, window.end + 1).map((line) => ({ ...line }));
    const oldNumbers = slice.flatMap((line) => (line.oldLine === null ? [] : [line.oldLine]));
    const newNumbers = slice.flatMap((line) => (line.newLine === null ? [] : [line.newLine]));
    const firstOldNumber = oldNumbers[0];
    const firstNewNumber = newNumbers[0];

    return {
      oldStart: firstOldNumber ?? 0,
      oldCount: oldNumbers.length,
      newStart: firstNewNumber ?? 0,
      newCount: newNumbers.length,
      lines: slice,
    };
  });
}

/**
 * Convert flat diff lines into numbered, word-highlighted hunks.
 *
 * Shared by both the git-based workspace review diff endpoint and the
 * trace-based session diff endpoint.
 */
export function buildDiffHunks(flatLines: FlatDiffLine[]): WorkspaceReviewDiffHunk[] {
  const lines = numberDiffLines(flatLines);
  applyWordLevelHighlights(lines, newWordDiffContext());
  return buildHunks(lines);
}

export async function buildWorkspaceReviewDiff(args: {
  workspaceId: string;
  workspaceRoot: string;
  trust: GitTrust;
  path: string;
}): Promise<WorkspaceReviewDiffResponse> {
  const { workspaceId, workspaceRoot, trust, path } = args;
  const reqPath = path.trim();

  if (!reqPath) {
    throw new WorkspaceReviewDiffError(400, "path parameter required");
  }

  const [baseline, current] = await Promise.all([
    readHeadText(workspaceRoot, trust, reqPath),
    readCurrentText(workspaceRoot, reqPath),
  ]);

  if (!baseline.exists && !current.exists) {
    throw new WorkspaceReviewDiffError(404, "File not found for review");
  }

  const flatLines = computeDiffLines(baseline.text, current.text);
  const hunks = buildDiffHunks(flatLines);
  const stats = computeLineDiffStatsFromLines(flatLines);

  return {
    workspaceId,
    path: reqPath,
    baselineText: baseline.text,
    currentText: current.text,
    addedLines: stats.added,
    removedLines: stats.removed,
    hunks,
  };
}

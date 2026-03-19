import { execFile } from "node:child_process";
import { readFile, realpath, stat } from "node:fs/promises";
import { resolve } from "node:path";

import { isPathWithinRoot, resolveHomePath } from "./git-utils.js";
import {
  computeDiffLines,
  computeLineDiffStatsFromLines,
  type DiffLine as FlatDiffLine,
} from "./diff-core.js";
import type {
  WorkspaceReviewDiffHunk,
  WorkspaceReviewDiffLine,
  WorkspaceReviewDiffResponse,
  WorkspaceReviewDiffSpan,
} from "./types.js";

const GIT_TIMEOUT_MS = 5000;
const MAX_REVIEW_TEXT_BYTES = 256 * 1024;
const HUNK_CONTEXT_LINES = 3;
const MAX_TOKEN_DIFF_CELLS = 40_000;

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
};

function bufferLooksBinary(buffer: Buffer): boolean {
  return buffer.includes(0);
}

function gitBuffer(cwd: string, args: string[]): Promise<Buffer | null> {
  return new Promise((resolvePromise) => {
    execFile("git", args, { cwd, timeout: GIT_TIMEOUT_MS }, (err, stdout) => {
      if (err) {
        resolvePromise(null);
        return;
      }

      if (Buffer.isBuffer(stdout)) {
        resolvePromise(stdout);
        return;
      }

      resolvePromise(Buffer.from(String(stdout), "utf8"));
    });
  });
}

async function readHeadText(repoDir: string, reqPath: string): Promise<ReadTextResult> {
  const resolved = resolveHomePath(repoDir);
  const stdout = await gitBuffer(resolved, ["show", `HEAD:${reqPath}`]);

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
  const regex = /\s+|[\p{L}\p{N}_]+|[^\s\p{L}\p{N}_]+/gu;
  let match: RegExpExecArray | null;

  while ((match = regex.exec(text)) !== null) {
    tokens.push({
      value: match[0],
      start: match.index,
      end: match.index + match[0].length,
    });
  }

  if (tokens.length === 0) {
    return [{ value: text, start: 0, end: text.length }];
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

function fullLineSpan(text: string): WorkspaceReviewDiffSpan[] {
  return text.length > 0 ? [{ start: 0, end: text.length, kind: "changed" }] : [];
}

function computeWordSpans(
  oldText: string,
  newText: string,
): {
  old: WorkspaceReviewDiffSpan[];
  new: WorkspaceReviewDiffSpan[];
} {
  if (oldText === newText) {
    return { old: [], new: [] };
  }

  const oldTokens = tokenize(oldText);
  const newTokens = tokenize(newText);

  const cellCount = oldTokens.length * newTokens.length;
  if (cellCount > MAX_TOKEN_DIFF_CELLS) {
    return {
      old: fullLineSpan(oldText),
      new: fullLineSpan(newText),
    };
  }

  const m = oldTokens.length;
  const n = newTokens.length;
  const dp = Array.from({ length: m + 1 }, () => Array<number>(n + 1).fill(0));

  for (let i = 0; i < m; i += 1) {
    const currentRow = dp[i + 1];
    const previousRow = dp[i];
    if (!currentRow || !previousRow) {
      continue;
    }

    for (let j = 0; j < n; j += 1) {
      const left = currentRow[j] ?? 0;
      const up = previousRow[j + 1] ?? 0;
      const diagonal = previousRow[j] ?? 0;

      if (oldTokens[i]?.value === newTokens[j]?.value) {
        currentRow[j + 1] = diagonal + 1;
      } else {
        currentRow[j + 1] = Math.max(up, left);
      }
    }
  }

  const oldSpans: WorkspaceReviewDiffSpan[] = [];
  const newSpans: WorkspaceReviewDiffSpan[] = [];
  let i = m;
  let j = n;

  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && oldTokens[i - 1]?.value === newTokens[j - 1]?.value) {
      i -= 1;
      j -= 1;
      continue;
    }

    const left = i >= 0 ? (dp[i]?.[j - 1] ?? 0) : 0;
    const up = i > 0 ? (dp[i - 1]?.[j] ?? 0) : 0;

    if (j > 0 && (i === 0 || left >= up)) {
      const token = newTokens[j - 1];
      if (token) {
        newSpans.push({ start: token.start, end: token.end, kind: "changed" });
      }
      j -= 1;
      continue;
    }

    const token = oldTokens[i - 1];
    if (token) {
      oldSpans.push({ start: token.start, end: token.end, kind: "changed" });
    }
    i -= 1;
  }

  return {
    old: mergeSpans(oldSpans.reverse()),
    new: mergeSpans(newSpans.reverse()),
  };
}

function applyWordLevelHighlights(lines: MutableReviewLine[]): void {
  let index = 0;

  while (index < lines.length) {
    if (lines[index]?.kind === "context") {
      index += 1;
      continue;
    }

    const removed: number[] = [];
    const added: number[] = [];
    let cursor = index;

    while (cursor < lines.length && lines[cursor]?.kind !== "context") {
      const line = lines[cursor];
      if (!line) {
        break;
      }
      if (line.kind === "removed") removed.push(cursor);
      if (line.kind === "added") added.push(cursor);
      cursor += 1;
    }

    const pairCount = Math.min(removed.length, added.length);
    for (let pairIndex = 0; pairIndex < pairCount; pairIndex += 1) {
      const removedLineIndex = removed[pairIndex];
      const addedLineIndex = added[pairIndex];
      if (removedLineIndex === undefined || addedLineIndex === undefined) {
        continue;
      }

      const removedLine = lines[removedLineIndex];
      const addedLine = lines[addedLineIndex];
      if (!removedLine || !addedLine) {
        continue;
      }

      const spans = computeWordSpans(removedLine.text, addedLine.text);
      if (spans.old.length > 0) {
        removedLine.spans = spans.old;
      }
      if (spans.new.length > 0) {
        addedLine.spans = spans.new;
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
 * trace-based session overall-diff endpoint.
 */
export function buildDiffHunks(flatLines: FlatDiffLine[]): WorkspaceReviewDiffHunk[] {
  const lines = numberDiffLines(flatLines);
  applyWordLevelHighlights(lines);
  return buildHunks(lines);
}

export async function buildWorkspaceReviewDiff(args: {
  workspaceId: string;
  workspaceRoot: string;
  path: string;
}): Promise<WorkspaceReviewDiffResponse> {
  const { workspaceId, workspaceRoot, path } = args;
  const reqPath = path.trim();

  if (!reqPath) {
    throw new WorkspaceReviewDiffError(400, "path parameter required");
  }

  const [baseline, current] = await Promise.all([
    readHeadText(workspaceRoot, reqPath),
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

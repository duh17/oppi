/**
 * Git commit browsing for workspace directories.
 *
 * Provides paginated commit log, per-commit detail with file stats,
 * and per-file diffs for individual commits. Uses the same shell-out
 * patterns as git-status.ts.
 */

import { execFile } from "node:child_process";

import { resolveHomePath } from "./git-utils.js";
import { computeDiffLines, computeLineDiffStatsFromLines } from "./diff-core.js";
import { buildDiffHunks } from "./workspace-review-diff.js";
import type {
  GitCommitDetail,
  GitCommitFileInfo,
  GitCommitSummary,
  WorkspaceReviewDiffHunk,
  WorkspaceReviewDiffLine,
  WorkspaceReviewDiffResponse,
} from "./types.js";

const GIT_TIMEOUT_MS = 5000;
const MAX_DIFF_TEXT_BYTES = 256 * 1024;
const MAX_DIFF_PATCH_BYTES = 256 * 1024;
const FIELD_SEP = "---sep---";

// ─── Helpers ───

function git(cwd: string, args: string[]): Promise<string | null> {
  return new Promise((resolve) => {
    execFile("git", args, { cwd, timeout: GIT_TIMEOUT_MS }, (err, stdout) => {
      if (err) {
        resolve(null);
      } else {
        resolve(stdout);
      }
    });
  });
}

function gitBuffer(cwd: string, args: string[], maxBuffer?: number): Promise<Buffer | null> {
  return new Promise((resolve) => {
    execFile("git", args, { cwd, timeout: GIT_TIMEOUT_MS, maxBuffer }, (err, stdout) => {
      if (err) {
        resolve(null);
        return;
      }

      if (Buffer.isBuffer(stdout)) {
        resolve(stdout);
        return;
      }

      resolve(Buffer.from(String(stdout), "utf8"));
    });
  });
}

function bufferLooksBinary(buffer: Buffer): boolean {
  return buffer.includes(0);
}

function parseHunkHeader(line: string): {
  oldStart: number;
  oldCount: number;
  newStart: number;
  newCount: number;
} | null {
  const match = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(line);
  if (!match) return null;

  return {
    oldStart: parseInt(match[1] ?? "0", 10),
    oldCount: parseInt(match[2] ?? "1", 10),
    newStart: parseInt(match[3] ?? "0", 10),
    newCount: parseInt(match[4] ?? "1", 10),
  };
}

function parseUnifiedDiffHunks(patch: string): WorkspaceReviewDiffHunk[] {
  const hunks: WorkspaceReviewDiffHunk[] = [];
  let current: WorkspaceReviewDiffHunk | null = null;
  let oldLine = 0;
  let newLine = 0;

  for (const rawLine of patch.split("\n")) {
    const header = parseHunkHeader(rawLine);
    if (header) {
      current = { ...header, lines: [] };
      hunks.push(current);
      oldLine = header.oldStart;
      newLine = header.newStart;
      continue;
    }

    if (!current || rawLine.startsWith("diff --git ") || rawLine.startsWith("index ")) {
      continue;
    }
    if (rawLine.startsWith("--- ") || rawLine.startsWith("+++ ")) {
      continue;
    }
    if (rawLine.startsWith("\\ No newline at end of file")) {
      continue;
    }

    const marker = rawLine[0];
    const text = rawLine.slice(1);
    let line: WorkspaceReviewDiffLine | null = null;

    if (marker === " ") {
      line = { kind: "context", text, oldLine, newLine };
      oldLine += 1;
      newLine += 1;
    } else if (marker === "-") {
      line = { kind: "removed", text, oldLine, newLine: null };
      oldLine += 1;
    } else if (marker === "+") {
      line = { kind: "added", text, oldLine: null, newLine };
      newLine += 1;
    }

    if (line) {
      current.lines.push(line);
    }
  }

  return hunks.filter((hunk) => hunk.lines.length > 0);
}

function validateSha(sha: string): void {
  if (!/^[a-zA-Z0-9]+$/.test(sha)) {
    throw new Error("Invalid commit SHA");
  }
}

// ─── Commit log ───

export async function getCommitLog(
  dir: string,
  offset: number,
  limit: number,
): Promise<{
  commits: GitCommitSummary[];
  total: number;
  hasMore: boolean;
}> {
  const resolved = resolveHomePath(dir);

  const [logOut, countOut] = await Promise.all([
    git(resolved, [
      "log",
      `--skip=${offset}`,
      `--max-count=${limit}`,
      `--format=%h${FIELD_SEP}%s${FIELD_SEP}%aI`,
    ]),
    git(resolved, ["rev-list", "--count", "HEAD"]),
  ]);

  const total = countOut ? parseInt(countOut.trim(), 10) || 0 : 0;

  const commits: GitCommitSummary[] = [];
  if (logOut) {
    const lines = logOut.split("\n").filter((l) => l.length > 0);
    for (const line of lines) {
      const parts = line.split(FIELD_SEP);
      if (parts.length >= 3) {
        commits.push({ sha: parts[0], message: parts[1], date: parts[2] });
      }
    }
  }

  return {
    commits,
    total,
    hasMore: offset + commits.length < total,
  };
}

// ─── Commit detail ───

export async function getCommitDetail(dir: string, sha: string): Promise<GitCommitDetail> {
  validateSha(sha);
  const resolved = resolveHomePath(dir);

  const [metaOut, numstatOut, nameStatusOut] = await Promise.all([
    git(resolved, [
      "log",
      "-1",
      `--format=%h${FIELD_SEP}%s${FIELD_SEP}%aI${FIELD_SEP}%an <%ae>`,
      sha,
    ]),
    git(resolved, ["diff-tree", "--no-commit-id", "-r", "--numstat", sha]),
    git(resolved, ["diff-tree", "--no-commit-id", "-r", "--name-status", sha]),
  ]);

  if (!metaOut) {
    throw new Error("Commit not found");
  }

  const metaParts = metaOut.trim().split(FIELD_SEP);
  if (metaParts.length < 4) {
    throw new Error("Commit not found");
  }

  // Parse numstat: "added\tremoved\tpath"
  const numstatMap = new Map<string, { added: number | null; removed: number | null }>();
  if (numstatOut) {
    for (const line of numstatOut.split("\n").filter((l) => l.length > 0)) {
      const parts = line.split("\t");
      if (parts.length < 3) continue;
      const [addedStr, removedStr, ...pathParts] = parts;
      const filePath = pathParts.join("\t");
      if (addedStr === "-" || removedStr === "-") {
        numstatMap.set(filePath, { added: null, removed: null }); // binary
      } else {
        const added = parseInt(addedStr, 10);
        const removed = parseInt(removedStr, 10);
        numstatMap.set(filePath, {
          added: isNaN(added) ? null : added,
          removed: isNaN(removed) ? null : removed,
        });
      }
    }
  }

  // Parse name-status: "M\tpath" or "R100\told\tnew"
  const statusMap = new Map<string, string>();
  if (nameStatusOut) {
    for (const line of nameStatusOut.split("\n").filter((l) => l.length > 0)) {
      const parts = line.split("\t");
      if (parts.length >= 2) {
        const status = parts[0];
        const filePath = parts[parts.length - 1]; // last part is the relevant path
        statusMap.set(filePath, status);
      }
    }
  }

  // Merge into file list
  const files: GitCommitFileInfo[] = [];
  let totalAdded = 0;
  let totalRemoved = 0;

  // Use statusMap paths as primary (covers all files)
  const allPaths = new Set([...statusMap.keys(), ...numstatMap.keys()]);
  for (const filePath of allPaths) {
    const stats = numstatMap.get(filePath);
    const status = statusMap.get(filePath) ?? "M";
    const addedLines = stats?.added ?? null;
    const removedLines = stats?.removed ?? null;

    files.push({ path: filePath, status, addedLines, removedLines });

    if (addedLines !== null) totalAdded += addedLines;
    if (removedLines !== null) totalRemoved += removedLines;
  }

  return {
    sha: metaParts[0],
    message: metaParts[1],
    date: metaParts[2],
    author: metaParts[3],
    files,
    addedLines: totalAdded,
    removedLines: totalRemoved,
  };
}

// ─── Commit file diff ───

export async function getCommitFileDiff(
  dir: string,
  sha: string,
  filePath: string,
  workspaceId: string,
): Promise<WorkspaceReviewDiffResponse> {
  validateSha(sha);
  const resolved = resolveHomePath(dir);

  if (!filePath || filePath.trim().length === 0) {
    throw new CommitDiffError(400, "path parameter required");
  }
  if (filePath.includes("\0")) {
    throw new CommitDiffError(400, "path parameter invalid");
  }

  const trimmedPath = filePath.trim();

  // Get the file content at the commit and its parent
  const [beforeBuf, afterBuf] = await Promise.all([
    gitBuffer(resolved, ["show", `${sha}^:${trimmedPath}`]),
    gitBuffer(resolved, ["show", `${sha}:${trimmedPath}`]),
  ]);

  const beforeExists = beforeBuf !== null;
  const afterExists = afterBuf !== null;

  if (!beforeExists && !afterExists) {
    throw new CommitDiffError(404, "File not found in commit");
  }

  // Check for binary content
  if (beforeBuf && bufferLooksBinary(beforeBuf)) {
    throw new CommitDiffError(422, "Binary files are not supported in diff view.");
  }
  if (afterBuf && bufferLooksBinary(afterBuf)) {
    throw new CommitDiffError(422, "Binary files are not supported in diff view.");
  }

  const canDiffFullText =
    (!beforeBuf || beforeBuf.byteLength <= MAX_DIFF_TEXT_BYTES) &&
    (!afterBuf || afterBuf.byteLength <= MAX_DIFF_TEXT_BYTES);

  if (canDiffFullText) {
    const beforeText = beforeBuf ? beforeBuf.toString("utf8") : "";
    const afterText = afterBuf ? afterBuf.toString("utf8") : "";

    const flatLines = computeDiffLines(beforeText, afterText);
    const hunks = buildDiffHunks(flatLines);
    const stats = computeLineDiffStatsFromLines(flatLines);

    return {
      workspaceId,
      path: trimmedPath,
      baselineText: beforeText,
      currentText: afterText,
      addedLines: stats.added,
      removedLines: stats.removed,
      hunks,
    };
  }

  // Large source files can still have tiny commits. In that case, diff the patch
  // Git already narrowed to the changed hunks instead of rejecting based on full
  // file size.
  const patchBuf = await gitBuffer(
    resolved,
    [
      "--literal-pathspecs",
      "diff",
      "--no-ext-diff",
      "--no-color",
      "--unified=3",
      `${sha}^`,
      sha,
      "--",
      trimmedPath,
    ],
    MAX_DIFF_PATCH_BYTES,
  );

  if (!patchBuf) {
    throw new CommitDiffError(413, "Diff too large for diff view.");
  }

  const patchText = patchBuf.toString("utf8");
  if (patchText.includes("Binary files ")) {
    throw new CommitDiffError(422, "Binary files are not supported in diff view.");
  }

  const hunks = parseUnifiedDiffHunks(patchText);
  let addedLines = 0;
  let removedLines = 0;
  for (const hunk of hunks) {
    for (const line of hunk.lines) {
      if (line.kind === "added") addedLines += 1;
      if (line.kind === "removed") removedLines += 1;
    }
  }

  return {
    workspaceId,
    path: trimmedPath,
    baselineText: "",
    currentText: "",
    addedLines,
    removedLines,
    hunks,
  };
}

export class CommitDiffError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "CommitDiffError";
  }
}

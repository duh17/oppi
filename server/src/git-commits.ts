/**
 * Git commit browsing for workspace directories.
 *
 * Provides paginated commit log, per-commit detail with file stats,
 * and per-file diffs for individual commits. Uses the same shell-out
 * patterns as git-status.ts.
 */

import { execGit, SandboxGitRefusedError, type GitTrust } from "./git-safe.js";
import { resolveHomePath } from "./git-utils.js";
import { computeDiffLines, computeLineDiffStatsFromLines } from "./diff-core.js";
import { applyWordSpansToNumberedHunks, buildDiffHunks } from "./workspace-review-diff.js";
import type {
  GitCommitDetail,
  GitCommitFileInfo,
  GitCommitSummary,
  GitGraphCommit,
  GitGraphRef,
  WorkspaceReviewDiffHunk,
  WorkspaceReviewDiffLine,
  WorkspaceReviewDiffResponse,
} from "./types.js";

const GIT_TIMEOUT_MS = 5000;
const MAX_DIFF_TEXT_BYTES = 256 * 1024;
const MAX_DIFF_PATCH_BYTES = 256 * 1024;
const FIELD_SEP = "---sep---";

// ─── Helpers ───

async function git(trust: GitTrust, cwd: string, args: string[]): Promise<string | null> {
  const { error, stdout } = await execGit(trust, cwd, args, { timeout: GIT_TIMEOUT_MS });
  return error ? null : String(stdout);
}

async function gitBuffer(
  trust: GitTrust,
  cwd: string,
  args: string[],
  maxBuffer?: number,
): Promise<Buffer | null> {
  const { error, stdout } = await execGit(trust, cwd, args, {
    timeout: GIT_TIMEOUT_MS,
    maxBuffer,
  });
  if (error) return null;
  return Buffer.isBuffer(stdout) ? stdout : Buffer.from(String(stdout), "utf8");
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
  trust: GitTrust,
  offset: number,
  limit: number,
): Promise<{
  commits: GitCommitSummary[];
  total: number;
  hasMore: boolean;
}> {
  const resolved = resolveHomePath(dir);

  const [logOut, countOut] = await Promise.all([
    git(trust, resolved, [
      "log",
      `--skip=${offset}`,
      `--max-count=${limit}`,
      `--format=%h${FIELD_SEP}%s${FIELD_SEP}%aI`,
    ]),
    git(trust, resolved, ["rev-list", "--count", "HEAD"]),
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

// ─── Commit graph ───

const UNIT_SEP = "\x1f";
const RECORD_SEP = "\x1e";

/**
 * One page of the commit graph: HEAD and every local branch in topological
 * order. One `git log` per page, and no count: a page asks for one commit more
 * than it returns to learn whether another follows. Full SHAs, because an
 * abbreviation can grow between pages and parents must match their commits.
 * A repository with no commits has an empty graph; any other git failure
 * throws, so the app can offer a retry instead of showing no history.
 */
export async function getCommitGraph(
  dir: string,
  trust: GitTrust,
  offset: number,
  limit: number,
): Promise<{ commits: GitGraphCommit[]; hasMore: boolean }> {
  const cwd = resolveHomePath(dir);
  const { error, stdout } = await execGit(
    trust,
    cwd,
    [
      "log",
      "--branches",
      "HEAD",
      "--topo-order",
      "--decorate=full",
      `--skip=${offset}`,
      `--max-count=${limit + 1}`,
      `--format=%H${UNIT_SEP}%h${UNIT_SEP}%P${UNIT_SEP}%D${UNIT_SEP}%s${UNIT_SEP}%aI${RECORD_SEP}`,
    ],
    { timeout: GIT_TIMEOUT_MS },
  );
  if (error) {
    // A repository whose HEAD resolves to nothing has no commits yet.
    const [repo, head] = await Promise.all([
      execGit(trust, cwd, ["rev-parse", "--git-dir"], { timeout: GIT_TIMEOUT_MS }),
      execGit(trust, cwd, ["rev-parse", "--verify", "--quiet", "HEAD"], {
        timeout: GIT_TIMEOUT_MS,
      }),
    ]);
    if (!repo.error && head.error && !(head.error instanceof SandboxGitRefusedError)) {
      return { commits: [], hasMore: false };
    }
    throw new Error("Commit graph unavailable");
  }

  const commits: GitGraphCommit[] = [];
  for (const record of String(stdout).split(RECORD_SEP)) {
    const fields = record.replace(/^\n/, "").split(UNIT_SEP);
    if (fields.length < 6) continue;
    const [sha, shortSha, parents, decoration, message, date] = fields;
    commits.push({
      sha,
      shortSha,
      parents: parents ? parents.split(" ") : [],
      message,
      date,
      refs: parseDecoration(decoration),
    });
  }
  const hasMore = commits.length > limit;
  return { commits: hasMore ? commits.slice(0, limit) : commits, hasMore };
}

/**
 * `%D` with full names (`HEAD -> refs/heads/main, refs/remotes/origin/main,
 * tag: refs/tags/v1`), so a remote branch and a local branch with a slash
 * stay apart. A remote's symbolic HEAD (`origin/HEAD`) only repeats its
 * default branch, and other refs (stash, notes) are not branches.
 */
export function parseDecoration(decoration: string): GitGraphRef[] {
  const refs: GitGraphRef[] = [];
  for (const part of decoration.split(", ")) {
    let ref = part.trim();
    if (!ref) continue;
    if (ref === "HEAD") {
      refs.push({ kind: "head", name: ref });
      continue;
    }
    const isHead = ref.startsWith("HEAD -> ");
    if (isHead) ref = ref.slice("HEAD -> ".length);
    if (ref.startsWith("tag: ")) ref = ref.slice("tag: ".length);
    if (ref.startsWith("refs/heads/")) {
      const name = ref.slice("refs/heads/".length);
      refs.push(isHead ? { kind: "branch", name, isHead } : { kind: "branch", name });
    } else if (ref.startsWith("refs/remotes/") && !ref.endsWith("/HEAD")) {
      refs.push({ kind: "remote", name: ref.slice("refs/remotes/".length) });
    } else if (ref.startsWith("refs/tags/")) {
      refs.push({ kind: "tag", name: ref.slice("refs/tags/".length) });
    }
  }
  return refs;
}

// ─── Commit detail ───

export async function getCommitDetail(
  dir: string,
  trust: GitTrust,
  sha: string,
): Promise<GitCommitDetail> {
  validateSha(sha);
  const resolved = resolveHomePath(dir);

  const [metaOut, numstatOut, nameStatusOut] = await Promise.all([
    git(trust, resolved, [
      "log",
      "-1",
      `--format=%h${FIELD_SEP}%B${FIELD_SEP}%aI${FIELD_SEP}%an <%ae>`,
      sha,
    ]),
    git(trust, resolved, ["diff-tree", "--no-commit-id", "-r", "--numstat", sha]),
    git(trust, resolved, ["diff-tree", "--no-commit-id", "-r", "--name-status", sha]),
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
    message: metaParts[1].trimEnd(),
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
  trust: GitTrust,
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
    gitBuffer(trust, resolved, ["show", `${sha}^:${trimmedPath}`]),
    gitBuffer(trust, resolved, ["show", `${sha}:${trimmedPath}`]),
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

    // The commit diff view renders hunks only. Sending both full file copies
    // more than tripled the response for a large file with a small change.
    return {
      workspaceId,
      path: trimmedPath,
      baselineText: "",
      currentText: "",
      addedLines: stats.added,
      removedLines: stats.removed,
      hunks,
    };
  }

  // Large source files can still have tiny commits. In that case, diff the patch
  // Git already narrowed to the changed hunks instead of rejecting based on full
  // file size.
  const patchBuf = await gitBuffer(
    trust,
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

  const hunks = applyWordSpansToNumberedHunks(parseUnifiedDiffHunks(patchText));
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

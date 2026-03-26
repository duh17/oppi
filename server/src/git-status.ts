/**
 * Git status for workspace directories.
 *
 * Shells out to git against a workspace's hostMount to provide
 * branch, dirty-file, and ahead/behind info. Designed to be polled
 * from iOS so the user sees uncommitted work accumulating and
 * remembers to commit.
 */

import { execFile } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

import { resolveHomePath } from "./git-utils.js";
import type { GitCommitSummary, GitFileStatus, GitStatus } from "./types.js";

const FILE_CAP = 500;
const GIT_TIMEOUT_MS = 5000;

/**
 * Run a git command and return stdout. Returns null on any error.
 */
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

// ─── Main ───

/**
 * Get git status for a directory. Returns a complete GitStatus object.
 * If the directory is not a git repo, returns { isGitRepo: false, ... }.
 */
export async function getGitStatus(dir: string): Promise<GitStatus> {
  const resolved = resolveHomePath(dir);

  const empty: GitStatus = {
    isGitRepo: false,
    branch: null,
    headSha: null,
    ahead: null,
    behind: null,
    dirtyCount: 0,
    untrackedCount: 0,
    stagedCount: 0,
    files: [],
    totalFiles: 0,
    addedLines: 0,
    removedLines: 0,
    stashCount: 0,
    lastCommitMessage: null,
    lastCommitDate: null,
    recentCommits: [],
  };

  if (!existsSync(join(resolved, ".git"))) {
    return empty;
  }

  const RECENT_COMMITS_CAP = 20;
  const COMMIT_RECORD_SEP = "---commit-sep---";

  // Run all git commands in parallel
  const [branchOut, shaOut, statusOut, stashOut, logOut, upstreamOut, numstatOut, recentOut] =
    await Promise.all([
      git(resolved, ["branch", "--show-current"]),
      git(resolved, ["rev-parse", "--short", "HEAD"]),
      git(resolved, ["status", "--porcelain"]),
      git(resolved, ["stash", "list"]),
      git(resolved, ["log", "-1", "--format=%s%n%aI"]),
      git(resolved, ["rev-list", "--left-right", "--count", "@{u}...HEAD"]),
      git(resolved, ["diff", "HEAD", "--numstat"]),
      git(resolved, [
        "log",
        `--max-count=${RECENT_COMMITS_CAP}`,
        `--format=%h${COMMIT_RECORD_SEP}%s${COMMIT_RECORD_SEP}%aI`,
      ]),
    ]);

  // Branch (empty string means detached HEAD)
  const branch = branchOut?.trim() || null;
  const headSha = shaOut?.trim() || null;

  // Parse status --porcelain
  const files: GitFileStatus[] = [];
  let dirtyCount = 0;
  let untrackedCount = 0;
  let stagedCount = 0;

  if (statusOut) {
    const lines = statusOut.split("\n").filter((l) => l.length > 0);
    for (const line of lines) {
      const statusCode = line.slice(0, 2);
      const filePath = line.slice(3);

      // Count categories
      const indexChar = statusCode[0];
      const workChar = statusCode[1];

      if (statusCode === "??") {
        untrackedCount++;
      } else {
        // Staged: index char is not space and not '?'
        if (indexChar !== " " && indexChar !== "?") {
          stagedCount++;
        }
        // Dirty (working tree modified): work char is not space
        if (workChar !== " ") {
          dirtyCount++;
        }
      }

      if (files.length < FILE_CAP) {
        files.push({ status: statusCode, path: filePath, addedLines: null, removedLines: null });
      }
    }
  }

  const totalFiles = dirtyCount + untrackedCount + stagedCount;

  // Parse git diff HEAD --numstat for per-file +/- lines
  // Format: "added\tremoved\tpath" (binary files show "-\t-\tpath")
  const numstatMap = new Map<string, { added: number; removed: number }>();
  let totalAdded = 0;
  let totalRemoved = 0;

  if (numstatOut) {
    const lines = numstatOut.split("\n").filter((l) => l.length > 0);
    for (const line of lines) {
      const parts = line.split("\t");
      if (parts.length < 3) continue;
      const [addedStr, removedStr, ...pathParts] = parts;
      const filePath = pathParts.join("\t"); // handle paths with tabs (rare)
      if (addedStr === "-" || removedStr === "-") continue; // binary
      const added = parseInt(addedStr, 10);
      const removed = parseInt(removedStr, 10);
      if (!isNaN(added) && !isNaN(removed)) {
        numstatMap.set(filePath, { added, removed });
        totalAdded += added;
        totalRemoved += removed;
      }
    }
  }

  // Merge numstat into file entries
  for (const file of files) {
    const stats = numstatMap.get(file.path);
    if (stats) {
      file.addedLines = stats.added;
      file.removedLines = stats.removed;
    }
  }

  // Count lines for untracked files.
  // git diff HEAD --numstat only covers tracked files, so untracked ("??")
  // files show addedLines=null in the file list and their lines are missing
  // from the totals. This makes the workspace bar say "+38 -2" when there's
  // also a brand-new 565-line file. Count them so the totals are accurate.
  const untrackedPaths = files
    .filter((f) => f.status === "??" && !numstatMap.has(f.path))
    .map((f) => f.path);

  if (untrackedPaths.length > 0) {
    const untrackedLineCounts = await countUntrackedFileLines(resolved, untrackedPaths);
    for (const file of files) {
      const lines = file.status === "??" ? untrackedLineCounts.get(file.path) : undefined;
      if (lines !== undefined) {
        file.addedLines = lines;
        file.removedLines = 0;
        totalAdded += lines;
      }
    }
  }

  // Ahead/behind
  let ahead: number | null = null;
  let behind: number | null = null;
  if (upstreamOut) {
    const parts = upstreamOut.trim().split(/\s+/);
    if (parts.length === 2) {
      behind = parseInt(parts[0], 10);
      ahead = parseInt(parts[1], 10);
    }
  }

  // Stash count
  const stashCount = stashOut ? stashOut.split("\n").filter((l) => l.length > 0).length : 0;

  // Last commit
  let lastCommitMessage: string | null = null;
  let lastCommitDate: string | null = null;
  if (logOut) {
    const logLines = logOut.trim().split("\n");
    if (logLines.length >= 2) {
      lastCommitMessage = logLines[0];
      lastCommitDate = logLines[1];
    }
  }

  // Recent commits
  const recentCommits: GitCommitSummary[] = [];
  if (recentOut) {
    const lines = recentOut.split("\n").filter((l) => l.length > 0);
    for (const line of lines) {
      const parts = line.split(COMMIT_RECORD_SEP);
      if (parts.length >= 3) {
        recentCommits.push({ sha: parts[0], message: parts[1], date: parts[2] });
      }
    }
  }

  return {
    isGitRepo: true,
    branch,
    headSha,
    ahead,
    behind,
    dirtyCount,
    untrackedCount,
    stagedCount,
    files,
    totalFiles,
    addedLines: totalAdded,
    removedLines: totalRemoved,
    stashCount,
    lastCommitMessage,
    lastCommitDate,
    recentCommits,
  };
}

// ─── Untracked file line counting ───

/** Max file size to read for line counting (256 KB). Skip larger files. */
const UNTRACKED_LINE_COUNT_MAX_BYTES = 256 * 1024;

/**
 * Count lines in untracked files so their additions appear in the totals.
 *
 * Reads each file synchronously (fast for small files, capped at 256 KB).
 * Returns a map from relative path to line count. Binary or oversized files
 * are silently skipped (they'll keep addedLines=null in the response).
 */
function countUntrackedFileLines(
  repoRoot: string,
  relativePaths: string[],
): Promise<Map<string, number>> {
  const result = new Map<string, number>();

  for (const relPath of relativePaths) {
    try {
      const fullPath = join(repoRoot, relPath);
      const stat = statSync(fullPath);
      if (!stat.isFile() || stat.size > UNTRACKED_LINE_COUNT_MAX_BYTES || stat.size === 0) {
        continue;
      }

      const content = readFileSync(fullPath, "utf-8");

      // Skip likely-binary files (NUL byte in the first 8 KB, same heuristic as git)
      if (content.slice(0, 8192).includes("\0")) {
        continue;
      }

      const lineCount = content.split("\n").length;
      result.set(relPath, lineCount);
    } catch {
      // File vanished or unreadable — skip silently
    }
  }

  return Promise.resolve(result);
}

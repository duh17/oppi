/**
 * Git status for workspace directories.
 *
 * Shells out to git against a workspace's hostMount to provide
 * branch, dirty-file, and ahead/behind info. Designed to be polled
 * from iOS so the user sees uncommitted work accumulating and
 * remembers to commit.
 */

import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

// ─── Types ───

export interface GitFileStatus {
  /** Two-char status code from `git status --porcelain` (e.g. " M", "??", "A ") */
  status: string;
  /** File path relative to repo root */
  path: string;
}

export interface GitStatus {
  /** Whether the directory is a git repo */
  isGitRepo: boolean;
  /** Current branch name (null if detached HEAD) */
  branch: string | null;
  /** Short SHA of HEAD */
  headSha: string | null;
  /** Commits ahead of upstream (null if no upstream) */
  ahead: number | null;
  /** Commits behind upstream (null if no upstream) */
  behind: number | null;
  /** Number of dirty (uncommitted) files */
  dirtyCount: number;
  /** Number of untracked files */
  untrackedCount: number;
  /** Number of staged files */
  stagedCount: number;
  /** Individual file statuses (capped to first 100) */
  files: GitFileStatus[];
  /** Total file count if capped */
  totalFiles: number;
  /** Number of stash entries */
  stashCount: number;
  /** Most recent commit subject line */
  lastCommitMessage: string | null;
  /** ISO timestamp of most recent commit */
  lastCommitDate: string | null;
}

const FILE_CAP = 100;
const GIT_TIMEOUT_MS = 5000;

// ─── Helpers ───

function resolveDir(dir: string): string {
  return dir.replace(/^~/, homedir());
}

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
  const resolved = resolveDir(dir);

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
    stashCount: 0,
    lastCommitMessage: null,
    lastCommitDate: null,
  };

  if (!existsSync(join(resolved, ".git"))) {
    return empty;
  }

  // Run all git commands in parallel
  const [branchOut, shaOut, statusOut, stashOut, logOut, upstreamOut] = await Promise.all([
    git(resolved, ["branch", "--show-current"]),
    git(resolved, ["rev-parse", "--short", "HEAD"]),
    git(resolved, ["status", "--porcelain"]),
    git(resolved, ["stash", "list"]),
    git(resolved, ["log", "-1", "--format=%s%n%aI"]),
    git(resolved, ["rev-list", "--left-right", "--count", "@{u}...HEAD"]),
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
        files.push({ status: statusCode, path: filePath });
      }
    }

    // dirtyCount should include untracked for the "total uncommitted" number
    // Keep separate counts but totalFiles = all non-clean
  }

  const totalFiles = dirtyCount + untrackedCount + stagedCount;

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
    stashCount,
    lastCommitMessage,
    lastCommitDate,
  };
}

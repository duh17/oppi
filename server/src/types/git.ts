import type { WorkspaceWorktree } from "./worktree.js";

// ─── Git status ───

export interface GitFileChange {
  /** File path relative to repo root. */
  path: string;
  /** Change status; source-specific format (porcelain, diff-tree, etc.). */
  status: string;
  /** Lines added (null when unavailable, such as binary or untracked files). */
  addedLines: number | null;
  /** Lines removed (null when unavailable, such as binary or untracked files). */
  removedLines: number | null;
}

export interface GitFileStatus extends GitFileChange {
  /** Two-char status code from `git status --porcelain` (e.g. " M", "??", "A "). */
  status: string;
}

export interface GitCommitSummary {
  /** Short SHA (7-char) */
  sha: string;
  /** Commit subject line */
  message: string;
  /** ISO timestamp */
  date: string;
}

/** A ref that points at a commit in the graph, from `git log --format=%D`. */
export interface GitGraphRef {
  /**
   * `branch` a local branch, `remote` a remote-tracking branch, `tag` a tag,
   * `head` a detached HEAD.
   */
  kind: "branch" | "remote" | "tag" | "head";
  /** Short ref name (`main`, `origin/main`, `v1.0`, `HEAD`). */
  name: string;
  /** The branch the queried checkout has checked out (`HEAD -> name`). */
  isHead?: boolean;
}

export interface GitGraphCommit {
  /** Full SHA. */
  sha: string;
  /** Abbreviated SHA, for display and commit detail requests. */
  shortSha: string;
  /** Full parent SHAs, first parent first. */
  parents: string[];
  /** Commit subject line */
  message: string;
  /** ISO timestamp */
  date: string;
  refs: GitGraphRef[];
}

/**
 * One page of the commit graph: HEAD and every local branch, newest first in
 * topological order, so a commit always comes before its parents.
 */
export interface GitGraphResponse {
  commits: GitGraphCommit[];
  hasMore: boolean;
  /** The repository's checkouts, on the first page only. */
  worktrees?: WorkspaceWorktree[];
}

export interface GitCommitFileInfo extends GitFileChange {
  /** Change status (M=modified, A=added, D=deleted, etc.). */
  status: string;
}

export interface GitCommitDetail {
  /** Short SHA (7-char) */
  sha: string;
  /** Full commit message, including subject and body. */
  message: string;
  /** ISO timestamp */
  date: string;
  /** Author name and email */
  author: string;
  /** Files changed in this commit */
  files: GitCommitFileInfo[];
  /** Total lines added */
  addedLines: number;
  /** Total lines removed */
  removedLines: number;
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
  /** Individual file statuses (capped to first 500) */
  files: GitFileStatus[];
  /** Total file count if capped */
  totalFiles: number;
  /** Total lines added vs HEAD (tracked files only) */
  addedLines: number;
  /** Total lines removed vs HEAD (tracked files only) */
  removedLines: number;
  /** Number of stash entries */
  stashCount: number;
  /** Most recent commit subject line */
  lastCommitMessage: string | null;
  /** ISO timestamp of most recent commit */
  lastCommitDate: string | null;
  /** Recent commits (newest first, capped at 20) */
  recentCommits: GitCommitSummary[];
}

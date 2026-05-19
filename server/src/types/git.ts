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

export interface GitCommitFileInfo extends GitFileChange {
  /** Change status (M=modified, A=added, D=deleted, etc.). */
  status: string;
}

export interface GitCommitDetail {
  /** Short SHA (7-char) */
  sha: string;
  /** Commit subject line */
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

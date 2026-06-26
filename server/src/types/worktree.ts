export interface WorkspaceWorktree {
  /** Stable server identifier used when binding sessions to a checkout. */
  id: string;
  /** Human-readable label for list rows. */
  name: string;
  /** Absolute host path for this checkout. */
  path: string;
  /** Current branch name, or null for detached/non-git checkouts. */
  branch: string | null;
  /** Short HEAD sha when available. */
  headSha: string | null;
  /** True for the workspace hostMount checkout used by older sessions. */
  isMain: boolean;
  /** True when the checkout came from git worktree discovery. */
  isGitRepo: boolean;
}

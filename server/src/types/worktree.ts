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
  /** True when Oppi created the checkout under OPPI_DATA_DIR/worktrees. */
  managedByOppi?: boolean;
  /** Managed Oppi sessions assigned to this checkout, when requested by the caller. */
  sessionCount?: number;
}

export interface CreateWorkspaceWorktreeRequest {
  branch?: string;
  base?: string;
  path?: string;
}

export interface OpenWorkspaceWorktreeRequest {
  branch?: string;
  path?: string;
}

export type WorkspaceWorktreeIntegrationMode = "merge" | "squash" | "ff-only";

export interface PreviewWorkspaceWorktreeRequest {
  into?: string;
  mode?: WorkspaceWorktreeIntegrationMode;
}

export interface WorkspaceWorktreePreviewFile {
  status: string;
  path: string;
  oldPath?: string;
}

export interface WorkspaceWorktreePreviewCommit {
  sha: string;
  subject: string;
}

export interface WorkspaceWorktreePreview {
  worktree: WorkspaceWorktree;
  source: {
    branch: string | null;
    headSha: string;
  };
  target: {
    ref: string;
    headSha: string;
  };
  mode: WorkspaceWorktreeIntegrationMode;
  alreadyMerged: boolean;
  fastForwardPossible: boolean;
  commitCount: number;
  commits: WorkspaceWorktreePreviewCommit[];
  changedFiles: WorkspaceWorktreePreviewFile[];
  conflictCheck: "clean" | "conflicts" | "unknown";
  conflictCheckError?: string;
}

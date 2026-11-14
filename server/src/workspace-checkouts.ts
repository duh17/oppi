import { resolve } from "node:path";

import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import { expandHome } from "./path-utils.js";
import type { Workspace } from "./types.js";
import { listWorkspaceWorktrees, MAIN_WORKTREE_ID } from "./worktrees.js";

const log = createLogger({ base: { component: "workspace_checkouts" } });

/** One checkout of a workspace: its own folder, or one of its worktrees. */
export interface WorkspaceCheckout {
  worktreeId: string;
  /** Display name: the worktree's, or the main checkout's. */
  label: string;
  /** Host directory: the workspace mount, or a worktree. */
  root: string;
}

/**
 * The workspace root, then its worktrees. A sandbox has only its mount. A failed worktree
 * listing (logged with `caller`) leaves the root alone.
 */
export async function listWorkspaceCheckouts(
  workspace: Workspace,
  dataDir: string,
  caller: string,
): Promise<WorkspaceCheckout[]> {
  let worktrees: Awaited<ReturnType<typeof listWorkspaceWorktrees>> = [];
  try {
    worktrees = await listWorkspaceWorktrees(workspace, { dataDir });
  } catch (error: unknown) {
    log.warn("workspace_checkouts.worktrees_failed", {
      caller,
      workspaceId: workspace.id,
      error: safeErrorMessage(error),
    });
  }
  const main = worktrees.find((worktree) => worktree.isMain);
  return [
    {
      worktreeId: MAIN_WORKTREE_ID,
      label: main?.name ?? "Main checkout",
      root: resolve(expandHome(workspace.hostMount)),
    },
    ...worktrees
      .filter((worktree) => !worktree.isMain)
      .map((worktree) => ({ worktreeId: worktree.id, label: worktree.name, root: worktree.path })),
  ];
}

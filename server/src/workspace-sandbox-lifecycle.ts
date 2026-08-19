/**
 * Workspace sandbox lifecycle helpers composed at the server root.
 *
 * Routes call this with an injected stop function so they never import
 * sdk-backend. Storage stays a persistence leaf.
 */

export function notifySandboxWorkspaceActivity(
  session: { id: string; workspaceId?: string; status: string },
  workspace: { runtime?: string } | undefined,
  vm?: {
    noteWorkspaceBusy?(workspaceId: string, sessionId: string): void;
    noteWorkspaceIdle?(workspaceId: string, sessionId: string): void;
  } | null,
): void {
  if (!session.workspaceId || workspace?.runtime !== "sandbox") return;
  if (session.status === "busy") {
    vm?.noteWorkspaceBusy?.(session.workspaceId, session.id);
    return;
  }
  if (session.status === "ready" || session.status === "stopped" || session.status === "error") {
    vm?.noteWorkspaceIdle?.(session.workspaceId, session.id);
  }
}

export async function deleteWorkspaceAndStopVm(
  workspaceId: string,
  deps: {
    deleteWorkspace: (workspaceId: string) => boolean;
    stopWorkspaceVm?: (workspaceId: string) => void | Promise<void>;
  },
): Promise<boolean> {
  const deleted = deps.deleteWorkspace(workspaceId);
  await deps.stopWorkspaceVm?.(workspaceId);
  return deleted;
}

import { posix, resolve } from "node:path";

import type { Workspace } from "./types.js";

type WorkspaceNameId = Pick<Workspace, "id" | "name">;

/** Folder name Oppi derives from a workspace name: sandbox guest mount segment and default folders. */
export function workspaceSlug(workspace: WorkspaceNameId): string {
  return (
    (workspace.name || workspace.id)
      .toLowerCase()
      .replace(/[^a-z0-9-_]/g, "-")
      .replace(/-+/g, "-")
      .replace(/^-|-$/g, "") || workspace.id
  );
}

/** A sandbox workspace's cwd inside the VM: `/workspace/<slug>`. */
export function resolveSandboxGuestCwd(workspace: WorkspaceNameId): string {
  return posix.join("/workspace", workspaceSlug(workspace));
}

/** Display-form hostMount Oppi stores for a sandbox workspace with an empty folder. */
export function defaultSandboxHostMount(workspace: WorkspaceNameId): string {
  return `~/sandbox/${workspaceSlug(workspace)}`;
}

const MAX_HOST_FOLDER_SLUG = 64;

/**
 * Absolute hostMount Oppi stores for a host workspace with an empty folder:
 * `<workspacesDir>/<slug>`, else `<slug>-<id>` when that is taken. `claim` is the caller's
 * atomic "take this path": it creates the folder and returns true, or returns false when the path
 * is taken (another workspace stores it, or anything already exists there). The slug
 * alphabet has no `.`, so a folder can never collide with the `<id>.json` records beside it.
 * Throws when both are taken: two workspaces never share a folder.
 */
export function defaultHostWorkspaceFolder(
  workspacesDir: string,
  workspace: WorkspaceNameId,
  claim: (resolvedPath: string) => boolean,
): string {
  // A name is user text of any length; keep the folder name well under the 255-byte limit.
  const slug =
    workspaceSlug(workspace).slice(0, MAX_HOST_FOLDER_SLUG).replace(/-+$/, "") || workspace.id;
  const plain = resolve(workspacesDir, slug);
  if (claim(plain)) return plain;
  const suffixed = resolve(workspacesDir, `${slug}-${workspace.id}`);
  if (claim(suffixed)) return suffixed;
  throw new Error(`No free default folder for workspace ${workspace.id}: ${suffixed} is taken`);
}

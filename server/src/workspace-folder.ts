import { resolve } from "node:path";

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

/** Display-form hostMount Oppi stores for a sandbox workspace with an empty folder. */
export function defaultSandboxHostMount(workspace: WorkspaceNameId): string {
  return `~/sandbox/${workspaceSlug(workspace)}`;
}

const MAX_HOST_FOLDER_SLUG = 64;

/**
 * Absolute hostMount Oppi stores for a host workspace with an empty folder:
 * `<workspacesDir>/<slug>`. The slug alphabet has no `.`, so it can never collide with the
 * `<id>.json` records in the same directory. When another workspace already owns that folder
 * (`ownedFolders` holds resolved paths), the workspace id is appended, so the same inputs always
 * give the same folder.
 */
export function defaultHostWorkspaceFolder(
  workspacesDir: string,
  workspace: WorkspaceNameId,
  ownedFolders: ReadonlySet<string>,
): string {
  // A name is user text of any length; keep the folder name well under the 255-byte limit.
  const slug =
    workspaceSlug(workspace).slice(0, MAX_HOST_FOLDER_SLUG).replace(/-+$/, "") || workspace.id;
  const plain = resolve(workspacesDir, slug);
  return ownedFolders.has(plain) ? resolve(workspacesDir, `${slug}-${workspace.id}`) : plain;
}

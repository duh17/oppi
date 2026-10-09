import type { Workspace } from "./types.js";

/** Guest mount segment and default `~/sandbox/<slug>` folder name. */
export function sandboxWorkspaceSlug(workspace: Pick<Workspace, "id" | "name">): string {
  return (
    (workspace.name || workspace.id)
      .toLowerCase()
      .replace(/[^a-z0-9-_]/g, "-")
      .replace(/-+/g, "-")
      .replace(/^-|-$/g, "") || workspace.id
  );
}

/** Display-form hostMount Oppi stores for a sandbox workspace with an empty folder. */
export function defaultSandboxHostMount(workspace: Pick<Workspace, "id" | "name">): string {
  return `~/sandbox/${sandboxWorkspaceSlug(workspace)}`;
}

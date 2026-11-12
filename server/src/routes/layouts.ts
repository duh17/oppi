import { LAYOUT_FILE_NAME } from "../layout-validation.js";
import type { WorkspaceLayoutsResponse } from "../types.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

/**
 * Read-only layout files of a workspace's checkouts (`layout-files.ts`). Nothing here writes: the
 * app saves a layout through the file editor, which may create `.oppi/layouts/<name>.json`.
 */
export function createLayoutRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  return async ({ method, path, url, res }) => {
    if (method !== "GET") return false;
    const list = /^\/workspaces\/([^/]+)\/layouts$/.exec(path);
    const one = list ? null : /^\/workspaces\/([^/]+)\/layouts\/([^/]+)$/.exec(path);
    const match = list ?? one;
    const layoutFiles = ctx.sessions.layoutFiles;
    if (!match || !layoutFiles) return false;

    const workspace = ctx.storage.getWorkspace(match[1] ?? "");
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return true;
    }

    if (list) {
      const body: WorkspaceLayoutsResponse = { layouts: await layoutFiles.list(workspace) };
      helpers.json(res, body);
      return true;
    }

    // Layout names are `[a-z0-9][a-z0-9_-]*`: nothing to decode.
    const name = one?.[2] ?? "";
    const worktreeId = url.searchParams.get("worktree") ?? undefined;
    const layout = LAYOUT_FILE_NAME.test(`${name}.json`)
      ? await layoutFiles.read(workspace, name, worktreeId)
      : null;
    if (!layout) {
      helpers.error(res, 404, "Layout not found");
      return true;
    }
    helpers.json(res, layout);
    return true;
  };
}

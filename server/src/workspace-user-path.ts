import { isAbsolute, resolve } from "node:path";

import { toHostPath } from "./gondolin-ops.js";
import { isPathWithinRoot } from "./git-utils.js";
import type { Workspace } from "./types.js";
import { resolveSandboxGuestCwd } from "./workspace-folder.js";

export interface ResolveWorkspaceUserPathParams {
  workspace: Workspace;
  requestedPath: string;
  /** Host directory the path resolves under: the workspace mount or a worktree path. */
  root: string;
}

/**
 * Map a user-facing browse or current-file path onto `root` (the workspace host mount or a
 * worktree path the caller already resolved).
 *
 * Humans always read sandbox artifacts from the host side. Sandbox sessions advertise guest cwd
 * `/workspace/<slug>`, so that prefix is rewritten with toHostPath. Relative paths resolve under
 * `root`. `~`, host-home, `/etc`, other workspace slugs, and anything outside the guest prefix or
 * `root` are rejected.
 */
export function resolveWorkspaceUserPath(params: ResolveWorkspaceUserPathParams): string | null {
  const requestedPath = params.requestedPath;
  if (requestedPath.includes("\0")) return null;
  if (requestedPath.toLowerCase().startsWith("file:")) return null;
  if (requestedPath.startsWith("~")) return null;

  const hostRoot = resolve(params.root);

  if (requestedPath === "" || requestedPath === "." || requestedPath === "./") {
    return hostRoot;
  }

  if (params.workspace.runtime === "sandbox") {
    const guestCwd = resolveSandboxGuestCwd(params.workspace);
    const guestPath = sandboxGuestPath(requestedPath, guestCwd);
    if (guestPath) {
      try {
        return containedUnderRoot(toHostPath(guestPath, hostRoot, guestCwd), hostRoot);
      } catch {
        return null;
      }
    }
  }

  if (isAbsolute(requestedPath)) {
    return containedUnderRoot(requestedPath, hostRoot);
  }

  return containedUnderRoot(resolve(hostRoot, requestedPath), hostRoot);
}

/** Restore a sandbox guest path after URL routing drops the leading slash. */
function sandboxGuestPath(requestedPath: string, guestCwd: string): string | null {
  const normalized = requestedPath.replaceAll("\\", "/");
  const absolute = normalized.startsWith("/") ? normalized : `/${normalized}`;
  if (absolute === guestCwd || absolute.startsWith(`${guestCwd}/`)) return absolute;
  return null;
}

function containedUnderRoot(candidate: string, root: string): string | null {
  const resolvedCandidate = resolve(candidate);
  return isPathWithinRoot(resolvedCandidate, root) ? resolvedCandidate : null;
}

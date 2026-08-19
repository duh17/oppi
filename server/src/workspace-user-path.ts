import { isAbsolute, resolve } from "node:path";

import { toHostPath } from "./gondolin-ops.js";
import { isPathWithinRoot } from "./git-utils.js";
import { resolveSandboxGuestCwd, resolveSdkSessionCwd } from "./sdk-backend.js";
import type { Session, Workspace } from "./types.js";

export interface ResolveWorkspaceUserPathParams {
  workspace: Workspace;
  requestedPath: string;
  session?: Pick<Session, "workspaceId" | "worktreeId" | "control">;
  dataDir?: string;
  /** Override the host mount, e.g. a worktree path from a browse query. */
  hostMount?: string;
}

/**
 * Map a user-facing browse/raw path onto the workspace host mount.
 *
 * Humans always read sandbox artifacts from the host mount. Sandbox sessions
 * advertise guest cwd `/workspace/<slug>`, so that prefix is rewritten with
 * toHostPath. Relative paths still resolve under the mount. `~`, host-home,
 * `/etc`, other workspace slugs, and anything outside the guest prefix / host
 * mount are rejected. Parent and child Agent sessions share the workspace id
 * and therefore this mapping; do not branch on launch source.
 */
export function resolveWorkspaceUserPath(params: ResolveWorkspaceUserPathParams): string | null {
  const requestedPath = params.requestedPath;
  if (requestedPath.includes("\0")) return null;
  if (requestedPath.toLowerCase().startsWith("file:")) return null;
  if (requestedPath.startsWith("~")) return null;

  let hostMount: string;
  try {
    hostMount =
      params.hostMount ??
      resolveSdkSessionCwd(params.workspace, params.session, { dataDir: params.dataDir });
  } catch {
    return null;
  }
  const hostRoot = resolve(hostMount);

  if (requestedPath === "" || requestedPath === "." || requestedPath === "./") {
    return hostRoot;
  }

  if (params.workspace.runtime === "sandbox") {
    const guestCwd = resolveSandboxGuestCwd(params.workspace);
    if (requestedPath === guestCwd || requestedPath.startsWith(`${guestCwd}/`)) {
      try {
        return containedUnderRoot(toHostPath(requestedPath, hostRoot, guestCwd), hostRoot);
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

function containedUnderRoot(candidate: string, root: string): string | null {
  const resolvedCandidate = resolve(candidate);
  return isPathWithinRoot(resolvedCandidate, root) ? resolvedCandidate : null;
}

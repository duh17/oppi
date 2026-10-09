import { isControlRouteSession } from "./control-session.js";
import type { Session, Workspace } from "./types.js";

/**
 * One owner for "may this session be reached under this route family?"
 *
 * Callers keep their current status mapping: sessions/session-files 400 for
 * wrong-workspace, uploads 404, stream close 1008. HTTP checks workspace
 * existence (default); stream passes `workspaceMustExist: false`. Stream path
 * matching URL-decodes ids; HTTP route regexes do not.
 */
export type SessionRouteStore = {
  getSession(sessionId: string): Session | undefined;
  getWorkspace(workspaceId: string): Workspace | undefined;
};

export type SessionRouteScope =
  | { scope: "workspace"; workspaceId: string; sessionId: string }
  | { scope: "control"; sessionId: string }
  | { scope: "generic"; sessionId: string };

export type FocusedSessionStreamPath = Exclude<SessionRouteScope, { scope: "generic" }>;

export type SessionRouteAdmission =
  | { kind: "ok"; session: Session; workspace?: Workspace }
  | { kind: "workspace-missing" }
  | { kind: "session-missing" }
  | { kind: "wrong-workspace" }
  | { kind: "not-control" };

export function matchFocusedSessionStreamPath(path: string): FocusedSessionStreamPath | null {
  const workspaceMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/stream$/);
  const controlMatch = path.match(/^\/control-sessions\/([^/]+)\/stream$/);
  try {
    if (workspaceMatch) {
      return {
        scope: "workspace",
        workspaceId: decodeURIComponent(workspaceMatch[1]),
        sessionId: decodeURIComponent(workspaceMatch[2]),
      };
    }
    if (controlMatch) {
      return { scope: "control", sessionId: decodeURIComponent(controlMatch[1]) };
    }
  } catch {
    return null;
  }
  return null;
}

type SessionMissing = { kind: "session-missing" };

// Per-family results list only the failures that family can produce, so each
// HTTP boundary maps every kind to a response and has no silent arm.
export function admitSessionRoute(
  store: SessionRouteStore,
  route: Extract<SessionRouteScope, { scope: "workspace" }>,
):
  | { kind: "ok"; session: Session; workspace: Workspace }
  | { kind: "workspace-missing" }
  | SessionMissing
  | { kind: "wrong-workspace" };
export function admitSessionRoute(
  store: SessionRouteStore,
  route: Extract<SessionRouteScope, { scope: "control" }>,
): { kind: "ok"; session: Session } | SessionMissing | { kind: "not-control" };
export function admitSessionRoute(
  store: SessionRouteStore,
  route: Extract<SessionRouteScope, { scope: "generic" }>,
): { kind: "ok"; session: Session } | SessionMissing;
export function admitSessionRoute(
  store: SessionRouteStore,
  route: SessionRouteScope,
  options?: { workspaceMustExist?: boolean },
): SessionRouteAdmission;
export function admitSessionRoute(
  store: SessionRouteStore,
  route: SessionRouteScope,
  options?: { workspaceMustExist?: boolean },
): SessionRouteAdmission {
  if (route.scope === "workspace") {
    const workspaceMustExist = options?.workspaceMustExist !== false;
    let workspace: Workspace | undefined;
    if (workspaceMustExist) {
      workspace = store.getWorkspace(route.workspaceId);
      if (!workspace) return { kind: "workspace-missing" };
    }
    const session = store.getSession(route.sessionId);
    if (!session) return { kind: "session-missing" };
    if (session.workspaceId !== route.workspaceId) return { kind: "wrong-workspace" };
    return workspace ? { kind: "ok", session, workspace } : { kind: "ok", session };
  }

  const session = store.getSession(route.sessionId);
  if (!session) return { kind: "session-missing" };
  if (route.scope === "control" && !isControlRouteSession(session)) {
    return { kind: "not-control" };
  }
  return { kind: "ok", session };
}

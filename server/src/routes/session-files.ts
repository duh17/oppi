import type { ServerResponse } from "node:http";

import { admitSessionRoute } from "../session-route-scope.js";
import { SessionTraceService } from "../session-trace-service.js";
import type { Session, Workspace } from "../types.js";
import type { RouteContext, RouteHelpers } from "./types.js";

export interface SessionFileHandlers {
  handleListSessionChanges(
    workspaceId: string,
    sessionId: string,
    res: ServerResponse,
  ): Promise<void>;
}

export function createSessionFileHandlers(
  ctx: RouteContext,
  helpers: RouteHelpers,
  traceService = new SessionTraceService({
    storage: ctx.storage,
    sessionRuntimes: ctx.sessionRuntimes,
    ensureSessionContextWindow: ctx.ensureSessionContextWindow,
    mobileRenderers: ctx.sessions.mobileRenderer,
  }),
): SessionFileHandlers {
  function requireWorkspaceSession(
    workspaceId: string,
    sessionId: string,
    res: ServerResponse,
  ): { workspace: Workspace; session: Session } | null {
    const result = admitSessionRoute(ctx.storage, {
      scope: "workspace",
      workspaceId,
      sessionId,
    });
    switch (result.kind) {
      case "ok":
        return { workspace: result.workspace, session: result.session };
      case "workspace-missing":
        helpers.error(res, 404, "Workspace not found");
        return null;
      case "session-missing":
        helpers.error(res, 404, "Session not found");
        return null;
      case "wrong-workspace":
        helpers.error(res, 400, "Session does not belong to this workspace");
        return null;
    }
  }

  async function handleListSessionChanges(
    workspaceId: string,
    sessionId: string,
    res: ServerResponse,
  ): Promise<void> {
    const ownedSession = requireWorkspaceSession(workspaceId, sessionId, res);
    if (!ownedSession) return;

    helpers.json(res, traceService.listSessionChanges(ownedSession.session));
  }

  return {
    handleListSessionChanges,
  };
}

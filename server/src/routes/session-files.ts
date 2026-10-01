import type { IncomingMessage, ServerResponse } from "node:http";

import { sendFileBytes } from "../current-file.js";
import { SessionTraceService } from "../session-trace-service.js";
import type { Session, Workspace } from "../types.js";
import type { RouteContext, RouteHelpers } from "./types.js";

export interface SessionFileHandlers {
  handleListSessionChanges(
    workspaceId: string,
    sessionId: string,
    res: ServerResponse,
  ): Promise<void>;
  handleGetSessionRaw(
    workspaceId: string,
    sessionId: string,
    requestedPath: string,
    res: ServerResponse,
    req?: IncomingMessage,
    method?: string,
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
    const workspace = ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return null;
    }

    const session = ctx.storage.getSession(sessionId);
    if (!session) {
      helpers.error(res, 404, "Session not found");
      return null;
    }
    if (session.workspaceId !== workspaceId) {
      helpers.error(res, 400, "Session does not belong to this workspace");
      return null;
    }

    return { workspace, session };
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

  async function handleGetSessionRaw(
    workspaceId: string,
    sessionId: string,
    requestedPath: string,
    res: ServerResponse,
    req?: IncomingMessage,
    method = "GET",
  ): Promise<void> {
    const ownedSession = requireWorkspaceSession(workspaceId, sessionId, res);
    if (!ownedSession) return;

    const result = await traceService.getSessionRawFile({
      workspace: ownedSession.workspace,
      session: ownedSession.session,
      path: requestedPath,
    });

    switch (result.kind) {
      case "ok":
        await sendFileBytes(req, res, method, result, { rangeLogTag: "session-raw" });
        return;
      case "path-required":
        helpers.error(res, 400, "path parameter required");
        return;
      case "file-not-found":
        helpers.error(res, 404, "File not found");
        return;
      case "workspace-root-not-found":
        helpers.error(res, 404, "Workspace root not found");
        return;
      case "path-outside-workspace":
        helpers.error(res, 403, "Path outside session workspace");
        return;
      case "not-file":
        helpers.error(res, 400, "Not a file");
        return;
      case "file-too-large":
        helpers.error(res, 413, `File too large (max ${result.maxSizeMegabytes}MB)`);
        return;
    }
  }

  return {
    handleListSessionChanges,
    handleGetSessionRaw,
  };
}

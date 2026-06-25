import type { ServerResponse } from "node:http";
import { createReadStream } from "node:fs";

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
  ): Promise<void>;
}

export function createSessionFileHandlers(
  ctx: RouteContext,
  helpers: RouteHelpers,
  traceService = new SessionTraceService({
    storage: ctx.storage,
    sessionRuntimes: ctx.sessionRuntimes,
    ensureSessionContextWindow: ctx.ensureSessionContextWindow,
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
  ): Promise<void> {
    const ownedSession = requireWorkspaceSession(workspaceId, sessionId, res);
    if (!ownedSession) return;

    const result = await traceService.getSessionRawFile({
      workspace: ownedSession.workspace,
      session: ownedSession.session,
      path: requestedPath,
    });

    switch (result.kind) {
      case "ok": {
        const stream = createReadStream(result.filePath);
        stream.once("error", (error) => {
          if (!res.headersSent) {
            helpers.error(res, 500, "Failed to read file");
            return;
          }
          res.destroy(error);
        });
        stream.once("open", () => {
          res.writeHead(200, {
            "Content-Type": result.contentType,
            "Content-Length": result.size.toString(),
            "Cache-Control": "private, no-cache",
          });
          stream.pipe(res as NodeJS.WritableStream);
        });
        return;
      }
      case "path-required":
        helpers.error(res, 400, "path parameter required");
        return;
      case "path-not-in-session-changes":
        helpers.error(res, 403, "Path not in session changed files");
        return;
      case "sensitive-path":
        helpers.error(res, 403, "Access denied: sensitive file");
        return;
      case "file-not-found":
        helpers.error(res, 404, "File not found");
        return;
      case "workspace-root-not-found":
        helpers.error(res, 404, "Workspace root not found");
        return;
      case "path-outside-workspaces":
        helpers.error(res, 403, "Path outside configured workspaces");
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

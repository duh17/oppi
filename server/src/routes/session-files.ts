import type { IncomingMessage, ServerResponse } from "node:http";
import { createReadStream } from "node:fs";

import { parseByteRangeHeader } from "../http-range.js";
import { SessionTraceService } from "../session-trace-service.js";
import type { Session, Workspace } from "../types.js";
import type { RouteContext, RouteHelpers } from "./types.js";

function pipeSessionFile(
  filePath: string,
  res: ServerResponse,
  statusCode: number,
  headers: Record<string, string>,
  onOpenError: () => void,
  range?: { start: number; end: number },
): void {
  const stream = range
    ? createReadStream(filePath, { start: range.start, end: range.end })
    : createReadStream(filePath);
  stream.once("error", (error) => {
    if (!res.headersSent) {
      onOpenError();
      return;
    }
    res.destroy(error);
  });
  stream.once("open", () => {
    res.writeHead(statusCode, headers);
    stream.pipe(res as NodeJS.WritableStream);
  });
}

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
      case "ok": {
        const commonHeaders = {
          "Content-Type": result.contentType,
          "Cache-Control": "private, no-cache",
          "Accept-Ranges": "bytes",
        };
        const range = parseByteRangeHeader(req?.headers.range, result.size);
        const isHeadRequest = method.toUpperCase() === "HEAD";

        if (range.kind === "invalid" || range.kind === "unsatisfiable") {
          res.writeHead(416, {
            ...commonHeaders,
            "Content-Range": `bytes */${result.size}`,
            "Content-Length": "0",
          });
          res.end();
          return;
        }

        if (range.kind === "valid") {
          const contentLength = range.end - range.start + 1;
          const headers = {
            ...commonHeaders,
            "Content-Range": `bytes ${range.start}-${range.end}/${result.size}`,
            "Content-Length": contentLength.toString(),
          };
          if (isHeadRequest) {
            res.writeHead(206, headers);
            res.end();
            return;
          }
          pipeSessionFile(
            result.filePath,
            res,
            206,
            headers,
            () => helpers.error(res, 500, "Failed to read file"),
            range,
          );
          return;
        }

        const headers = {
          ...commonHeaders,
          "Content-Length": result.size.toString(),
        };
        if (isHeadRequest) {
          res.writeHead(200, headers);
          res.end();
          return;
        }
        pipeSessionFile(result.filePath, res, 200, headers, () =>
          helpers.error(res, 500, "Failed to read file"),
        );
        return;
      }
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

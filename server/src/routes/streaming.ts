import type { IncomingMessage, ServerResponse } from "node:http";

import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

type PermissionRespondBody = {
  action?: unknown;
  scope?: unknown;
  expiresInMs?: unknown;
};

export function createStreamingRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  function handleGetUserStreamEvents(url: URL, res: ServerResponse): void {
    const sinceParam = url.searchParams.get("since");
    const sinceSeq = sinceParam ? Number.parseInt(sinceParam, 10) : 0;
    if (!Number.isFinite(sinceSeq) || sinceSeq < 0) {
      helpers.error(res, 400, "since must be a non-negative integer");
      return;
    }

    const catchUp = ctx.streamMux.getUserStreamCatchUp(sinceSeq);

    helpers.json(res, {
      events: catchUp.events,
      currentSeq: catchUp.currentSeq,
      catchUpComplete: catchUp.catchUpComplete,
    });
  }

  function handleGetPendingPermissions(url: URL, res: ServerResponse): void {
    const sessionIdFilter = url.searchParams.get("sessionId") || undefined;
    const workspaceIdFilter = url.searchParams.get("workspaceId") || undefined;

    if (sessionIdFilter) {
      const session = ctx.storage.getSession(sessionIdFilter);
      if (!session) {
        helpers.error(res, 404, "Session not found");
        return;
      }
    }

    if (workspaceIdFilter) {
      const workspace = ctx.storage.getWorkspace(workspaceIdFilter);
      if (!workspace) {
        helpers.error(res, 404, "Workspace not found");
        return;
      }
    }

    const serverTime = Date.now();
    const pending = ctx.gate
      .getPendingForUser()
      .filter((decision) => decision.expires === false || decision.timeoutAt > serverTime)
      .filter((decision) => !sessionIdFilter || decision.sessionId === sessionIdFilter)
      .filter((decision) => !workspaceIdFilter || decision.workspaceId === workspaceIdFilter)
      .map((decision) => ({
        id: decision.id,
        sessionId: decision.sessionId,
        workspaceId: decision.workspaceId,
        tool: decision.tool,
        input: decision.input,
        displaySummary: decision.displaySummary,
        reason: decision.reason,
        timeoutAt: decision.timeoutAt,
        expires: decision.expires ?? true,
      }));

    helpers.json(res, {
      pending,
      serverTime,
    });
  }

  async function handleRespondToPermission(
    permissionId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    let body: PermissionRespondBody;
    try {
      body = await helpers.parseBody<PermissionRespondBody>(req);
    } catch {
      helpers.error(res, 400, "Invalid JSON");
      return;
    }

    const action = body.action;
    if (action !== "allow" && action !== "deny") {
      helpers.error(res, 400, 'action must be "allow" or "deny"');
      return;
    }

    const rawScope = body.scope;
    const scope = rawScope === undefined ? "once" : rawScope;
    if (scope !== "once" && scope !== "session" && scope !== "global") {
      helpers.error(res, 400, 'scope must be "once", "session", or "global"');
      return;
    }

    const rawExpires = body.expiresInMs;
    let expiresInMs: number | undefined;
    if (rawExpires !== undefined) {
      const parsedExpiresInMs = Number(rawExpires);
      if (!Number.isFinite(parsedExpiresInMs) || parsedExpiresInMs <= 0) {
        helpers.error(res, 400, "expiresInMs must be a positive number when provided");
        return;
      }
      expiresInMs = parsedExpiresInMs;
    }

    const resolved = ctx.gate.resolveDecision(permissionId, action, scope, expiresInMs);
    if (!resolved) {
      helpers.error(res, 404, "Permission request not found");
      return;
    }

    helpers.json(res, {
      ok: true,
      id: permissionId,
      action,
      scope,
      ...(expiresInMs !== undefined ? { expiresInMs } : {}),
    });
  }

  return async ({ method, path, url, req, res }) => {
    if (path === "/stream/events" && method === "GET") {
      handleGetUserStreamEvents(url, res);
      return true;
    }

    if (path === "/permissions/pending" && method === "GET") {
      handleGetPendingPermissions(url, res);
      return true;
    }

    if (method === "POST") {
      const respondMatch = path.match(/^\/permissions\/([^/]+)\/respond$/);
      if (respondMatch) {
        try {
          const permissionId = decodeURIComponent(respondMatch[1]);
          await handleRespondToPermission(permissionId, req, res);
        } catch {
          helpers.error(res, 400, "Invalid permission id");
        }
        return true;
      }
    }

    return false;
  };
}

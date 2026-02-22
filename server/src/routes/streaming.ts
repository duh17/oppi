import type { ServerResponse } from "node:http";

import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

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

  return async ({ method, path, url, res }) => {
    if (path === "/stream/events" && method === "GET") {
      handleGetUserStreamEvents(url, res);
      return true;
    }

    if (path === "/permissions/pending" && method === "GET") {
      handleGetPendingPermissions(url, res);
      return true;
    }

    return false;
  };
}

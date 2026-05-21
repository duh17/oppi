import type { IncomingMessage, ServerResponse } from "node:http";

import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

type PermissionRespondBody = {
  action?: unknown;
  scope?: unknown;
  expiresInMs?: unknown;
};

export function createStreamingRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
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

  return async ({ method, path, req, res }) => {
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

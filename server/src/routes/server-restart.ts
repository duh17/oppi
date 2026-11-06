import type { IncomingMessage, ServerResponse } from "node:http";

import { MAX_DRAIN_MAX_WAIT_MS } from "../server-drain.js";
import { safeErrorMessage } from "../log-utils.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

/**
 * `/server/restart`: restart this server once running turns finish (server-drain.ts).
 * GET reads the pending drain, POST `{ maxWaitMs? }` starts one (or returns the one already
 * pending), DELETE cancels it.
 */
export function createServerRestartRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
): RouteDispatcher {
  async function handlePost(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const control = ctx.serverRestart;
    const unavailable = control ? control.unavailableReason() : "Server restart is unavailable";
    if (!control || unavailable) {
      helpers.json(res, { error: unavailable, code: "restart_unavailable" }, 409);
      return;
    }
    let body: { maxWaitMs?: unknown };
    try {
      body =
        (await helpers.parseBody<{ maxWaitMs?: unknown } | null>(req, { maxBytes: 4096 })) ?? {};
    } catch (err: unknown) {
      helpers.json(
        res,
        { error: safeErrorMessage(err) || "Invalid JSON", code: "invalid_json" },
        400,
      );
      return;
    }
    const maxWaitMs = body.maxWaitMs;
    if (
      maxWaitMs !== undefined &&
      (typeof maxWaitMs !== "number" ||
        !Number.isInteger(maxWaitMs) ||
        maxWaitMs < 0 ||
        maxWaitMs > MAX_DRAIN_MAX_WAIT_MS)
    ) {
      helpers.json(
        res,
        {
          error: `maxWaitMs must be an integer from 0 to ${MAX_DRAIN_MAX_WAIT_MS}`,
          code: "invalid_max_wait",
        },
        400,
      );
      return;
    }
    const pending = control.status().state !== "idle";
    const status = control.request({
      ...(maxWaitMs !== undefined ? { maxWaitMs } : {}),
      source: "http",
    });
    helpers.json(res, { restart: status }, pending ? 200 : 202);
  }

  return async ({ method, path, req, res }) => {
    if (path !== "/server/restart") return false;
    const control = ctx.serverRestart;
    if (method === "POST") {
      await handlePost(req, res);
      return true;
    }
    if (!control) {
      helpers.json(
        res,
        { error: "Server restart is unavailable", code: "restart_unavailable" },
        409,
      );
      return true;
    }
    if (method === "GET") {
      helpers.json(res, { restart: control.status() });
      return true;
    }
    if (method === "DELETE") {
      const status = control.cancel("http");
      if (!status) {
        helpers.json(res, { error: "No restart is pending", code: "restart_not_pending" }, 409);
        return true;
      }
      helpers.json(res, { restart: status });
      return true;
    }
    return false;
  };
}

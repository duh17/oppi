import type { IncomingMessage, ServerResponse } from "node:http";

import { createLogger } from "../logger.js";
import { safeErrorMessage } from "../log-utils.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

const log = createLogger({ base: { component: "route_server_update" } });

export function createServerUpdateRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
): RouteDispatcher {
  async function handlePost(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const service = ctx.serverUpdate;
    if (!service) {
      helpers.error(res, 500, "Server update is unavailable");
      return;
    }

    let body: unknown;
    try {
      body = await helpers.parseBody<unknown>(req, { maxBytes: 16 * 1024 });
    } catch (err: unknown) {
      helpers.json(
        res,
        { error: safeErrorMessage(err) || "Invalid JSON", code: "invalid_json" },
        400,
      );
      return;
    }

    if (!body || typeof body !== "object" || Array.isArray(body)) {
      helpers.json(
        res,
        {
          error: 'Request body must be { version: "<semver>" }',
          code: "invalid_version",
        },
        400,
      );
      return;
    }

    const version = (body as { version?: unknown }).version;
    const result = service.beginUpdate(version);
    if (!result.ok) {
      log.info("server_update.rejected", { code: result.code });
      helpers.json(res, { error: result.message, code: result.code }, result.status);
      return;
    }

    helpers.json(res, result.update, 202);
  }

  return async ({ method, path, req, res }) => {
    if (path !== "/server/update") return false;
    if (method === "POST") {
      await handlePost(req, res);
      return true;
    }
    return false;
  };
}

import { safeErrorMessage } from "../log-utils.js";
import { RequiredExtensionError } from "../sessions.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

/**
 * Durable extension routes (owner only):
 * - `GET /durable/extensions`: the durable extensions workspace sessions may select, from the
 *   built-in and the owner's plugins, each with `enabled`.
 * - `PUT /durable/extensions/{name}/enabled` `{ enabled }`: enable or disable one by name in the
 *   server config, as `/server/resources/extensions/{id}/enabled` does for classic extensions; a
 *   required built-in is 409.
 * - `POST /durable/extensions/reload`: discover and load every plugin again in the running
 *   server, without a restart.
 */
export function createDurableExtensionRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
): RouteDispatcher {
  return async ({ method, path, req, res }) => {
    if (path === "/durable/extensions" && method === "GET") {
      try {
        const extensions = await ctx.sessions.listDurableExtensions();
        helpers.json(res, { extensions });
      } catch (error: unknown) {
        helpers.error(res, 500, safeErrorMessage(error));
      }
      return true;
    }

    const encoded = path.match(/^\/durable\/extensions\/([^/]+)\/enabled$/)?.[1];
    if (encoded !== undefined && method === "PUT") {
      let name: string;
      try {
        name = decodeURIComponent(encoded);
      } catch {
        helpers.error(res, 400, "Invalid extension name");
        return true;
      }
      let body: unknown;
      try {
        body = await helpers.parseBody<unknown>(req, { maxBytes: 1024 });
      } catch {
        helpers.error(res, 400, "Request body must be valid JSON");
        return true;
      }
      const enabled = (body as { enabled?: unknown } | null)?.enabled;
      if (
        typeof body !== "object" ||
        body === null ||
        Object.keys(body).length !== 1 ||
        typeof enabled !== "boolean"
      ) {
        helpers.error(res, 400, "Request body must be exactly { enabled: boolean }");
        return true;
      }
      try {
        const extension = await ctx.sessions.setDurableExtensionEnabled(name, enabled);
        if (extension === null)
          helpers.error(res, 404, `No durable extension named ${name} is loaded`);
        else helpers.json(res, { extension });
      } catch (error: unknown) {
        helpers.error(
          res,
          error instanceof RequiredExtensionError ? 409 : 500,
          safeErrorMessage(error),
        );
      }
      return true;
    }

    if (path !== "/durable/extensions/reload" || method !== "POST") return false;
    try {
      const report = await ctx.sessions.reloadDurableExtensions();
      helpers.json(res, report);
    } catch (error: unknown) {
      helpers.error(res, 500, safeErrorMessage(error));
    }
    return true;
  };
}

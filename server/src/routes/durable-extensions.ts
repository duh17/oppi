import { safeErrorMessage } from "../log-utils.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

/**
 * `POST /durable/extensions/reload` (owner only): re-read the durable entries of enabled Pi
 * packages and install them in the running Harness registry, without a server restart.
 */
export function createDurableExtensionRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
): RouteDispatcher {
  return async ({ method, path, res }) => {
    if (path !== "/durable/extensions/reload" || method !== "POST") return false;
    try {
      const report = await ctx.sessions.reloadDurableExtensions();
      if (!report) {
        helpers.error(
          res,
          409,
          "Durable extensions are not available on this server; enable experimental.serverDurable",
        );
        return true;
      }
      helpers.json(res, report);
    } catch (error: unknown) {
      helpers.error(res, 500, safeErrorMessage(error));
    }
    return true;
  };
}

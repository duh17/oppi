import { arch, platform } from "node:os";

import {
  parseServerMetricsRange,
  readServerMetricsHistory,
  SERVER_METRICS_RANGES,
} from "../server-metrics-history.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

/**
 * Server Metrics page: `GET /server/metrics?range=1h|24h|7d|30d` and the
 * `serverMetrics.enabled` switch at `/server/metrics/settings`.
 */
export function createServerMetricsRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
): RouteDispatcher {
  return async ({ method, path, url, req, res }) => {
    if (path === "/server/metrics" && method === "GET") {
      const control = ctx.serverMetrics;
      if (!control) {
        helpers.error(res, 503, "Server metrics are unavailable");
        return true;
      }
      const range = parseServerMetricsRange(url.searchParams.get("range"));
      if (!range) {
        helpers.error(
          res,
          400,
          `range must be one of ${Object.keys(SERVER_METRICS_RANGES).join(", ")}`,
        );
        return true;
      }
      const enabled = control.isEnabled();
      helpers.compressedJson(req, res, {
        enabled,
        intervalMs: control.intervalMs,
        serverStartedAt: ctx.serverStartedAt,
        platform: platform(),
        arch: arch(),
        latest: enabled ? control.latestSample() : null,
        history: enabled ? await readServerMetricsHistory(control.telemetryDir, range) : null,
      });
      return true;
    }

    if (path === "/server/metrics/settings") {
      const control = ctx.serverMetrics;
      if (!control) {
        helpers.error(res, 503, "Server metrics are unavailable");
        return true;
      }
      if (method === "GET") {
        helpers.json(res, { enabled: control.isEnabled() });
        return true;
      }
      if (method === "PUT") {
        const body = await helpers.parseBody<{ enabled?: unknown }>(req, { maxBytes: 1024 });
        if (typeof body.enabled !== "boolean") {
          helpers.error(res, 400, "enabled must be a boolean");
          return true;
        }
        control.setEnabled(body.enabled);
        helpers.json(res, { enabled: control.isEnabled() });
        return true;
      }
    }
    return false;
  };
}

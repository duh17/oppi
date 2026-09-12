import { DesktopCompanionStillError } from "../desktop-companion-still-client.js";
import { isDeviceAccessPrincipal } from "../request-principal.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

const STILL_HEADERS = {
  captureId: "X-Oppi-Capture-ID",
  surfaceWindowId: "X-Oppi-Surface-Window-ID",
  surfaceTitle: "X-Oppi-Surface-Title",
  capturedAt: "X-Oppi-Captured-At",
  width: "X-Oppi-Width",
  height: "X-Oppi-Height",
  caption: "X-Oppi-Caption",
} as const;

export function createDesktopStillRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
): RouteDispatcher {
  return async ({ method, path, res, principal }) => {
    if (path !== "/desktop/stills/current") return false;
    if (method !== "GET") {
      res.writeHead(405, {
        Allow: "GET",
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
      });
      res.end(JSON.stringify({ error: "Method not allowed" }));
      return true;
    }

    if (!isDeviceAccessPrincipal(principal)) {
      helpers.error(res, 404, "Not found");
      return true;
    }

    const client = ctx.desktopCompanionStillClient;
    if (!client) {
      helpers.error(res, 404, "Not found");
      return true;
    }

    try {
      const still = await client.fetchCurrentStill();
      res.writeHead(200, {
        "Content-Type": "image/png",
        "Content-Length": String(still.png.length),
        "Cache-Control": "no-store",
        [STILL_HEADERS.captureId]: still.captureId,
        [STILL_HEADERS.surfaceWindowId]: String(still.surface.windowId),
        [STILL_HEADERS.surfaceTitle]: utf8Header(still.surface.title),
        [STILL_HEADERS.capturedAt]: still.capturedAt,
        [STILL_HEADERS.width]: String(still.width),
        [STILL_HEADERS.height]: String(still.height),
        [STILL_HEADERS.caption]: utf8Header(still.caption),
      });
      res.end(still.png);
    } catch (error: unknown) {
      if (error instanceof DesktopCompanionStillError) {
        if (error.code === "sharing_disabled") {
          helpers.error(res, 403, error.message);
          return true;
        }
        if (error.code === "stale_capture") {
          helpers.error(res, 404, error.message);
          return true;
        }
        helpers.error(res, 502, error.message);
        return true;
      }
      helpers.error(res, 502, "Desktop companion is unavailable");
    }
    return true;
  };
}

/** Node rejects non-Latin-1 header values. Companion writes UTF-8 bytes; match that wire. */
function utf8Header(value: string): string {
  return Buffer.from(value, "utf8").toString("latin1");
}

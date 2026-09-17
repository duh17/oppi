import type { ServerResponse } from "node:http";

import { DesktopCompanionViewSessionError } from "../desktop-companion-view-session-client.js";
import { isDeviceAccessPrincipal } from "../request-principal.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

const VIEW_SESSION_CAPTION = "View session\u2014not live delivery";

export function createDesktopViewSessionRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
): RouteDispatcher {
  return async ({ method, path, res, principal }) => {
    if (path !== "/desktop/view/session") return false;
    if (method !== "GET") {
      res.writeHead(405, {
        Allow: "GET",
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
      });
      res.end(JSON.stringify({ error: "Method not allowed" }));
      return true;
    }

    if (!isDeviceAccessPrincipal(principal) || principal.deviceId.trim() === "") {
      helpers.error(res, 404, "Not found");
      return true;
    }

    const client = ctx.desktopCompanionViewSessionClient;
    if (!client) {
      helpers.error(res, 404, "Not found");
      return true;
    }

    const deviceName = lookupDeviceName(ctx, principal.deviceId);

    try {
      const session = await client.fetchViewSession({
        deviceId: principal.deviceId,
        deviceName,
      });
      res.writeHead(200, {
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
      });
      res.end(
        JSON.stringify({
          grantId: session.grantId,
          capability: "view",
          deviceId: principal.deviceId,
          expiresAt: session.expiresAt,
          caption: VIEW_SESSION_CAPTION,
        }),
      );
    } catch (error: unknown) {
      if (error instanceof DesktopCompanionViewSessionError) {
        if (error.code === "not_bound") {
          writeCodedError(res, 403, error.message, "view_grant_not_bound");
          return true;
        }
        if (error.code === "unavailable") {
          writeCodedError(res, 403, error.message, "view_grant_unavailable");
          return true;
        }
        if (error.code === "malformed_session") {
          helpers.error(res, 502, error.message);
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

function writeCodedError(res: ServerResponse, status: number, message: string, code: string): void {
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
  });
  res.end(JSON.stringify({ error: message, code }));
}

function lookupDeviceName(ctx: RouteContext, deviceId: string): string | undefined {
  const storage = ctx.storage as
    | { listDevices?: () => Array<{ id: string; name: string }> }
    | undefined;
  const devices = storage?.listDevices?.() ?? [];
  const match = devices.find((device) => device.id === deviceId);
  const name = match?.name?.trim();
  return name && name.length > 0 ? name : undefined;
}

import type { IncomingMessage, ServerResponse } from "node:http";

import { AppletError } from "../storage/applet-store.js";
import type { CreateAppletRequest, UpdateAppletRequest } from "../types.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

export function createAppletRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  function handleListApplets(workspaceId: string, res: ServerResponse): void {
    const workspace = ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const applets = ctx.storage.listApplets(workspaceId);
    helpers.json(res, { applets });
  }

  async function handleCreateApplet(
    workspaceId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const body = await helpers.parseBody<CreateAppletRequest>(req);
    if (!body.title || typeof body.title !== "string" || body.title.trim().length === 0) {
      helpers.error(res, 400, "title required");
      return;
    }

    if (!body.html || typeof body.html !== "string") {
      helpers.error(res, 400, "html required");
      return;
    }

    try {
      const result = ctx.storage.createApplet(workspaceId, body);
      helpers.json(res, result, 201);
    } catch (err) {
      if (err instanceof AppletError) {
        helpers.error(res, err.status, err.message);
        return;
      }
      throw err;
    }
  }

  function handleGetApplet(workspaceId: string, appletId: string, res: ServerResponse): void {
    const applet = ctx.storage.getApplet(workspaceId, appletId);
    if (!applet) {
      helpers.error(res, 404, "Applet not found");
      return;
    }

    // Include latest version HTML
    const latestVersion = ctx.storage.getAppletVersion(
      workspaceId,
      appletId,
      applet.currentVersion,
    );

    helpers.json(res, { applet, latestVersion });
  }

  async function handleUpdateApplet(
    workspaceId: string,
    appletId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const body = await helpers.parseBody<UpdateAppletRequest>(req);
    if (!body.html || typeof body.html !== "string") {
      helpers.error(res, 400, "html required");
      return;
    }

    try {
      const result = ctx.storage.updateApplet(workspaceId, appletId, body);
      if (!result) {
        helpers.error(res, 404, "Applet not found");
        return;
      }
      helpers.json(res, result);
    } catch (err) {
      if (err instanceof AppletError) {
        helpers.error(res, err.status, err.message);
        return;
      }
      throw err;
    }
  }

  function handleDeleteApplet(workspaceId: string, appletId: string, res: ServerResponse): void {
    if (!ctx.storage.deleteApplet(workspaceId, appletId)) {
      helpers.error(res, 404, "Applet not found");
      return;
    }
    helpers.json(res, { ok: true });
  }

  function handleListVersions(workspaceId: string, appletId: string, res: ServerResponse): void {
    const applet = ctx.storage.getApplet(workspaceId, appletId);
    if (!applet) {
      helpers.error(res, 404, "Applet not found");
      return;
    }

    const versions = ctx.storage.listAppletVersions(workspaceId, appletId);
    helpers.json(res, { versions });
  }

  function handleGetVersion(
    workspaceId: string,
    appletId: string,
    version: number,
    res: ServerResponse,
  ): void {
    const v = ctx.storage.getAppletVersion(workspaceId, appletId, version);
    if (!v) {
      helpers.error(res, 404, "Version not found");
      return;
    }
    helpers.json(res, { version: v });
  }

  function handleGetVersionHtml(
    workspaceId: string,
    appletId: string,
    version: number,
    res: ServerResponse,
  ): void {
    const html = ctx.storage.getAppletVersionHtml(workspaceId, appletId, version);
    if (!html) {
      helpers.error(res, 404, "Version not found");
      return;
    }

    res.writeHead(200, {
      "Content-Type": "text/html; charset=utf-8",
      "Content-Security-Policy":
        "default-src 'self' 'unsafe-inline' 'unsafe-eval' " +
        "https://cdnjs.cloudflare.com https://cdn.jsdelivr.net https://unpkg.com https://esm.sh " +
        "data: blob:; " +
        "img-src 'self' data: blob: https:; " +
        "font-src 'self' data: https://cdnjs.cloudflare.com https://cdn.jsdelivr.net https://fonts.gstatic.com;",
      "X-Content-Type-Options": "nosniff",
    });
    res.end(html);
  }

  // ─── Dispatch ───

  return async ({ method, path, url: _url, req, res }) => {
    // POST /workspaces/:wid/applets
    const listMatch = path.match(/^\/workspaces\/([^/]+)\/applets$/);
    if (listMatch) {
      const wid = listMatch[1];
      if (method === "GET") {
        handleListApplets(wid, res);
        return true;
      }
      if (method === "POST") {
        await handleCreateApplet(wid, req, res);
        return true;
      }
    }

    // /workspaces/:wid/applets/:aid/versions/:v/html
    const htmlMatch = path.match(
      /^\/workspaces\/([^/]+)\/applets\/([^/]+)\/versions\/(\d+)\/html$/,
    );
    if (htmlMatch && method === "GET") {
      handleGetVersionHtml(htmlMatch[1], htmlMatch[2], parseInt(htmlMatch[3], 10), res);
      return true;
    }

    // /workspaces/:wid/applets/:aid/versions/:v
    const versionMatch = path.match(/^\/workspaces\/([^/]+)\/applets\/([^/]+)\/versions\/(\d+)$/);
    if (versionMatch && method === "GET") {
      handleGetVersion(versionMatch[1], versionMatch[2], parseInt(versionMatch[3], 10), res);
      return true;
    }

    // /workspaces/:wid/applets/:aid/versions
    const versionsMatch = path.match(/^\/workspaces\/([^/]+)\/applets\/([^/]+)\/versions$/);
    if (versionsMatch && method === "GET") {
      handleListVersions(versionsMatch[1], versionsMatch[2], res);
      return true;
    }

    // /workspaces/:wid/applets/:aid
    const appletMatch = path.match(/^\/workspaces\/([^/]+)\/applets\/([^/]+)$/);
    if (appletMatch) {
      const [, wid, aid] = appletMatch;
      if (method === "GET") {
        handleGetApplet(wid, aid, res);
        return true;
      }
      if (method === "PUT") {
        await handleUpdateApplet(wid, aid, req, res);
        return true;
      }
      if (method === "DELETE") {
        handleDeleteApplet(wid, aid, res);
        return true;
      }
    }

    return false;
  };
}

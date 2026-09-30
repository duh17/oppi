import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";
import type { McpAddServerRequest, McpPatchServerRequest } from "../types/mcp.js";
import type { ProviderAuthLaunchMode } from "../provider-auth/types.js";
import { McpError } from "../mcp-config.js";

export function createMcpRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  return async ({ method, path, req, res }) => {
    if (path !== "/mcp" && !path.startsWith("/mcp/")) return false;
    if (!ctx.mcp) {
      helpers.error(res, 503, "MCP management unavailable");
      return true;
    }
    try {
      if (path === "/mcp/servers" && method === "GET") {
        helpers.json(res, await ctx.mcp.list());
        return true;
      }
      if (path === "/mcp/servers" && method === "POST") {
        await ctx.mcp.add(await helpers.parseBody<McpAddServerRequest>(req));
        helpers.json(res, { ok: true }, 201);
        return true;
      }
      const server = path.match(/^\/mcp\/scopes\/([^/]+)\/servers\/([^/]+)(?:\/(login|logout))?$/);
      if (server) {
        const scopeId = decodeURIComponent(server[1]);
        const name = decodeURIComponent(server[2]);
        if (!server[3] && method === "PATCH") {
          await ctx.mcp.patch(scopeId, name, await helpers.parseBody<McpPatchServerRequest>(req));
          helpers.json(res, { ok: true });
          return true;
        }
        if (!server[3] && method === "DELETE") {
          await ctx.mcp.remove(scopeId, name);
          helpers.json(res, { ok: true });
          return true;
        }
        if (server[3] === "login" && method === "POST") {
          const body = await helpers.parseBody<{ launchMode?: ProviderAuthLaunchMode }>(req);
          helpers.json(
            res,
            { flow: await ctx.mcp.login(scopeId, name, body.launchMode ?? "phone_browser") },
            201,
          );
          return true;
        }
        if (server[3] === "logout" && method === "POST") {
          await ctx.mcp.logout(scopeId, name);
          helpers.json(res, { ok: true });
          return true;
        }
      }
      const flow = path.match(/^\/mcp\/auth\/flows\/([^/]+)(?:\/(manual-code|cancel))?$/);
      if (flow) {
        const id = decodeURIComponent(flow[1]);
        if (!flow[2] && method === "GET") {
          helpers.json(res, { flow: ctx.mcp.auth.get(id) });
          return true;
        }
        if (flow[2] === "cancel" && method === "POST") {
          helpers.json(res, { flow: ctx.mcp.auth.cancel(id) });
          return true;
        }
        if (flow[2] === "manual-code" && method === "POST") {
          const body = await helpers.parseBody<{ input?: string }>(req);
          if (typeof body.input !== "string")
            throw new McpError(400, "Paste the full callback URL");
          helpers.json(res, { flow: await ctx.mcp.auth.submit(id, body.input) });
          return true;
        }
      }
      return false;
    } catch (error) {
      if (error instanceof McpError || error instanceof URIError) {
        helpers.error(
          res,
          error instanceof McpError ? error.statusCode : 400,
          error instanceof McpError ? error.message : "Invalid path encoding",
        );
        return true;
      }
      throw error;
    }
  };
}

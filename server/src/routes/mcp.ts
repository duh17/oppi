import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";
import { McpError } from "../mcp-config.js";
import {
  parseMcpAddRequest,
  parseMcpPatchRequest,
  parseMcpLoginRequest,
  parseMcpManualRequest,
  parseMcpEmptyRequest,
} from "../mcp-requests.js";

export function createMcpRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  return async ({ method, path, req, res }) => {
    if (path !== "/mcp" && !path.startsWith("/mcp/")) return false;
    if (!ctx.mcp) {
      helpers.error(res, 503, "MCP management unavailable");
      return true;
    }
    const body = async (): Promise<unknown> => {
      try {
        return await helpers.parseBody<unknown>(req);
      } catch {
        throw new McpError(400, "Invalid JSON request body");
      }
    };
    try {
      const scopeServers = path.match(/^\/mcp\/scopes\/([^/]+)\/servers$/);
      if (scopeServers && method === "GET") {
        helpers.json(res, await ctx.mcp.list(decodeURIComponent(scopeServers[1])));
        return true;
      }
      if (scopeServers && method === "POST") {
        const scopeId = decodeURIComponent(scopeServers[1]);
        await ctx.mcp.add(scopeId, parseMcpAddRequest(await body()));
        helpers.json(res, { ok: true }, 201);
        return true;
      }
      const server = path.match(/^\/mcp\/scopes\/([^/]+)\/servers\/([^/]+)(?:\/(login|logout))?$/);
      if (server) {
        const scopeId = decodeURIComponent(server[1]);
        const name = decodeURIComponent(server[2]);
        if (!server[3] && method === "PATCH") {
          await ctx.mcp.patch(scopeId, name, parseMcpPatchRequest(await body()));
          helpers.json(res, { ok: true });
          return true;
        }
        if (!server[3] && method === "DELETE") {
          parseMcpEmptyRequest(await body());
          await ctx.mcp.remove(scopeId, name);
          helpers.json(res, { ok: true });
          return true;
        }
        if (server[3] === "login" && method === "POST") {
          const mode = parseMcpLoginRequest(await body());
          helpers.json(res, { flow: await ctx.mcp.login(scopeId, name, mode) }, 201);
          return true;
        }
        if (server[3] === "logout" && method === "POST") {
          parseMcpEmptyRequest(await body());
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
          parseMcpEmptyRequest(await body());
          helpers.json(res, { flow: ctx.mcp.auth.cancel(id) });
          return true;
        }
        if (flow[2] === "manual-code" && method === "POST") {
          const input = parseMcpManualRequest(await body());
          helpers.json(res, { flow: await ctx.mcp.auth.submit(id, input) });
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

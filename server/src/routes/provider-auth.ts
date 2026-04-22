import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";
import { ProviderAuthError, type ProviderAuthLaunchMode } from "../provider-auth/types.js";

const LAUNCH_MODES = new Set<ProviderAuthLaunchMode>(["server_browser", "phone_browser", "none"]);

function parseFlowId(path: string): string | null {
  const match = path.match(/^\/provider-auth\/flows\/([^/]+)$/);
  return match ? decodeURIComponent(match[1]) : null;
}

function parseFlowSubresource(path: string, suffix: string): string | null {
  const pattern = new RegExp(`^/provider-auth/flows/([^/]+)/${suffix}$`);
  const match = path.match(pattern);
  return match ? decodeURIComponent(match[1]) : null;
}

function handleProviderAuthError(
  error: unknown,
  helpers: RouteHelpers,
  res: Parameters<RouteDispatcher>[0]["res"],
): boolean {
  if (error instanceof ProviderAuthError) {
    helpers.error(res, error.statusCode, error.message);
    return true;
  }
  return false;
}

export function createProviderAuthRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
): RouteDispatcher {
  return async ({ method, path, req, res }) => {
    if (!path.startsWith("/provider-auth")) {
      return false;
    }

    try {
      if (path === "/provider-auth/providers" && method === "GET") {
        helpers.json(res, { providers: ctx.providerAuth.listProviders() });
        return true;
      }

      if (path === "/provider-auth/status" && method === "GET") {
        helpers.json(res, { providers: ctx.providerAuth.getStatus() });
        return true;
      }

      if (path === "/provider-auth/flows" && method === "POST") {
        const body = await helpers.parseBody<{
          providerId?: string;
          launchMode?: ProviderAuthLaunchMode;
        }>(req);

        const providerId = typeof body.providerId === "string" ? body.providerId : "";
        const launchMode = body.launchMode ?? "server_browser";

        if (!LAUNCH_MODES.has(launchMode)) {
          helpers.error(res, 400, "Invalid launchMode");
          return true;
        }

        const flow = ctx.providerAuth.startFlow(providerId, launchMode);
        helpers.json(res, { flow }, 201);
        return true;
      }

      const flowId = parseFlowId(path);
      if (flowId && method === "GET") {
        const flow = ctx.providerAuth.getFlow(flowId);
        helpers.json(res, { flow });
        return true;
      }

      const promptFlowId = parseFlowSubresource(path, "prompt-response");
      if (promptFlowId && method === "POST") {
        const body = await helpers.parseBody<{ value?: string }>(req);
        const value = typeof body.value === "string" ? body.value : "";
        const flow = ctx.providerAuth.submitPromptResponse(promptFlowId, value);
        helpers.json(res, { flow });
        return true;
      }

      const manualFlowId = parseFlowSubresource(path, "manual-code");
      if (manualFlowId && method === "POST") {
        const body = await helpers.parseBody<{ input?: string }>(req);
        const input = typeof body.input === "string" ? body.input : "";
        const flow = ctx.providerAuth.submitManualCode(manualFlowId, input);
        helpers.json(res, { flow });
        return true;
      }

      const cancelFlowId = parseFlowSubresource(path, "cancel");
      if (cancelFlowId && method === "POST") {
        const body = await helpers.parseBody<{ reason?: string }>(req);
        const reason = typeof body.reason === "string" ? body.reason : undefined;
        const flow = ctx.providerAuth.cancelFlow(cancelFlowId, reason);
        helpers.json(res, { flow });
        return true;
      }

      if (path === "/provider-auth/api-key" && method === "PUT") {
        const body = await helpers.parseBody<{ providerId?: string; key?: string }>(req);
        const providerId = typeof body.providerId === "string" ? body.providerId : "";
        const key = typeof body.key === "string" ? body.key : "";
        await ctx.providerAuth.setApiKey(providerId, key);
        helpers.json(res, { ok: true });
        return true;
      }

      const deleteMatch = path.match(/^\/provider-auth\/([^/]+)$/);
      if (deleteMatch && method === "DELETE") {
        const providerId = decodeURIComponent(deleteMatch[1]);
        await ctx.providerAuth.removeCredential(providerId);
        helpers.json(res, { ok: true });
        return true;
      }

      return false;
    } catch (error) {
      if (handleProviderAuthError(error, helpers, res)) {
        return true;
      }
      throw error;
    }
  };
}

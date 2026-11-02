import type { IncomingMessage, ServerResponse } from "node:http";

import type { RequestPrincipal } from "../request-principal.js";
import { createRouteHelpers } from "./http.js";
import type { RouteContext, RouteDispatcher } from "./types.js";
import { createIdentityRoutes } from "./identity.js";
import { createServerUpdateRoutes } from "./server-update.js";
import { createServerMetricsRoutes } from "./server-metrics.js";
import { createDurableSessionsSettingsRoutes } from "./durable-sessions-settings.js";
import { createDictationDictionaryRoutes } from "./dictation-dictionary.js";
import { createSpeechRoutes } from "./speech.js";
import { createSkillRoutes } from "./skills.js";
import { createWorkspaceRoutes } from "./workspaces.js";
import { createAgentRoutes } from "./agents.js";
import { createControlConversationRoutes } from "./control-conversation.js";
import { createSessionRoutes } from "./sessions.js";
import { createUploadRoutes } from "./uploads.js";
import { createIconAssetRoutes } from "./icon-assets.js";
import { createThemeRoutes } from "./themes.js";
import { createTelemetryRoutes } from "./telemetry.js";
import { createWorkspaceFileRoutes } from "./workspace-files.js";
import { createHostFileRoutes } from "./host-files.js";
import { createProviderAuthRoutes } from "./provider-auth.js";
import { createMcpRoutes } from "./mcp.js";
import { createScheduleRoutes } from "./schedules.js";
import { createE2EUIHarnessRoutes } from "./e2e-ui-harness.js";
import { createServerResourceRoutes } from "./server-resources.js";
import { registeredMethodsForPath } from "./registry.js";

export type { RouteContext } from "./types.js";

export class RouteHandler {
  private dispatchers: RouteDispatcher[];
  private readonly e2eUIHarness: RouteDispatcher;
  private readonly helpers = createRouteHelpers();

  constructor(private readonly ctx: RouteContext) {
    this.dispatchers = [
      createIdentityRoutes(this.ctx, this.helpers),
      createServerUpdateRoutes(this.ctx, this.helpers),
      createServerMetricsRoutes(this.ctx, this.helpers),
      createDurableSessionsSettingsRoutes(this.ctx, this.helpers),
      createDictationDictionaryRoutes(this.ctx, this.helpers),
      createSpeechRoutes(this.ctx, this.helpers),
      createServerResourceRoutes(this.ctx, this.helpers),
      createSkillRoutes(this.ctx, this.helpers),
      createWorkspaceRoutes(this.ctx, this.helpers),
      createAgentRoutes(this.ctx, this.helpers),
      createControlConversationRoutes(this.ctx, this.helpers),
      createIconAssetRoutes(this.ctx, this.helpers),
      createUploadRoutes(this.ctx, this.helpers),
      createSessionRoutes(this.ctx, this.helpers),
      createTelemetryRoutes(this.ctx, this.helpers),
      createThemeRoutes(this.ctx, this.helpers),
      createWorkspaceFileRoutes(this.ctx, this.helpers),
      createHostFileRoutes(this.ctx, this.helpers),
      createProviderAuthRoutes(this.ctx, this.helpers),
      createMcpRoutes(this.ctx, this.helpers),
      createScheduleRoutes(this.ctx, this.helpers),
    ];
    this.e2eUIHarness = createE2EUIHarnessRoutes(this.ctx, this.helpers);
  }

  /**
   * Dispatch an authenticated HTTP request to the appropriate handler.
   * Called by Server after /health and auth checks.
   */
  async dispatch(
    method: string,
    path: string,
    url: URL,
    req: IncomingMessage,
    res: ServerResponse,
    principal?: RequestPrincipal,
  ): Promise<void> {
    const request = { method, path, url, req, res, principal };
    // The UI test fixtures under /e2e/ui/ are not product routes and have no registry rows; the
    // harness answers 404 for them unless OPPI_E2E_UI_HARNESS=1.
    if (await this.e2eUIHarness(request)) return;

    // The registry decides which routes exist: a handler without its row is unreachable.
    const methods = registeredMethodsForPath(path);
    if (!methods) {
      this.helpers.error(res, 404, "Not found");
      return;
    }
    if (!methods.has(method)) {
      res.writeHead(405, { "Content-Type": "application/json", Allow: [...methods].join(", ") });
      res.end(JSON.stringify({ error: "Method not allowed" }));
      return;
    }

    for (const dispatch of this.dispatchers) {
      if (await dispatch(request)) return;
    }

    this.helpers.error(res, 404, "Not found");
  }
}

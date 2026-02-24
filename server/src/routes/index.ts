import type { IncomingMessage, ServerResponse } from "node:http";

import { createRouteHelpers } from "./http.js";
import type { RouteContext, RouteDispatcher } from "./types.js";
import { createIdentityRoutes } from "./identity.js";
import { createSkillRoutes } from "./skills.js";
import { createWorkspaceRoutes } from "./workspaces.js";
import { createSessionRoutes } from "./sessions.js";
import { createStreamingRoutes } from "./streaming.js";
import { createPolicyRoutes } from "./policy.js";
import { createThemeRoutes } from "./themes.js";
import { createTelemetryRoutes } from "./telemetry.js";

export type { RouteContext } from "./types.js";

export class RouteHandler {
  private dispatchers: RouteDispatcher[];
  private readonly helpers = createRouteHelpers();

  constructor(private readonly ctx: RouteContext) {
    this.dispatchers = [
      createStreamingRoutes(this.ctx, this.helpers),
      createPolicyRoutes(this.ctx, this.helpers),
      createIdentityRoutes(this.ctx, this.helpers),
      createSkillRoutes(this.ctx, this.helpers),
      createWorkspaceRoutes(this.ctx, this.helpers),
      createSessionRoutes(this.ctx, this.helpers),
      createTelemetryRoutes(this.ctx, this.helpers),
      createThemeRoutes(this.ctx, this.helpers),
    ];
  }

  /**
   * Dispatch an authenticated HTTP request to the appropriate handler.
   * Called by Server after CORS, OPTIONS, /health, and auth checks.
   */
  async dispatch(
    method: string,
    path: string,
    url: URL,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    for (const dispatch of this.dispatchers) {
      if (await dispatch({ method, path, url, req, res })) {
        return;
      }
    }

    this.helpers.error(res, 404, "Not found");
  }
}

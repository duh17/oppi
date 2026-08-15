import type { IncomingMessage, ServerResponse } from "node:http";

import { createRouteHelpers } from "./http.js";
import type { RouteContext, RouteDispatcher } from "./types.js";
import { createIdentityRoutes } from "./identity.js";
import { createSkillRoutes } from "./skills.js";
import { createWorkspaceRoutes } from "./workspaces.js";
import { createAgentRoutes } from "./agents.js";
import { createSessionRoutes } from "./sessions.js";
import { createUploadRoutes } from "./uploads.js";
import { createIconAssetRoutes } from "./icon-assets.js";
import { createThemeRoutes } from "./themes.js";
import { createTelemetryRoutes } from "./telemetry.js";
import { createWorkspaceFileRoutes } from "./workspace-files.js";
import { createHostFileRoutes } from "./host-files.js";
import { createProviderAuthRoutes } from "./provider-auth.js";
import { createScheduleRoutes } from "./schedules.js";
import { createE2EUIHarnessRoutes } from "./e2e-ui-harness.js";
import { createServerResourceRoutes } from "./server-resources.js";

export type { RouteContext } from "./types.js";

export class RouteHandler {
  private dispatchers: RouteDispatcher[];
  private readonly helpers = createRouteHelpers();

  constructor(private readonly ctx: RouteContext) {
    this.dispatchers = [
      createIdentityRoutes(this.ctx, this.helpers),
      createServerResourceRoutes(this.ctx, this.helpers),
      createSkillRoutes(this.ctx, this.helpers),
      createWorkspaceRoutes(this.ctx, this.helpers),
      createAgentRoutes(this.ctx, this.helpers),
      createIconAssetRoutes(this.ctx, this.helpers),
      createUploadRoutes(this.ctx, this.helpers),
      createSessionRoutes(this.ctx, this.helpers),
      createTelemetryRoutes(this.ctx, this.helpers),
      createThemeRoutes(this.ctx, this.helpers),
      createWorkspaceFileRoutes(this.ctx, this.helpers),
      createHostFileRoutes(this.ctx, this.helpers),
      createProviderAuthRoutes(this.ctx, this.helpers),
      createScheduleRoutes(this.ctx, this.helpers),
      createE2EUIHarnessRoutes(this.ctx, this.helpers),
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

import {
  applySetting,
  parseBaseRevision,
  readConfigSetting,
  revisionConflictBody,
  type RevisionedEnabled,
} from "../settings/config-settings.js";
import { SettingValidationError, validateSetting } from "../settings/registry.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

/**
 * The Durable Sessions switch at `/server/durable-sessions/settings`: `experimental.serverDurable`,
 * saved like every revisioned setting (an optional `baseRevision`, a 409 `revision_conflict` when
 * it is stale). A save applies at once: new creates may ask for `engine: "durable"` and
 * `/server/info` advertises `capabilities.durableSessions` without a restart. `oppi config set`
 * still applies at the next restart, so `enabled` is always what the running server does.
 */
export function createDurableSessionsSettingsRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
): RouteDispatcher {
  const running = (): RevisionedEnabled => ({
    ...readConfigSetting(ctx.storage.getConfig(), "durableSessions"),
    enabled: ctx.sessions.durableSessionsAvailable(),
  });

  return async ({ method, path, req, res }) => {
    if (path !== "/server/durable-sessions/settings") return false;
    if (method === "GET") {
      helpers.json(res, running());
      return true;
    }
    if (method === "PUT") {
      const body = await helpers.parseBody<Record<string, unknown>>(req, { maxBytes: 1024 });
      try {
        const patch = validateSetting("durableSessions", body);
        const result = applySetting(
          ctx.storage,
          "durableSessions",
          patch,
          parseBaseRevision(body.baseRevision),
        );
        if (!result.ok) {
          helpers.json(res, revisionConflictBody("durableSessions", running()), 409);
          return true;
        }
        ctx.sessions.setDurableSessionsAvailable(result.current.enabled);
        helpers.json(res, result.current);
      } catch (cause: unknown) {
        if (!(cause instanceof SettingValidationError)) throw cause;
        helpers.error(res, 400, cause.message);
      }
      return true;
    }
    return false;
  };
}

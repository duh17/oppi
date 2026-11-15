import { serverFeatures } from "../server-features.js";
import { SettingValidationError, validateSetting } from "../settings/registry.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

/**
 * The feature switches at `/server/features`: GET answers every switch, PUT saves the switches it
 * names (last writer wins per switch) and answers every switch. A save applies at once: the next
 * `/server/info` lists it, new sessions follow it, and apps hear `features_changed`.
 */
export function createServerFeaturesRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
): RouteDispatcher {
  return async ({ method, path, req, res }) => {
    if (path !== "/server/features") return false;
    if (method === "GET") {
      helpers.json(res, serverFeatures(ctx.storage.getConfig()));
      return true;
    }
    if (method === "PUT") {
      const body = await helpers.parseBody<unknown>(req, { maxBytes: 4096 });
      try {
        const patch = validateSetting("features", body);
        const before = serverFeatures(ctx.storage.getConfig());
        const config = ctx.storage.mutateConfig((latest) =>
          Object.keys(patch).length > 0 ? { features: { ...latest.features, ...patch } } : {},
        );
        const after = serverFeatures(config);
        if (JSON.stringify(after) !== JSON.stringify(before)) ctx.featuresChanged?.();
        helpers.json(res, after);
      } catch (cause: unknown) {
        if (!(cause instanceof SettingValidationError)) throw cause;
        helpers.error(res, 400, cause.message);
      }
      return true;
    }
    return false;
  };
}

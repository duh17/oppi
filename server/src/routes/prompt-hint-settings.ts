import {
  applySetting,
  parseBaseRevision,
  readConfigSetting,
  revisionConflictBody,
} from "../settings/config-settings.js";
import { SettingValidationError, validateSetting } from "../settings/registry.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

/** Each prompt hint's route, by the config.json block that stores it. */
const PROMPT_HINT_ROUTES = {
  "/server/oppi-docs-prompt": "oppiDocsPrompt",
  "/server/oppi-cli-prompt": "oppiCliPrompt",
} as const;

/**
 * The prompt hint switches, `oppiDocsPrompt` and `oppiCliPrompt`, saved like every revisioned
 * setting (an optional `baseRevision`, a 409 `revision_conflict` when it is stale). Sessions read
 * them at each build, so a save applies to new sessions and to sessions that reload.
 */
export function createPromptHintSettingsRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
): RouteDispatcher {
  return async ({ method, path, req, res }) => {
    if (!Object.hasOwn(PROMPT_HINT_ROUTES, path)) return false;
    const key = PROMPT_HINT_ROUTES[path as keyof typeof PROMPT_HINT_ROUTES];
    if (method === "GET") {
      helpers.json(res, readConfigSetting(ctx.storage.getConfig(), key));
      return true;
    }
    if (method === "PUT") {
      const body = await helpers.parseBody<Record<string, unknown>>(req, { maxBytes: 1024 });
      try {
        const patch = validateSetting(key, body);
        const result = applySetting(ctx.storage, key, patch, parseBaseRevision(body.baseRevision));
        if (!result.ok) {
          helpers.json(res, revisionConflictBody(key, result.current), 409);
          return true;
        }
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

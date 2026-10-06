import {
  ControlConversationError,
  ControlConversationService,
} from "../control-conversation-service.js";
import { safeErrorMessage } from "../log-utils.js";
import { SessionLifecycleError, SessionLifecycleService } from "../session-lifecycle-service.js";
import { isThinkingLevel } from "../thinking-levels.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

/**
 * `POST /control-conversation`: find-or-create the data directory's one control
 * conversation (owner only). Body `{ model?, thinking? }` applies on create only.
 */
export function createControlConversationRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
): RouteDispatcher {
  // One service per server: its queue is what serializes concurrent first calls.
  const service = new ControlConversationService({
    storage: ctx.storage,
    lifecycle: new SessionLifecycleService({
      storage: ctx.storage,
      sessions: ctx.sessions,
      sessionRuntimes: ctx.sessionRuntimes,
      ensureSessionContextWindow: ctx.ensureSessionContextWindow,
      deleteSearchIndexSession: (sessionId) => ctx.searchIndex?.deleteSession(sessionId),
    }),
  });

  return async ({ method, path, req, res }) => {
    if (path !== "/control-conversation" || method !== "POST") return false;
    const body = await helpers.parseBody<{ model?: unknown; thinking?: unknown }>(req);
    if (
      (body.model !== undefined && (typeof body.model !== "string" || !body.model.trim())) ||
      (body.thinking !== undefined &&
        (typeof body.thinking !== "string" || !isThinkingLevel(body.thinking)))
    ) {
      helpers.error(res, 400, "Invalid control conversation options");
      return true;
    }
    try {
      const { session, created } = await service.open({
        ...(typeof body.model === "string" ? { model: body.model.trim() } : {}),
        ...(typeof body.thinking === "string" ? { thinking: body.thinking } : {}),
      });
      helpers.json(res, { session }, created ? 201 : 200);
    } catch (error: unknown) {
      const status =
        error instanceof ControlConversationError || error instanceof SessionLifecycleError
          ? error.statusCode
          : 500;
      helpers.error(res, status, safeErrorMessage(error));
    }
    return true;
  };
}

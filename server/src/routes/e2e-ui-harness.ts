import type { IncomingMessage, ServerResponse } from "node:http";

import type { AskQuestion, ServerMessage } from "../types.js";
import type { RouteDispatcher, RouteHelpers, RouteContext } from "./types.js";

const MAX_E2E_UI_MESSAGE_BYTES = 32 * 1024;

export function createE2EUIHarnessRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
): RouteDispatcher {
  return async ({ method, path, req, res }) => {
    if (!path.startsWith("/e2e/ui/")) {
      return false;
    }

    if (process.env.OPPI_E2E_UI_HARNESS !== "1") {
      helpers.error(res, 404, "Not found");
      return true;
    }

    const match = path.match(/^\/e2e\/ui\/sessions\/([^/]+)\/message$/);
    if (!match) {
      helpers.error(res, 404, "Not found");
      return true;
    }

    if (method !== "POST") {
      helpers.error(res, 405, "Method not allowed");
      return true;
    }

    await handleHarnessMessage(ctx, helpers, decodeURIComponent(match[1]), req, res);
    return true;
  };
}

async function handleHarnessMessage(
  ctx: RouteContext,
  helpers: RouteHelpers,
  sessionId: string,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const session = ctx.storage.getSession(sessionId) ?? ctx.sessions.getActiveSession(sessionId);
  if (!session) {
    helpers.error(res, 404, "Session not found");
    return;
  }

  if (!ctx.sessions.isActive(sessionId)) {
    helpers.error(res, 409, "Session is not active");
    return;
  }

  const body = await helpers.parseBody<Record<string, unknown>>(req, {
    maxBytes: MAX_E2E_UI_MESSAGE_BYTES,
  });
  const message = normalizeHarnessMessage(sessionId, body);
  if (!message) {
    helpers.error(res, 400, "Unsupported E2E UI harness message");
    return;
  }

  const subscriberCount = ctx.sessions.broadcastSessionMessage(sessionId, message);
  helpers.json(res, { ok: true, subscriberCount, message });
}

function normalizeHarnessMessage(
  sessionId: string,
  body: Record<string, unknown>,
): ServerMessage | null {
  switch (body.type) {
    case "extension_ui_request":
      return normalizeExtensionUIRequest(sessionId, body);
    case "extension_ui_notification":
      return normalizeExtensionUINotification(body);
    case "extension_ui_settled":
      return normalizeExtensionUISettled(sessionId, body);
    default:
      return null;
  }
}

function normalizeExtensionUIRequest(
  sessionId: string,
  body: Record<string, unknown>,
): ServerMessage | null {
  const id = stringField(body.id);
  const method = stringField(body.method);
  if (!id || !method) return null;

  return {
    type: "extension_ui_request",
    id,
    sessionId,
    method,
    title: stringField(body.title),
    options: stringArrayField(body.options),
    message: stringField(body.message),
    placeholder: stringField(body.placeholder),
    prefill: stringField(body.prefill),
    timeout: numberField(body.timeout),
    timeoutAt: numberField(body.timeoutAt),
    questions: askQuestionsField(body.questions),
    allowCustom: booleanField(body.allowCustom),
  };
}

function normalizeExtensionUINotification(body: Record<string, unknown>): ServerMessage | null {
  const method = stringField(body.method);
  if (!method) return null;

  return {
    type: "extension_ui_notification",
    method,
    message: stringField(body.message),
    notifyType: stringField(body.notifyType),
    statusKey: stringField(body.statusKey),
    statusText: stringField(body.statusText),
    title: stringField(body.title),
    text: stringField(body.text),
    widgetKey: stringField(body.widgetKey),
    widgetLines: stringArrayField(body.widgetLines),
    widgetPlacement: stringField(body.widgetPlacement),
  };
}

function normalizeExtensionUISettled(
  sessionId: string,
  body: Record<string, unknown>,
): ServerMessage | null {
  const id = stringField(body.id);
  if (!id) return null;

  return {
    type: "extension_ui_settled",
    id,
    sessionId,
  };
}

function stringField(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function numberField(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function booleanField(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

function askQuestionsField(value: unknown): AskQuestion[] | undefined {
  return Array.isArray(value) ? (value as AskQuestion[]) : undefined;
}

function stringArrayField(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  return value.filter((item): item is string => typeof item === "string");
}

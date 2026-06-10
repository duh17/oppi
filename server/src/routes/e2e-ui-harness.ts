import type { IncomingMessage, ServerResponse } from "node:http";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

import {
  clearRecordedE2EUIResponses,
  getRecordedE2EUIResponses,
  recordSyntheticE2EUIRequest,
} from "../e2e-ui-harness-state.js";
import {
  buildExtensionUINotificationMessage,
  buildExtensionUIRequestMessage,
  normalizeExtensionUIWidgetNativeSurface,
} from "../extension-ui-contract.js";
import type { AskQuestion, ServerMessage } from "../types.js";
import type { RouteDispatcher, RouteHelpers, RouteContext } from "./types.js";

const MAX_E2E_UI_MESSAGE_BYTES = 32 * 1024;
const MAX_E2E_FIXTURE_FILE_BYTES = 5 * 1024 * 1024;
const MAX_E2E_FIXTURE_BODY_BYTES = 8 * 1024 * 1024;

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

    const fixtureMatch = path.match(/^\/e2e\/ui\/fixtures\/workspace-file$/);
    if (fixtureMatch) {
      if (method !== "POST") {
        helpers.error(res, 405, "Method not allowed");
        return true;
      }
      await handleWorkspaceFileFixture(ctx, helpers, req, res);
      return true;
    }

    const responseMatch = path.match(/^\/e2e\/ui\/sessions\/([^/]+)\/responses$/);
    if (responseMatch) {
      handleHarnessResponses(helpers, decodeURIComponent(responseMatch[1]), method, res);
      return true;
    }

    const messageMatch = path.match(/^\/e2e\/ui\/sessions\/([^/]+)\/message$/);
    if (!messageMatch) {
      helpers.error(res, 404, "Not found");
      return true;
    }

    if (method !== "POST") {
      helpers.error(res, 405, "Method not allowed");
      return true;
    }

    await handleHarnessMessage(ctx, helpers, decodeURIComponent(messageMatch[1]), req, res);
    return true;
  };
}

async function handleWorkspaceFileFixture(
  ctx: RouteContext,
  helpers: RouteHelpers,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = await helpers.parseBody<Record<string, unknown>>(req, {
    maxBytes: MAX_E2E_FIXTURE_BODY_BYTES,
  });
  const directoryName = safePathSegment(stringField(body.directoryName));
  const filename = safePathSegment(stringField(body.filename));
  const rawBase64 = stringField(body.base64);

  if (!directoryName || !filename || !rawBase64) {
    helpers.error(res, 400, "Fixture requires directoryName, filename, and base64");
    return;
  }

  const compactBase64 = rawBase64.replace(/\s/g, "");
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(compactBase64)) {
    helpers.error(res, 400, "Fixture base64 is invalid");
    return;
  }

  const bytes = Buffer.from(compactBase64, "base64");
  if (bytes.length === 0 || bytes.length > MAX_E2E_FIXTURE_FILE_BYTES) {
    helpers.error(res, 400, "Fixture file size is invalid");
    return;
  }

  const root = join(ctx.storage.getDataDir(), "e2e-fixtures");
  const hostMount = join(root, directoryName);
  const filePath = join(hostMount, filename);
  await mkdir(hostMount, { recursive: true, mode: 0o700 });
  await writeFile(filePath, bytes, { mode: 0o600 });
  helpers.json(res, { ok: true, hostMount, filePath, filename });
}

function safePathSegment(value: string | undefined): string | null {
  if (!value || value === "." || value === ".." || value.includes("\0")) return null;
  if (!/^[A-Za-z0-9._-]+$/.test(value)) return null;
  return value;
}

function handleHarnessResponses(
  helpers: RouteHelpers,
  sessionId: string,
  method: string,
  res: ServerResponse,
): void {
  if (method === "GET") {
    helpers.json(res, { ok: true, responses: getRecordedE2EUIResponses(sessionId) });
    return;
  }

  if (method === "DELETE") {
    clearRecordedE2EUIResponses(sessionId);
    helpers.json(res, { ok: true });
    return;
  }

  helpers.error(res, 405, "Method not allowed");
}

async function handleHarnessMessage(
  ctx: RouteContext,
  helpers: RouteHelpers,
  sessionId: string,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const session = ctx.sessionRuntimes.getSessionSnapshot(sessionId);
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

  if (message.type === "extension_ui_request") {
    recordSyntheticE2EUIRequest(sessionId, message.id);
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
    case "session_ended":
      return normalizeSessionEnded(body);
    case "agent_start":
      return { type: "agent_start" };
    case "agent_end":
      return { type: "agent_end" };
    case "thinking_delta":
      return normalizeThinkingDelta(body);
    case "tool_start":
      return normalizeToolStart(body);
    case "tool_output":
      return normalizeToolOutput(body);
    case "tool_end":
      return normalizeToolEnd(body);
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

  return buildExtensionUIRequestMessage(sessionId, {
    id,
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
  });
}

function normalizeExtensionUINotification(body: Record<string, unknown>): ServerMessage | null {
  const method = stringField(body.method);
  if (!method) return null;
  const widgetKey = stringField(body.widgetKey);
  const hasNativeSurface = Object.hasOwn(body, "nativeSurface");
  const nativeSurface = hasNativeSurface
    ? normalizeExtensionUIWidgetNativeSurface(body.nativeSurface, widgetKey, {
        maxBytes: MAX_E2E_UI_MESSAGE_BYTES,
      })
    : undefined;

  if (hasNativeSurface && (!nativeSurface || method !== "setWidget")) {
    return null;
  }

  return buildExtensionUINotificationMessage({
    id: stringField(body.id) ?? "e2e-ui-notification",
    method,
    message: stringField(body.message),
    notifyType: stringField(body.notifyType),
    statusKey: stringField(body.statusKey),
    statusText: stringField(body.statusText),
    title: stringField(body.title),
    text: stringField(body.text),
    widgetKey,
    widgetLines: stringArrayField(body.widgetLines),
    widgetPlacement: stringField(body.widgetPlacement),
    workingIndicator: recordField(body.workingIndicator),
    workingVisible: booleanField(body.workingVisible),
    hiddenThinkingLabel: stringField(body.hiddenThinkingLabel),
    toolsExpanded: booleanField(body.toolsExpanded),
    nativeSurface,
  });
}

function normalizeThinkingDelta(body: Record<string, unknown>): ServerMessage {
  return {
    type: "thinking_delta",
    delta: stringField(body.delta) ?? "",
    contentIndex: numberField(body.contentIndex),
  };
}

function normalizeToolStart(body: Record<string, unknown>): ServerMessage | null {
  const tool = stringField(body.tool);
  if (!tool) return null;
  return {
    type: "tool_start",
    tool,
    args: recordField(body.args) ?? {},
    toolCallId: stringField(body.toolCallId),
  };
}

function normalizeToolOutput(body: Record<string, unknown>): ServerMessage | null {
  const output = stringField(body.output);
  if (output === undefined) return null;
  const mode = stringField(body.mode);
  return {
    type: "tool_output",
    output,
    isError: booleanField(body.isError),
    toolCallId: stringField(body.toolCallId),
    mode: mode === "replace" ? "replace" : mode === "append" ? "append" : undefined,
    truncated: booleanField(body.truncated),
    totalBytes: numberField(body.totalBytes),
    details: recordField(body.details),
  };
}

function normalizeToolEnd(body: Record<string, unknown>): ServerMessage | null {
  const tool = stringField(body.tool);
  if (!tool) return null;
  return {
    type: "tool_end",
    tool,
    toolCallId: stringField(body.toolCallId),
    details: recordField(body.details),
    isError: booleanField(body.isError),
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

function normalizeSessionEnded(body: Record<string, unknown>): ServerMessage {
  return {
    type: "session_ended",
    reason: stringField(body.reason) ?? "e2e_ui_harness",
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

function recordField(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function askQuestionsField(value: unknown): AskQuestion[] | undefined {
  return Array.isArray(value) ? (value as AskQuestion[]) : undefined;
}

function stringArrayField(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  return value.filter((item): item is string => typeof item === "string");
}

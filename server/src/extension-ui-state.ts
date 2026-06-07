import {
  buildExtensionUINotificationMessage,
  buildExtensionUIRequestMessage,
  buildExtensionUISettledMessage,
  type ExtensionUIResponsePayload,
  isExtensionUIFireAndForgetMethod,
} from "./extension-ui-contract.js";
import type { ExtensionUIRequestEvent } from "./pi-events.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import type { ServerMessage, Session } from "./types.js";

/** Extension UI request from pi SDK or pi-tui mirror bridge. */
export type ExtensionUIRequest = ExtensionUIRequestEvent;

/** Server-side state for a pending first-class ask request. */
export interface PendingAskState {
  requestId: string;
  questionCount: number;
  /** Timestamp when the ask flow was initiated for round-trip timing. */
  initiatedAt: number;
}

export interface ExtensionUIState {
  session: Pick<Session, "id">;
  pendingUIRequests: Map<string, ExtensionUIRequest>;
  /** Last persistent extension UI surfaces/status/title, replayed to late focused clients. */
  persistentExtensionUINotifications?: Map<string, ExtensionUIRequest>;
  /** Pending first-class ask request awaiting a user response. */
  pendingAsk?: PendingAskState;
}

/** Extension UI response sent to pi. */
export interface ExtensionUIResponse extends ExtensionUIResponsePayload {
  type: "extension_ui_response";
}

export function respondToExtensionUIRequest(
  active: ExtensionUIState | undefined,
  response: ExtensionUIResponse,
  options: {
    deliver: (response: ExtensionUIResponse, request: ExtensionUIRequest) => boolean;
    metrics?: ServerMetricCollector;
    now?: () => number;
    broadcastSettled?: (message: ServerMessage) => void;
  },
): boolean {
  const req = active?.pendingUIRequests.get(response.id);
  if (!active || !req) {
    return false;
  }

  if (!options.deliver(response, req)) {
    return false;
  }

  settleExtensionUIRequest(active, response.id, {
    cancelled: !!response.cancelled,
    metrics: options.metrics,
    now: options.now,
    broadcastSettled: options.broadcastSettled,
  });
  return true;
}

const TERMINAL_ONLY_STATUS_KEYS = new Set(["oppi-mirror"]);

function terminalOnlyStatusText(req: ExtensionUIRequest): string | undefined {
  if (req.method === "setStatus" && req.statusKey && TERMINAL_ONLY_STATUS_KEYS.has(req.statusKey)) {
    return undefined;
  }
  return req.statusText;
}

function notificationReplayKey(req: ExtensionUIRequest): string | undefined {
  switch (req.method) {
    case "setStatus":
      return req.statusKey && !TERMINAL_ONLY_STATUS_KEYS.has(req.statusKey)
        ? `status:${req.statusKey}`
        : undefined;
    case "setWidget":
      return req.widgetKey ? `widget:${req.widgetKey}` : undefined;
    case "setTitle":
      return "title";
    case "setWorkingMessage":
      return "working:message";
    case "setWorkingVisible":
      return "working:visible";
    case "setWorkingIndicator":
      return "working:indicator";
    case "setHiddenThinkingLabel":
      return "thinking:hidden-label";
    case "setToolsExpanded":
      return "tools:expanded";
    default:
      return undefined;
  }
}

function widgetLinesHaveContent(lines: string[] | undefined): boolean {
  return lines?.some((line) => line.replace(/[\r\n]/g, "").length > 0) ?? false;
}

function hasPersistentNotificationContent(req: ExtensionUIRequest): boolean {
  switch (req.method) {
    case "setStatus":
      return (req.statusText?.trim().length ?? 0) > 0;
    case "setWidget":
      return req.nativeSurface !== undefined || widgetLinesHaveContent(req.widgetLines);
    case "setTitle":
      return (req.title?.trim().length ?? 0) > 0;
    case "setWorkingMessage":
      return (req.message?.trim().length ?? 0) > 0;
    case "setWorkingVisible":
      return typeof req.workingVisible === "boolean";
    case "setWorkingIndicator":
      return req.workingIndicator !== undefined;
    case "setHiddenThinkingLabel":
      return (req.hiddenThinkingLabel?.trim().length ?? 0) > 0;
    case "setToolsExpanded":
      return typeof req.toolsExpanded === "boolean";
    default:
      return false;
  }
}

function normalizeFireAndForgetNotificationRequest(req: ExtensionUIRequest): ExtensionUIRequest {
  if (req.method === "setStatus") {
    return { ...req, statusText: terminalOnlyStatusText(req) };
  }
  return req;
}

export function updatePersistentExtensionUINotifications(
  active: Pick<ExtensionUIState, "persistentExtensionUINotifications">,
  req: ExtensionUIRequest,
): void {
  const key = notificationReplayKey(req);
  if (!key) {
    return;
  }

  const store = (active.persistentExtensionUINotifications ??= new Map());
  if (hasPersistentNotificationContent(req)) {
    store.set(key, req);
    return;
  }

  const clearReq = buildPersistentExtensionUIClearRequest(req);
  if (clearReq) {
    store.set(key, clearReq);
  } else {
    store.delete(key);
  }
}

export function buildPersistentExtensionUINotificationMessages(
  active: Pick<ExtensionUIState, "persistentExtensionUINotifications">,
): ServerMessage[] {
  return Array.from(active.persistentExtensionUINotifications?.values() ?? []).map((req) =>
    buildExtensionUINotificationMessage(req),
  );
}

function buildPersistentExtensionUIClearRequest(
  req: ExtensionUIRequest,
): ExtensionUIRequest | undefined {
  switch (req.method) {
    case "setStatus":
      return req.statusKey
        ? {
            type: "extension_ui_request",
            id: req.id,
            method: "setStatus",
            statusKey: req.statusKey,
          }
        : undefined;
    case "setWidget":
      return req.widgetKey
        ? {
            type: "extension_ui_request",
            id: req.id,
            method: "setWidget",
            widgetKey: req.widgetKey,
          }
        : undefined;
    case "setTitle":
      return { type: "extension_ui_request", id: req.id, method: "setTitle" };
    case "setWorkingMessage":
      return { type: "extension_ui_request", id: req.id, method: "setWorkingMessage" };
    case "setWorkingVisible":
      return {
        type: "extension_ui_request",
        id: req.id,
        method: "setWorkingVisible",
        workingVisible: true,
      };
    case "setWorkingIndicator":
      return { type: "extension_ui_request", id: req.id, method: "setWorkingIndicator" };
    case "setHiddenThinkingLabel":
      return { type: "extension_ui_request", id: req.id, method: "setHiddenThinkingLabel" };
    case "setToolsExpanded":
      return {
        type: "extension_ui_request",
        id: req.id,
        method: "setToolsExpanded",
        toolsExpanded: false,
      };
    default:
      return undefined;
  }
}

export function drainPersistentExtensionUIClearMessages(
  active: Pick<ExtensionUIState, "persistentExtensionUINotifications">,
): ServerMessage[] {
  const store = active.persistentExtensionUINotifications;
  if (!store?.size) {
    return [];
  }

  const messages: ServerMessage[] = [];
  for (const req of store.values()) {
    const clearReq = buildPersistentExtensionUIClearRequest(req);
    if (clearReq) {
      messages.push(buildExtensionUINotificationMessage(clearReq));
    }
  }
  store.clear();
  return messages;
}

export function handleExtensionUIRequest(
  active: ExtensionUIState,
  req: ExtensionUIRequest,
  deps: {
    broadcast: (message: ServerMessage) => void;
    now?: () => number;
  },
): void {
  if (isExtensionUIFireAndForgetMethod(req.method)) {
    const notificationReq = normalizeFireAndForgetNotificationRequest(req);
    updatePersistentExtensionUINotifications(active, notificationReq);
    deps.broadcast(buildExtensionUINotificationMessage(notificationReq));
    return;
  }

  const broadcastMessage = buildExtensionUIRequestMessage(active.session.id, req);
  active.pendingUIRequests.set(req.id, req);

  if (req.method === "ask") {
    active.pendingAsk = {
      requestId: req.id,
      questionCount: req.questions?.length ?? 0,
      initiatedAt: deps.now?.() ?? Date.now(),
    };
  }

  deps.broadcast(broadcastMessage);
}

function completeAskRequest(
  active: Pick<ExtensionUIState, "pendingAsk" | "session">,
  options: {
    cancelled: boolean;
    metrics?: ServerMetricCollector;
    now?: () => number;
  },
): void {
  const ask = active.pendingAsk;
  if (!ask) {
    return;
  }

  const metrics = options.metrics;
  if (metrics && ask.initiatedAt) {
    metrics.record("server.ask_round_trip_ms", (options.now?.() ?? Date.now()) - ask.initiatedAt, {
      sessionId: active.session.id,
      cancelled: options.cancelled ? "true" : "false",
      questionCount: String(ask.questionCount),
    });
  }

  active.pendingAsk = undefined;
}

export function settleExtensionUIRequest(
  active: ExtensionUIState,
  requestId: string,
  options: {
    cancelled?: boolean;
    metrics?: ServerMetricCollector;
    now?: () => number;
    broadcastSettled?: (message: ServerMessage) => void;
    broadcastIfMissing?: boolean;
  } = {},
): boolean {
  const req = active.pendingUIRequests.get(requestId);
  if (!req) {
    if (options.broadcastIfMissing) {
      options.broadcastSettled?.(buildExtensionUISettledMessage(active.session.id, requestId));
    }
    return false;
  }

  active.pendingUIRequests.delete(requestId);
  if (req.method === "ask" || active.pendingAsk?.requestId === requestId) {
    completeAskRequest(active, {
      cancelled: options.cancelled ?? false,
      metrics: options.metrics,
      now: options.now,
    });
  }

  options.broadcastSettled?.(buildExtensionUISettledMessage(active.session.id, requestId));
  return true;
}

export function settleAllExtensionUIRequests(
  active: ExtensionUIState,
  options: {
    cancelled?: boolean;
    metrics?: ServerMetricCollector;
    now?: () => number;
    broadcastSettled?: (message: ServerMessage) => void;
  } = {},
): void {
  for (const requestId of Array.from(active.pendingUIRequests.keys())) {
    settleExtensionUIRequest(active, requestId, options);
  }
}

export function clearExtensionUIState(
  active: Pick<
    ExtensionUIState,
    "pendingUIRequests" | "persistentExtensionUINotifications" | "pendingAsk"
  >,
): void {
  active.pendingUIRequests.clear();
  active.persistentExtensionUINotifications?.clear();
  active.pendingAsk = undefined;
}

export function drainExtensionUITeardownMessages(
  active: ExtensionUIState,
  options: {
    cancelled?: boolean;
    metrics?: ServerMetricCollector;
    now?: () => number;
  } = {},
): ServerMessage[] {
  const messages: ServerMessage[] = [];
  settleAllExtensionUIRequests(active, {
    ...options,
    broadcastSettled: (message) => messages.push(message),
  });
  messages.push(...drainPersistentExtensionUIClearMessages(active));
  return messages;
}

export function buildPendingExtensionUIRequestMessages(
  active: ExtensionUIState | undefined,
): ServerMessage[] {
  if (!active) {
    return [];
  }

  const messages: ServerMessage[] = buildPersistentExtensionUINotificationMessages(active);
  for (const req of active.pendingUIRequests.values()) {
    messages.push(buildExtensionUIRequestMessage(active.session.id, req));
  }
  return messages;
}

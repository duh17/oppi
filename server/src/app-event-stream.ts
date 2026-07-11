import { WebSocket, type RawData } from "ws";

import type { SessionBroadcastEvent } from "./session-broadcast.js";
import {
  pendingBlockingUIRequestCount,
  type PendingUIRequestProvider,
} from "./session-attention.js";
import { buildSessionSummary, sessionSummaryFingerprint } from "./session-summary.js";
import { startServerPing } from "./stream.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import type { Storage } from "./storage.js";
import type {
  AppEventMessage,
  AppEventSessionLifecycleType,
  ServerMessage,
  Session,
  SessionSummary,
} from "./types.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";

const APP_EVENT_STREAM_PATH = "/app/events/stream";
const APP_EVENT_STREAM_PATH_TAG = "app_event_stream";
const PING_INTERVAL_MS = 30_000;
const MAX_SESSION_ERROR_MESSAGE_LENGTH = 1_000;

export const APP_EVENT_ALLOWED_TYPES = [
  "session_created",
  "session_imported",
  "session_discovered",
  "session_summary",
  "session_deleted",
  "session_ended",
  "stop_requested",
  "stop_confirmed",
  "stop_failed",
  "session_error",
  "extension_ui_request",
  "extension_ui_settled",
  "extension_ui_notification",
  "workspace_git_changed",
] as const satisfies readonly AppEventMessage["type"][];

export const APP_EVENT_CONNECTION_TYPES = [
  "app_events_connected",
] as const satisfies readonly AppEventMessage["type"][];

export const APP_EVENT_FORBIDDEN_SERVER_MESSAGE_TYPES = [
  "state",
  "connected",
  "stream_connected",
  "agent_start",
  "agent_end",
  "agent_settled",
  "text_delta",
  "thinking_delta",
  "message_end",
  "tool_start",
  "tool_update",
  "tool_output",
  "tool_end",
  "command_result",
  "turn_ack",
  "queue_state",
  "queue_item_started",
  "audio_stream",
  "dictation_ready",
  "dictation_result",
  "dictation_final",
  "dictation_error",
  "error",
  "git_status",
] as const satisfies readonly ServerMessage["type"][];

const appEventAllowedTypeSet = new Set<string>([
  ...APP_EVENT_CONNECTION_TYPES,
  ...APP_EVENT_ALLOWED_TYPES,
]);

export function isAppEventAllowedType(type: string): type is AppEventMessage["type"] {
  return appEventAllowedTypeSet.has(type);
}

export interface AppEventSessionRuntimeProvider extends PendingUIRequestProvider {
  getSessionSnapshot?: (sessionId: string) => Session | undefined;
}

export interface AppEventStreamContext {
  storage: Pick<Storage, "getSession">;
  sessionRuntimes: AppEventSessionRuntimeProvider;
  ensureSessionContextWindow: (session: Session) => Session;
  trackConnection: (ws: WebSocket) => void;
  untrackConnection: (ws: WebSocket) => void;
  metrics?: ServerMetricCollector;
  now?: () => number;
}

export interface AppEventEmitter {
  emitSessionCreated(session: Session): void;
  emitSessionImported(session: Session): void;
  emitSessionDiscovered(session: Session): void;
  emitSessionDeleted(session: Session): void;
  emitSessionSummary(session: Session): void;
  emitSessionSummaryById(sessionId: string): void;
  emitStopConfirmed(session: Session, source?: string, reason?: string): void;
  handleSessionBroadcastEvent(payload: SessionBroadcastEvent): void;
}

const log = createLogger({ base: { component: "app_event_stream" } });

function toBuffer(data: RawData): Buffer {
  if (Buffer.isBuffer(data)) return data;
  if (Array.isArray(data)) return Buffer.concat(data);
  return Buffer.from(data);
}

function embeddedSessionId(event: ServerMessage, fallback: string): string {
  return typeof event.sessionId === "string" && event.sessionId.length > 0
    ? event.sessionId
    : fallback;
}

function sanitizeSessionErrorMessage(message: string): string {
  const normalized = Array.from(message)
    .filter((char) => {
      const code = char.charCodeAt(0);
      return code > 0x1f && code !== 0x7f;
    })
    .join("")
    .trim();
  if (normalized.length <= MAX_SESSION_ERROR_MESSAGE_LENGTH) {
    return normalized || "Session error";
  }
  return `${normalized.slice(0, MAX_SESSION_ERROR_MESSAGE_LENGTH)}…`;
}

function notificationCoalescingKey(
  message: Extract<AppEventMessage, { type: "extension_ui_notification" }>,
): string | undefined {
  if (message.statusKey) {
    return `${message.sessionId}:${message.method}:status:${message.statusKey}`;
  }
  if (message.widgetKey) {
    return `${message.sessionId}:${message.method}:widget:${message.widgetKey}`;
  }
  switch (message.method) {
    case "setTitle":
      return `${message.sessionId}:${message.method}:title`;
    case "setWorkingMessage":
      return `${message.sessionId}:${message.method}:working-message`;
    case "setWorkingVisible":
      return `${message.sessionId}:${message.method}:working-visible`;
    case "setWorkingIndicator":
      return `${message.sessionId}:${message.method}:working-indicator`;
    case "setHiddenThinkingLabel":
      return `${message.sessionId}:${message.method}:hidden-thinking-label`;
    case "setToolsExpanded":
      return `${message.sessionId}:${message.method}:tools-expanded`;
    default:
      return undefined;
  }
}

export class AppEventStreamMux implements AppEventEmitter {
  private connectionSeq = 0;
  private subscribers = new Set<(message: AppEventMessage) => void>();
  private lastSummaryFingerprintBySession = new Map<string, string>();
  private lastNotificationFingerprintByKey = new Map<string, string>();

  constructor(private readonly ctx: AppEventStreamContext) {}

  private nextConnId(): string {
    this.connectionSeq += 1;
    return `app_event_stream_${this.connectionSeq}`;
  }

  handleWebSocket(ws: WebSocket, upgradeReceivedAt?: number): void {
    const connectedAt = this.now();
    const metrics = this.ctx.metrics;
    const connId = this.nextConnId();

    if (upgradeReceivedAt && metrics) {
      metrics.record("server.ws_handshake_ms", connectedAt - upgradeReceivedAt, {
        path: APP_EVENT_STREAM_PATH_TAG,
      });
    }

    log.info("ws.app_event_stream_connected", { connId, path: APP_EVENT_STREAM_PATH });

    this.ctx.trackConnection(ws);
    const stopPing = startServerPing(ws, APP_EVENT_STREAM_PATH, PING_INTERVAL_MS, metrics, connId);

    let msgSent = 0;
    let msgRecv = 0;
    let connectionClosed = false;

    const send = (message: AppEventMessage): boolean => {
      if (ws.readyState !== WebSocket.OPEN) {
        return false;
      }
      msgSent += 1;
      ws.send(JSON.stringify(message));
      metrics?.record("server.ws_message_sent", 1, {
        type: message.type,
        level: "app_event",
        path: APP_EVENT_STREAM_PATH_TAG,
      });
      return true;
    };

    const subscriber = (message: AppEventMessage): void => {
      send(message);
    };
    this.subscribers.add(subscriber);

    const cleanup = (code: number, reason?: Buffer): void => {
      if (connectionClosed) return;
      connectionClosed = true;
      this.subscribers.delete(subscriber);
      stopPing();
      this.ctx.untrackConnection(ws);
      metrics?.record("server.ws_session_duration_ms", this.now() - connectedAt, {
        path: APP_EVENT_STREAM_PATH_TAG,
      });
      metrics?.record("server.ws_messages_sent", msgSent, { path: APP_EVENT_STREAM_PATH_TAG });
      metrics?.record("server.ws_messages_received", msgRecv, { path: APP_EVENT_STREAM_PATH_TAG });
      metrics?.record("server.ws_close_code", 1, {
        code: String(code),
        path: APP_EVENT_STREAM_PATH_TAG,
      });
      log.info("ws.app_event_stream_disconnected", {
        connId,
        code,
        reason: reason?.toString() || undefined,
        sent: msgSent,
        recv: msgRecv,
        durationMs: this.now() - connectedAt,
      });
    };

    ws.on("message", (data, isBinary) => {
      msgRecv += 1;
      if (isBinary) {
        metrics?.record("server.ws_message_received", 1, {
          type: "binary",
          path: APP_EVENT_STREAM_PATH_TAG,
        });
        metrics?.record("server.ws_binary_received_bytes", toBuffer(data).byteLength, {
          path: APP_EVENT_STREAM_PATH_TAG,
        });
        return;
      }
      metrics?.record("server.ws_message_received", 1, {
        type: "client_frame_ignored",
        path: APP_EVENT_STREAM_PATH_TAG,
      });
    });

    ws.on("close", cleanup);
    ws.on("error", (err) => {
      log.warn("ws.app_event_stream_error", {
        connId,
        error: safeErrorMessage(err),
      });
    });

    send({
      type: "app_events_connected",
      serverTime: this.now(),
      snapshotRequired: true,
    });
  }

  emitSessionCreated(session: Session): void {
    this.emitSessionLifecycle("session_created", session);
  }

  emitSessionImported(session: Session): void {
    this.emitSessionLifecycle("session_imported", session);
  }

  emitSessionDiscovered(session: Session): void {
    this.emitSessionLifecycle("session_discovered", session);
  }

  emitSessionDeleted(session: Session): void {
    this.emit({
      type: "session_deleted",
      sessionId: session.id,
      ...(session.workspaceId ? { workspaceId: session.workspaceId } : {}),
      emittedAt: this.now(),
    });
  }

  emitSessionSummary(session: Session): void {
    const summary = this.summaryFromSession(session);
    this.emitSummary(summary);
  }

  emitSessionSummaryById(sessionId: string): void {
    const session = this.sessionSnapshot(sessionId);
    if (!session) {
      return;
    }
    this.emitSessionSummary(session);
  }

  emitStopConfirmed(session: Session, source = "user", reason?: string): void {
    this.emit({
      type: "stop_confirmed",
      sessionId: session.id,
      ...(session.workspaceId ? { workspaceId: session.workspaceId } : {}),
      emittedAt: this.now(),
      source,
      ...(reason ? { reason } : {}),
    });
    this.emitSessionSummary(session);
  }

  handleSessionBroadcastEvent(payload: SessionBroadcastEvent): void {
    for (const message of this.mapSessionBroadcastEvent(payload)) {
      this.emit(message);
    }
  }

  private mapSessionBroadcastEvent(payload: SessionBroadcastEvent): AppEventMessage[] {
    const event = payload.event;
    const sessionId = embeddedSessionId(event, payload.sessionId);
    const emittedAt = this.now();

    switch (event.type) {
      case "state": {
        return [this.summaryMessageFromSession(event.session, emittedAt)];
      }
      case "session_summary":
        return [this.summaryMessageFromSummary(event.summary, sessionId, emittedAt)];
      case "session_deleted": {
        const targetSessionId = event.sessionId || sessionId;
        const workspaceId = this.workspaceIdForSession(targetSessionId);
        return [
          {
            type: "session_deleted",
            sessionId: targetSessionId,
            ...(workspaceId ? { workspaceId } : {}),
            emittedAt,
          },
        ];
      }
      case "session_ended": {
        const workspaceId = this.workspaceIdForSession(sessionId);
        return [
          {
            type: "session_ended",
            sessionId,
            ...(workspaceId ? { workspaceId } : {}),
            emittedAt,
            reason: event.reason,
          },
        ];
      }
      case "stop_requested":
      case "stop_confirmed":
      case "stop_failed": {
        const workspaceId = this.workspaceIdForSession(sessionId);
        return [
          {
            type: event.type,
            sessionId,
            ...(workspaceId ? { workspaceId } : {}),
            emittedAt,
            source: event.source,
            ...(event.reason ? { reason: event.reason } : {}),
          },
        ];
      }
      case "error": {
        const workspaceId = this.workspaceIdForSession(sessionId);
        return [
          {
            type: "session_error",
            sessionId,
            ...(workspaceId ? { workspaceId } : {}),
            emittedAt,
            message: sanitizeSessionErrorMessage(event.error),
            ...(event.code ? { code: event.code } : {}),
            ...(event.fatal !== undefined ? { fatal: event.fatal } : {}),
          },
        ];
      }
      case "extension_ui_request": {
        const workspaceId = this.workspaceIdForSession(sessionId);
        const request: Extract<AppEventMessage, { type: "extension_ui_request" }> = {
          type: "extension_ui_request",
          sessionId,
          ...(workspaceId ? { workspaceId } : {}),
          emittedAt,
          id: event.id,
          method: event.method,
          ...(event.title !== undefined ? { title: event.title } : {}),
          ...(event.options !== undefined ? { options: event.options } : {}),
          ...(event.message !== undefined ? { message: event.message } : {}),
          ...(event.placeholder !== undefined ? { placeholder: event.placeholder } : {}),
          ...(event.prefill !== undefined ? { prefill: event.prefill } : {}),
          ...(event.timeout !== undefined ? { timeout: event.timeout } : {}),
          ...(event.timeoutAt !== undefined ? { timeoutAt: event.timeoutAt } : {}),
          ...(event.questions !== undefined ? { questions: event.questions } : {}),
          ...(event.allowCustom !== undefined ? { allowCustom: event.allowCustom } : {}),
          ...(event.extensionScopeId !== undefined
            ? { extensionScopeId: event.extensionScopeId }
            : {}),
          ...(event.extensionDisplayName !== undefined
            ? { extensionDisplayName: event.extensionDisplayName }
            : {}),
        };
        return [request, ...this.summaryMessagesForSessionId(sessionId, emittedAt)];
      }
      case "extension_ui_settled": {
        const workspaceId = this.workspaceIdForSession(sessionId);
        return [
          {
            type: "extension_ui_settled",
            sessionId,
            ...(workspaceId ? { workspaceId } : {}),
            emittedAt,
            id: event.id,
          },
          ...this.summaryMessagesForSessionId(sessionId, emittedAt),
        ];
      }
      case "extension_ui_notification": {
        const workspaceId = this.workspaceIdForSession(sessionId);
        return [
          {
            type: "extension_ui_notification",
            sessionId,
            ...(workspaceId ? { workspaceId } : {}),
            emittedAt,
            method: event.method,
            ...(event.message !== undefined ? { message: event.message } : {}),
            ...(event.notifyType !== undefined ? { notifyType: event.notifyType } : {}),
            ...(event.statusKey !== undefined ? { statusKey: event.statusKey } : {}),
            ...(event.statusText !== undefined ? { statusText: event.statusText } : {}),
            ...(event.title !== undefined ? { title: event.title } : {}),
            ...(event.text !== undefined ? { text: event.text } : {}),
            ...(event.widgetKey !== undefined ? { widgetKey: event.widgetKey } : {}),
            ...(event.widgetLines !== undefined ? { widgetLines: event.widgetLines } : {}),
            ...(event.widgetPlacement !== undefined
              ? { widgetPlacement: event.widgetPlacement }
              : {}),
            ...(event.extensionScopeId !== undefined
              ? { extensionScopeId: event.extensionScopeId }
              : {}),
            ...(event.extensionDisplayName !== undefined
              ? { extensionDisplayName: event.extensionDisplayName }
              : {}),
            ...(event.nativeSurface !== undefined ? { nativeSurface: event.nativeSurface } : {}),
            ...(event.workingIndicator !== undefined
              ? { workingIndicator: event.workingIndicator }
              : {}),
            ...(event.workingVisible !== undefined ? { workingVisible: event.workingVisible } : {}),
            ...(event.hiddenThinkingLabel !== undefined
              ? { hiddenThinkingLabel: event.hiddenThinkingLabel }
              : {}),
            ...(event.toolsExpanded !== undefined ? { toolsExpanded: event.toolsExpanded } : {}),
          },
        ];
      }
      case "git_status":
        return [
          {
            type: "workspace_git_changed",
            workspaceId: event.workspaceId,
            ...(event.worktreeId ? { worktreeId: event.worktreeId } : {}),
            sessionId,
            emittedAt,
            reason: "mutation_tool",
          },
        ];
      default:
        return [];
    }
  }

  private emitSessionLifecycle(type: AppEventSessionLifecycleType, session: Session): void {
    const summary = this.summaryFromSession(session);
    this.recordSummaryFingerprint(summary);
    this.emit({
      type,
      sessionId: summary.id,
      ...(summary.workspaceId ? { workspaceId: summary.workspaceId } : {}),
      emittedAt: this.now(),
      summary,
    });
  }

  private emitSummary(summary: SessionSummary): void {
    const message: Extract<AppEventMessage, { type: "session_summary" }> = {
      type: "session_summary",
      sessionId: summary.id,
      ...(summary.workspaceId ? { workspaceId: summary.workspaceId } : {}),
      emittedAt: this.now(),
      summary,
    };
    this.emit(message);
  }

  private emit(message: AppEventMessage): void {
    if (!isAppEventAllowedType(message.type)) {
      return;
    }

    if (message.type === "session_summary") {
      const fingerprint = sessionSummaryFingerprint(message.summary);
      if (this.lastSummaryFingerprintBySession.get(message.sessionId) === fingerprint) {
        return;
      }
      this.lastSummaryFingerprintBySession.set(message.sessionId, fingerprint);
    }

    if (message.type === "extension_ui_notification" && this.shouldDropNotification(message)) {
      return;
    }

    for (const callback of this.subscribers) {
      try {
        callback(message);
      } catch (err) {
        log.error("app_event_stream.subscriber_callback.failed", {
          messageType: message.type,
          error: safeErrorMessage(err),
        });
      }
    }
  }

  private shouldDropNotification(
    message: Extract<AppEventMessage, { type: "extension_ui_notification" }>,
  ): boolean {
    const key = notificationCoalescingKey(message);
    if (!key) {
      return false;
    }
    const { emittedAt: _emittedAt, ...stable } = message;
    const fingerprint = JSON.stringify(stable);
    if (this.lastNotificationFingerprintByKey.get(key) === fingerprint) {
      return true;
    }
    this.lastNotificationFingerprintByKey.set(key, fingerprint);
    return false;
  }

  private summaryMessageFromSession(
    session: Session,
    emittedAt: number,
  ): Extract<AppEventMessage, { type: "session_summary" }> {
    const summary = this.summaryFromSession(session);
    return {
      type: "session_summary",
      sessionId: summary.id,
      ...(summary.workspaceId ? { workspaceId: summary.workspaceId } : {}),
      emittedAt,
      summary,
    };
  }

  private summaryMessageFromSummary(
    summary: SessionSummary,
    sessionId: string,
    emittedAt: number,
  ): Extract<AppEventMessage, { type: "session_summary" }> {
    const session = this.sessionSnapshot(summary.id) ?? this.sessionSnapshot(sessionId);
    const enriched = this.enrichSummary({
      ...summary,
      ...(summary.workspaceId === undefined && session?.workspaceId
        ? { workspaceId: session.workspaceId }
        : {}),
      ...(summary.workspaceName === undefined && session?.workspaceName
        ? { workspaceName: session.workspaceName }
        : {}),
      ...(summary.contextWindow === undefined && session?.contextWindow !== undefined
        ? { contextWindow: session.contextWindow }
        : {}),
    });
    return {
      type: "session_summary",
      sessionId: enriched.id,
      ...(enriched.workspaceId ? { workspaceId: enriched.workspaceId } : {}),
      emittedAt,
      summary: enriched,
    };
  }

  private summaryMessagesForSessionId(
    sessionId: string,
    emittedAt: number,
  ): Array<Extract<AppEventMessage, { type: "session_summary" }>> {
    const session = this.sessionSnapshot(sessionId);
    if (!session) {
      return [];
    }
    return [this.summaryMessageFromSession(session, emittedAt)];
  }

  private summaryFromSession(session: Session): SessionSummary {
    return this.enrichSummary(buildSessionSummary(this.ctx.ensureSessionContextWindow(session)));
  }

  private enrichSummary(summary: SessionSummary): SessionSummary {
    const pendingAskCount = this.pendingAskCount(summary.id);
    return pendingAskCount === undefined ? { ...summary } : { ...summary, pendingAskCount };
  }

  private pendingAskCount(sessionId: string): number | undefined {
    try {
      return pendingBlockingUIRequestCount(this.ctx.sessionRuntimes, sessionId);
    } catch {
      return undefined;
    }
  }

  private recordSummaryFingerprint(summary: SessionSummary): void {
    this.lastSummaryFingerprintBySession.set(summary.id, sessionSummaryFingerprint(summary));
  }

  private sessionSnapshot(sessionId: string): Session | undefined {
    return (
      this.ctx.sessionRuntimes.getSessionSnapshot?.(sessionId) ??
      this.ctx.storage.getSession(sessionId) ??
      undefined
    );
  }

  private workspaceIdForSession(sessionId: string): string | undefined {
    return this.sessionSnapshot(sessionId)?.workspaceId;
  }

  private now(): number {
    return this.ctx.now?.() ?? Date.now();
  }
}

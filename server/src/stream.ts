/**
 * WebSocket stream transports.
 *
 * Split-stream server transports for focused session commands/timeline
 * and server-level ASR dictation.
 */

import { WebSocket, type RawData } from "ws";
import type { SessionManager } from "./sessions.js";
import type { Storage } from "./storage.js";
import type { ClientMessage, ServerMessage, Session, Workspace } from "./types.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import type { DictationManager } from "./dictation-manager.js";
import { SessionLifecycleService } from "./session-lifecycle-service.js";
import type { SessionRuntimes } from "./runtime-router.js";
import type { DictationClientMessage, DictationServerMessage } from "./dictation-types.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";

/** Services needed by the stream mux — injected by Server. */
export interface StreamContext {
  storage: Storage;
  sessions: SessionManager;
  sessionRuntimes: SessionRuntimes;
  metrics?: ServerMetricCollector;
  ensureSessionContextWindow: (session: Session) => Session;
  resolveWorkspaceForSession: (session: Session) => Workspace | undefined;
  handleClientMessage: (
    session: Session,
    msg: ClientMessage,
    send: (msg: ServerMessage) => void,
    meta?: { connId?: string },
  ) => Promise<void>;
  trackConnection: (ws: WebSocket) => void;
  untrackConnection: (ws: WebSocket) => void;
  dictationManager?: DictationManager;
  createDictationManager?: () => DictationManager | undefined;
}

// ─── Keepalive ───

/** Default server-side ping interval (seconds). */
const PING_INTERVAL_MS = 30_000;

const log = createLogger({ base: { component: "stream" } });

function streamConnectedMessage(ctx: unknown, userName: string): ServerMessage {
  const streamContext = ctx as { dictationManager?: DictationManager };
  return {
    type: "stream_connected",
    userName,
    serverDictationAvailable: Boolean(streamContext.dictationManager),
  };
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, unknown>;
}

function rawDataToText(data: RawData | string): string {
  if (typeof data === "string") {
    return data;
  }

  if (Buffer.isBuffer(data)) {
    return data.toString("utf8");
  }

  if (Array.isArray(data)) {
    return Buffer.concat(data).toString("utf8");
  }

  return Buffer.from(data).toString("utf8");
}

function toBuffer(data: RawData): Buffer {
  if (Buffer.isBuffer(data)) return data;
  if (Array.isArray(data)) return Buffer.concat(data);
  return Buffer.from(data);
}

function countBucketForTag(count: number): string {
  if (count <= 0) return "0";
  if (count === 1) return "1";
  if (count <= 4) return "2-4";
  return "5+";
}

function parseIncomingClientMessage(
  data: RawData,
):
  | { ok: true; message: ClientMessage }
  | { ok: false; error: string; requestId?: string; command?: string } {
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawDataToText(data));
  } catch {
    return { ok: false, error: "Invalid JSON payload" };
  }

  const record = asRecord(parsed);
  if (!record) {
    return { ok: false, error: "Message payload must be a JSON object" };
  }

  const requestId = typeof record.requestId === "string" ? record.requestId : undefined;
  const type = record.type;

  if (typeof type !== "string" || type.trim().length === 0) {
    return { ok: false, error: "Message type is required", requestId };
  }

  // Cast to ClientMessage — the exhaustive switch in WsMessageHandler
  // sends a command_result error for any unknown type at runtime.
  return { ok: true, message: record as ClientMessage };
}

/**
 * Start a server-initiated ping/pong keepalive for a WebSocket.
 *
 * Sends a WS ping every `intervalMs`. Tolerates one missed pong (brief
 * iOS background suspension) before terminating the connection on the
 * second consecutive miss. This matches the iOS client's 2-failure
 * threshold and avoids killing connections during quick lock/unlock cycles.
 *
 * Returns a cleanup function that stops the timer.
 */
export function startServerPing(
  ws: WebSocket,
  label: string,
  intervalMs = PING_INTERVAL_MS,
  metrics?: ServerMetricCollector,
  connId?: string,
): () => void {
  let missedPongs = 0;
  let lastPingSentAt = 0;

  ws.on("pong", () => {
    missedPongs = 0;
    if (lastPingSentAt > 0 && metrics) {
      metrics.record("server.ws_ping_rtt_ms", Date.now() - lastPingSentAt);
    }
  });

  const timer = setInterval(() => {
    missedPongs++;
    if (missedPongs > 2) {
      metrics?.record("server.ws_ping_timeout", 1);
      log.warn("ws.ping_timeout", {
        connId,
        label,
        consecutiveMisses: missedPongs,
      });
      clearInterval(timer);
      ws.terminate();
      return;
    }
    lastPingSentAt = Date.now();
    ws.ping();
  }, intervalMs);

  return () => clearInterval(timer);
}

// ─── Bound Session Stream Mux ───

export class BoundSessionStreamMux {
  private connectionSeq = 0;
  private liveSessionConnections = new Map<string, Set<(msg: ServerMessage) => void>>();
  private readonly lifecycle: SessionLifecycleService;

  constructor(private ctx: StreamContext) {
    this.lifecycle = new SessionLifecycleService({
      storage: ctx.storage,
      sessions: ctx.sessions,
      sessionRuntimes: ctx.sessionRuntimes,
      ensureSessionContextWindow: ctx.ensureSessionContextWindow,
    });
  }

  private nextConnId(): string {
    this.connectionSeq += 1;
    return `bound_session_stream_${this.connectionSeq}`;
  }

  sendToSession(sessionId: string, msg: ServerMessage): number {
    const connections = this.liveSessionConnections.get(sessionId);
    if (!connections) return 0;
    let delivered = 0;
    for (const send of connections) {
      send(msg);
      delivered += 1;
    }
    return delivered;
  }

  async handleWebSocket(
    workspaceId: string,
    sessionId: string,
    ws: WebSocket,
    upgradeReceivedAt?: number,
  ): Promise<void> {
    const connectedAt = Date.now();
    const metrics = this.ctx.metrics;
    const owner = this.ctx.storage.getOwnerName();
    const connId = this.nextConnId();
    const path = `/workspaces/${workspaceId}/sessions/${sessionId}/stream`;

    const session = this.ctx.storage.getSession(sessionId);
    if (!session || session.workspaceId !== workspaceId) {
      ws.close(1008, "Session not found");
      return;
    }

    if (upgradeReceivedAt && metrics) {
      metrics.record("server.ws_handshake_ms", connectedAt - upgradeReceivedAt, {
        path: "bound_session_stream",
      });
    }

    log.info("ws.bound_session_stream_connected", {
      connId,
      owner,
      workspaceId,
      sessionId,
      path,
    });

    this.ctx.trackConnection(ws);
    const stopPing = startServerPing(ws, path, PING_INTERVAL_MS, metrics, connId);

    let msgSent = 0;
    let msgRecv = 0;
    let firstMessageRecorded = false;
    let unsubscribed = false;
    let unsubscribeBoundSession: (() => void) | undefined;
    const liveConnectionCleanup: { run?: () => void } = {};
    let connectionClosed = false;
    let queue: Promise<void> = Promise.resolve();

    const cleanupBoundConnection = (code: number, reason?: Buffer): void => {
      if (connectionClosed) return;
      connectionClosed = true;
      if (!unsubscribed) {
        unsubscribed = true;
        unsubscribeBoundSession?.();
      }
      liveConnectionCleanup.run?.();
      stopPing();
      this.ctx.untrackConnection(ws);
      const reasonStr = reason?.toString() || "";
      metrics?.record("server.ws_session_duration_ms", Date.now() - connectedAt, {
        path: "bound_session_stream",
      });
      metrics?.record("server.ws_messages_sent", msgSent, { path: "bound_session_stream" });
      metrics?.record("server.ws_messages_received", msgRecv, { path: "bound_session_stream" });
      metrics?.record("server.ws_close_code", 1, {
        code: String(code),
        path: "bound_session_stream",
      });
      log.info("ws.bound_session_stream_disconnected", {
        connId,
        workspaceId,
        sessionId,
        code,
        reason: reasonStr || undefined,
        sent: msgSent,
        recv: msgRecv,
        durationMs: Date.now() - connectedAt,
      });
    };

    ws.on("close", cleanupBoundConnection);

    ws.on("error", (err) => {
      log.warn("ws.bound_session_stream_error", {
        connId,
        workspaceId,
        sessionId,
        error: safeErrorMessage(err),
      });
    });

    const send = (msg: ServerMessage): boolean => {
      if (ws.readyState !== WebSocket.OPEN) {
        const context = {
          connId,
          messageType: msg.type,
          readyState: ws.readyState,
          sessionId,
        };
        if (ws.readyState === WebSocket.CLOSING || ws.readyState === WebSocket.CLOSED) {
          log.info("ws.bound_session_stream_drop_after_close", context);
        } else {
          log.warn("ws.bound_session_stream_drop_message", context);
        }
        return false;
      }
      msgSent += 1;
      ws.send(JSON.stringify(msg));
      return true;
    };

    const sendForSession = (msg: ServerMessage): void => {
      if (send({ ...msg, sessionId })) {
        metrics?.record("server.ws_message_sent", 1, {
          type: msg.type,
          level: "bound_session",
          path: "bound_session_stream",
        });
      }
    };

    let liveConnections = this.liveSessionConnections.get(sessionId);
    if (!liveConnections) {
      liveConnections = new Set();
      this.liveSessionConnections.set(sessionId, liveConnections);
    }
    liveConnections.add(sendForSession);
    liveConnectionCleanup.run = () => {
      const connections = this.liveSessionConnections.get(sessionId);
      connections?.delete(sendForSession);
      if (connections?.size === 0) {
        this.liveSessionConnections.delete(sessionId);
      }
    };

    send(streamConnectedMessage(this.ctx, owner));

    try {
      // Capture the durable cursor before session opening. Opening an already-running
      // session can await long enough for tool completions to land before the live
      // subscription exists. Replaying from this cursor closes that bootstrap gap.
      const beforeOpenSeq = this.ctx.sessionRuntimes.getCurrentSeq(sessionId);
      const openResult = await this.lifecycle.openFocusedSession({
        session,
        workspace: this.ctx.resolveWorkspaceForSession(session),
      });
      if (connectionClosed || ws.readyState !== WebSocket.OPEN) return;
      const hydratedSession = openResult.session;

      let bootstrapping = true;
      const bootstrapLiveQueue: ServerMessage[] = [];
      const callback = (msg: ServerMessage): void => {
        const outbound =
          msg.type === "state"
            ? {
                ...msg,
                session: this.ctx.ensureSessionContextWindow(msg.session),
              }
            : msg;
        if (bootstrapping) {
          bootstrapLiveQueue.push(outbound);
          return;
        }
        sendForSession(outbound);
      };
      unsubscribeBoundSession = this.ctx.sessionRuntimes.subscribe(sessionId, callback);
      unsubscribed = false;

      // A newly started runtime has no meaningful pre-open cursor. For an existing
      // runtime, replay only events emitted while openFocusedSession was in flight.
      const catchUpSinceSeq = openResult.startedSession
        ? this.ctx.sessionRuntimes.getCurrentSeq(sessionId)
        : beforeOpenSeq;
      const catchUp = this.ctx.sessionRuntimes.getCatchUp(sessionId, catchUpSinceSeq);

      // A temporarily disconnected terminal mirror intentionally remains terminal-owned,
      // but has no active broadcaster or ring to query. Keep its focused stream open so
      // the live bridge can resume instead of forcing an unproductive reconnect loop.
      const unavailableDisconnectedMirror =
        !catchUp &&
        openResult.owner === "pi-tui" &&
        !this.ctx.sessionRuntimes.isSessionConnected(sessionId);
      if ((!catchUp || !catchUp.catchUpComplete) && !unavailableDisconnectedMirror) {
        log.warn("ws.bound_session_stream_bootstrap_catchup_unavailable", {
          connId,
          sessionId,
          fromSeq: catchUpSinceSeq,
          currentSeq: catchUp?.currentSeq,
          runtimeAvailable: Boolean(catchUp),
        });
        metrics?.record("server.session_subscribe_ms", Date.now() - connectedAt, {
          level: "bound_session",
          outcome: "error",
          path: "bound_session_stream",
          catchup_requested: "true",
          catchup_complete: "false",
          started_session: openResult.startedSession ? "true" : "false",
          pending_permissions: "0",
          pending_ui_requests: "0",
        });
        cleanupBoundConnection(1011);
        ws.close(1011, "Session stream bootstrap retry required");
        return;
      }

      const bootstrapCurrentSeq =
        catchUp?.currentSeq ?? this.ctx.sessionRuntimes.getCurrentSeq(sessionId);
      sendForSession({
        type: "connected",
        session: hydratedSession,
        currentSeq: bootstrapCurrentSeq,
      });

      const catchUpEvents = catchUp?.events ?? [];
      for (const event of catchUpEvents) {
        sendForSession(event);
      }

      // Events emitted after subscribe may also be present in the ring snapshot. Drain
      // them only after replay and discard sequenced overlap to preserve exactly-once,
      // monotonically ordered delivery at the catch-up/live boundary. Keep buffering
      // until the queue is empty so reentrant callbacks cannot overtake queued events.
      for (let index = 0; index < bootstrapLiveQueue.length; index += 1) {
        const event = bootstrapLiveQueue[index];
        if (!event) continue;
        if (typeof event.seq === "number" && event.seq <= bootstrapCurrentSeq) continue;
        sendForSession(event);
      }
      bootstrapping = false;

      if (catchUpEvents.length > 0) {
        log.info("ws.bound_session_stream_bootstrap_replayed", {
          connId,
          sessionId,
          fromSeq: catchUpSinceSeq,
          currentSeq: bootstrapCurrentSeq,
          eventCount: catchUpEvents.length,
        });
      }

      const activeSession = this.ctx.sessionRuntimes.getActiveSession(sessionId) ?? hydratedSession;
      sendForSession({
        type: "state",
        session: this.ctx.ensureSessionContextWindow(activeSession),
      });

      const pendingUIMsgs = this.ctx.sessionRuntimes.getPendingUIRequestMessages(sessionId);
      for (const pendingUIMsg of pendingUIMsgs) {
        sendForSession(pendingUIMsg);
      }
      const pendingUIDialogCount = pendingUIMsgs.filter(
        (message) => message.type === "extension_ui_request",
      ).length;

      metrics?.record("server.session_subscribe_ms", Date.now() - connectedAt, {
        level: "bound_session",
        outcome: "success",
        path: "bound_session_stream",
        catchup_requested: catchUpEvents.length > 0 ? "true" : "false",
        catchup_complete: catchUp ? "true" : "false",
        started_session: openResult.startedSession ? "true" : "false",
        pending_permissions: countBucketForTag(0),
        pending_ui_requests: countBucketForTag(pendingUIDialogCount),
      });

      ws.on("message", (data, isBinary) => {
        queue = queue
          .then(async () => {
            msgRecv += 1;

            if (isBinary) {
              metrics?.record("server.ws_message_received", 1, {
                type: "binary",
                path: "bound_session_stream",
              });
              send({ type: "error", error: "Binary messages are not supported on session stream" });
              return;
            }

            if (!firstMessageRecorded && metrics) {
              firstMessageRecorded = true;
              metrics.record("server.ws_first_message_ms", Date.now() - connectedAt, {
                path: "bound_session_stream",
              });
            }

            const parsed = parseIncomingClientMessage(data);
            if (!parsed.ok) {
              if (parsed.command) {
                send({
                  type: "command_result",
                  command: parsed.command,
                  requestId: parsed.requestId,
                  success: false,
                  error: parsed.error,
                  sessionId,
                });
              } else {
                send({ type: "error", error: parsed.error, sessionId });
              }
              return;
            }

            const msg = parsed.message;
            metrics?.record("server.ws_message_received", 1, {
              type: msg.type,
              path: "bound_session_stream",
            });
            const trace = msg as { requestId?: string; sessionId?: string };
            log.debug("ws.bound_session_stream_message_received", {
              connId,
              owner,
              messageType: msg.type,
              requestId: trace.requestId,
              sessionId: trace.sessionId ?? sessionId,
            });

            switch (msg.type) {
              case "dictation_start":
              case "dictation_stop":
              case "dictation_cancel":
                send({
                  type: "dictation_error",
                  error: "Dictation uses the dedicated dictation stream",
                  fatal: false,
                } as ServerMessage);
                return;

              default: {
                const targetSessionId = msg.sessionId ?? sessionId;
                if (targetSessionId !== sessionId) {
                  const error = `Bound session stream cannot target session ${targetSessionId}`;
                  send({ type: "error", error, sessionId: targetSessionId });
                  if (typeof msg.requestId === "string" && msg.requestId.length > 0) {
                    send({
                      type: "command_result",
                      command: msg.type,
                      requestId: msg.requestId,
                      success: false,
                      error,
                      sessionId: targetSessionId,
                    });
                  }
                  return;
                }

                const targetSession = this.ctx.storage.getSession(sessionId);
                if (!targetSession) {
                  send({ type: "error", error: `Session not found: ${sessionId}`, sessionId });
                  return;
                }

                await this.ctx.handleClientMessage(
                  targetSession,
                  { ...msg, sessionId },
                  sendForSession,
                  { connId },
                );
              }
            }
          })
          .catch((err: unknown) => {
            const message = safeErrorMessage(err);
            log.error("ws.bound_session_stream_message.error", {
              connId,
              sessionId,
              error: message,
            });
            send({ type: "error", error: message, sessionId });
          });
      });
    } catch (err: unknown) {
      const message = safeErrorMessage(err);
      metrics?.record("server.session_subscribe_ms", Date.now() - connectedAt, {
        level: "bound_session",
        outcome: "error",
        path: "bound_session_stream",
        catchup_requested: "false",
        catchup_complete: "false",
        started_session: "false",
        pending_permissions: "0",
        pending_ui_requests: "0",
      });
      send({ type: "error", error: message, sessionId });
      cleanupBoundConnection(1011);
      ws.close(1011, "Session stream setup failed");
      log.warn("ws.bound_session_stream_setup_failed", {
        connId,
        workspaceId,
        sessionId,
        error: message,
      });
    }
  }
}

// ─── Dictation Stream Mux ───

export class DictationStreamMux {
  private connectionSeq = 0;

  constructor(
    private ctx: Pick<
      StreamContext,
      "metrics" | "trackConnection" | "untrackConnection" | "createDictationManager"
    >,
  ) {}

  private nextConnId(pathTag: string): string {
    this.connectionSeq += 1;
    return `${pathTag}_${this.connectionSeq}`;
  }

  handleServerWebSocket(ws: WebSocket, upgradeReceivedAt?: number): void {
    this.handleDictationWebSocket({
      ws,
      path: "/dictation/stream",
      pathTag: "dictation_stream",
      level: "dictation",
      upgradeReceivedAt,
      logMetadata: {},
    });
  }

  private handleDictationWebSocket({
    ws,
    path,
    pathTag,
    level,
    upgradeReceivedAt,
    logMetadata,
  }: {
    ws: WebSocket;
    path: string;
    pathTag: string;
    level: string;
    upgradeReceivedAt?: number;
    logMetadata: Record<string, unknown>;
  }): void {
    const dictationManager = this.ctx.createDictationManager?.();
    const connectedAt = Date.now();
    const metrics = this.ctx.metrics;
    const connId = this.nextConnId(pathTag);
    if (upgradeReceivedAt && metrics) {
      metrics.record("server.ws_handshake_ms", connectedAt - upgradeReceivedAt, {
        path: pathTag,
      });
    }

    log.info(`ws.${pathTag}_connected`, {
      connId,
      ...logMetadata,
      path,
      serverDictationAvailable: Boolean(dictationManager),
    });

    this.ctx.trackConnection(ws);
    const stopPing = startServerPing(ws, path, PING_INTERVAL_MS, metrics, connId);

    let msgSent = 0;
    let msgRecv = 0;
    const send = (msg: DictationServerMessage): void => {
      if (ws.readyState !== WebSocket.OPEN) return;
      msgSent += 1;
      ws.send(JSON.stringify(msg));
      metrics?.record("server.ws_message_sent", 1, {
        type: msg.type,
        level,
        path: pathTag,
      });
    };

    if (!dictationManager) {
      metrics?.record("server.dictation_error", 1, {
        stage: "audio_stream_connect",
        path: pathTag,
      });
      send({
        type: "dictation_error",
        error: "Server dictation is unavailable",
        fatal: true,
      });
      stopPing();
      this.ctx.untrackConnection(ws);
      ws.close(1013, "Dictation unavailable");
      return;
    }

    ws.on("message", (data, isBinary) => {
      msgRecv += 1;
      if (isBinary) {
        const buffer = toBuffer(data);
        metrics?.record("server.ws_message_received", 1, {
          type: "binary_audio",
          path: pathTag,
        });
        metrics?.record("server.ws_binary_received_bytes", buffer.byteLength, {
          path: pathTag,
        });
        dictationManager.handleAudioData(buffer);
        return;
      }

      const parsed = parseIncomingClientMessage(data);
      if (!parsed.ok) {
        send({ type: "dictation_error", error: parsed.error, fatal: false });
        return;
      }

      const msg = parsed.message;
      metrics?.record("server.ws_message_received", 1, {
        type: msg.type,
        path: pathTag,
      });
      switch (msg.type) {
        case "dictation_start":
        case "dictation_stop":
        case "dictation_cancel":
          dictationManager.handleControlMessage(msg as DictationClientMessage, send);
          return;
        default:
          metrics?.record("server.dictation_error", 1, {
            stage: "unsupported_audio_stream_message",
            path: pathTag,
          });
          send({
            type: "dictation_error",
            error: `Unsupported dictation stream message: ${msg.type}`,
            fatal: false,
          });
      }
    });

    ws.on("close", (code) => {
      dictationManager.handleDisconnect();
      stopPing();
      this.ctx.untrackConnection(ws);
      metrics?.record("server.ws_session_duration_ms", Date.now() - connectedAt, {
        path: pathTag,
      });
      metrics?.record("server.ws_messages_sent", msgSent, { path: pathTag });
      metrics?.record("server.ws_messages_received", msgRecv, { path: pathTag });
      metrics?.record("server.ws_close_code", 1, {
        code: String(code),
        path: pathTag,
      });
      log.info(`ws.${pathTag}_closed`, {
        connId,
        ...logMetadata,
        code,
        msgSent,
        msgRecv,
      });
    });

    ws.on("error", (err) => {
      log.warn(`ws.${pathTag}_error`, {
        connId,
        ...logMetadata,
        error: safeErrorMessage(err),
      });
    });
  }
}

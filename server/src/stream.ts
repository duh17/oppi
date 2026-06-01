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
import {
  canResumeStoppedMirrorAsOppi,
  promoteStoppedMirrorToOppi,
} from "./mirror-session-resume.js";
import type { PiTuiMirrorRuntime } from "./pi-tui-mirror-runtime.js";
import type { DictationClientMessage, DictationServerMessage } from "./dictation-types.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";

/** Services needed by the stream mux — injected by Server. */
export interface StreamContext {
  storage: Storage;
  sessions: SessionManager;
  mirrorRuntime?: PiTuiMirrorRuntime;
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

  constructor(private ctx: StreamContext) {}

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
        log.warn("ws.bound_session_stream_drop_message", {
          connId,
          messageType: msg.type,
          readyState: ws.readyState,
          sessionId,
        });
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
      const isStoredMirrorSession = session.runtime === "pi-tui";
      const mirrorRuntime = isStoredMirrorSession ? this.ctx.mirrorRuntime : undefined;
      const mirrorConnected = isStoredMirrorSession
        ? mirrorRuntime?.isSessionConnected(sessionId) === true
        : false;
      const shouldResumeMirrorAsOppi = canResumeStoppedMirrorAsOppi(session, mirrorConnected);
      if (shouldResumeMirrorAsOppi) {
        promoteStoppedMirrorToOppi(session);
        this.ctx.storage.saveSession(session);
      } else if (isStoredMirrorSession && !mirrorRuntime) {
        throw new Error("pi-tui runtime is not available");
      }
      const isMirrorSession = isStoredMirrorSession && !shouldResumeMirrorAsOppi;

      let hydratedSession = this.ctx.ensureSessionContextWindow(session);
      const hadActiveSession = isMirrorSession
        ? mirrorRuntime?.isSessionConnected(sessionId) === true
        : this.ctx.sessions.getActiveSession(sessionId) !== undefined;

      if (isMirrorSession) {
        hydratedSession = this.ctx.ensureSessionContextWindow(
          mirrorRuntime?.getActiveSession(sessionId) ?? session,
        );
      } else {
        const workspace = this.ctx.resolveWorkspaceForSession(session);
        const started = await this.ctx.sessions.startSession(sessionId, workspace);
        if (connectionClosed || ws.readyState !== WebSocket.OPEN) return;
        hydratedSession = this.ctx.ensureSessionContextWindow(started);
      }

      sendForSession({
        type: "connected",
        session: hydratedSession,
        currentSeq: isMirrorSession
          ? (mirrorRuntime?.getCurrentSeq(sessionId) ?? 0)
          : this.ctx.sessions.getCurrentSeq(sessionId),
      });

      const callback = (msg: ServerMessage): void => {
        const outbound =
          msg.type === "state"
            ? {
                ...msg,
                session: this.ctx.ensureSessionContextWindow(msg.session),
              }
            : msg;
        sendForSession(outbound);
      };
      unsubscribeBoundSession = isMirrorSession
        ? mirrorRuntime?.subscribe(sessionId, callback)
        : this.ctx.sessions.subscribe(sessionId, callback);
      unsubscribed = false;

      const activeSession = isMirrorSession
        ? (mirrorRuntime?.getActiveSession(sessionId) ?? hydratedSession)
        : (this.ctx.sessions.getActiveSession(sessionId) ?? hydratedSession);
      sendForSession({
        type: "state",
        session: this.ctx.ensureSessionContextWindow(activeSession),
      });

      const pendingAskMsg = isMirrorSession
        ? mirrorRuntime?.getPendingAskMessage(sessionId)
        : this.ctx.sessions.getPendingAskMessage(sessionId);
      if (pendingAskMsg) send(pendingAskMsg);

      const pendingUIMsgs = isMirrorSession
        ? (mirrorRuntime?.getPendingUIRequestMessages(sessionId) ?? [])
        : this.ctx.sessions.getPendingUIRequestMessages(sessionId);
      for (const pendingUIMsg of pendingUIMsgs) {
        send(pendingUIMsg);
      }

      metrics?.record("server.session_subscribe_ms", Date.now() - connectedAt, {
        level: "bound_session",
        outcome: "success",
        path: "bound_session_stream",
        catchup_requested: "false",
        catchup_complete: "true",
        started_session: isMirrorSession ? "false" : hadActiveSession ? "false" : "true",
        pending_permissions: countBucketForTag(0),
        pending_ui_requests: countBucketForTag((pendingAskMsg ? 1 : 0) + pendingUIMsgs.length),
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

export class SessionAudioStreamMux {
  private connectionSeq = 0;

  constructor(
    private ctx: Pick<
      StreamContext,
      "storage" | "metrics" | "trackConnection" | "untrackConnection" | "createDictationManager"
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

  handleWebSocket(
    workspaceId: string,
    sessionId: string,
    ws: WebSocket,
    upgradeReceivedAt?: number,
  ): void {
    const session = this.ctx.storage.getSession(sessionId);
    if (!session || session.workspaceId !== workspaceId) {
      ws.close(1008, "Session not found");
      return;
    }

    this.handleDictationWebSocket({
      ws,
      path: `/workspaces/${workspaceId}/sessions/${sessionId}/audio/stream`,
      pathTag: "session_audio_stream",
      level: "session_audio",
      upgradeReceivedAt,
      logMetadata: { workspaceId, sessionId },
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
            error: `Unsupported audio stream message: ${msg.type}`,
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

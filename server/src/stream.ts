/**
 * User stream multiplexer.
 *
 * Manages per-user WebSocket connections for the multiplexed /stream endpoint.
 * Handles subscribe/unsubscribe, event ring replay, backpressure, and
 * notification-level filtering.
 */

import { WebSocket, type RawData } from "ws";
import { EventRing } from "./event-ring.js";
import type { SessionManager } from "./sessions.js";
import { buildPermissionMessage, type GateServer, type PendingDecision } from "./gate.js";
import type { Storage } from "./storage.js";
import type { ClientMessage, ServerMessage, Session, Workspace } from "./types.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import type { DictationManager } from "./dictation-manager.js";
import type { DictationClientMessage, DictationServerMessage } from "./dictation-types.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";

// ─── Types ───

export type StreamSubscriptionLevel = "full" | "notifications";

export interface UserStreamSubscription {
  level: StreamSubscriptionLevel;
  unsubscribe: () => void;
  subscriptionGeneration?: number;
}

interface UserStreamLiveConnection {
  subscriptions: Map<string, UserStreamSubscription>;
  sendForSession: (sessionId: string, msg: ServerMessage) => void;
}

interface WorkspaceStreamState {
  seq: number;
  ring: EventRing;
  liveConnections: Set<WorkspaceStreamLiveConnection>;
}

interface WorkspaceStreamLiveConnection {
  send: (msg: ServerMessage) => void;
}

/** Services needed by the stream mux — injected by Server. */
export interface StreamContext {
  storage: Storage;
  sessions: SessionManager;
  gate: GateServer;
  metrics?: ServerMetricCollector;
  ensureSessionContextWindow: (session: Session) => Session;
  resolveWorkspaceForSession: (session: Session) => Workspace | undefined;
  handleClientMessage: (
    session: Session,
    msg: ClientMessage,
    send: (msg: ServerMessage) => void,
    meta?: { connId?: string },
  ) => Promise<void>;
  trackConnection: (ws: WebSocket, options?: { userBroadcast?: boolean }) => void;
  untrackConnection: (ws: WebSocket) => void;
  dictationManager?: DictationManager;
  createDictationManager?: () => DictationManager | undefined;
}

// ─── Keepalive ───

/** Default server-side ping interval (seconds). */
const PING_INTERVAL_MS = 30_000;

/** Typed stream error code: command sent for non-full subscription session. */
export const STREAM_ERROR_NOT_SUBSCRIBED_FULL = "stream_not_subscribed_full";

const log = createLogger({ base: { component: "stream" } });

function streamConnectedMessage(ctx: unknown, userName: string): ServerMessage {
  const streamContext = ctx as { dictationManager?: DictationManager };
  return {
    type: "stream_connected",
    userName,
    asrAvailable: Boolean(streamContext.dictationManager),
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

function isStaleSubscriptionGeneration(
  currentGeneration: number | undefined,
  incomingGeneration: number | undefined,
): boolean {
  return (
    currentGeneration !== undefined &&
    incomingGeneration !== undefined &&
    incomingGeneration < currentGeneration
  );
}

function latestSubscriptionGeneration(
  currentGeneration: number | undefined,
  incomingGeneration: number | undefined,
): number | undefined {
  if (incomingGeneration === undefined) return currentGeneration;
  if (currentGeneration === undefined) return incomingGeneration;
  return Math.max(currentGeneration, incomingGeneration);
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

// ─── Workspace Stream Mux ───

export class WorkspaceStreamMux {
  private readonly ringCapacity: number;
  private readonly states = new Map<string, WorkspaceStreamState>();
  private connectionSeq = 0;

  constructor(
    private ctx: Pick<
      StreamContext,
      "storage" | "metrics" | "trackConnection" | "untrackConnection"
    >,
    options?: { ringCapacity?: number },
  ) {
    this.ringCapacity = options?.ringCapacity ?? 2000;
  }

  private nextConnId(): string {
    this.connectionSeq += 1;
    return `workspace_stream_${this.connectionSeq}`;
  }

  private stateFor(workspaceId: string): WorkspaceStreamState {
    let state = this.states.get(workspaceId);
    if (!state) {
      state = { seq: 0, ring: new EventRing(this.ringCapacity), liveConnections: new Set() };
      this.states.set(workspaceId, state);
    }
    return state;
  }

  getWorkspaceStreamCatchUp(
    workspaceId: string,
    sinceSeq: number,
  ): { events: ServerMessage[]; currentSeq: number; catchUpComplete: boolean } {
    const state = this.stateFor(workspaceId);
    const catchUpComplete = state.ring.canServe(sinceSeq);
    const events = catchUpComplete ? state.ring.since(sinceSeq).map((entry) => entry.event) : [];
    this.ctx.metrics?.record(
      catchUpComplete ? "server.catchup_events" : "server.catchup_miss",
      catchUpComplete ? events.length : 1,
      {
        ring: "workspace_stream",
      },
    );
    return { events, currentSeq: state.seq || state.ring.currentSeq, catchUpComplete };
  }

  hasOpenConnections(workspaceId: string): boolean {
    return this.stateFor(workspaceId).liveConnections.size > 0;
  }

  recordAndFanOutWorkspaceEvent(workspaceId: string, msg: ServerMessage): number {
    const state = this.stateFor(workspaceId);
    state.seq += 1;
    const event = { ...msg, workspaceId, streamSeq: state.seq } as ServerMessage;
    state.ring.push({ seq: state.seq, event, timestamp: Date.now() });

    let delivered = 0;
    for (const connection of state.liveConnections) {
      connection.send(event);
      delivered += 1;
    }
    this.ctx.metrics?.record("server.user_stream_fanout", delivered, {
      type: msg.type,
      lane: "workspace",
    });
    return state.seq;
  }

  handleWebSocket(workspaceId: string, ws: WebSocket, upgradeReceivedAt?: number): void {
    const workspace = this.ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      ws.close(1008, "Workspace not found");
      return;
    }

    const connectedAt = Date.now();
    const metrics = this.ctx.metrics;
    const connId = this.nextConnId();
    if (upgradeReceivedAt && metrics) {
      metrics.record("server.ws_handshake_ms", connectedAt - upgradeReceivedAt, {
        path: "workspace_stream",
      });
    }

    log.info("ws.workspace_stream_connected", {
      connId,
      workspaceId,
      path: `/workspaces/${workspaceId}/stream`,
    });
    this.ctx.trackConnection(ws, { userBroadcast: false });
    const stopPing = startServerPing(
      ws,
      `/workspaces/${workspaceId}/stream`,
      PING_INTERVAL_MS,
      metrics,
      connId,
    );
    const state = this.stateFor(workspaceId);
    let msgSent = 0;
    const send = (msg: ServerMessage): void => {
      if (ws.readyState !== WebSocket.OPEN) return;
      msgSent += 1;
      ws.send(JSON.stringify(msg));
      metrics?.record("server.ws_message_sent", 1, {
        type: msg.type,
        level: "workspace",
        path: "workspace_stream",
      });
    };
    const liveConnection: WorkspaceStreamLiveConnection = { send };
    state.liveConnections.add(liveConnection);
    send(streamConnectedMessage(this.ctx, this.ctx.storage.getOwnerName()));

    ws.on("message", () => {
      metrics?.record("server.ws_message_received", 1, {
        type: "unexpected_client_message",
        path: "workspace_stream",
      });
      send({ type: "error", error: "Workspace stream is server-to-client only" });
    });
    ws.on("close", (code) => {
      state.liveConnections.delete(liveConnection);
      stopPing();
      this.ctx.untrackConnection(ws);
      metrics?.record("server.ws_session_duration_ms", Date.now() - connectedAt, {
        path: "workspace_stream",
      });
      metrics?.record("server.ws_messages_sent", msgSent, { path: "workspace_stream" });
      metrics?.record("server.ws_close_code", 1, { code: String(code), path: "workspace_stream" });
      log.info("ws.workspace_stream_closed", { connId, workspaceId, code, msgSent });
    });
    ws.on("error", (err) => {
      log.warn("ws.workspace_stream_error", { connId, workspaceId, error: safeErrorMessage(err) });
    });
  }
}

// ─── Session Audio Stream Mux ───

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

    this.ctx.trackConnection(ws, { userBroadcast: false });
    const stopPing = startServerPing(ws, path, PING_INTERVAL_MS, metrics, connId);

    let msgSent = 0;
    let msgRecv = 0;
    let firstMessageRecorded = false;
    let unsubscribed = false;
    let unsubscribeBoundSession: (() => void) | undefined;
    const liveConnectionCleanup: { run?: () => void } = {};
    let connectionClosed = false;
    let queue: Promise<void> = Promise.resolve();
    let setupComplete = false;

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

    // Register the permission response path before session startup finishes.
    // A guarded startup can block on a pending approval, and a fast client tap
    // must be able to unblock the gate before the full session handler exists.
    ws.on("message", (data, isBinary) => {
      if (setupComplete || isBinary) return;
      const parsed = parseIncomingClientMessage(data);
      if (!parsed.ok || parsed.message.type !== "permission_response") return;

      msgRecv += 1;
      if (!firstMessageRecorded && metrics) {
        firstMessageRecorded = true;
        metrics.record("server.ws_first_message_ms", Date.now() - connectedAt, {
          path: "bound_session_stream",
        });
      }

      const msg = parsed.message;
      metrics?.record("server.ws_message_received", 1, {
        type: msg.type,
        path: "bound_session_stream",
      });
      const scope = msg.scope || "once";
      const resolved = this.ctx.gate.resolveDecision(msg.id, msg.action, scope, msg.expiresInMs);
      if (!resolved) {
        send({
          type: "error",
          error: `Permission request not found: ${msg.id}`,
          sessionId,
        });
        return;
      }
      if (msg.requestId) {
        send({
          type: "command_result",
          command: "permission_response",
          requestId: msg.requestId,
          success: true,
          sessionId,
        });
      }
    });

    send(streamConnectedMessage(this.ctx, owner));

    try {
      let hydratedSession = this.ctx.ensureSessionContextWindow(session);
      const hadActiveSession = this.ctx.sessions.getActiveSession(sessionId) !== undefined;
      const workspace = this.ctx.resolveWorkspaceForSession(session);
      const started = await this.ctx.sessions.startSession(sessionId, workspace);
      if (connectionClosed || ws.readyState !== WebSocket.OPEN) return;
      hydratedSession = this.ctx.ensureSessionContextWindow(started);

      sendForSession({
        type: "connected",
        session: hydratedSession,
        currentSeq: this.ctx.sessions.getCurrentSeq(sessionId),
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
      unsubscribeBoundSession = this.ctx.sessions.subscribe(sessionId, callback);
      unsubscribed = false;

      sendForSession({
        type: "state",
        session: this.ctx.ensureSessionContextWindow(
          this.ctx.sessions.getActiveSession(sessionId) ?? hydratedSession,
        ),
      });

      const pendingPerms = this.ctx.gate
        .getPendingForUser()
        .filter((p: PendingDecision) => p.sessionId === sessionId);
      for (const pending of pendingPerms) {
        send(buildPermissionMessage(pending));
      }

      const pendingAskMsg = this.ctx.sessions.getPendingAskMessage(sessionId);
      if (pendingAskMsg) send(pendingAskMsg);

      const pendingUIMsgs = this.ctx.sessions.getPendingUIRequestMessages(sessionId);
      for (const pendingUIMsg of pendingUIMsgs) {
        send(pendingUIMsg);
      }

      metrics?.record("server.session_subscribe_ms", Date.now() - connectedAt, {
        level: "bound_session",
        outcome: "success",
        path: "bound_session_stream",
        catchup_requested: "false",
        catchup_complete: "true",
        started_session: hadActiveSession ? "false" : "true",
        pending_permissions: countBucketForTag(pendingPerms.length),
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
              case "subscribe":
              case "unsubscribe":
                send({
                  type: "command_result",
                  command: msg.type,
                  requestId: msg.requestId,
                  success: false,
                  error: `${msg.type} is not supported on bound session streams`,
                  sessionId,
                });
                return;

              case "dictation_start":
              case "dictation_stop":
              case "dictation_cancel":
                send({
                  type: "dictation_error",
                  error: "Dictation uses the session audio stream",
                  fatal: false,
                } as ServerMessage);
                return;

              case "permission_response": {
                const scope = msg.scope || "once";
                const resolved = this.ctx.gate.resolveDecision(
                  msg.id,
                  msg.action,
                  scope,
                  msg.expiresInMs,
                );
                if (!resolved) {
                  send({
                    type: "error",
                    error: `Permission request not found: ${msg.id}`,
                    sessionId,
                  });
                  return;
                }
                if (msg.requestId) {
                  send({
                    type: "command_result",
                    command: "permission_response",
                    requestId: msg.requestId,
                    success: true,
                    sessionId,
                  });
                }
                return;
              }

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
      setupComplete = true;
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

export class SessionAudioStreamMux {
  private connectionSeq = 0;

  constructor(
    private ctx: Pick<
      StreamContext,
      "storage" | "metrics" | "trackConnection" | "untrackConnection" | "createDictationManager"
    >,
  ) {}

  private nextConnId(): string {
    this.connectionSeq += 1;
    return `session_audio_stream_${this.connectionSeq}`;
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

    const dictationManager = this.ctx.createDictationManager?.();
    const connectedAt = Date.now();
    const metrics = this.ctx.metrics;
    const connId = this.nextConnId();
    if (upgradeReceivedAt && metrics) {
      metrics.record("server.ws_handshake_ms", connectedAt - upgradeReceivedAt, {
        path: "session_audio_stream",
      });
    }

    log.info("ws.session_audio_stream_connected", {
      connId,
      workspaceId,
      sessionId,
      path: `/workspaces/${workspaceId}/sessions/${sessionId}/audio/stream`,
      asrAvailable: Boolean(dictationManager),
    });

    this.ctx.trackConnection(ws, { userBroadcast: false });
    const stopPing = startServerPing(
      ws,
      `/workspaces/${workspaceId}/sessions/${sessionId}/audio/stream`,
      PING_INTERVAL_MS,
      metrics,
      connId,
    );

    let msgSent = 0;
    let msgRecv = 0;
    const send = (msg: DictationServerMessage): void => {
      if (ws.readyState !== WebSocket.OPEN) return;
      msgSent += 1;
      ws.send(JSON.stringify(msg));
      metrics?.record("server.ws_message_sent", 1, {
        type: msg.type,
        level: "session_audio",
        path: "session_audio_stream",
      });
    };

    if (!dictationManager) {
      metrics?.record("server.dictation_error", 1, {
        stage: "audio_stream_connect",
        path: "session_audio_stream",
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
          path: "session_audio_stream",
        });
        metrics?.record("server.ws_binary_received_bytes", buffer.byteLength, {
          path: "session_audio_stream",
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
        path: "session_audio_stream",
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
            path: "session_audio_stream",
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
        path: "session_audio_stream",
      });
      metrics?.record("server.ws_messages_sent", msgSent, { path: "session_audio_stream" });
      metrics?.record("server.ws_messages_received", msgRecv, { path: "session_audio_stream" });
      metrics?.record("server.ws_close_code", 1, {
        code: String(code),
        path: "session_audio_stream",
      });
      log.info("ws.session_audio_stream_closed", {
        connId,
        workspaceId,
        sessionId,
        code,
        msgSent,
        msgRecv,
      });
    });

    ws.on("error", (err) => {
      log.warn("ws.session_audio_stream_error", {
        connId,
        workspaceId,
        sessionId,
        error: safeErrorMessage(err),
      });
    });
  }
}

// ─── User Stream Mux ───

export class UserStreamMux {
  private streamSeq = 0;
  private streamRing: EventRing | null = null;
  private readonly ringCapacity: number;
  private dictationManager?: DictationManager;
  private connectionSeq = 0;
  private readonly liveConnections = new Set<UserStreamLiveConnection>();

  constructor(
    private ctx: StreamContext,
    options?: { ringCapacity?: number },
  ) {
    this.ringCapacity = options?.ringCapacity ?? 2000;
    this.dictationManager = ctx.dictationManager;
  }

  private nextConnId(): string {
    this.connectionSeq += 1;
    return `stream_${this.connectionSeq}`;
  }

  // ─── Message Classification ───

  isNotificationLevelMessage(msg: ServerMessage): boolean {
    switch (msg.type) {
      case "permission_request":
      case "permission_expired":
      case "permission_cancelled":
      case "permission_resolved":
      case "extension_ui_request":
      case "agent_start":
      case "agent_end":
      case "state":
      case "session_summary":
      case "session_ended":
      case "session_deleted":
      case "stop_requested":
      case "stop_confirmed":
      case "stop_failed":
      case "error":
        return true;
      default:
        return false;
    }
  }

  // ─── Sequence Tracking ───

  nextUserStreamSeq(): number {
    return ++this.streamSeq;
  }

  getUserStreamRing(): EventRing {
    if (!this.streamRing) {
      this.streamRing = new EventRing(this.ringCapacity);
    }
    return this.streamRing;
  }

  getUserStreamCatchUp(sinceSeq: number): {
    events: ServerMessage[];
    currentSeq: number;
    catchUpComplete: boolean;
  } {
    const ring = this.getUserStreamRing();
    const catchUpComplete = ring.canServe(sinceSeq);
    const events = catchUpComplete ? ring.since(sinceSeq).map((entry) => entry.event) : [];

    let expected = sinceSeq;
    for (const event of events) {
      const seq = event.streamSeq;
      if (typeof seq !== "number" || !Number.isInteger(seq) || seq <= expected) {
        throw new Error(`Invalid stream replay ordering: expected > ${expected}, got ${seq}`);
      }
      expected = seq;
    }

    const metrics = this.ctx.metrics;
    if (metrics) {
      if (catchUpComplete && events.length > 0) {
        metrics.record("server.catchup_events", events.length, { ring: "user_stream" });
      }
      if (!catchUpComplete) {
        metrics.record("server.catchup_miss", 1, { ring: "user_stream" });
      }
    }

    return {
      events,
      currentSeq: this.streamSeq || ring.currentSeq,
      catchUpComplete,
    };
  }

  /** Return event ring stats for utilization sampling. */
  getEventRingStats(): { length: number; capacity: number } | null {
    if (!this.streamRing) return null;
    return { length: this.streamRing.length, capacity: this.streamRing.capacity };
  }

  private appendUserStreamEvent(
    sessionId: string,
    msg: ServerMessage,
  ): { streamSeq: number; event: ServerMessage } {
    const streamSeq = this.nextUserStreamSeq();
    const ring = this.getUserStreamRing();

    const event: ServerMessage = {
      ...msg,
      sessionId,
      streamSeq,
    };

    ring.push({ seq: streamSeq, event, timestamp: Date.now() });
    this.ctx.metrics?.record("server.user_stream_event", 1, { type: msg.type });
    return { streamSeq, event };
  }

  recordUserStreamEvent(sessionId: string, msg: ServerMessage): number {
    return this.appendUserStreamEvent(sessionId, msg).streamSeq;
  }

  recordAndFanOutUserStreamEvent(sessionId: string, msg: ServerMessage): number {
    const { streamSeq, event } = this.appendUserStreamEvent(sessionId, msg);
    this.fanOutUserStreamEvent(sessionId, event);
    return streamSeq;
  }

  private fanOutUserStreamEvent(sessionId: string, event: ServerMessage): void {
    let delivered = 0;
    for (const connection of this.liveConnections) {
      const sub = connection.subscriptions.get(sessionId);
      if (!sub) continue;
      if (sub.level === "notifications" && !this.isNotificationLevelMessage(event)) continue;
      connection.sendForSession(sessionId, event);
      delivered += 1;
    }
    this.ctx.metrics?.record("server.user_stream_fanout", delivered, { type: event.type });
  }

  // ─── WebSocket Handler ───

  async handleWebSocket(ws: WebSocket, upgradeReceivedAt?: number): Promise<void> {
    const connectedAt = Date.now();
    const metrics = this.ctx.metrics;
    const owner = this.ctx.storage.getOwnerName();
    const connId = this.nextConnId();

    if (upgradeReceivedAt && metrics) {
      metrics.record("server.ws_handshake_ms", connectedAt - upgradeReceivedAt, {
        path: "legacy_stream",
      });
    }

    log.info("ws.stream_connected", {
      connId,
      owner,
      path: "/stream",
    });
    this.ctx.trackConnection(ws, { userBroadcast: true });

    const stopPing = startServerPing(ws, `/stream (${owner})`, PING_INTERVAL_MS, metrics, connId);

    let msgSent = 0;
    let msgRecv = 0;
    let firstMessageRecorded = false;
    const subscriptions = new Map<string, UserStreamSubscription>();
    let queue: Promise<void> = Promise.resolve();

    const send = (msg: ServerMessage): boolean => {
      if (ws.readyState !== WebSocket.OPEN) {
        log.warn("ws.stream_drop_message", {
          connId,
          messageType: msg.type,
          readyState: ws.readyState,
          owner,
        });
        return false;
      }

      msgSent++;
      ws.send(JSON.stringify(msg));
      return true;
    };

    const sendForSession = (sessionId: string, msg: ServerMessage): void => {
      const level = subscriptions.get(sessionId)?.level ?? "none";
      if (send({ ...msg, sessionId })) {
        metrics?.record("server.ws_message_sent", 1, {
          type: msg.type,
          level,
          path: "legacy_stream",
        });
      }
    };

    const liveConnection: UserStreamLiveConnection = { subscriptions, sendForSession };
    this.liveConnections.add(liveConnection);

    const clearSubscription = (
      sessionId: string,
      subscriptionGeneration?: number,
    ): { cleared: boolean; ignoredStale: boolean } => {
      const sub = subscriptions.get(sessionId);
      if (!sub) return { cleared: false, ignoredStale: false };

      if (isStaleSubscriptionGeneration(sub.subscriptionGeneration, subscriptionGeneration)) {
        log.info("stream.unsubscribe.ignored_stale", {
          connId,
          sessionId,
          subscriptionGeneration,
          currentGeneration: sub.subscriptionGeneration,
        });
        return { cleared: false, ignoredStale: true };
      }

      sub.unsubscribe();
      subscriptions.delete(sessionId);
      return { cleared: true, ignoredStale: false };
    };

    const clearAllSubscriptions = (): void => {
      for (const [, sub] of subscriptions) {
        sub.unsubscribe();
      }
      subscriptions.clear();
    };

    const subscribeSession = async (
      sessionId: string,
      level: StreamSubscriptionLevel,
      requestId?: string,
      sinceSeq?: number,
      subscriptionGeneration?: number,
    ): Promise<void> => {
      const subscribeStart = Date.now();
      log.info("stream.subscribe.received", {
        connId,
        sessionId,
        requestId,
        requestedLevel: level,
        sinceSeq,
        subscriptionGeneration,
      });

      if (sinceSeq !== undefined && (!Number.isInteger(sinceSeq) || sinceSeq < 0)) {
        log.warn("stream.subscribe.rejected", {
          connId,
          sessionId,
          requestId,
          reason: "invalid_since_seq",
          sinceSeq,
        });
        send({
          type: "command_result",
          command: "subscribe",
          requestId,
          success: false,
          error: "sinceSeq must be a non-negative integer",
          sessionId,
        });
        return;
      }

      const session = this.ctx.storage.getSession(sessionId);
      if (!session) {
        log.warn("stream.subscribe.rejected", {
          connId,
          sessionId,
          requestId,
          reason: "session_not_found",
        });
        send({
          type: "command_result",
          command: "subscribe",
          requestId,
          success: false,
          error: `Session not found: ${sessionId}`,
          sessionId,
        });
        return;
      }

      // ── Dedup: already subscribed at same level → short-circuit ──
      // Prevents the reconnect death spiral where rapid WS reconnects
      // each re-subscribe hundreds of notification sessions, overwhelming
      // the event loop and causing ping timeouts → more reconnects.
      const existing = subscriptions.get(sessionId);
      if (existing && sinceSeq === undefined) {
        if (
          isStaleSubscriptionGeneration(existing.subscriptionGeneration, subscriptionGeneration)
        ) {
          log.info("stream.subscribe.ignored_stale", {
            connId,
            sessionId,
            requestId,
            requestedLevel: level,
            effectiveLevel: existing.level,
            subscriptionGeneration,
            currentGeneration: existing.subscriptionGeneration,
          });
          send({
            type: "command_result",
            command: "subscribe",
            requestId,
            success: true,
            data: {
              sessionId,
              level: existing.level,
              requestedLevel: level,
              currentSeq: this.ctx.sessions.getCurrentSeq(sessionId),
              catchUpComplete: true,
              ignoredStale: true,
              subscriptionGeneration: existing.subscriptionGeneration,
            },
            sessionId,
          });
          return;
        }

        const retainFullSubscription = existing.level === "full" && level === "notifications";
        if (existing.level === level || retainFullSubscription) {
          const effectiveGeneration = latestSubscriptionGeneration(
            existing.subscriptionGeneration,
            subscriptionGeneration,
          );
          if (effectiveGeneration !== existing.subscriptionGeneration) {
            subscriptions.set(sessionId, {
              ...existing,
              subscriptionGeneration: effectiveGeneration,
            });
          }
          log.debug("stream.subscribe.deduplicated", {
            connId,
            sessionId,
            requestId,
            requestedLevel: level,
            effectiveLevel: existing.level,
            retainFullSubscription,
            subscriptionGeneration,
            effectiveGeneration,
          });
          send({
            type: "command_result",
            command: "subscribe",
            requestId,
            success: true,
            data: {
              sessionId,
              level: existing.level,
              requestedLevel: level,
              currentSeq: this.ctx.sessions.getCurrentSeq(sessionId),
              catchUpComplete: true,
              deduplicated: true,
              retainedFullSubscription: retainFullSubscription,
              subscriptionGeneration: effectiveGeneration,
            },
            sessionId,
          });
          return;
        }
      }

      clearSubscription(sessionId);

      const catchupRequested = sinceSeq !== undefined;
      let catchUpComplete = !catchupRequested;
      let pendingPermissionCount = 0;
      let pendingUIRequestCount = 0;
      let startedSession = false;

      try {
        let hydratedSession = this.ctx.ensureSessionContextWindow(session);
        if (level === "full") {
          const subStartMs = Date.now();
          const hadActiveSession = this.ctx.sessions.getActiveSession(sessionId) !== undefined;
          const workspace = this.ctx.resolveWorkspaceForSession(session);
          const started = await this.ctx.sessions.startSession(sessionId, workspace);
          startedSession = !hadActiveSession;
          const startSessionMs = Date.now() - subStartMs;
          hydratedSession = this.ctx.ensureSessionContextWindow(started);
          sendForSession(sessionId, {
            type: "connected",
            session: hydratedSession,
            currentSeq: this.ctx.sessions.getCurrentSeq(sessionId),
          });

          const connectedSentMs = Date.now() - subStartMs;
          log.info("stream.subscribe.session.started", {
            connId,
            sessionId,
            startSessionMs,
            connectedSentMs,
          });
        }

        const callback = (msg: ServerMessage): void => {
          const sub = subscriptions.get(sessionId);
          if (!sub) {
            return;
          }

          if (sub.level === "notifications" && !this.isNotificationLevelMessage(msg)) {
            return;
          }

          const outbound =
            msg.type === "state"
              ? {
                  ...msg,
                  session: this.ctx.ensureSessionContextWindow(msg.session),
                }
              : msg;

          sendForSession(sessionId, outbound);
        };

        const unsubscribe = this.ctx.sessions.subscribe(sessionId, callback);
        subscriptions.set(sessionId, { level, unsubscribe, subscriptionGeneration });

        sendForSession(sessionId, {
          type: "state",
          session: this.ctx.ensureSessionContextWindow(
            this.ctx.sessions.getActiveSession(sessionId) ?? hydratedSession,
          ),
        });

        if (sinceSeq !== undefined) {
          const catchUp = this.ctx.sessions.getCatchUp(sessionId, sinceSeq);
          if (catchUp) {
            catchUpComplete = catchUp.catchUpComplete;
            for (const event of catchUp.events) {
              sendForSession(sessionId, event);
            }
          }
        }

        const pendingPerms = this.ctx.gate
          .getPendingForUser()
          .filter((p: PendingDecision) => p.sessionId === sessionId);
        pendingPermissionCount = pendingPerms.length;
        for (const pending of pendingPerms) {
          send(buildPermissionMessage(pending));
        }

        // Re-send pending UI requests so iOS can restore user-blocking sheets
        // after reconnects, focus changes, or stream re-subscribe.
        const pendingAskMsg = this.ctx.sessions.getPendingAskMessage(sessionId);
        if (pendingAskMsg) {
          pendingUIRequestCount++;
          send(pendingAskMsg);
        }

        const pendingUIMsgs = this.ctx.sessions.getPendingUIRequestMessages(sessionId);
        pendingUIRequestCount += pendingUIMsgs.length;
        for (const pendingUIMsg of pendingUIMsgs) {
          send(pendingUIMsg);
        }

        const durationMs = Date.now() - subscribeStart;
        metrics?.record("server.session_subscribe_ms", durationMs, {
          level,
          outcome: "success",
          path: "legacy_stream",
          catchup_requested: catchupRequested ? "true" : "false",
          catchup_complete: catchUpComplete ? "true" : "false",
          started_session: startedSession ? "true" : "false",
          pending_permissions: countBucketForTag(pendingPermissionCount),
          pending_ui_requests: countBucketForTag(pendingUIRequestCount),
        });

        send({
          type: "command_result",
          command: "subscribe",
          requestId,
          success: true,
          data: {
            sessionId,
            level,
            currentSeq: this.ctx.sessions.getCurrentSeq(sessionId),
            catchUpComplete,
          },
          sessionId,
        });

        log.info("stream.subscribe.completed", {
          connId,
          sessionId,
          requestId,
          subscribedLevel: level,
          catchUpComplete,
          durationMs,
        });
      } catch (err: unknown) {
        const message = safeErrorMessage(err);
        metrics?.record("server.session_subscribe_ms", Date.now() - subscribeStart, {
          level,
          outcome: "error",
          path: "legacy_stream",
          catchup_requested: catchupRequested ? "true" : "false",
          catchup_complete: catchUpComplete ? "true" : "false",
          started_session: startedSession ? "true" : "false",
          pending_permissions: countBucketForTag(pendingPermissionCount),
          pending_ui_requests: countBucketForTag(pendingUIRequestCount),
        });
        send({
          type: "command_result",
          command: "subscribe",
          requestId,
          success: false,
          error: message,
          sessionId,
        });

        log.warn("stream.subscribe.failed", {
          connId,
          sessionId,
          requestId,
          requestedLevel: level,
          durationMs: Date.now() - subscribeStart,
          error: message,
        });
      }
    };

    // ── Subscribe rate limit ──
    // Prevents a misbehaving client from flooding subscribes and wedging the
    // event loop. Allows short bursts (reconnect re-subscribes tracked sessions)
    // but caps sustained throughput.
    const SUBSCRIBE_RATE_WINDOW_MS = 5_000;
    const SUBSCRIBE_RATE_MAX = 30;
    let subscribeTimestamps: number[] = [];

    const isSubscribeRateLimited = (): boolean => {
      const now = Date.now();
      subscribeTimestamps = subscribeTimestamps.filter((t) => now - t < SUBSCRIBE_RATE_WINDOW_MS);
      if (subscribeTimestamps.length >= SUBSCRIBE_RATE_MAX) {
        return true;
      }
      subscribeTimestamps.push(now);
      return false;
    };

    send(streamConnectedMessage(this.ctx, owner));

    ws.on("message", (data, isBinary) => {
      queue = queue
        .then(async () => {
          msgRecv++;

          if (isBinary) {
            const buffer = toBuffer(data);
            metrics?.record("server.ws_message_received", 1, {
              type: "binary_audio",
              path: "legacy_stream",
            });
            metrics?.record("server.ws_binary_received_bytes", buffer.byteLength, {
              path: "legacy_stream",
            });
            if (this.dictationManager) {
              this.dictationManager.handleAudioData(buffer);
            }
            return;
          }

          if (!firstMessageRecorded && metrics) {
            firstMessageRecorded = true;
            metrics.record("server.ws_first_message_ms", Date.now() - connectedAt, {
              path: "legacy_stream",
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
              });
            } else {
              send({
                type: "error",
                error: parsed.error,
              });
            }
            return;
          }

          const msg = parsed.message;
          metrics?.record("server.ws_message_received", 1, {
            type: msg.type,
            path: "legacy_stream",
          });
          const trace = msg as { requestId?: string; sessionId?: string };
          log.debug("ws.stream_message_received", {
            connId,
            owner,
            messageType: msg.type,
            requestId: trace.requestId,
            sessionId: trace.sessionId,
          });

          switch (msg.type) {
            case "subscribe": {
              if (isSubscribeRateLimited()) {
                log.warn("stream.subscribe.rate_limited", {
                  connId,
                  owner,
                  sessionId: msg.sessionId,
                  requestId: msg.requestId,
                });
                send({
                  type: "command_result",
                  command: "subscribe",
                  requestId: msg.requestId,
                  success: false,
                  error: "Subscribe rate limit exceeded — try again later",
                  sessionId: msg.sessionId,
                });
                break;
              }
              const level = msg.level === "notifications" ? "notifications" : "full";
              await subscribeSession(
                msg.sessionId,
                level,
                msg.requestId,
                msg.sinceSeq,
                msg.subscriptionGeneration,
              );
              break;
            }

            case "unsubscribe": {
              const result = clearSubscription(msg.sessionId, msg.subscriptionGeneration);
              log.info("stream.unsubscribe.completed", {
                connId,
                sessionId: msg.sessionId,
                requestId: msg.requestId,
                subscriptionGeneration: msg.subscriptionGeneration,
                cleared: result.cleared,
                ignoredStale: result.ignoredStale,
              });
              send({
                type: "command_result",
                command: "unsubscribe",
                requestId: msg.requestId,
                success: true,
                data: {
                  sessionId: msg.sessionId,
                  ignoredStale: result.ignoredStale,
                },
                sessionId: msg.sessionId,
              });
              break;
            }

            case "permission_response": {
              const scope = msg.scope || "once";
              const resolved = this.ctx.gate.resolveDecision(
                msg.id,
                msg.action,
                scope,
                msg.expiresInMs,
              );
              if (!resolved) {
                send({ type: "error", error: `Permission request not found: ${msg.id}` });
                return;
              }

              if (msg.requestId) {
                send({
                  type: "command_result",
                  command: "permission_response",
                  requestId: msg.requestId,
                  success: true,
                });
              }
              break;
            }

            case "dictation_start":
            case "dictation_stop":
            case "dictation_cancel":
              if (this.dictationManager) {
                this.dictationManager.handleControlMessage(msg, (dictMsg) => {
                  send(dictMsg as unknown as ServerMessage);
                });
              }
              return;

            default: {
              const targetSessionId = msg.sessionId;
              if (!targetSessionId) {
                send({ type: "error", error: `sessionId is required for ${msg.type} on /stream` });
                return;
              }

              const sub = subscriptions.get(targetSessionId);
              if (!sub || sub.level !== "full") {
                const error = `Session ${targetSessionId} is not subscribed at level=full`;
                send({
                  type: "error",
                  error,
                  code: STREAM_ERROR_NOT_SUBSCRIBED_FULL,
                  sessionId: targetSessionId,
                });

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

              const targetSession = this.ctx.storage.getSession(targetSessionId);
              if (!targetSession) {
                send({ type: "error", error: `Session not found: ${targetSessionId}` });
                return;
              }

              await this.ctx.handleClientMessage(
                targetSession,
                msg,
                (out) => {
                  sendForSession(targetSessionId, out);
                },
                { connId },
              );
              break;
            }
          }
        })
        .catch((err: unknown) => {
          const message = safeErrorMessage(err);
          log.error("ws.stream_message.error", {
            connId,
            error: message,
          });
          send({ type: "error", error: message });
        });
    });

    ws.on("close", (code, reason) => {
      stopPing();
      const reasonStr = reason?.toString() || "";
      const durationMs = Date.now() - connectedAt;

      log.info("ws.stream_disconnected", {
        connId,
        owner,
        code,
        reason: reasonStr || undefined,
        sent: msgSent,
        recv: msgRecv,
        durationMs,
      });

      if (metrics) {
        metrics.record("server.ws_session_duration_ms", durationMs, { path: "legacy_stream" });
        metrics.record("server.ws_messages_sent", msgSent, { path: "legacy_stream" });
        metrics.record("server.ws_messages_received", msgRecv, { path: "legacy_stream" });
        metrics.record("server.ws_close_code", 1, { code: String(code), path: "legacy_stream" });
      }

      this.dictationManager?.handleDisconnect();
      clearAllSubscriptions();
      this.liveConnections.delete(liveConnection);
      this.ctx.untrackConnection(ws);
    });

    ws.on("error", (err) => {
      stopPing();
      log.error("ws.stream.error", {
        connId,
        owner,
        error: safeErrorMessage(err),
      });
      clearAllSubscriptions();
      this.liveConnections.delete(liveConnection);
      this.ctx.untrackConnection(ws);
    });
  }
}

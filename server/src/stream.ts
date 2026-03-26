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

// ─── Types ───

export type StreamSubscriptionLevel = "full" | "notifications";

export interface UserStreamSubscription {
  level: StreamSubscriptionLevel;
  unsubscribe: () => void;
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
  ) => Promise<void>;
  trackConnection: (ws: WebSocket) => void;
  untrackConnection: (ws: WebSocket) => void;
}

// ─── Keepalive ───

/** Default server-side ping interval (seconds). */
const PING_INTERVAL_MS = 30_000;

/** Typed stream error code: command sent for non-full subscription session. */
export const STREAM_ERROR_NOT_SUBSCRIBED_FULL = "stream_not_subscribed_full";

function asRecord(value: unknown): Record<string, unknown> | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, unknown>;
}

function rawDataToText(data: RawData): string {
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
 * Sends a WS ping every `intervalMs`. If a pong is not received before
 * the next ping fires, the connection is terminated — which triggers
 * the `close` event and runs existing cleanup.
 *
 * Returns a cleanup function that stops the timer.
 */
export function startServerPing(
  ws: WebSocket,
  label: string,
  intervalMs = PING_INTERVAL_MS,
  metrics?: ServerMetricCollector,
): () => void {
  let alive = true;
  let lastPingSentAt = 0;

  ws.on("pong", () => {
    alive = true;
    if (lastPingSentAt > 0 && metrics) {
      metrics.record("server.ws_ping_rtt_ms", Date.now() - lastPingSentAt);
    }
  });

  const timer = setInterval(() => {
    if (!alive) {
      metrics?.record("server.ws_ping_timeout", 1);
      console.log("[ws] Ping timeout — terminating", {
        label,
      });
      clearInterval(timer);
      ws.terminate();
      return;
    }
    alive = false;
    lastPingSentAt = Date.now();
    ws.ping();
  }, intervalMs);

  return () => clearInterval(timer);
}

// ─── Stream Mux ───

export class UserStreamMux {
  private streamSeq = 0;
  private streamRing: EventRing | null = null;
  private readonly ringCapacity: number;

  constructor(
    private ctx: StreamContext,
    options?: { ringCapacity?: number },
  ) {
    this.ringCapacity = options?.ringCapacity ?? 2000;
  }

  // ─── Message Classification ───

  isNotificationLevelMessage(msg: ServerMessage): boolean {
    switch (msg.type) {
      case "permission_request":
      case "permission_expired":
      case "permission_cancelled":
      case "agent_start":
      case "agent_end":
      case "state":
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

  recordUserStreamEvent(sessionId: string, msg: ServerMessage): number {
    const streamSeq = this.nextUserStreamSeq();
    const ring = this.getUserStreamRing();

    const event: ServerMessage = {
      ...msg,
      sessionId,
      streamSeq,
    };

    ring.push({ seq: streamSeq, event, timestamp: Date.now() });
    return streamSeq;
  }

  // ─── WebSocket Handler ───

  async handleWebSocket(ws: WebSocket, upgradeReceivedAt?: number): Promise<void> {
    const connectedAt = Date.now();
    const metrics = this.ctx.metrics;

    if (upgradeReceivedAt && metrics) {
      metrics.record("server.ws_handshake_ms", connectedAt - upgradeReceivedAt);
    }

    console.log("[ws] Connected: /stream", {
      owner: this.ctx.storage.getOwnerName(),
    });
    this.ctx.trackConnection(ws);

    const stopPing = startServerPing(
      ws,
      `/stream (${this.ctx.storage.getOwnerName()})`,
      PING_INTERVAL_MS,
      metrics,
    );

    let msgSent = 0;
    let msgRecv = 0;
    let firstMessageRecorded = false;
    const subscriptions = new Map<string, UserStreamSubscription>();
    let queue: Promise<void> = Promise.resolve();

    const send = (msg: ServerMessage): void => {
      if (ws.readyState !== WebSocket.OPEN) {
        console.warn("[ws] Drop message from /stream", {
          messageType: msg.type,
          readyState: ws.readyState,
          owner: this.ctx.storage.getOwnerName(),
        });
        return;
      }

      msgSent++;
      ws.send(JSON.stringify(msg));
    };

    const sendForSession = (sessionId: string, msg: ServerMessage): void => {
      send({ ...msg, sessionId });
    };

    const clearSubscription = (sessionId: string): void => {
      const sub = subscriptions.get(sessionId);
      if (!sub) return;
      sub.unsubscribe();
      subscriptions.delete(sessionId);
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
    ): Promise<void> => {
      const subscribeStart = Date.now();

      if (sinceSeq !== undefined && (!Number.isInteger(sinceSeq) || sinceSeq < 0)) {
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
      if (existing && existing.level === level && sinceSeq === undefined) {
        send({
          type: "command_result",
          command: "subscribe",
          requestId,
          success: true,
          data: {
            sessionId,
            level,
            currentSeq: this.ctx.sessions.getCurrentSeq(sessionId),
            catchUpComplete: true,
            deduplicated: true,
          },
          sessionId,
        });
        return;
      }

      clearSubscription(sessionId);

      try {
        let hydratedSession = this.ctx.ensureSessionContextWindow(session);
        if (level === "full") {
          const subStartMs = Date.now();
          const workspace = this.ctx.resolveWorkspaceForSession(session);
          const started = await this.ctx.sessions.startSession(sessionId, workspace);
          const startSessionMs = Date.now() - subStartMs;
          hydratedSession = this.ctx.ensureSessionContextWindow(started);
          sendForSession(sessionId, {
            type: "connected",
            session: hydratedSession,
            currentSeq: this.ctx.sessions.getCurrentSeq(sessionId),
          });

          const connectedSentMs = Date.now() - subStartMs;
          console.log("[stream] Subscribing to session", {
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
        subscriptions.set(sessionId, { level, unsubscribe });

        sendForSession(sessionId, {
          type: "state",
          session: this.ctx.ensureSessionContextWindow(
            this.ctx.sessions.getActiveSession(sessionId) ?? hydratedSession,
          ),
        });

        let catchUpComplete = true;
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
        for (const pending of pendingPerms) {
          send(buildPermissionMessage(pending));
        }

        // Re-send pending ask request so iOS can restore the AskCard
        const pendingAskMsg = this.ctx.sessions.getPendingAskMessage(sessionId);
        if (pendingAskMsg) {
          send(pendingAskMsg);
        }

        metrics?.record("server.session_subscribe_ms", Date.now() - subscribeStart, {
          level,
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
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        send({
          type: "command_result",
          command: "subscribe",
          requestId,
          success: false,
          error: message,
          sessionId,
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

    send({ type: "stream_connected", userName: this.ctx.storage.getOwnerName() });

    ws.on("message", (data) => {
      queue = queue
        .then(async () => {
          msgRecv++;

          if (!firstMessageRecorded && metrics) {
            firstMessageRecorded = true;
            metrics.record("server.ws_first_message_ms", Date.now() - connectedAt);
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
          console.log("[ws] Received stream message", {
            messageType: msg.type,
            owner: this.ctx.storage.getOwnerName(),
          });

          switch (msg.type) {
            case "subscribe": {
              if (isSubscribeRateLimited()) {
                console.warn("[ws] Subscribe rate limited", {
                  sessionId: msg.sessionId,
                  owner: this.ctx.storage.getOwnerName(),
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
              await subscribeSession(msg.sessionId, level, msg.requestId, msg.sinceSeq);
              break;
            }

            case "unsubscribe": {
              clearSubscription(msg.sessionId);
              send({
                type: "command_result",
                command: "unsubscribe",
                requestId: msg.requestId,
                success: true,
                data: { sessionId: msg.sessionId },
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

              await this.ctx.handleClientMessage(targetSession, msg, (out) => {
                sendForSession(targetSessionId, out);
              });
              break;
            }
          }
        })
        .catch((err: unknown) => {
          const message = err instanceof Error ? err.message : "Unknown error";
          console.error("[ws] Stream message error /stream", {
            message,
          });
          send({ type: "error", error: message });
        });
    });

    ws.on("close", (code, reason) => {
      stopPing();
      const reasonStr = reason?.toString() || "";
      console.log("[ws] Disconnected /stream", {
        owner: this.ctx.storage.getOwnerName(),
        code,
        reason: reasonStr || undefined,
        sent: msgSent,
        recv: msgRecv,
      });

      if (metrics) {
        metrics.record("server.ws_session_duration_ms", Date.now() - connectedAt);
        metrics.record("server.ws_messages_sent", msgSent);
        metrics.record("server.ws_messages_received", msgRecv);
        metrics.record("server.ws_close_code", 1, { code: String(code) });
      }

      clearAllSubscriptions();
      this.ctx.untrackConnection(ws);
    });

    ws.on("error", (err) => {
      stopPing();
      console.error("[ws] Stream error /stream", {
        owner: this.ctx.storage.getOwnerName(),
        error: err,
      });
      clearAllSubscriptions();
      this.ctx.untrackConnection(ws);
    });
  }
}

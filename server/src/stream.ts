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
  trackConnection: (ws: WebSocket) => void;
  untrackConnection: (ws: WebSocket) => void;
  dictationManager?: DictationManager;
}

// ─── Keepalive ───

/** Default server-side ping interval (seconds). */
const PING_INTERVAL_MS = 30_000;

/** Typed stream error code: command sent for non-full subscription session. */
export const STREAM_ERROR_NOT_SUBSCRIBED_FULL = "stream_not_subscribed_full";

const log = createLogger({ base: { component: "stream" } });

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

// ─── Stream Mux ───

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
    for (const connection of this.liveConnections) {
      const sub = connection.subscriptions.get(sessionId);
      if (!sub) continue;
      if (sub.level === "notifications" && !this.isNotificationLevelMessage(event)) continue;
      connection.sendForSession(sessionId, event);
    }
  }

  // ─── WebSocket Handler ───

  async handleWebSocket(ws: WebSocket, upgradeReceivedAt?: number): Promise<void> {
    const connectedAt = Date.now();
    const metrics = this.ctx.metrics;
    const owner = this.ctx.storage.getOwnerName();
    const connId = this.nextConnId();

    if (upgradeReceivedAt && metrics) {
      metrics.record("server.ws_handshake_ms", connectedAt - upgradeReceivedAt);
    }

    log.info("ws.stream_connected", {
      connId,
      owner,
      path: "/stream",
    });
    this.ctx.trackConnection(ws);

    const stopPing = startServerPing(ws, `/stream (${owner})`, PING_INTERVAL_MS, metrics, connId);

    let msgSent = 0;
    let msgRecv = 0;
    let firstMessageRecorded = false;
    const subscriptions = new Map<string, UserStreamSubscription>();
    let queue: Promise<void> = Promise.resolve();

    const send = (msg: ServerMessage): void => {
      if (ws.readyState !== WebSocket.OPEN) {
        log.warn("ws.stream_drop_message", {
          connId,
          messageType: msg.type,
          readyState: ws.readyState,
          owner,
        });
        return;
      }

      msgSent++;
      ws.send(JSON.stringify(msg));
    };

    const sendForSession = (sessionId: string, msg: ServerMessage): void => {
      send({ ...msg, sessionId });
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

    send({
      type: "stream_connected",
      userName: owner,
      ...(this.dictationManager ? { asrAvailable: true } : {}),
    });

    ws.on("message", (data, isBinary) => {
      queue = queue
        .then(async () => {
          msgRecv++;

          if (isBinary) {
            if (this.dictationManager) {
              this.dictationManager.handleAudioData(toBuffer(data));
            }
            return;
          }

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
        metrics.record("server.ws_session_duration_ms", durationMs);
        metrics.record("server.ws_messages_sent", msgSent);
        metrics.record("server.ws_messages_received", msgRecv);
        metrics.record("server.ws_close_code", 1, { code: String(code) });
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

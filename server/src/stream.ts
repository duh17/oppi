/**
 * User stream multiplexer.
 *
 * Manages per-user WebSocket connections for the multiplexed /stream endpoint.
 * Handles subscribe/unsubscribe, event ring replay, backpressure, and
 * notification-level filtering.
 */

import { WebSocket } from "ws";
import { EventRing } from "./event-ring.js";
import type { SessionManager } from "./sessions.js";
import type { GateServer, PendingDecision } from "./gate.js";
import type { Storage } from "./storage.js";
import type { ClientMessage, ServerMessage, Session, Workspace } from "./types.js";

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

function ts(): string {
  return new Date().toISOString().replace("T", " ").slice(0, 23);
}

const STREAM_MAX_BUFFERED_BYTES = 64 * 1024;

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
      case "stop_requested":
      case "stop_confirmed":
      case "stop_failed":
      case "error":
        return true;
      default:
        return false;
    }
  }

  isBackpressureDroppable(msg: ServerMessage): boolean {
    switch (msg.type) {
      case "text_delta":
      case "thinking_delta":
      case "tool_output":
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

  getUserStreamCatchUp(
    sinceSeq: number,
  ): {
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
        throw new Error(
          `Invalid stream replay ordering: expected > ${expected}, got ${seq}`,
        );
      }
      expected = seq;
    }

    return {
      events,
      currentSeq: this.streamSeq || ring.currentSeq,
      catchUpComplete,
    };
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

  async handleWebSocket(ws: WebSocket): Promise<void> {
    console.log(`${ts()} [ws] Connected: ${this.ctx.storage.getOwnerName()} → /stream`);
    this.ctx.trackConnection(ws);

    let msgSent = 0;
    let msgRecv = 0;
    const subscriptions = new Map<string, UserStreamSubscription>();
    let fullSessionId: string | null = null;
    let queue: Promise<void> = Promise.resolve();

    const send = (msg: ServerMessage): void => {
      if (ws.readyState !== WebSocket.OPEN) {
        console.warn(`${ts()} [ws] DROP ${msg.type} → /stream (readyState=${ws.readyState})`);
        return;
      }

      if (ws.bufferedAmount > STREAM_MAX_BUFFERED_BYTES && this.isBackpressureDroppable(msg)) {
        const scope = msg.sessionId ? ` session=${msg.sessionId}` : "";
        console.warn(
          `${ts()} [ws] DROP ${msg.type} → /stream (backpressure buffered=${ws.bufferedAmount}${scope})`,
        );
        return;
      }

      msgSent++;
      ws.send(JSON.stringify(msg), { compress: false });
    };

    const sendForSession = (sessionId: string, msg: ServerMessage): void => {
      send({ ...msg, sessionId });
    };

    const clearSubscription = (sessionId: string): void => {
      const sub = subscriptions.get(sessionId);
      if (!sub) return;
      sub.unsubscribe();
      subscriptions.delete(sessionId);
      if (fullSessionId === sessionId) {
        fullSessionId = null;
      }
    };

    const clearAllSubscriptions = (): void => {
      for (const [sessionId, sub] of subscriptions) {
        sub.unsubscribe();
        if (fullSessionId === sessionId) {
          fullSessionId = null;
        }
      }
      subscriptions.clear();
    };

    const subscribeSession = async (
      sessionId: string,
      level: StreamSubscriptionLevel,
      requestId?: string,
      sinceSeq?: number,
    ): Promise<void> => {
      if (sinceSeq !== undefined && (!Number.isInteger(sinceSeq) || sinceSeq < 0)) {
        send({
          type: "rpc_result",
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
          type: "rpc_result",
          command: "subscribe",
          requestId,
          success: false,
          error: `Session not found: ${sessionId}`,
          sessionId,
        });
        return;
      }

      if (level === "full" && fullSessionId && fullSessionId !== sessionId) {
        const prior = subscriptions.get(fullSessionId);
        if (prior) {
          prior.level = "notifications";
        }
      }

      clearSubscription(sessionId);

      try {
        let hydratedSession = this.ctx.ensureSessionContextWindow(session);
        if (level === "full") {
          const workspace = this.ctx.resolveWorkspaceForSession(session);
          const started = await this.ctx.sessions.startSession(
            sessionId,
            this.ctx.storage.getOwnerName(),
            workspace,
          );
          hydratedSession = this.ctx.ensureSessionContextWindow(started);
          fullSessionId = sessionId;

          sendForSession(sessionId, {
            type: "connected",
            session: hydratedSession,
            currentSeq: this.ctx.sessions.getCurrentSeq(sessionId),
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

          sendForSession(sessionId, msg);
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
          send({
            type: "permission_request",
            id: pending.id,
            sessionId: pending.sessionId,
            tool: pending.tool,
            input: pending.input,
            displaySummary: pending.displaySummary,
            reason: pending.reason,
            timeoutAt: pending.timeoutAt,
            expires: pending.expires ?? true,
            resolutionOptions: pending.resolutionOptions,
          });
        }

        send({
          type: "rpc_result",
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
          type: "rpc_result",
          command: "subscribe",
          requestId,
          success: false,
          error: message,
          sessionId,
        });
      }
    };

    send({ type: "stream_connected", userName: this.ctx.storage.getOwnerName() });

    ws.on("message", (data) => {
      queue = queue
        .then(async () => {
          const msg = JSON.parse(data.toString()) as ClientMessage;
          msgRecv++;
          console.log(`${ts()} [ws] RECV ${msg.type} from ${this.ctx.storage.getOwnerName()} → /stream`);

          switch (msg.type) {
            case "subscribe": {
              const level = msg.level === "notifications" ? "notifications" : "full";
              await subscribeSession(msg.sessionId, level, msg.requestId, msg.sinceSeq);
              break;
            }

            case "unsubscribe": {
              clearSubscription(msg.sessionId);
              send({
                type: "rpc_result",
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
              const resolved = this.ctx.gate.resolveDecision(msg.id, msg.action, scope, msg.expiresInMs);
              if (!resolved) {
                send({ type: "error", error: `Permission request not found: ${msg.id}` });
                return;
              }

              if (msg.requestId) {
                send({
                  type: "rpc_result",
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
                send({
                  type: "error",
                  error: `Session ${targetSessionId} is not subscribed at level=full`,
                  sessionId: targetSessionId,
                });
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
          console.error(`${ts()} [ws] MSG ERROR /stream: ${message}`);
          send({ type: "error", error: message });
        });
    });

    ws.on("close", (code, reason) => {
      const reasonStr = reason?.toString() || "";
      console.log(
        `${ts()} [ws] Disconnected: ${this.ctx.storage.getOwnerName()} → /stream (code=${code}${reasonStr ? ` reason=${reasonStr}` : ""}, sent=${msgSent} recv=${msgRecv})`,
      );
      clearAllSubscriptions();
      this.ctx.untrackConnection(ws);
    });

    ws.on("error", (err) => {
      console.error(`${ts()} [ws] Error: ${this.ctx.storage.getOwnerName()} → /stream:`, err);
      clearAllSubscriptions();
      this.ctx.untrackConnection(ws);
    });
  }
}

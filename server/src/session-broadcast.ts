import type { EventRing } from "./event-ring.js";
import type { Session, ServerMessage } from "./types.js";

export interface SessionCatchUpResponse {
  events: ServerMessage[];
  currentSeq: number;
  session: Session;
  catchUpComplete: boolean;
}

export interface SessionBroadcastEvent {
  sessionId: string;
  event: ServerMessage;
  durable: boolean;
}

export interface BroadcastSessionState {
  session: Session;
  subscribers: Set<(msg: ServerMessage) => void>;
  seq: number;
  eventRing: EventRing;
}

export interface SessionBroadcasterDeps {
  getActiveSession: (key: string) => BroadcastSessionState | undefined;
  emitSessionEvent: (payload: SessionBroadcastEvent) => void;
  saveSession: (session: Session) => void;
}

export class SessionBroadcaster {
  private static readonly DURABLE_MESSAGE_TYPES = new Set<ServerMessage["type"]>([
    "agent_start",
    "agent_end",
    "message_end",
    "tool_start",
    "tool_end",
    "permission_request",
    "permission_expired",
    "permission_cancelled",
    "stop_requested",
    "stop_confirmed",
    "stop_failed",
    "session_ended",
    "session_deleted",
    "error",
  ]);

  private dirtySessions: Set<string> = new Set();
  private saveTimer: NodeJS.Timeout | null = null;

  constructor(
    private readonly deps: SessionBroadcasterDeps,
    private readonly saveDebounceMs = 1000,
  ) {}

  subscribe(key: string, callback: (msg: ServerMessage) => void): () => void {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      return () => {};
    }

    active.subscribers.add(callback);
    return () => active.subscribers.delete(callback);
  }

  getCurrentSeq(key: string): number {
    const active = this.deps.getActiveSession(key);
    return active?.seq ?? 0;
  }

  getCatchUp(key: string, sinceSeq: number): SessionCatchUpResponse | null {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      return null;
    }

    const canServe = active.eventRing.canServe(sinceSeq);
    const events = canServe ? active.eventRing.since(sinceSeq).map((entry) => entry.event) : [];

    return {
      events,
      currentSeq: active.seq,
      session: active.session,
      catchUpComplete: canServe,
    };
  }

  broadcast(key: string, message: ServerMessage): void {
    if (SessionBroadcaster.DURABLE_MESSAGE_TYPES.has(message.type)) {
      this.broadcastDurable(key, message);
      return;
    }

    this.broadcastEphemeral(key, message);
  }

  markSessionDirty(key: string): void {
    this.dirtySessions.add(key);

    if (this.saveTimer) {
      return;
    }

    this.saveTimer = setTimeout(() => {
      this.flushDirtySessions();
    }, this.saveDebounceMs);
  }

  flushDirtySessions(): void {
    const keys = Array.from(this.dirtySessions);
    this.dirtySessions.clear();
    this.saveTimer = null;

    for (const key of keys) {
      const active = this.deps.getActiveSession(key);
      if (!active) {
        continue;
      }

      this.deps.saveSession(active.session);
    }
  }

  persistSessionNow(key: string, session: Session): void {
    this.dirtySessions.delete(key);
    this.deps.saveSession(session);
  }

  private broadcastDurable(key: string, message: ServerMessage): void {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      return;
    }

    active.seq += 1;
    const sequenced: ServerMessage = { ...message, seq: active.seq };

    active.eventRing.push({
      seq: active.seq,
      event: sequenced,
      timestamp: Date.now(),
    });

    this.deps.emitSessionEvent({
      sessionId: active.session.id,
      event: sequenced,
      durable: true,
    });

    for (const cb of active.subscribers) {
      try {
        cb(sequenced);
      } catch (err) {
        console.error("Subscriber error:", err);
      }
    }
  }

  private broadcastEphemeral(key: string, message: ServerMessage): void {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      return;
    }

    // Only emit low-frequency ephemeral events to global observers.
    // High-frequency deltas (text/thinking/tool_output) should not fan out
    // through EventEmitter to avoid hot-path overhead.
    if (message.type === "state") {
      this.deps.emitSessionEvent({
        sessionId: active.session.id,
        event: message,
        durable: false,
      });
    }

    for (const cb of active.subscribers) {
      try {
        cb(message);
      } catch (err) {
        console.error("Subscriber error:", err);
      }
    }
  }
}

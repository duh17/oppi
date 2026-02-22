/**
 * Live Activity bridge — debounced APNs push updates for iOS Live Activities.
 *
 * Translates session lifecycle events into coalesced Live Activity content
 * state updates. Debounces rapid-fire events (750ms) and handles end-of-session
 * teardown.
 */

import type { PushClient } from "./push.js";
import type { Storage } from "./storage.js";
import type { GateServer } from "./gate.js";
import type { Session } from "./types.js";
import type { SessionBroadcastEvent } from "./sessions.js";

// ─── Types ───

type LiveActivityStatus = "busy" | "stopping" | "ready" | "stopped" | "error";

interface LiveActivityContentState {
  status: LiveActivityStatus;
  activeTool: string | null;
  pendingPermissions: number;
  lastEvent: string | null;
  elapsedSeconds: number;
}

interface PendingLiveActivityUpdate {
  sessionId?: string;
  status?: LiveActivityStatus;
  activeTool?: string | null;
  lastEvent?: string | null;
  end?: boolean;
  priority?: 5 | 10;
}

// ─── LiveActivityBridge ───

export class LiveActivityBridge {
  private timer: NodeJS.Timeout | null = null;
  private pending: PendingLiveActivityUpdate | null = null;
  private readonly debounceMs = 750;

  constructor(
    private push: PushClient,
    private storage: Storage,
    private gate: GateServer,
  ) {}

  /** Handle a session broadcast event and queue a Live Activity update. */
  handleSessionEvent(payload: SessionBroadcastEvent): void {
    const { event, sessionId } = payload;

    switch (event.type) {
      case "state":
        this.queue({
          sessionId,
          status: this.mapStatus(event.session.status),
          lastEvent: this.statusLabel(event.session.status),
          priority: 5,
        });
        return;
      case "agent_start":
        this.queue({ sessionId, status: "busy", lastEvent: "Agent started", priority: 5 });
        return;
      case "agent_end":
        this.queue({
          sessionId,
          status: "ready",
          activeTool: null,
          lastEvent: "Agent finished",
          priority: 5,
        });
        return;
      case "tool_start":
        this.queue({
          sessionId,
          status: "busy",
          activeTool: event.tool,
          lastEvent: event.tool,
          priority: 5,
        });
        return;
      case "tool_end":
        this.queue({ sessionId, activeTool: null, priority: 5 });
        return;
      case "stop_requested":
        this.queue({ sessionId, status: "stopping", lastEvent: "Stopping", priority: 5 });
        return;
      case "stop_confirmed":
        this.queue({
          sessionId,
          status: "ready",
          activeTool: null,
          lastEvent: "Stop confirmed",
          priority: 5,
        });
        return;
      case "stop_failed":
        this.queue({ sessionId, status: "error", lastEvent: "Stop failed", priority: 10 });
        return;
      case "permission_request":
        this.queue({ sessionId, lastEvent: "Permission required", priority: 10 });
        return;
      case "permission_expired":
        this.queue({ sessionId, lastEvent: "Permission expired", priority: 5 });
        return;
      case "permission_cancelled":
        this.queue({ sessionId, lastEvent: "Permission resolved", priority: 5 });
        return;
      case "error":
        if (!event.error.startsWith("Retrying (")) {
          this.queue({ sessionId, status: "error", lastEvent: "Error", priority: 10 });
        }
        return;
      case "session_ended":
        this.queue({
          sessionId,
          status: "stopped",
          activeTool: null,
          lastEvent: event.reason,
          end: true,
          priority: 5,
        });
        return;
      default:
        return;
    }
  }

  /** Queue a Live Activity update from gate events (approval timeout/resolved). */
  queueUpdate(update: PendingLiveActivityUpdate): void {
    this.queue(update);
  }

  /** Stop the debounce timer and clear pending state. */
  shutdown(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.pending = null;
  }

  // ─── Private ───

  private queue(update: PendingLiveActivityUpdate): void {
    const current = this.pending ?? {};
    const merged: PendingLiveActivityUpdate = {
      sessionId: update.sessionId ?? current.sessionId,
      status: update.status ?? current.status,
      activeTool: update.activeTool !== undefined ? update.activeTool : current.activeTool,
      lastEvent: update.lastEvent !== undefined ? update.lastEvent : current.lastEvent,
      end: Boolean(current.end || update.end),
      priority: Math.max(current.priority ?? 5, update.priority ?? 5) as 5 | 10,
    };

    this.pending = merged;

    if (this.timer) {
      return;
    }

    const timer = setTimeout(() => this.flush(), this.debounceMs);
    this.timer = timer;
  }

  private flush(): void {
    const timer = this.timer;
    if (timer) {
      clearTimeout(timer);
      this.timer = null;
    }

    const pending = this.pending;
    if (!pending) {
      return;
    }
    this.pending = null;

    const token = this.storage.getLiveActivityToken();
    if (!token) {
      return;
    }

    const contentState = this.buildContentState(pending);
    const payload: Record<string, unknown> = { ...contentState };

    if (pending.end) {
      void this.push
        .endLiveActivity(token, payload, undefined, pending.priority ?? 10)
        .then((ok) => {
          if (ok) {
            this.storage.setLiveActivityToken(null);
          }
        });
      return;
    }

    const staleDate = Date.now() + 2 * 60 * 1000;
    void this.push.sendLiveActivityUpdate(token, payload, staleDate, pending.priority ?? 5);
  }

  private buildContentState(pending: PendingLiveActivityUpdate): LiveActivityContentState {
    const session = pending.sessionId
      ? this.findSessionById(pending.sessionId)
      : this.findPrimarySession();

    const now = Date.now();
    const elapsedSeconds = session ? Math.max(0, Math.floor((now - session.createdAt) / 1000)) : 0;

    return {
      status: pending.status ?? this.mapStatus(session?.status),
      activeTool: pending.activeTool ?? null,
      pendingPermissions: this.gate.getPendingForUser().length,
      lastEvent: pending.lastEvent ?? null,
      elapsedSeconds,
    };
  }

  private findSessionById(sessionId: string): Session | undefined {
    const sessions = this.storage.listSessions();
    return sessions.find((s) => s.id === sessionId);
  }

  private findPrimarySession(): Session | undefined {
    const sessions = this.storage.listSessions();
    if (sessions.length === 0) {
      return undefined;
    }

    const score = (status: Session["status"]): number => {
      switch (status) {
        case "busy":
          return 5;
        case "stopping":
          return 4;
        case "ready":
          return 3;
        case "starting":
          return 2;
        case "error":
          return 1;
        case "stopped":
          return 0;
      }
    };

    return sessions.slice().sort((a, b) => {
      const priority = score(b.status) - score(a.status);
      if (priority !== 0) {
        return priority;
      }
      return b.lastActivity - a.lastActivity;
    })[0];
  }

  private mapStatus(status: Session["status"] | undefined): LiveActivityStatus {
    switch (status) {
      case "busy":
        return "busy";
      case "stopping":
        return "stopping";
      case "stopped":
        return "stopped";
      case "error":
        return "error";
      case "ready":
      case "starting":
      default:
        return "ready";
    }
  }

  private statusLabel(status: Session["status"]): string {
    switch (status) {
      case "busy":
        return "Working";
      case "stopping":
        return "Stopping";
      case "ready":
        return "Ready";
      case "starting":
        return "Starting";
      case "stopped":
        return "Session ended";
      case "error":
        return "Error";
    }
  }
}

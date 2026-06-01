import type { ExtensionUIRequest } from "./session-events.js";
import type { PendingStop, StopSessionState } from "./session-stop.js";
import type { SdkBackend } from "./sdk-backend.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import type { Session, ServerMessage } from "./types.js";
import { createLogger } from "./logger.js";

export interface SessionLifecycleSessionState {
  session: Session;
  sdkBackend: SdkBackend;
  workspaceId: string;
  pendingUIRequests: Map<string, ExtensionUIRequest>;
  /** Output tokens when this activation started. Used to detect new work vs. prior-life tokens. */
  outputTokensAtStart: number;
}

export interface SessionLifecycleCoordinatorDeps {
  getActiveSession: (key: string) => SessionLifecycleSessionState | undefined;
  removeActiveSession: (key: string) => void;
  clearPendingStop: (active: StopSessionState) => PendingStop | null;
  broadcast: (key: string, message: ServerMessage) => void;
  persistSessionNow: (key: string, session: Session) => void;
  releaseSession: (identity: { workspaceId: string; sessionId: string }) => void;
  stopSession: (sessionId: string) => Promise<void>;
  getSessionIdleTimeoutMs: () => number;
  /** Whether children automatically stop after completing work. */
  getChildAutoStopWhenDone: () => boolean;
  /** Grace period (ms) for a child that hasn't produced output yet. */
  getChildStartupGraceMs: () => number;
  /** Idle timeout (ms) for a child that completed work (when autoStopWhenDone is false). */
  getChildIdleTimeoutMs: () => number;
  hasActiveChildren: (sessionId: string) => boolean;
  metrics?: ServerMetricCollector;
}

const log = createLogger({ base: { component: "session_lifecycle" } });

export class SessionLifecycleCoordinator {
  private idleTimers: Map<string, NodeJS.Timeout> = new Map();
  /** Keys pending idle-timeout stop — consumed in handleSessionEnd to tag the metric. */
  private pendingIdleTimeoutKeys: Set<string> = new Set();

  constructor(private readonly deps: SessionLifecycleCoordinatorDeps) {}

  async handleSessionEnd(key: string, reason: string): Promise<void> {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      return;
    }

    const isIdleTimeout = this.pendingIdleTimeoutKeys.delete(key);
    const metricReason = isIdleTimeout ? "idle_timeout" : normalizeEndReason(reason);
    this.deps.metrics?.record("server.session_end", 1, { reason: metricReason });

    const pendingStop = this.deps.clearPendingStop(active as StopSessionState);
    if (pendingStop?.mode === "terminate") {
      this.deps.broadcast(key, {
        type: "stop_confirmed",
        source: pendingStop.source,
        reason: "Session terminated",
      });
    } else if (pendingStop?.mode === "abort") {
      this.deps.broadcast(key, {
        type: "stop_failed",
        source: "server",
        reason: `Session ended before stop completed (${reason})`,
      });
    }

    active.session.status = "stopped";
    active.session.currentTurnStartedAt = undefined;
    this.deps.persistSessionNow(key, active.session);

    if (active.session.parentSessionId) {
      this.deps.broadcast(active.session.parentSessionId, {
        type: "state",
        session: active.session,
      });
    }

    active.pendingUIRequests.clear();

    if (!active.sdkBackend.isDisposed) {
      await active.sdkBackend.dispose();
    }

    this.deps.broadcast(key, { type: "session_ended", reason });
    this.clearIdleTimer(key);
    this.deps.removeActiveSession(key);

    this.deps.releaseSession({
      workspaceId: active.workspaceId,
      sessionId: active.session.id,
    });
  }

  resetIdleTimer(key: string): void {
    this.clearIdleTimer(key);

    // Auto-stop child sessions after they complete their work.
    // Children are ephemeral — they do one task and exit.
    // Give a grace period so the prompt has time to dispatch (especially
    // in sandbox mode where VM boot adds latency before the first turn).
    const active = this.deps.getActiveSession(key);
    if (active?.session.parentSessionId && active.session.status === "ready") {
      // Has the child produced NEW LLM output since this activation started?
      // Compare against outputTokensAtStart to distinguish fresh work from
      // tokens inherited from a previous activation (i.e. before stop+resume).
      // messageCount alone is unreliable — sendPrompt increments it before the
      // SDK processes the prompt, so a resetIdleTimer call from sendCommand
      // sees messageCount > 0 while the agent hasn't started yet.
      const hasCompletedWork = active.session.tokens.output > active.outputTokensAtStart;

      if (hasCompletedWork && this.deps.getChildAutoStopWhenDone()) {
        log.info("session_lifecycle.child_auto_stop_when_done", {
          sessionId: active.session.id,
          parentSessionId: active.session.parentSessionId,
        });
        this.pendingIdleTimeoutKeys.add(key);
        setTimeout(() => {
          void this.deps.stopSession(active.session.id);
        }, 0);
        return;
      }

      // If auto-stop is disabled and work is done, use childIdleTimeoutMs
      // (typically matches prompt-cache TTL) so follow-ups reuse cached context.
      if (hasCompletedWork) {
        const childIdleMs = this.deps.getChildIdleTimeoutMs();
        const timer = setTimeout(() => {
          const current = this.deps.getActiveSession(key);
          if (current?.session.parentSessionId && current.session.status === "ready") {
            log.info("session_lifecycle.child_idle_timeout_post_work", {
              sessionId: current.session.id,
              parentSessionId: current.session.parentSessionId,
              timeoutMs: childIdleMs,
            });
            this.pendingIdleTimeoutKeys.add(key);
            void this.deps.stopSession(current.session.id);
          }
        }, childIdleMs);
        this.idleTimers.set(key, timer);
        return;
      } else {
        // Child hasn't produced output yet — either still initializing,
        // waiting for the LLM, or in sandbox VM boot. Give it time.
        const graceMs = this.deps.getChildStartupGraceMs();
        const timer = setTimeout(() => {
          const current = this.deps.getActiveSession(key);
          if (current?.session.parentSessionId && current.session.status === "ready") {
            log.info("session_lifecycle.child_startup_grace_expired", {
              sessionId: current.session.id,
              parentSessionId: current.session.parentSessionId,
              timeoutMs: graceMs,
            });
            this.pendingIdleTimeoutKeys.add(key);
            void this.deps.stopSession(current.session.id);
          }
        }, graceMs);
        this.idleTimers.set(key, timer);
        return;
      }
    }

    const timeoutMs = this.deps.getSessionIdleTimeoutMs();
    const timer = setTimeout(() => {
      const active = this.deps.getActiveSession(key);
      if (!active) {
        return;
      }

      // Don't idle-stop a parent while any of its children are still active.
      // The parent needs to stay alive to receive child results and coordinate.
      if (this.deps.hasActiveChildren(active.session.id)) {
        log.info("session_lifecycle.idle_timeout_deferred_active_children", {
          sessionId: active.session.id,
        });
        // Re-arm the timer so we check again later.
        this.resetIdleTimer(key);
        return;
      }

      log.info("session_lifecycle.idle_timeout", {
        sessionId: active.session.id,
        key,
        timeoutMs,
      });
      this.pendingIdleTimeoutKeys.add(key);
      void this.deps.stopSession(active.session.id);
    }, timeoutMs);

    this.idleTimers.set(key, timer);
  }

  clearIdleTimer(key: string): void {
    const timer = this.idleTimers.get(key);
    if (timer) {
      clearTimeout(timer);
      this.idleTimers.delete(key);
    }
  }
}

/** Map SDK/server reason strings to metric tag values. */
function normalizeEndReason(reason: string): string {
  const lower = reason.toLowerCase();
  if (lower === "completed" || lower === "done") return "completed";
  if (lower === "stopped" || lower === "terminated") return "stopped";
  if (lower.includes("error")) return "error";
  return reason;
}

import { clearExtensionUIState, type ExtensionUIState } from "./extension-ui-state.js";
import type { PendingStop, PendingStopSessionState } from "./session-stop.js";
import type { AgentBackend } from "./agent-backend.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import { isPendingUserReplyRequest } from "./session-attention.js";
import type { Session, ServerMessage } from "./types.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";

export interface SessionLifecycleSessionState extends ExtensionUIState {
  session: Session;
  sdkBackend: AgentBackend;
  pendingStop?: PendingStop;
  workspaceId: string;
}

export interface SessionLifecycleCoordinatorDeps {
  getActiveSession: (key: string) => SessionLifecycleSessionState | undefined;
  removeActiveSession: (key: string) => void;
  clearPendingStop: (active: PendingStopSessionState) => PendingStop | null;
  broadcast: (key: string, message: ServerMessage) => void;
  persistSessionNow: (key: string, session: Session) => void;
  releaseSession: (identity: { workspaceId: string; sessionId: string }) => void;
  stopSession: (sessionId: string) => Promise<void>;
  /**
   * Auto-stop's Stop: decides again under the session lock with `guard` (and work announced
   * for the session, which keeps it), then stops. True when it began stopping the session.
   */
  autoStopSession: (sessionId: string, guard: AutoStopGuard) => Promise<boolean>;
  getSessionIdleTimeoutMs: () => number;
  metrics?: ServerMetricCollector;
}

/** What auto-stop's locked recheck asks of the session. */
export interface AutoStopGuard {
  /** Nothing keeps it: no live run or queued input in its backend, and no pending wake. */
  idle(): Promise<boolean>;
  /** Still the settled, ready session the decision was made for, with no reply dialog. */
  still(): boolean;
}

const log = createLogger({ base: { component: "session_lifecycle" } });

export class SessionLifecycleCoordinator {
  private idleTimers: Map<string, NodeJS.Timeout> = new Map();
  /** Keys pending idle-timeout stop — consumed in handleSessionEnd to tag the metric. */
  private pendingIdleTimeoutKeys: Set<string> = new Set();
  /** The newest auto-stop decision per session; a newer settle or the session's end replaces it. */
  private autoStopChecks: Map<string, object> = new Map();

  constructor(private readonly deps: SessionLifecycleCoordinatorDeps) {}

  async handleSessionEnd(
    key: string,
    reason: string,
    stopConfirmationReason?: string,
  ): Promise<void> {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      return;
    }

    const isIdleTimeout = this.pendingIdleTimeoutKeys.delete(key);
    const metricReason = isIdleTimeout ? "idle_timeout" : normalizeEndReason(reason);
    this.deps.metrics?.record("server.session_end", 1, { reason: metricReason });

    const failures: Array<{ phase: string; message: string }> = [];
    const recordFailure = (phase: string, error: unknown): void => {
      const message = safeErrorMessage(error);
      failures.push({ phase, message });
      log.error(`session_lifecycle.${phase}.failed`, {
        sessionId: active.session.id,
        workspaceId: active.workspaceId,
        reason,
        attemptedStatus: "stopped",
        durableRecovery:
          active.pendingStop?.mode === "terminate"
            ? "persisted_stopping_marker_retry_stop"
            : "retry_terminal_persistence",
        error: message,
      });
    };

    active.session.status = "stopped";
    active.session.currentTurnStartedAt = undefined;
    try {
      // A terminate request persists `stopping` before backend cleanup. If this
      // final write fails, that durable marker remains retryable while runtime
      // ownership is still detached below.
      this.deps.persistSessionNow(key, active.session);
    } catch (error) {
      recordFailure("final_persistence", error);
    }

    try {
      clearExtensionUIState(active);
    } catch (error) {
      recordFailure("extension_ui_cleanup", error);
    }

    if (!active.sdkBackend.isDisposed) {
      try {
        await active.sdkBackend.dispose();
      } catch (error) {
        recordFailure("backend_disposal", error);
      }
    }

    this.clearIdleTimer(key);
    this.autoStopChecks.delete(key);
    try {
      this.deps.releaseSession({
        workspaceId: active.workspaceId,
        sessionId: active.session.id,
      });
    } catch (error) {
      recordFailure("workspace_release", error);
    }

    const pendingStop = this.deps.clearPendingStop(active);
    try {
      if (pendingStop?.mode === "terminate") {
        const persistenceFailure = failures.find(
          (failure) => failure.phase === "final_persistence",
        );
        if (persistenceFailure) {
          this.deps.broadcast(key, {
            type: "stop_failed",
            source: "server",
            reason: `Failed to persist stopped session: ${persistenceFailure.message}`,
          });
        } else if (failures.length > 0) {
          const failure = failures[0];
          this.deps.broadcast(key, {
            type: "stop_failed",
            source: "server",
            reason: `Failed to finalize stopped session (${failure?.phase}): ${failure?.message}`,
          });
        } else {
          this.deps.broadcast(key, {
            type: "stop_confirmed",
            source: pendingStop.source,
            reason: stopConfirmationReason || "Session terminated",
          });
        }
      } else if (pendingStop?.mode === "abort") {
        this.deps.broadcast(key, {
          type: "stop_failed",
          source: "server",
          reason: `Session ended before stop completed (${reason})`,
        });
      }

      this.deps.broadcast(key, { type: "session_ended", reason });
    } finally {
      // Active ownership is the final in-memory teardown step because terminal
      // events need the active broadcaster state. Never let persistence,
      // disposal, or observer failures strand that ownership.
      this.deps.removeActiveSession(key);
    }
  }

  handleSessionSettled(key: string): void {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      return;
    }

    // Auto-stop sessions keep the idle timeout too: one attached again for work that never
    // comes, or held for a wake that ends without a turn, still stops.
    this.resetIdleTimer(key);
    if (active.session.launch?.autoStop !== true) {
      return;
    }
    if (active.session.status !== "ready" || hasPendingUserReplyDialog(active)) {
      return;
    }

    const check = {};
    this.autoStopChecks.set(key, check);
    void this.autoStop(key, active, check);
  }

  private async autoStop(
    key: string,
    active: SessionLifecycleSessionState,
    check: object,
  ): Promise<void> {
    // A newer settle or the session's end replaced this decision.
    const current = (): boolean =>
      this.autoStopChecks.get(key) === check && this.deps.getActiveSession(key) === active;
    // A running background job or a supervised child wakes this session when it finishes.
    // Stopping now would kill that job or drop the child's report: the turn its wake starts
    // settles again and decides then.
    let pendingWake: boolean;
    try {
      pendingWake = await active.sdkBackend.hasPendingWake();
    } catch (error) {
      // Kept; the idle timeout decides later.
      log.warn("session_lifecycle.auto_stop.pending_wake_check_failed", {
        sessionId: active.session.id,
        key,
        error: safeErrorMessage(error),
      });
      return;
    }
    if (!current()) {
      return;
    }
    if (pendingWake) {
      this.autoStopChecks.delete(key);
      log.info("session_lifecycle.auto_stop.held_for_pending_wake", {
        sessionId: active.session.id,
        key,
      });
      return;
    }

    // Events trail the backend (a durable store commits input before the session sees its
    // run start), so the locked recheck reads the backend, not only the projected status.
    let stopping: boolean;
    try {
      stopping = await this.deps.autoStopSession(active.session.id, {
        idle: async () =>
          !(await active.sdkBackend.hasPendingWork()) &&
          !(await active.sdkBackend.hasPendingWake()),
        still: () =>
          current() && active.session.status === "ready" && !hasPendingUserReplyDialog(active),
      });
    } catch (error) {
      log.error("session_lifecycle.stop_session.failed", {
        sessionId: active.session.id,
        error: safeErrorMessage(error),
      });
      return;
    }
    log.info("session_lifecycle.auto_stop", {
      sessionId: active.session.id,
      key,
      outcome: stopping ? "stopping" : "kept",
    });
  }

  resetIdleTimer(key: string): void {
    this.clearIdleTimer(key);

    const timeoutMs = this.deps.getSessionIdleTimeoutMs();
    const timer = setTimeout(() => {
      void this.expireIdle(key, timer, timeoutMs);
    }, timeoutMs);

    this.idleTimers.set(key, timer);
  }

  private async expireIdle(key: string, timer: NodeJS.Timeout, timeoutMs: number): Promise<void> {
    const idleActive = this.deps.getActiveSession(key);
    if (!idleActive) {
      return;
    }

    if (hasPendingUserReplyDialog(idleActive)) {
      log.info("session_lifecycle.idle_timeout.held_for_dialog", {
        sessionId: idleActive.session.id,
        key,
        timeoutMs,
      });
      this.resetIdleTimer(key);
      return;
    }

    // A running background job or a supervised child wakes this session when it
    // finishes. Stopping now would kill that job or drop the child's report.
    let pendingWake = false;
    try {
      pendingWake = await idleActive.sdkBackend.hasPendingWake();
    } catch (error) {
      log.warn("session_lifecycle.idle_timeout.pending_wake_check_failed", {
        sessionId: idleActive.session.id,
        key,
        error: safeErrorMessage(error),
      });
    }
    // Input, a stop, or a new turn while the check ran replaced or cleared this timer.
    if (this.idleTimers.get(key) !== timer || this.deps.getActiveSession(key) !== idleActive) {
      return;
    }
    if (pendingWake) {
      log.info("session_lifecycle.idle_timeout.held_for_pending_wake", {
        sessionId: idleActive.session.id,
        key,
        timeoutMs,
      });
      this.resetIdleTimer(key);
      return;
    }

    log.info("session_lifecycle.idle_timeout", {
      sessionId: idleActive.session.id,
      key,
      timeoutMs,
    });
    this.idleTimers.delete(key);
    this.pendingIdleTimeoutKeys.add(key);
    this.stopSessionObserved(idleActive.session.id);
  }

  clearIdleTimer(key: string): void {
    const timer = this.idleTimers.get(key);
    if (timer) {
      clearTimeout(timer);
      this.idleTimers.delete(key);
    }
  }

  private stopSessionObserved(sessionId: string): void {
    void this.deps.stopSession(sessionId).catch((error) => {
      log.error("session_lifecycle.stop_session.failed", {
        sessionId,
        error: safeErrorMessage(error),
      });
    });
  }
}

function hasPendingUserReplyDialog(active: SessionLifecycleSessionState): boolean {
  for (const request of active.pendingUIRequests.values()) {
    if (isPendingUserReplyRequest(request)) {
      return true;
    }
  }
  return false;
}

/** Map SDK/server reason strings to metric tag values. */
function normalizeEndReason(reason: string): string {
  const lower = reason.toLowerCase();
  if (lower === "completed" || lower === "done") return "completed";
  if (lower === "stopped" || lower === "terminated") return "stopped";
  if (lower.includes("error")) return "error";
  return reason;
}

import { clearExtensionUIState, type ExtensionUIState } from "./extension-ui-state.js";
import type { PendingStop, PendingStopSessionState } from "./session-stop.js";
import type { SdkBackend } from "./sdk-backend.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import type { Session, ServerMessage } from "./types.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";

export interface SessionLifecycleSessionState extends ExtensionUIState {
  session: Session;
  sdkBackend: SdkBackend;
  pendingStop?: PendingStop;
  workspaceId: string;
}

export interface SessionLifecycleCoordinatorDeps {
  getActiveSession: (key: string) => SessionLifecycleSessionState | undefined;
  removeActiveSession: (key: string) => void;
  releaseResourceUsageSession?: (session: Session) => void;
  clearPendingStop: (active: PendingStopSessionState) => PendingStop | null;
  broadcast: (key: string, message: ServerMessage) => void;
  persistSessionNow: (key: string, session: Session) => void;
  releaseSession: (identity: { workspaceId: string; sessionId: string }) => void;
  stopSession: (sessionId: string) => Promise<void>;
  getSessionIdleTimeoutMs: () => number;
  metrics?: ServerMetricCollector;
}

const log = createLogger({ base: { component: "session_lifecycle" } });

export class SessionLifecycleCoordinator {
  private idleTimers: Map<string, NodeJS.Timeout> = new Map();
  /** Keys pending idle-timeout stop — consumed in handleSessionEnd to tag the metric. */
  private pendingIdleTimeoutKeys: Set<string> = new Set();

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

    this.deps.releaseResourceUsageSession?.(active.session);
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

  resetIdleTimer(key: string): void {
    this.clearIdleTimer(key);

    const timeoutMs = this.deps.getSessionIdleTimeoutMs();
    const timer = setTimeout(() => {
      const active = this.deps.getActiveSession(key);
      if (!active) {
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

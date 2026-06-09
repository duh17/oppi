import { clearExtensionUIState, type ExtensionUIState } from "./extension-ui-state.js";
import type { PendingStop, StopSessionState } from "./session-stop.js";
import type { SdkBackend } from "./sdk-backend.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import type { Session, ServerMessage } from "./types.js";
import { createLogger } from "./logger.js";

export interface SessionLifecycleSessionState extends ExtensionUIState {
  session: Session;
  sdkBackend: SdkBackend;
  workspaceId: string;
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

    clearExtensionUIState(active);

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

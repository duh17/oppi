import { clearExtensionUIState, type ExtensionUIState } from "./extension-ui-state.js";
import type { SessionSurfaces } from "./session-surfaces.js";
import type { AgentBackend } from "./agent-backend.js";
import type { EventTags } from "./telemetry/catalog.js";
import type { ServerTelemetry } from "./telemetry/server-telemetry.js";

type SessionEndReason = EventTags<"server.session_end">["reason"];
import { isPendingUserReplyRequest } from "./session-attention.js";
import type { Session, ServerMessage } from "./types.js";
import { createLogger } from "./logger.js";
import {
  activeStop,
  applyLifecycle,
  lifecyclePhase,
  type StopState,
} from "./session-lifecycle-state.js";
import { safeErrorMessage } from "./log-utils.js";
import { programRunFor, type ProgramRunTracker } from "./program-status.js";

export interface SessionLifecycleSessionState extends ExtensionUIState {
  session: Session;
  sdkBackend: AgentBackend;
  workspaceId: string;
  /** Composable surfaces a plugin published here, if any. */
  surfaces?: SessionSurfaces;
  /** Event-folded run state behind `session.programStatus`; the wake watch sets `awaitingWake`. */
  programRun?: ProgramRunTracker;
}

export interface SessionLifecycleCoordinatorDeps {
  getActiveSession: (key: string) => SessionLifecycleSessionState | undefined;
  removeActiveSession: (key: string) => void;
  endStop: (stop: StopState) => void;
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
  metrics?: ServerTelemetry;
}

/** What auto-stop's locked recheck asks of the session. */
export interface AutoStopGuard {
  /** Nothing keeps it: no live run or queued input in its backend, and no pending wake. */
  idle(): Promise<boolean>;
  /** Still the settled, ready session the decision was made for, with no reply dialog. */
  still(): boolean;
}

const log = createLogger({ base: { component: "session_lifecycle" } });

/**
 * Whether a `ready` live session will start its next turn: a background job or supervised
 * child still waits to wake it, or the turn it started is not running yet. A job or child
 * clears its wake as it starts that turn, but status turns `busy` only on `agent_start`,
 * after Pi's before-start hooks, so the pending-work check closes that gap (auto-stop reads
 * the same pair). Any other status skips the backend read. A failed check reads as no wake:
 * a supervisor's wait must settle, not hang.
 */
export async function activeAwaitsNextTurn(active: SessionLifecycleSessionState): Promise<boolean> {
  if (lifecyclePhase(active.session).name !== "idle") return false;
  try {
    return (await active.sdkBackend.hasPendingWake()) || (await active.sdkBackend.hasPendingWork());
  } catch (error) {
    log.warn("sessions.pending_wake_check_failed", {
      sessionId: active.session.id,
      error: safeErrorMessage(error),
    });
    return false;
  }
}

/**
 * How long a running turn may go without a single event before the idle timeout stops it
 * anyway. A quiet tool or MCP call is live work, but a turn this quiet is almost surely wedged (a
 * hung provider stream or tool); unbounded, it would hold the session and its sandbox VM forever.
 */
const QUIET_RUNNING_TURN_LIMIT_MS = 2 * 60 * 60_000;

/** How often a settled session re-reads its pending wake. */
const WAKE_WATCH_INTERVAL_MS = 1000;

export class SessionLifecycleCoordinator {
  private idleTimers: Map<string, NodeJS.Timeout> = new Map();
  /** Keys pending idle-timeout stop — consumed in handleSessionEnd to tag the metric. */
  private pendingIdleTimeoutKeys: Set<string> = new Set();
  /** The newest auto-stop decision per session; a newer settle or the session's end replaces it. */
  private autoStopChecks: Map<string, object> = new Map();
  /** When each session's running turn last sent an event, while the idle timeout holds for it. */
  private quietTurnSince: Map<string, number> = new Map();
  /** Stops idle expiry already held once; one still under way at the next expiry is stuck. */
  private heldStops = new WeakSet<StopState>();
  /** Settled sessions whose pending wake is being watched, by session key. */
  private wakeWatches: Map<string, NodeJS.Timeout> = new Map();

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

    // Read before `runtime_ended` leaves the stop's phase.
    const { name: stopPhase } = lifecyclePhase(active.session);
    const wasTerminating = stopPhase === "terminating";
    const stop = activeStop(active.session);

    const isIdleTimeout = this.pendingIdleTimeoutKeys.delete(key);
    const metricReason = isIdleTimeout ? "idle_timeout" : normalizeEndReason(reason);
    this.deps.metrics?.record(
      "server.session_end",
      {},
      { reason: metricReason },
      { sessionId: active.session.id, workspaceId: active.workspaceId },
    );

    const failures: Array<{ phase: string; message: string }> = [];
    const recordFailure = (phase: string, error: unknown): void => {
      const message = safeErrorMessage(error);
      failures.push({ phase, message });
      log.error(`session_lifecycle.${phase}.failed`, {
        sessionId: active.session.id,
        workspaceId: active.workspaceId,
        reason,
        attemptedStatus: "stopped",
        durableRecovery: wasTerminating
          ? "persisted_stopping_marker_retry_stop"
          : "retry_terminal_persistence",
        error: message,
      });
    };

    applyLifecycle(active.session, "runtime_ended");
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

    // A surface is the Session's own state too: its deadlines and action work stop here, and the
    // clients still watching are told each surface is gone. It stops even when the dialog cleanup
    // above failed, so nothing keeps running past the Session.
    try {
      active.surfaces?.stop();
    } catch (error) {
      recordFailure("surface_cleanup", error);
    }

    if (!active.sdkBackend.isDisposed) {
      try {
        await active.sdkBackend.dispose();
      } catch (error) {
        recordFailure("backend_disposal", error);
      }
    }

    this.clearIdleTimer(key);
    clearTimeout(this.wakeWatches.get(key));
    this.wakeWatches.delete(key);
    this.autoStopChecks.delete(key);
    try {
      this.deps.releaseSession({
        workspaceId: active.workspaceId,
        sessionId: active.session.id,
      });
    } catch (error) {
      recordFailure("workspace_release", error);
    }

    if (stop) this.deps.endStop(stop);
    // The stopped summary, with its idle program status, goes out while subscribers remain, before
    // any stop outcome: Build 57 then ignores stop_confirmed's `ready` (it applies only from
    // `stopping`), so the row never flickers ready before session_ended.
    this.deps.broadcast(key, { type: "state", session: active.session });

    try {
      if (wasTerminating) {
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
            source: stop?.source ?? "server",
            reason: stopConfirmationReason || "Session terminated",
          });
        }
      } else if (stopPhase === "aborting") {
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

    this.watchWake(key);
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

  /**
   * `active`'s pending-wake read; `undefined` means the read failed, which each caller below
   * treats differently for its own deadline.
   */
  private async readPendingWake(
    active: SessionLifecycleSessionState,
    key: string,
    scope: "auto_stop" | "idle_timeout",
  ): Promise<boolean | undefined> {
    try {
      return await active.sdkBackend.hasPendingWake();
    } catch (error) {
      log.warn(`session_lifecycle.${scope}.pending_wake_check_failed`, {
        sessionId: active.session.id,
        key,
        error: safeErrorMessage(error),
      });
      return undefined;
    }
  }

  private async autoStop(
    key: string,
    active: SessionLifecycleSessionState,
    check: object,
  ): Promise<void> {
    // A newer settle or the session's end replaced this decision.
    const current = (): boolean =>
      this.autoStopChecks.get(key) === check && this.deps.getActiveSession(key) === active;
    // A failed read is kept; the idle timeout decides later.
    const pendingWake = await this.readPendingWake(active, key, "auto_stop");
    if (pendingWake === undefined || !current()) {
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

  /**
   * A settled session that a background job or child will wake keeps `working` program status
   * (`ProgramRunTracker.awaitingWake`), so its row and subagent pill do not read Done while work
   * is on the way. Polls while the session is ready, since the extensions' wake count has no
   * change channel the durable engine shares; stops once the wake clears (a new settle
   * restarts it), the turn starts, or the session ends. Broadcasts `state` only on a change.
   */
  private watchWake(key: string, delayMs = 0): void {
    clearTimeout(this.wakeWatches.get(key));
    const tick = async (): Promise<void> => {
      const active = this.deps.getActiveSession(key);
      if (!active) return;
      const awaiting = active.session.status === "ready" && (await activeAwaitsNextTurn(active));
      // Another settle, the session's end, or a new turn replaced this watch while it read.
      if (this.deps.getActiveSession(key) !== active || this.wakeWatches.get(key) !== timer) return;
      this.wakeWatches.delete(key);
      // A turn that began while the read ran owns the status; it already cleared the hold.
      if (active.session.status !== "ready" && awaiting) return;
      const tracker = programRunFor(active);
      if (tracker.awaitingWake !== awaiting) {
        tracker.awaitingWake = awaiting;
        this.deps.broadcast(key, { type: "state", session: active.session });
      }
      if (awaiting) this.watchWake(key, WAKE_WATCH_INTERVAL_MS);
    };
    const timer: NodeJS.Timeout = setTimeout(() => void tick(), delayMs);
    timer.unref();
    this.wakeWatches.set(key, timer);
  }

  resetIdleTimer(key: string): void {
    this.clearIdleTimer(key);
    this.armIdleTimer(key);
  }

  /** Arm the timer and keep `quietTurnSince`; only `resetIdleTimer` and `clearIdleTimer` clear it. */
  private armIdleTimer(key: string): void {
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

    // A stop under way finishes within seconds on its own deadlines; expiring it would turn a
    // user's abort into a terminate, so it gets one more timeout. Not every stop stays bounded:
    // an abort Pi confirmed at agent_end waits unbounded for agent_settled, which a hung extension
    // handler holds. A stop still under way a whole timeout later is stuck, and stopSession
    // promotes or retries it under a bounded deadline. A pending wake cannot hold it: the stop
    // was already decided.
    const stop = activeStop(idleActive.session);
    if (stop && !this.heldStops.has(stop)) {
      this.heldStops.add(stop);
      log.info("session_lifecycle.idle_timeout.held_for_stop", {
        sessionId: idleActive.session.id,
        key,
        timeoutMs,
      });
      this.resetIdleTimer(key);
      return;
    }
    if (stop) {
      log.warn("session_lifecycle.idle_timeout.stuck_stop", {
        sessionId: idleActive.session.id,
        key,
        phase: lifecyclePhase(idleActive.session).name,
        timeoutMs,
      });
      this.expire(key, idleActive);
      return;
    }

    // "Idle" here only means no events for the timeout; a turn can be busy and quiet (a long
    // tool or MCP call). Stopping then would kill live work. The hold below reads the phase,
    // not status: a `running` phase with no live engine run or compaction is stale (a missed
    // settle), and that session still expires. So does a turn quiet past QUIET_RUNNING_TURN_LIMIT_MS.
    if (
      lifecyclePhase(idleActive.session).name === "running" &&
      (idleActive.sdkBackend.isStreaming || idleActive.sdkBackend.isCompacting)
    ) {
      const now = Date.now();
      const quietSince = this.quietTurnSince.get(key) ?? now - timeoutMs;
      const quietMs = now - quietSince;
      if (quietMs < QUIET_RUNNING_TURN_LIMIT_MS) {
        log.info("session_lifecycle.idle_timeout.held_for_running_turn", {
          sessionId: idleActive.session.id,
          key,
          timeoutMs,
          quietMs,
        });
        this.quietTurnSince.set(key, quietSince);
        this.armIdleTimer(key);
        return;
      }
      log.warn("session_lifecycle.idle_timeout.quiet_turn_limit", {
        sessionId: idleActive.session.id,
        key,
        quietMs,
        limitMs: QUIET_RUNNING_TURN_LIMIT_MS,
      });
      this.expire(key, idleActive);
      return;
    }

    // A running background job or a supervised child wakes this session when it finishes.
    // Stopping now would kill that job or drop the child's report. A failed read defaults to
    // no wake: this timer must still decide.
    const pendingWake = (await this.readPendingWake(idleActive, key, "idle_timeout")) ?? false;
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
    this.expire(key, idleActive);
  }

  private expire(key: string, active: SessionLifecycleSessionState): void {
    this.idleTimers.delete(key);
    this.quietTurnSince.delete(key);
    this.pendingIdleTimeoutKeys.add(key);
    this.stopSessionObserved(active.session.id);
  }

  clearIdleTimer(key: string): void {
    this.quietTurnSince.delete(key);
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
function normalizeEndReason(reason: string): SessionEndReason {
  const lower = reason.toLowerCase();
  if (lower === "completed" || lower === "done") return "completed";
  if (lower === "stopped" || lower === "terminated") return "stopped";
  if (lower.includes("error")) return "error";
  if (lower === "server_restart" || lower === "store_failed") return lower;
  return "other";
}

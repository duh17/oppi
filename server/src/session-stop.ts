import type { SdkBackendDisposeResult } from "./sdk-backend.js";
import type { AgentBackend } from "./agent-backend.js";
import type { Session, ServerMessage } from "./types.js";
import { createLogger } from "./logger.js";
import {
  activeStop,
  applyLifecycle,
  isStopping,
  lifecyclePhase,
  type StopRequestSource,
  type StopState,
} from "./session-lifecycle-state.js";
import type { SessionRuntimeTransactionPermit } from "./session-runtime-transaction.js";

export type { StopRequestSource } from "./session-lifecycle-state.js";

export interface SessionStopTimers {
  setTimeout(callback: () => void, timeoutMs: number): NodeJS.Timeout;
  clearTimeout(handle: NodeJS.Timeout): void;
}

const log = createLogger({ base: { component: "session_stop" } });
const DEFAULT_STOP_TIMERS: SessionStopTimers = {
  setTimeout: (callback, timeoutMs) => setTimeout(callback, timeoutMs),
  clearTimeout: (handle) => clearTimeout(handle),
};

export interface StopSessionState {
  session: Session;
  sdkBackend: AgentBackend;
}

export interface SessionStopCoordinatorDeps {
  getActiveSession: (key: string) => StopSessionState | undefined;
  persistSessionNow: (key: string, session: Session) => void;
  broadcast: (key: string, message: ServerMessage) => void;
  handleSessionEnd: (
    key: string,
    reason: string,
    stopConfirmationReason?: string,
  ) => void | Promise<void>;
}

export class SessionStopCoordinator {
  constructor(
    private readonly deps: SessionStopCoordinatorDeps,
    private readonly stopAbortTimeoutMs: number,
    private readonly stopAbortRetryTimeoutMs: number,
    private readonly timers: SessionStopTimers = DEFAULT_STOP_TIMERS,
  ) {}

  /** Clears `stop`'s timer and resolves its completion. Leaves the phase itself untouched: an
   * abort confirmed at `agent_end` clears this way while its phase still reads `aborting` until
   * `agent_settled`; a caller that also leaves the phase calls `applyLifecycle` right after. */
  private clearStopTimer(stop: StopState): void {
    if (stop.timeoutHandle !== undefined) {
      this.timers.clearTimeout(stop.timeoutHandle);
      stop.timeoutHandle = undefined;
    }
  }

  clearStop(active: StopSessionState): StopState | null {
    const stop = activeStop(active.session);
    if (!stop) return null;
    this.clearStopTimer(stop);
    stop.resolveCompletion();
    return stop;
  }

  beginPendingStop(
    key: string,
    active: StopSessionState,
    mode: "abort" | "terminate",
    source: StopRequestSource,
    reason?: string,
  ): boolean {
    if (isStopping(active.session)) {
      return false;
    }

    if (!this.applyStopRequest(active.session, mode, source)) return false;
    active.session.lastActivity = Date.now();
    this.deps.persistSessionNow(key, active.session);

    this.deps.broadcast(key, { type: "stop_requested", source, reason });
    this.deps.broadcast(key, { type: "state", session: active.session });
    return true;
  }

  promotePendingStop(
    key: string,
    active: StopSessionState,
    mode: "abort" | "terminate",
    source: StopRequestSource,
    reason?: string,
    emitLifecycleEvent = false,
  ): void {
    const stop = activeStop(active.session);
    if (!stop) {
      this.beginPendingStop(key, active, mode, source, reason);
      return;
    }
    this.clearStopTimer(stop);

    if (this.applyStopRequest(active.session, mode, source)) {
      active.session.lastActivity = Date.now();
      this.deps.persistSessionNow(key, active.session);
    }

    if (emitLifecycleEvent) {
      this.deps.broadcast(key, { type: "stop_requested", source, reason });
      this.deps.broadcast(key, { type: "state", session: active.session });
    }
  }

  finishPendingStopWithFailure(
    key: string,
    active: StopSessionState,
    source: StopRequestSource,
    reason: string,
  ): void {
    const stop = this.clearStop(active);
    if (!stop) {
      return;
    }

    if (applyLifecycle(active.session, "stop_failed")) {
      active.session.lastActivity = Date.now();
      this.deps.persistSessionNow(key, active.session);
      this.deps.broadcast(key, { type: "state", session: active.session });
    }

    this.deps.broadcast(key, { type: "stop_failed", source, reason });
  }

  private applyStopRequest(
    session: Session,
    mode: "abort" | "terminate",
    source: StopRequestSource,
  ): boolean {
    return mode === "abort"
      ? applyLifecycle(session, "abort_requested", source)
      : applyLifecycle(session, "terminate_requested", source);
  }

  /**
   * An abort of work that opened no turn (a compaction, or a durable run before its agent_start)
   * has no agent_end to confirm it: it is confirmed once the abort was accepted and the engine
   * is idle. A turn that started meanwhile confirms at its agent_end instead.
   */
  confirmAbortWithoutRun(key: string, active: StopSessionState): void {
    const stop = activeStop(active.session);
    const phase = lifecyclePhase(active.session);
    if (!stop || stop.claimed || phase.name !== "aborting" || phase.back === "running") return;
    if (active.sdkBackend.isStreaming || active.sdkBackend.isCompacting) return;
    this.clearStop(active);
    this.deps.broadcast(key, { type: "stop_confirmed", source: stop.source });
    if (applyLifecycle(active.session, "run_settled")) {
      active.session.lastActivity = Date.now();
      this.deps.persistSessionNow(key, active.session);
      this.deps.broadcast(key, { type: "state", session: active.session });
    }
  }

  finishPendingStopOnAgentEnd(key: string, active: { session: Session }): void {
    const stop = activeStop(active.session);
    if (!stop || stop.claimed) {
      return;
    }

    if (lifecyclePhase(active.session).name === "aborting") {
      stop.claimed = true;
      this.clearStopTimer(stop);
      this.deps.broadcast(key, { type: "stop_confirmed", source: stop.source });
      return;
    }

    queueMicrotask(() => {
      const current = this.deps.getActiveSession(key);
      if (!current || activeStop(current.session) !== stop || stop.claimed) {
        return;
      }

      this.forceTerminateSessionProcess(key, current, stop.source, undefined, stop.permit);
    });
  }

  armStopRequestLifecycleDeadline(
    key: string,
    active: StopSessionState,
    timeoutMs: number,
    emergencyDispose: () => SdkBackendDisposeResult | Promise<SdkBackendDisposeResult>,
  ): { completion: Promise<void>; cancel: () => void } {
    let resolveCompletion!: () => void;
    const completion = new Promise<void>((resolve) => {
      resolveCompletion = resolve;
    });
    let handle: NodeJS.Timeout | undefined = this.timers.setTimeout(() => {
      handle = undefined;
      const current = this.deps.getActiveSession(key);
      if (!current || current !== active) {
        resolveCompletion();
        return;
      }
      if (!this.beginPendingStop(key, current, "terminate", "user")) {
        this.promotePendingStop(key, current, "terminate", "user");
      }

      log.warn("session_stop.lifecycle_deadline_force_shutdown", {
        sessionId: current.session.id,
        timeoutMs,
      });
      void this.forceTerminateSessionProcess(
        key,
        current,
        "user",
        `Stop lifecycle timed out after ${timeoutMs}ms`,
        undefined,
        emergencyDispose,
      ).finally(resolveCompletion);
    }, timeoutMs);

    return {
      completion,
      cancel: () => {
        if (!handle) return;
        this.timers.clearTimeout(handle);
        handle = undefined;
      },
    };
  }

  /** The stop's completion, armed with a grace timeout that force-terminates when it elapses. A
   * concurrent caller can await the returned promise instead of re-arming its own timer. */
  armPendingTerminateTimeout(
    key: string,
    active: StopSessionState,
    timeoutMs: number,
  ): Promise<void> {
    const stop = activeStop(active.session);
    if (!stop || lifecyclePhase(active.session).name !== "terminating") {
      return Promise.resolve();
    }

    this.clearStopTimer(stop);

    stop.timeoutHandle = this.timers.setTimeout(() => {
      const current = this.deps.getActiveSession(key);
      const currentStop = current && activeStop(current.session);
      if (
        !current ||
        currentStop !== stop ||
        lifecyclePhase(current.session).name !== "terminating"
      ) {
        return;
      }

      log.warn("session_stop.terminate_timeout_force_shutdown", {
        sessionId: current.session.id,
        timeoutMs,
      });
      this.forceTerminateSessionProcess(
        key,
        current,
        stop.source,
        `Stop session timed out after ${timeoutMs}ms`,
        stop.permit,
      );
    }, timeoutMs);

    return stop.completion;
  }

  async forceTerminateSessionProcess(
    key: string,
    active: StopSessionState,
    source: StopRequestSource,
    reason?: string,
    permit?: SessionRuntimeTransactionPermit,
    emergencyDispose?: () => SdkBackendDisposeResult | Promise<SdkBackendDisposeResult>,
  ): Promise<void> {
    const stop = activeStop(active.session);
    if (!stop || lifecyclePhase(active.session).name !== "terminating") return;
    if (stop.claimed && !emergencyDispose) return;
    stop.claimed = true;
    stop.source = source;
    this.clearStopTimer(stop);

    try {
      const disposal = emergencyDispose
        ? await emergencyDispose()
        : await active.sdkBackend.dispose(permit);
      if (activeStop(active.session) !== stop) return;
      const forcedDisposalReason =
        disposal.disposal !== "forced"
          ? undefined
          : disposal.cause === "extension_shutdown_timeout"
            ? `Pi extension shutdown timed out after ${disposal.timeoutMs}ms; forced local session disposal`
            : disposal.cause === "lifecycle_timeout"
              ? `Pi ${disposal.operation} timed out after ${disposal.timeoutMs}ms; forced local session disposal`
              : disposal.cause === "local_cleanup_error"
                ? disposal.diagnosticReason
                : "Pi runtime disposal failed; forced local session disposal";
      const cleanupDiagnostic =
        disposal.disposal === "forced" && disposal.cause !== "local_cleanup_error"
          ? disposal.diagnosticReason
          : undefined;
      const confirmedReason = [reason, forcedDisposalReason, cleanupDiagnostic]
        .filter(Boolean)
        .join("; ");

      // Lifecycle finalization owns the one terminal outcome. In particular,
      // it must persist stopped state and release active/workspace ownership
      // before a successful stop can be confirmed.
      await this.deps.handleSessionEnd(key, "stopped", confirmedReason || undefined);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      this.finishPendingStopWithFailure(key, active, "server", `Force stop failed: ${message}`);
    }
  }

  /**
   * Settles once this abort gives up and escalates, or is no longer the session's active stop:
   * a stop confirmed at `agent_end` claims it without changing its phase or identity, so that
   * check (not just "is it still `aborting`") is what lets this promise settle on every exit.
   */
  scheduleAbortStopTimeout(
    key: string,
    active: StopSessionState,
    onGiveUp: () => Promise<void>,
  ): Promise<void> {
    const stop = activeStop(active.session);
    if (!stop || lifecyclePhase(active.session).name !== "aborting") {
      return Promise.resolve();
    }

    // The session still active and owning this exact stop, unclaimed and still aborting, or
    // undefined when any of that no longer holds.
    const ownedActive = (): StopSessionState | undefined => {
      const current = this.deps.getActiveSession(key);
      if (
        !current ||
        activeStop(current.session) !== stop ||
        stop.claimed ||
        lifecyclePhase(current.session).name !== "aborting"
      ) {
        return undefined;
      }
      return current;
    };

    return new Promise<void>((resolve) => {
      stop.timeoutHandle = this.timers.setTimeout(() => {
        const current = ownedActive();
        if (!current) {
          resolve();
          return;
        }

        // Pi abort already submitted cancellation. Retrying it while its first
        // wait-for-idle is unresolved would be a concurrent Pi operation, so
        // escalation interrupts only a potentially hung bash process.
        log.info("session_stop.abort_timeout_retrying", {
          sessionId: current.session.id,
          timeoutMs: this.stopAbortTimeoutMs,
        });
        this.deps.broadcast(key, {
          type: "stop_requested",
          source: "server",
          reason: `Graceful stop timed out after ${this.stopAbortTimeoutMs}ms; retrying process interrupt`,
        });

        try {
          current.sdkBackend.abortBash();
        } catch {
          // process may have already exited
        }

        stop.timeoutHandle = this.timers.setTimeout(() => {
          void (async () => {
            const still = ownedActive();
            if (!still) {
              resolve();
              return;
            }

            log.warn("session_stop.abort_retry_timeout_give_up", {
              sessionId: still.session.id,
              timeoutMs: this.stopAbortRetryTimeoutMs,
            });
            await onGiveUp();
            const final = ownedActive();
            if (final) {
              this.finishPendingStopWithFailure(
                key,
                final,
                "server",
                `Stop timed out — the agent may still be processing. You can send another message or stop the session.`,
              );
            }
            resolve();
          })();
        }, this.stopAbortRetryTimeoutMs);
      }, this.stopAbortTimeoutMs);
    });
  }
}

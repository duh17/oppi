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

  private clearStopTimer(stop: StopState): void {
    if (stop.timeoutHandle !== undefined) {
      this.timers.clearTimeout(stop.timeoutHandle);
      stop.timeoutHandle = undefined;
    }
  }

  /** Clears `stop`'s timer and settles it; leaving its phase is the caller's part. */
  endStop(stop: StopState): void {
    this.clearStopTimer(stop);
    stop.settle();
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

    const event = mode === "abort" ? "abort_requested" : "terminate_requested";
    if (!applyLifecycle(active.session, event, source)) return false;
    active.session.lastActivity = Date.now();
    this.deps.persistSessionNow(key, active.session);

    this.deps.broadcast(key, { type: "stop_requested", source, reason });
    this.deps.broadcast(key, { type: "state", session: active.session });
    return true;
  }

  /** A user terminate: a new stop, or the stop under way promoted to one (still `stopping`). */
  requestTerminate(key: string, active: StopSessionState): void {
    if (this.beginPendingStop(key, active, "terminate", "user")) return;
    const stop = activeStop(active.session);
    if (!stop) return;
    this.clearStopTimer(stop);
    applyLifecycle(active.session, "terminate_requested", "user");
  }

  finishPendingStopWithFailure(
    key: string,
    active: StopSessionState,
    source: StopRequestSource,
    reason: string,
  ): void {
    const stop = activeStop(active.session);
    if (!stop) return;
    this.endStop(stop);
    if (applyLifecycle(active.session, "stop_failed")) {
      active.session.lastActivity = Date.now();
      this.deps.persistSessionNow(key, active.session);
      this.deps.broadcast(key, { type: "state", session: active.session });
    }

    this.deps.broadcast(key, { type: "stop_failed", source, reason });
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
    this.endStop(stop);
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

    if (activeStop(active.session, "aborting")) {
      // The abort deadline stays armed: it sees the claim and settles without acting.
      stop.claimed = true;
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
      this.requestTerminate(key, current);
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

  /** The terminate's completion, with a grace timeout that force-terminates when it elapses. */
  armPendingTerminateTimeout(
    key: string,
    active: StopSessionState,
    timeoutMs: number,
  ): Promise<unknown> {
    const stop = activeStop(active.session, "terminating");
    if (!stop) return Promise.resolve();

    this.clearStopTimer(stop);
    stop.timeoutHandle = this.timers.setTimeout(() => {
      const current = this.deps.getActiveSession(key);
      if (!current || activeStop(current.session, "terminating") !== stop) return;

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
    const stop = activeStop(active.session, "terminating");
    if (!stop || (stop.claimed && !emergencyDispose)) return;
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

  /** Resolves when the abort gives up, or once it is no longer this unclaimed, aborting stop. */
  scheduleAbortStopTimeout(
    key: string,
    active: StopSessionState,
    onGiveUp: () => Promise<void>,
  ): Promise<void> {
    const stop = activeStop(active.session, "aborting");
    if (!stop) return Promise.resolve();

    const ownedActive = (): StopSessionState | undefined => {
      const current = this.deps.getActiveSession(key);
      return current && !stop.claimed && activeStop(current.session, "aborting") === stop
        ? current
        : undefined;
    };

    return new Promise<void>((resolve) => {
      // A cleared timer (stop failed, promoted, or the runtime ended) never fires.
      void stop.completion.then(() => resolve());
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

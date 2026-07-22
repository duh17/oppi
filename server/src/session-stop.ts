import type { SdkBackend, SdkBackendDisposeResult } from "./sdk-backend.js";
import type { Session, ServerMessage } from "./types.js";
import { createLogger } from "./logger.js";
import type { SessionRuntimeTransactionPermit } from "./session-runtime-transaction.js";

export type StopRequestSource = "user" | "timeout" | "server";

export interface SessionStopTimers {
  setTimeout(callback: () => void, timeoutMs: number): NodeJS.Timeout;
  clearTimeout(handle: NodeJS.Timeout): void;
}

const log = createLogger({ base: { component: "session_stop" } });
const DEFAULT_STOP_TIMERS: SessionStopTimers = {
  setTimeout: (callback, timeoutMs) => setTimeout(callback, timeoutMs),
  clearTimeout: (handle) => clearTimeout(handle),
};

export interface PendingStop {
  mode: "abort" | "terminate";
  source: StopRequestSource;
  requestedAt: number;
  previousStatus: Session["status"];
  timeoutHandle?: NodeJS.Timeout;
  completionPromise?: Promise<void>;
  completionResolve?: () => void;
  /** Exclusive permit owned by this stop while timeout/event supervision runs. */
  runtimePermit?: SessionRuntimeTransactionPermit;
  forceTerminationStarted?: boolean;
}

export interface PendingStopSessionState {
  pendingStop?: PendingStop;
}

export interface StopSessionState extends PendingStopSessionState {
  session: Session;
  sdkBackend: SdkBackend;
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

  clearPendingStop(active: PendingStopSessionState): PendingStop | null {
    const pending = active.pendingStop;
    if (!pending) {
      return null;
    }

    if (pending.timeoutHandle) {
      this.timers.clearTimeout(pending.timeoutHandle);
      pending.timeoutHandle = undefined;
    }

    const resolve = pending.completionResolve;
    pending.completionResolve = undefined;
    pending.completionPromise = undefined;
    active.pendingStop = undefined;
    resolve?.();
    return pending;
  }

  private ensurePendingStopCompletion(pending: PendingStop): Promise<void> {
    if (!pending.completionPromise) {
      pending.completionPromise = new Promise<void>((resolve) => {
        pending.completionResolve = resolve;
      });
    }

    return pending.completionPromise;
  }

  beginPendingStop(
    key: string,
    active: StopSessionState,
    mode: PendingStop["mode"],
    source: StopRequestSource,
    reason?: string,
  ): boolean {
    if (active.pendingStop) {
      return false;
    }

    active.pendingStop = {
      mode,
      source,
      requestedAt: Date.now(),
      previousStatus: active.session.status,
    };

    active.session.status = "stopping";
    active.session.lastActivity = Date.now();
    this.deps.persistSessionNow(key, active.session);

    this.deps.broadcast(key, { type: "stop_requested", source, reason });
    this.deps.broadcast(key, { type: "state", session: active.session });
    return true;
  }

  promotePendingStop(
    key: string,
    active: StopSessionState,
    mode: PendingStop["mode"],
    source: StopRequestSource,
    reason?: string,
    emitLifecycleEvent = false,
  ): void {
    if (!active.pendingStop) {
      this.beginPendingStop(key, active, mode, source, reason);
      return;
    }

    const pending = active.pendingStop;

    if (pending.timeoutHandle) {
      this.timers.clearTimeout(pending.timeoutHandle);
      pending.timeoutHandle = undefined;
    }

    pending.mode = mode;
    pending.source = source;

    if (active.session.status !== "stopping") {
      active.session.status = "stopping";
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
    const pending = this.clearPendingStop(active);
    if (!pending) {
      return;
    }

    if (active.session.status === "stopping") {
      const fallbackStatus =
        pending.previousStatus === "stopping" ? "busy" : pending.previousStatus;
      active.session.status = fallbackStatus;
      active.session.lastActivity = Date.now();
      this.deps.persistSessionNow(key, active.session);
      this.deps.broadcast(key, { type: "state", session: active.session });
    }

    this.deps.broadcast(key, { type: "stop_failed", source, reason });
  }

  finishPendingStopOnAgentEnd(key: string, active: PendingStopSessionState): void {
    const pending = active.pendingStop;
    if (!pending) {
      return;
    }

    if (pending.mode === "abort") {
      this.clearPendingStop(active);
      this.deps.broadcast(key, { type: "stop_confirmed", source: pending.source });
      return;
    }

    queueMicrotask(() => {
      const current = this.deps.getActiveSession(key);
      if (!current || current.pendingStop !== pending || pending.mode !== "terminate") {
        return;
      }

      this.forceTerminateSessionProcess(
        key,
        current,
        pending.source,
        undefined,
        pending.runtimePermit,
      );
    });
  }

  armStopRequestLifecycleDeadline(
    key: string,
    active: StopSessionState,
    timeoutMs: number,
    emergencyDispose: () => SdkBackendDisposeResult,
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

  armPendingTerminateTimeout(
    key: string,
    active: StopSessionState,
    timeoutMs: number,
  ): Promise<void> {
    const pending = active.pendingStop;
    if (!pending || pending.mode !== "terminate") {
      return Promise.resolve();
    }

    const completion = this.ensurePendingStopCompletion(pending);

    if (pending.timeoutHandle) {
      this.timers.clearTimeout(pending.timeoutHandle);
    }

    pending.timeoutHandle = this.timers.setTimeout(() => {
      const current = this.deps.getActiveSession(key);
      if (!current || current.pendingStop !== pending || pending.mode !== "terminate") {
        return;
      }

      log.warn("session_stop.terminate_timeout_force_shutdown", {
        sessionId: current.session.id,
        timeoutMs,
      });
      this.forceTerminateSessionProcess(
        key,
        current,
        pending.source,
        `Stop session timed out after ${timeoutMs}ms`,
        pending.runtimePermit,
      );
    }, timeoutMs);

    return completion;
  }

  async forceTerminateSessionProcess(
    key: string,
    active: StopSessionState,
    source: StopRequestSource,
    reason?: string,
    permit?: SessionRuntimeTransactionPermit,
    emergencyDispose?: () => SdkBackendDisposeResult,
  ): Promise<void> {
    const ownedPending = active.pendingStop;
    if (!ownedPending || ownedPending.mode !== "terminate") return;
    if (ownedPending.forceTerminationStarted && !emergencyDispose) return;
    ownedPending.forceTerminationStarted = true;
    ownedPending.source = source;
    if (ownedPending.timeoutHandle) {
      this.timers.clearTimeout(ownedPending.timeoutHandle);
      ownedPending.timeoutHandle = undefined;
    }

    try {
      const disposal = emergencyDispose
        ? emergencyDispose()
        : await active.sdkBackend.dispose(permit);
      if (active.pendingStop !== ownedPending) return;
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

  scheduleAbortStopTimeout(
    key: string,
    active: StopSessionState,
    onGiveUp: () => Promise<void>,
  ): Promise<void> {
    const pending = active.pendingStop;
    if (!pending || pending.mode !== "abort") {
      return Promise.resolve();
    }

    return new Promise<void>((resolve) => {
      pending.timeoutHandle = this.timers.setTimeout(() => {
        const current = this.deps.getActiveSession(key);
        if (!current || current.pendingStop !== pending || pending.mode !== "abort") {
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
          current.sdkBackend.session.abortBash();
        } catch {
          // process may have already exited
        }

        pending.timeoutHandle = this.timers.setTimeout(() => {
          void (async () => {
            const still = this.deps.getActiveSession(key);
            if (!still || still.pendingStop !== pending || pending.mode !== "abort") {
              return;
            }

            log.warn("session_stop.abort_retry_timeout_give_up", {
              sessionId: still.session.id,
              timeoutMs: this.stopAbortRetryTimeoutMs,
            });
            await onGiveUp();
            if (this.deps.getActiveSession(key) === still && still.pendingStop === pending) {
              this.finishPendingStopWithFailure(
                key,
                still,
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

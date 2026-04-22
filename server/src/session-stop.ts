import type { SdkBackend } from "./sdk-backend.js";
import type { Session, ServerMessage } from "./types.js";
import { createLogger } from "./logger.js";

export type StopRequestSource = "user" | "timeout" | "server";

const log = createLogger({ base: { component: "session_stop" } });

export interface PendingStop {
  mode: "abort" | "terminate";
  source: StopRequestSource;
  requestedAt: number;
  previousStatus: Session["status"];
  timeoutHandle?: NodeJS.Timeout;
  completionPromise?: Promise<void>;
  completionResolve?: () => void;
}

export interface StopSessionState {
  session: Session;
  sdkBackend: SdkBackend;
  pendingStop?: PendingStop;
}

export interface SessionStopCoordinatorDeps {
  getActiveSession: (key: string) => StopSessionState | undefined;
  persistSessionNow: (key: string, session: Session) => void;
  broadcast: (key: string, message: ServerMessage) => void;
  handleSessionEnd: (key: string, reason: string) => void | Promise<void>;
}

export class SessionStopCoordinator {
  constructor(
    private readonly deps: SessionStopCoordinatorDeps,
    private readonly stopAbortTimeoutMs: number,
    private readonly stopAbortRetryTimeoutMs: number,
  ) {}

  clearPendingStop(active: StopSessionState): PendingStop | null {
    const pending = active.pendingStop;
    if (!pending) {
      return null;
    }

    if (pending.timeoutHandle) {
      clearTimeout(pending.timeoutHandle);
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
      clearTimeout(pending.timeoutHandle);
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

  finishPendingStopOnAgentEnd(key: string, active: StopSessionState): void {
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
      if (!current || current.pendingStop?.mode !== "terminate") {
        return;
      }

      this.forceTerminateSessionProcess(key, current, current.pendingStop.source);
    });
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
      clearTimeout(pending.timeoutHandle);
    }

    pending.timeoutHandle = setTimeout(() => {
      const current = this.deps.getActiveSession(key);
      if (!current || current.pendingStop?.mode !== "terminate") {
        return;
      }

      log.warn("session_stop.terminate_timeout_force_shutdown", {
        sessionId: current.session.id,
        timeoutMs,
      });
      this.forceTerminateSessionProcess(
        key,
        current,
        current.pendingStop.source,
        `Stop session timed out after ${timeoutMs}ms`,
      );
    }, timeoutMs);

    return completion;
  }

  async forceTerminateSessionProcess(
    key: string,
    active: StopSessionState,
    source: StopRequestSource,
    reason?: string,
  ): Promise<void> {
    try {
      await active.sdkBackend.dispose();

      const pending = this.clearPendingStop(active);
      this.deps.broadcast(key, {
        type: "stop_confirmed",
        source: pending?.source ?? source,
        reason,
      });
      await this.deps.handleSessionEnd(key, "stopped");
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      this.finishPendingStopWithFailure(key, active, "server", `Force stop failed: ${message}`);
    }
  }

  scheduleAbortStopTimeout(key: string, active: StopSessionState): void {
    const pending = active.pendingStop;
    if (!pending || pending.mode !== "abort") {
      return;
    }

    pending.timeoutHandle = setTimeout(() => {
      const current = this.deps.getActiveSession(key);
      if (!current || current.pendingStop?.mode !== "abort") {
        return;
      }

      // Phase 1: first abort timed out — retry abort to interrupt running tools
      log.info("session_stop.abort_timeout_retrying", {
        sessionId: current.session.id,
        timeoutMs: this.stopAbortTimeoutMs,
      });
      this.deps.broadcast(key, {
        type: "stop_requested",
        source: "server",
        reason: `Graceful stop timed out after ${this.stopAbortTimeoutMs}ms; retrying abort`,
      });

      try {
        void current.sdkBackend.abort();
        current.sdkBackend.session.abortBash();
      } catch {
        // process may have already exited
      }

      // Phase 2: if retry doesn't resolve the abort, give up but keep session alive
      const currentPendingStop = current.pendingStop;
      if (!currentPendingStop || currentPendingStop.mode !== "abort") {
        return;
      }

      currentPendingStop.timeoutHandle = setTimeout(() => {
        const still = this.deps.getActiveSession(key);
        if (!still || still.pendingStop?.mode !== "abort") {
          return;
        }

        log.warn("session_stop.abort_retry_timeout_give_up", {
          sessionId: still.session.id,
          timeoutMs: this.stopAbortRetryTimeoutMs,
        });
        this.finishPendingStopWithFailure(
          key,
          still,
          "server",
          `Stop timed out — the agent may still be processing. You can send another message or stop the session.`,
        );
      }, this.stopAbortRetryTimeoutMs);
    }, this.stopAbortTimeoutMs);
  }
}

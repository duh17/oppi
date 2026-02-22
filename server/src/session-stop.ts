import type { SdkBackend } from "./sdk-backend.js";
import { ts } from "./log-utils.js";
import type { Session, ServerMessage } from "./types.js";

export type StopRequestSource = "user" | "timeout" | "server";

export interface PendingStop {
  mode: "abort" | "terminate";
  source: StopRequestSource;
  requestedAt: number;
  previousStatus: Session["status"];
  timeoutHandle?: NodeJS.Timeout;
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
  handleSessionEnd: (key: string, reason: string) => void;
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

    active.pendingStop = undefined;
    return pending;
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

  finishPendingAbortWithSuccess(key: string, active: StopSessionState): void {
    const pending = this.clearPendingStop(active);
    if (!pending || pending.mode !== "abort") {
      return;
    }

    this.deps.broadcast(key, { type: "stop_confirmed", source: pending.source });
  }

  forceTerminateSessionProcess(
    key: string,
    active: StopSessionState,
    source: StopRequestSource,
    reason?: string,
  ): void {
    try {
      active.sdkBackend.dispose();

      const pending = this.clearPendingStop(active);
      this.deps.broadcast(key, {
        type: "stop_confirmed",
        source: pending?.source ?? source,
        reason,
      });
      this.deps.handleSessionEnd(key, "stopped");
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
      console.log(
        `${ts()} [session] Abort timed out after ${this.stopAbortTimeoutMs}ms; retrying abort`,
      );
      this.deps.broadcast(key, {
        type: "stop_requested",
        source: "server",
        reason: `Graceful stop timed out after ${this.stopAbortTimeoutMs}ms; retrying abort`,
      });

      try {
        void current.sdkBackend.abort();
        current.sdkBackend.abortBash();
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

        console.warn(
          `${ts()} [session] Abort still pending after retry + ${this.stopAbortRetryTimeoutMs}ms; giving up (session stays alive)`,
        );
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

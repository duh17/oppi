import type { SdkBackendDisposeResult } from "./sdk-backend.js";
import { activeStop, isStopping, lifecyclePhase, turnRunning } from "./session-lifecycle-state.js";
import type { SessionStopCoordinator, StopSessionState } from "./session-stop.js";
import type { ServerMessage } from "./types.js";
import type { WorkspaceRuntime } from "./workspace-runtime.js";
import type { SessionRuntimeTransactionPermit } from "./session-runtime-transaction.js";
import type { SessionAbortQueueClear } from "./session-queue.js";

export interface SessionStopFlowSessionState extends StopSessionState {
  workspaceId: string;
}

export interface SessionStopFlowCoordinatorDeps {
  runtimeManager: WorkspaceRuntime;
  getActiveSession: (key: string) => SessionStopFlowSessionState | undefined;
  stopCoordinator: SessionStopCoordinator;
  broadcast: (key: string, message: ServerMessage) => void;
  /** Clear queued steering/follow-up messages and retain a rollback snapshot. */
  clearQueueOnAbort: (
    key: string,
    permit: SessionRuntimeTransactionPermit,
  ) => SessionAbortQueueClear | undefined;
  acceptQueueClearOnAbort: (clear: SessionAbortQueueClear) => void;
  restoreQueueAfterAbortFailure: (
    clear: SessionAbortQueueClear,
    permit: SessionRuntimeTransactionPermit,
  ) => Promise<void>;
}

export class SessionStopFlowCoordinator {
  private readonly inFlightAbortRequests = new Map<string, Promise<void>>();
  private readonly inFlightTerminateRequests = new Map<string, Promise<void>>();

  constructor(
    private readonly deps: SessionStopFlowCoordinatorDeps,
    private readonly stopSessionGraceMs: number,
    /** Total stop/stopAll bound, including permit wait, grace, and disposal. */
    private readonly stopSessionBoundMs: number,
  ) {}

  async sendAbort(key: string, sessionId: string, preAbort?: () => void): Promise<void> {
    const existing = this.inFlightAbortRequests.get(key);
    if (existing) return existing;

    const operation = this.sendAbortOwned(key, sessionId, preAbort);
    this.inFlightAbortRequests.set(key, operation);
    try {
      await operation;
    } finally {
      if (this.inFlightAbortRequests.get(key) === operation) {
        this.inFlightAbortRequests.delete(key);
      }
    }
  }

  private async sendAbortOwned(
    key: string,
    sessionId: string,
    preAbort?: () => void,
  ): Promise<void> {
    await this.deps.runtimeManager.withSessionLock(sessionId, async () => {
      // Run pre-abort callback inside the lock so it serializes with
      // WebSocket message handlers (e.g. respondToUIRequest). Without
      // this, cancelPendingAsk could race with an ask answer — if the
      // stop message arrives first, the answer is silently lost.
      preAbort?.();
      const active = this.deps.getActiveSession(key);
      if (!active || !this.hasTurnToAbort(key, active)) return;

      let ownedStop = activeStop(active.session);
      let queueClear: SessionAbortQueueClear | undefined;
      try {
        await active.sdkBackend.withRuntimeLifecycleTransaction("abort", async (permit) => {
          if (this.deps.getActiveSession(key) !== active) return;
          // The turn can settle while abort waits behind reload/queue work. Do
          // not create a pending stop for a turn that already became idle.
          if (!this.hasTurnToAbort(key, active)) return;
          if (!this.deps.stopCoordinator.beginPendingStop(key, active, "abort", "user")) return;
          ownedStop = activeStop(active.session);
          if (!ownedStop) return;
          ownedStop.permit = permit;

          // Clearing, abort submission, rollback, and timeout ownership share
          // this permit. The deadline races the unresolved Pi wait-for-idle,
          // so the exclusive transaction remains bounded.
          queueClear = this.deps.clearQueueOnAbort(key, permit);
          const deadline = this.deps.stopCoordinator.scheduleAbortStopTimeout(
            key,
            active,
            async () => {
              if (!queueClear) return;
              const clear = queueClear;
              queueClear = undefined;
              await this.deps.restoreQueueAfterAbortFailure(clear, permit);
            },
          );
          const abort = active.sdkBackend.abort(permit);
          try {
            active.sdkBackend.abortBash();
          } catch {
            // no bash running — fine
          }

          try {
            const outcome = await Promise.race([
              abort.then(() => "accepted" as const),
              deadline.then(() => "timed_out" as const),
            ]);
            if (outcome === "accepted" && queueClear) {
              this.deps.acceptQueueClearOnAbort(queueClear);
              queueClear = undefined;
            }
            if (outcome === "accepted")
              this.deps.stopCoordinator.confirmAbortWithoutRun(key, active);
          } catch (error) {
            if (activeStop(active.session) !== ownedStop) {
              // Agent-end/timeout ownership already settled this request. A
              // late abort rejection cannot roll back or report a second result.
              if (queueClear) this.deps.acceptQueueClearOnAbort(queueClear);
              queueClear = undefined;
              return;
            }
            if (queueClear) {
              const clear = queueClear;
              queueClear = undefined;
              await this.deps.restoreQueueAfterAbortFailure(clear, permit);
            }
            throw error;
          }
        });
      } catch (error) {
        if (ownedStop && activeStop(active.session) === ownedStop) {
          const message = error instanceof Error ? error.message : String(error);
          this.deps.stopCoordinator.finishPendingStopWithFailure(
            key,
            active,
            "server",
            `Abort failed: ${message}`,
          );
        }
        throw error;
      }
    });
  }

  /**
   * Whether an abort has a turn to stop. A stop under way owns the turn, including an abort that
   * Pi confirmed at agent_end and that has not settled; with no turn running the answer is that
   * the session is already idle.
   */
  private hasTurnToAbort(key: string, active: SessionStopFlowSessionState): boolean {
    if (isStopping(active.session)) return false;
    if (turnRunning(active)) return true;
    this.deps.broadcast(key, {
      type: "stop_confirmed",
      source: "user",
      reason: "Session already idle",
    });
    return false;
  }

  async stopSession(key: string, sessionId: string, preStop?: () => void): Promise<void> {
    const existing = this.inFlightTerminateRequests.get(key);
    if (existing) return existing;

    const operation = this.stopSessionOwned(key, sessionId, preStop);
    this.inFlightTerminateRequests.set(key, operation);
    try {
      await operation;
    } finally {
      if (this.inFlightTerminateRequests.get(key) === operation) {
        this.inFlightTerminateRequests.delete(key);
      }
    }
  }

  private async stopSessionOwned(
    key: string,
    sessionId: string,
    preStop?: () => void,
  ): Promise<void> {
    const active = this.deps.getActiveSession(key);
    if (!active) return;

    // Start the total deadline before every lock/permit wait. Its emergency path
    // poisons the runtime transaction outside the stuck owner, which lets any
    // transaction-waiting outer lock unwind while this request settles on time.
    const capturedEmergencyDisposal = active.sdkBackend.captureEmergencyDisposalForStop();
    const emergencyDispose = (): SdkBackendDisposeResult | Promise<SdkBackendDisposeResult> =>
      capturedEmergencyDisposal(this.stopSessionBoundMs);
    const lifecycleDeadline = this.deps.stopCoordinator.armStopRequestLifecycleDeadline(
      key,
      active,
      this.stopSessionBoundMs,
      emergencyDispose,
    );

    const lockedStop = this.deps.runtimeManager.withSessionLock(sessionId, async () => {
      preStop?.();
      if (this.deps.getActiveSession(key) !== active) return;

      await this.deps.runtimeManager.withWorkspaceLock(active.workspaceId, async () => {
        if (this.deps.getActiveSession(key) !== active) return;
        const wasBusy = turnRunning(active);
        if (!this.deps.stopCoordinator.beginPendingStop(key, active, "terminate", "user")) {
          this.deps.stopCoordinator.promotePendingStop(key, active, "terminate", "user");
        }
        const ownedStop = activeStop(active.session);
        if (!ownedStop || lifecyclePhase(active.session).name !== "terminating") return;

        const runtimeStop = active.sdkBackend.withRuntimeLifecycleTransaction(
          "stop",
          async (permit) => {
            if (this.deps.getActiveSession(key) !== active) return;
            ownedStop.permit = permit;

            if (!wasBusy) {
              await this.deps.stopCoordinator.forceTerminateSessionProcess(
                key,
                active,
                "user",
                undefined,
                permit,
              );
              return;
            }

            const waitForTerminate = this.deps.stopCoordinator.armPendingTerminateTimeout(
              key,
              active,
              this.stopSessionGraceMs,
            );
            const abort = active.sdkBackend.abort(permit);
            try {
              active.sdkBackend.abortBash();
            } catch {
              // no bash running — fine
            }

            try {
              await Promise.race([abort, waitForTerminate]);
              if (activeStop(active.session) === ownedStop) await waitForTerminate;
            } catch (error) {
              if (activeStop(active.session) !== ownedStop) return;
              const message = error instanceof Error ? error.message : String(error);
              this.deps.stopCoordinator.finishPendingStopWithFailure(
                key,
                active,
                "server",
                `Abort failed: ${message}`,
              );
              throw error;
            }
          },
          { allowDisposed: true },
        );

        try {
          await runtimeStop;
        } catch (error) {
          if (activeStop(active.session) !== ownedStop) {
            if (active.sdkBackend.isDisposed || this.deps.getActiveSession(key) !== active) return;
            throw error;
          }
          if (active.sdkBackend.isDisposed) {
            await this.deps.stopCoordinator.forceTerminateSessionProcess(
              key,
              active,
              "user",
              undefined,
              undefined,
              emergencyDispose,
            );
            return;
          }
          throw error;
        }
      });
    });

    const stopAttempt = lockedStop.finally(lifecycleDeadline.cancel);
    await Promise.race([stopAttempt, lifecycleDeadline.completion]);
  }
}

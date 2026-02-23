import type { SessionStopCoordinator, StopSessionState } from "./session-stop.js";
import type { ServerMessage } from "./types.js";
import type { WorkspaceRuntime } from "./workspace-runtime.js";

export interface SessionStopFlowSessionState extends StopSessionState {
  workspaceId: string;
}

export interface SessionStopFlowCoordinatorDeps {
  runtimeManager: WorkspaceRuntime;
  getActiveSession: (key: string) => SessionStopFlowSessionState | undefined;
  stopCoordinator: SessionStopCoordinator;
  broadcast: (key: string, message: ServerMessage) => void;
  sendCommand: (key: string, command: Record<string, unknown>) => void;
}

export class SessionStopFlowCoordinator {
  constructor(
    private readonly deps: SessionStopFlowCoordinatorDeps,
    private readonly stopSessionGraceMs: number,
  ) {}

  async sendAbort(key: string, sessionId: string): Promise<void> {
    await this.deps.runtimeManager.withSessionLock(sessionId, async () => {
      const active = this.deps.getActiveSession(key);
      if (!active) {
        return;
      }

      if (active.session.status !== "busy") {
        this.deps.broadcast(key, {
          type: "stop_confirmed",
          source: "user",
          reason: "Session already idle",
        });
        return;
      }

      if (!this.deps.stopCoordinator.beginPendingStop(key, active, "abort", "user")) {
        return;
      }

      this.deps.sendCommand(key, { type: "abort" });

      try {
        active.sdkBackend.session.abortBash();
      } catch {
        // no bash running — fine
      }

      this.deps.stopCoordinator.scheduleAbortStopTimeout(key, active);
    });
  }

  async stopSession(key: string, sessionId: string): Promise<void> {
    await this.deps.runtimeManager.withSessionLock(sessionId, async () => {
      const active = this.deps.getActiveSession(key);
      if (!active) {
        return;
      }

      await this.deps.runtimeManager.withWorkspaceLock(active.workspaceId, async () => {
        if (!this.deps.stopCoordinator.beginPendingStop(key, active, "terminate", "user")) {
          this.deps.stopCoordinator.promotePendingStop(key, active, "terminate", "user");
        }

        void active.sdkBackend.abort();
        await new Promise((resolve) => setTimeout(resolve, this.stopSessionGraceMs));

        this.deps.stopCoordinator.forceTerminateSessionProcess(key, active, "user");
      });
    });
  }
}

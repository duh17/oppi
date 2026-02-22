import { ts } from "./log-utils.js";
import type { ExtensionUIRequest } from "./session-events.js";
import type { PendingStop, StopSessionState } from "./session-stop.js";
import type { SdkBackend } from "./sdk-backend.js";
import type { Session, ServerMessage } from "./types.js";

export interface SessionLifecycleSessionState {
  session: Session;
  sdkBackend: SdkBackend;
  workspaceId: string;
  pendingUIRequests: Map<string, ExtensionUIRequest>;
}

export interface SessionLifecycleCoordinatorDeps {
  getActiveSession: (key: string) => SessionLifecycleSessionState | undefined;
  removeActiveSession: (key: string) => void;
  clearPendingStop: (active: StopSessionState) => PendingStop | null;
  broadcast: (key: string, message: ServerMessage) => void;
  persistSessionNow: (key: string, session: Session) => void;
  destroySessionGuard: (sessionId: string) => void;
  releaseSession: (identity: { workspaceId: string; sessionId: string }) => void;
  stopSession: (sessionId: string) => Promise<void>;
  getSessionIdleTimeoutMs: () => number;
}

export class SessionLifecycleCoordinator {
  private idleTimers: Map<string, NodeJS.Timeout> = new Map();

  constructor(private readonly deps: SessionLifecycleCoordinatorDeps) {}

  handleSessionEnd(key: string, reason: string): void {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      return;
    }

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
    this.deps.persistSessionNow(key, active.session);

    this.deps.destroySessionGuard(active.session.id);
    active.pendingUIRequests.clear();

    if (!active.sdkBackend.isDisposed) {
      active.sdkBackend.dispose();
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
      console.log(`${ts()} [session] idle timeout: ${key}`);
      const active = this.deps.getActiveSession(key);
      if (!active) {
        return;
      }

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

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
  hasActiveChildren: (sessionId: string) => boolean;
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

    // Auto-stop child sessions after they complete their work.
    // Children are ephemeral — they do one task and exit.
    // Give a grace period so the prompt has time to dispatch (especially
    // in sandbox mode where VM boot adds latency before the first turn).
    const active = this.deps.getActiveSession(key);
    if (active?.session.parentSessionId && active.session.status === "ready") {
      // Has the child actually produced LLM output? messageCount alone is
      // unreliable — sendPrompt increments it before the SDK processes the
      // prompt, so a resetIdleTimer call from sendCommand sees messageCount > 0
      // while the agent hasn't started yet.
      const hasCompletedWork = active.session.tokens.output > 0;

      if (hasCompletedWork) {
        console.log("[session] auto-stopping idle child", {
          sessionId: active.session.id,
          parent: active.session.parentSessionId,
        });
        setTimeout(() => {
          void this.deps.stopSession(active.session.id);
        }, 0);
        return;
      }

      // Child hasn't produced output yet — either still initializing,
      // waiting for the LLM, or in sandbox VM boot. Give it time.
      const CHILD_GRACE_MS = 60_000;
      const timer = setTimeout(() => {
        const current = this.deps.getActiveSession(key);
        if (current?.session.parentSessionId && current.session.status === "ready") {
          console.log("[session] auto-stopping idle child (grace expired)", {
            sessionId: current.session.id,
            parent: current.session.parentSessionId,
          });
          void this.deps.stopSession(current.session.id);
        }
      }, CHILD_GRACE_MS);
      this.idleTimers.set(key, timer);
      return;
    }

    const timeoutMs = this.deps.getSessionIdleTimeoutMs();
    const timer = setTimeout(() => {
      const active = this.deps.getActiveSession(key);
      if (!active) {
        return;
      }

      // Don't idle-stop a parent while any of its children are still active.
      // The parent needs to stay alive to receive child results and coordinate.
      if (this.deps.hasActiveChildren(active.session.id)) {
        console.log("[session] idle timeout deferred — active children", {
          sessionId: active.session.id,
        });
        // Re-arm the timer so we check again later.
        this.resetIdleTimer(key);
        return;
      }

      console.log("[session] idle timeout", {
        key,
      });
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

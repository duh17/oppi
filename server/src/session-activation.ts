import type { Session, Workspace } from "./types.js";
import type { WorkspaceRuntime } from "./workspace-runtime.js";

export interface SessionActivationActiveSession {
  session: Session;
}

export interface SessionActivationCoordinatorDeps {
  runtimeManager: WorkspaceRuntime;
  getActiveSession: (key: string) => SessionActivationActiveSession | undefined;
  resetIdleTimer: (key: string) => void;
  startSessionInner: (key: string, sessionId: string, workspace?: Workspace) => Promise<Session>;
}

export class SessionActivationCoordinator {
  private starting: Map<string, Promise<Session>> = new Map();

  constructor(private readonly deps: SessionActivationCoordinatorDeps) {}

  async startSession(key: string, sessionId: string, workspace?: Workspace): Promise<Session> {
    const existing = this.deps.getActiveSession(key);
    if (existing) {
      this.deps.resetIdleTimer(key);
      return existing.session;
    }

    const pending = this.starting.get(key);
    if (pending) {
      return pending;
    }

    const promise = this.deps.runtimeManager.withSessionLock(sessionId, async () => {
      const active = this.deps.getActiveSession(key);
      if (active) {
        this.deps.resetIdleTimer(key);
        return active.session;
      }

      return this.deps.startSessionInner(key, sessionId, workspace);
    });

    this.starting.set(key, promise);
    try {
      return await promise;
    } finally {
      this.starting.delete(key);
    }
  }
}

import { EventRing } from "./event-ring.js";
import type { GateServer } from "./gate.js";
import type { SessionBackendEvent } from "./pi-events.js";
import { SdkBackend } from "./sdk-backend.js";
import type { ExtensionUIRequest } from "./session-events.js";
import type { PendingStop } from "./session-stop.js";
import type { Storage } from "./storage.js";
import { TurnDedupeCache } from "./turn-cache.js";
import type { ServerConfig, ServerMessage, Session, Workspace } from "./types.js";
import type { WorkspaceRuntime, WorkspaceSessionIdentity } from "./workspace-runtime.js";

export interface SessionStartActiveSession {
  session: Session;
  sdkBackend: SdkBackend;
  workspaceId: string;
  subscribers: Set<(msg: ServerMessage) => void>;
  pendingUIRequests: Map<string, ExtensionUIRequest>;
  partialResults: Map<string, string>;
  streamedAssistantText: string;
  hasStreamedThinking: boolean;
  turnCache: TurnDedupeCache;
  pendingTurnStarts: string[];
  pendingStop?: PendingStop;
  seq: number;
  eventRing: EventRing;
}

export interface SessionStartCoordinatorDeps {
  storage: Storage;
  runtimeManager: WorkspaceRuntime;
  config: ServerConfig;
  gate: GateServer;
  eventRingCapacity: number;
  getSkillPathResolver: () => ((skillNames: string[]) => string[]) | null;
  onPiEvent: (key: string, event: SessionBackendEvent) => void;
  onSessionEnd: (key: string, reason: string) => void;
  registerActiveSession: (key: string, active: SessionStartActiveSession) => void;
  persistSessionNow: (key: string, session: Session) => void;
  resetIdleTimer: (key: string) => void;
  bootstrapSessionState: (key: string) => Promise<void>;
}

export class SessionStartCoordinator {
  constructor(private readonly deps: SessionStartCoordinatorDeps) {}

  async startSessionInner(key: string, sessionId: string, workspace?: Workspace): Promise<Session> {
    const session = this.deps.storage.getSession(sessionId);
    if (!session) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    const identity = this.buildWorkspaceIdentity(session, workspace);

    return this.deps.runtimeManager.withWorkspaceLock(identity.workspaceId, async () => {
      this.deps.runtimeManager.reserveSessionStart(identity);

      try {
        const useGate = this.deps.config.permissionGate !== false;
        const skillPathResolver = this.deps.getSkillPathResolver();
        const skillPaths =
          workspace?.skills && skillPathResolver ? skillPathResolver(workspace.skills) : [];

        const sdkBackend = await SdkBackend.create({
          session,
          workspace,
          onEvent: (event) => this.deps.onPiEvent(key, event),
          onEnd: (reason) => this.deps.onSessionEnd(key, reason),
          gate: useGate ? this.deps.gate : undefined,
          workspaceId: identity.workspaceId,
          permissionGate: useGate,
          skillPaths,
        });

        const activeSession: SessionStartActiveSession = {
          session,
          sdkBackend,
          workspaceId: identity.workspaceId,
          subscribers: new Set(),
          pendingUIRequests: new Map(),
          partialResults: new Map(),
          streamedAssistantText: "",
          hasStreamedThinking: false,
          turnCache: new TurnDedupeCache(),
          pendingTurnStarts: [],
          seq: 0,
          eventRing: new EventRing(this.deps.eventRingCapacity),
        };

        this.deps.registerActiveSession(key, activeSession);
        this.deps.runtimeManager.markSessionReady(identity);

        session.status = "ready";
        session.lastActivity = Date.now();
        this.deps.persistSessionNow(key, session);
        this.deps.resetIdleTimer(key);

        void this.deps.bootstrapSessionState(key);

        return session;
      } catch (err) {
        this.deps.gate.destroySessionGuard(sessionId);
        this.deps.runtimeManager.releaseSession(identity);
        throw err;
      }
    });
  }

  buildWorkspaceIdentity(session: Session, workspace?: Workspace): WorkspaceSessionIdentity {
    return {
      workspaceId: this.resolveSessionWorkspaceId(session, workspace),
      sessionId: session.id,
    };
  }

  resolveSessionWorkspaceId(session: Session, workspace?: Workspace): string {
    if (workspace?.id && workspace.id.trim().length > 0) {
      return workspace.id;
    }

    if (session.workspaceId && session.workspaceId.trim().length > 0) {
      return session.workspaceId;
    }

    return `session-${session.id}`;
  }
}

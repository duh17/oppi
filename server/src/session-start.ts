import type { AgentDefinition } from "./agent-launch-service.js";
import { applyDefaultAgentSafetyDefaults, isDefaultAgentId } from "./default-agent.js";
import type { SessionBackendEvent } from "./pi-events.js";
import { SdkBackend } from "./sdk-backend.js";
import {
  createRuntimeSessionStateScaffold,
  type RuntimeSessionStateScaffold,
} from "./session-runtime-state.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import type { SessionMessageQueueStore } from "./session-queue.js";
import type { Storage } from "./storage.js";
import type { ServerConfig, Session, Workspace } from "./types.js";
import type { WorkspaceRuntime, WorkspaceSessionIdentity } from "./workspace-runtime.js";

export interface SessionStartActiveSession extends RuntimeSessionStateScaffold<SessionMessageQueueStore> {
  sdkBackend: SdkBackend;
  workspaceId: string;
}

export interface SessionStartCoordinatorDeps {
  storage: Storage;
  runtimeManager: WorkspaceRuntime;
  config: ServerConfig;
  eventRingCapacity: number;
  getSkillPathResolver: () => ((skillNames: string[]) => Promise<string[]>) | null;
  onPiEvent: (key: string, event: SessionBackendEvent) => void;
  onSessionEnd: (key: string, reason: string) => void;
  registerActiveSession: (key: string, active: SessionStartActiveSession) => void;
  persistSessionNow: (key: string, session: Session) => void;
  resetIdleTimer: (key: string) => void;
  bootstrapSessionState: (key: string) => Promise<void>;
  metrics?: ServerMetricCollector;
}

export class SessionStartCoordinator {
  constructor(private readonly deps: SessionStartCoordinatorDeps) {}

  async startSessionInner(key: string, sessionId: string, workspace?: Workspace): Promise<Session> {
    const session = this.deps.storage.getSession(sessionId);
    if (!session) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    const identity = this.buildWorkspaceIdentity(session, workspace);
    const previousStatus = session.status === "starting" ? "ready" : session.status;

    return this.deps.runtimeManager.withWorkspaceLock(identity.workspaceId, async () => {
      this.deps.runtimeManager.reserveSessionStart(identity);
      session.status = "starting";
      session.lastActivity = Date.now();
      this.deps.persistSessionNow(key, session);

      try {
        const createStart = Date.now();
        const sdkBackend = await SdkBackend.create({
          session,
          workspace,
          agentDefinition: this.resolveAgentDefinition(session),
          onEvent: (event) => this.deps.onPiEvent(key, event),
          onEnd: (reason) => this.deps.onSessionEnd(key, reason),
          dataDir: this.deps.storage.getDataDir(),
          metrics: this.deps.metrics,
          serverConfig: this.deps.config,
        });
        this.deps.metrics?.record("server.session_create_ms", Date.now() - createStart);

        const activeSession: SessionStartActiveSession = {
          ...createRuntimeSessionStateScaffold<SessionMessageQueueStore>(
            session,
            this.deps.eventRingCapacity,
          ),
          sdkBackend,
          workspaceId: identity.workspaceId,
        };

        this.deps.registerActiveSession(key, activeSession);
        this.deps.runtimeManager.markSessionReady(identity);

        session.status = "ready";
        session.currentTurnStartedAt = undefined;
        session.lastActivity = Date.now();
        this.deps.persistSessionNow(key, session);
        this.deps.resetIdleTimer(key);

        void this.deps.bootstrapSessionState(key);

        return session;
      } catch (err) {
        session.status = previousStatus;
        session.currentTurnStartedAt = undefined;
        session.lastActivity = Date.now();
        this.deps.persistSessionNow(key, session);
        this.deps.runtimeManager.releaseSession(identity);
        throw err;
      }
    });
  }

  private resolveAgentDefinition(session: Session): AgentDefinition | undefined {
    const agentId = session.launch?.agentId;
    if (!agentId) return undefined;
    const store = this.deps.storage.getAgentDefinitionStore();
    const agentVersion = session.launch?.agentVersion;
    let definition: AgentDefinition | undefined;
    if (agentVersion !== undefined) {
      definition = store.getAgentVersion(agentId, agentVersion)?.definition;
    }
    definition = definition ?? store.getAgent(agentId)?.definition;
    return definition && isDefaultAgentId(agentId)
      ? applyDefaultAgentSafetyDefaults(definition)
      : definition;
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

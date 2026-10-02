import type { AgentDefinition } from "./agent-launch-service.js";
import type { SessionBackendEvent } from "./pi-events.js";
import { SdkBackend } from "./sdk-backend.js";
import { isServerDurableSession } from "./session-runtime-capabilities.js";
import type { DurableHarness } from "./durable-harness.js";
import type { AgentBackend } from "./agent-backend.js";
import type { SdkUiBridge } from "./sdk-ui-bridge.js";
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
  sdkBackend: AgentBackend;
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
  /** True once the owning SessionManager is closed for server shutdown. */
  isClosed?: () => boolean;
  metrics?: ServerMetricCollector;
  durableHarness?: Promise<DurableHarness>;
  onUIBridgeReady?: (key: string, bridge: SdkUiBridge | undefined) => void;
  hasUI?: (key: string) => boolean;
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
    const assertOpen = (): void => {
      if (this.deps.isClosed?.()) throw new Error("Server is stopping; session not started");
    };

    return this.deps.runtimeManager.withWorkspaceLock(identity.workspaceId, async () => {
      assertOpen();
      this.deps.runtimeManager.reserveSessionStart(identity);
      session.status = "starting";
      session.lastActivity = Date.now();
      this.deps.persistSessionNow(key, session);

      let abandoned = false;
      try {
        const createStart = Date.now();
        const agentDefinition = this.resolveAgentDefinition(session);
        const sandboxRequired =
          workspace?.runtime === "sandbox" ||
          session.launch?.target?.runtime === "sandbox" ||
          agentDefinition?.launchConstraints?.requiredRuntime === "sandbox";
        if (session.serverDurable && sandboxRequired) {
          if (session.serverDurable.conversationId !== undefined)
            throw new Error("A server durable session cannot switch to a sandbox");
          delete session.serverDurable;
          session.warnings = [
            ...(session.warnings ?? []),
            "Server durable is host-only; using the SDK backend for this sandbox session",
          ];
        }
        if (session.serverDurable?.conversationId !== undefined && !this.deps.durableHarness) {
          throw new Error(
            "Enable experimental.serverDurable to resume this server durable session",
          );
        }
        const useDurable =
          this.deps.durableHarness && isServerDurableSession(session) && !session.piSessionFile;
        const durableHarness = useDurable ? await this.deps.durableHarness : undefined;
        const DurableBackend = useDurable
          ? (await import("./durable-backend.js")).DurableBackend
          : undefined;
        const sdkBackend: AgentBackend =
          DurableBackend && durableHarness
            ? await DurableBackend.create({
                ...(await durableHarness.open()),
                session,
                workspace,
                agentDefinition,
                dataDir: this.deps.storage.getDataDir(),
                persistBinding: () => this.deps.persistSessionNow(key, session),
                onEvent: (event) => this.deps.onPiEvent(key, event),
              })
            : await SdkBackend.create({
                session,
                workspace,
                agentDefinition,
                onEvent: (event) => this.deps.onPiEvent(key, event),
                onEnd: (reason) => this.deps.onSessionEnd(key, reason),
                dataDir: this.deps.storage.getDataDir(),
                getMobileOutputGuideSettings: () =>
                  this.deps.storage.getMobileOutputGuideSettings(),
                metrics: this.deps.metrics,
                serverConfig: this.deps.config,
                onUIBridgeReady: (bridge) => this.deps.onUIBridgeReady?.(key, bridge),
                hasUI: () => this.deps.hasUI?.(key) ?? false,
              });
        this.deps.metrics?.record("server.session_create_ms", Date.now() - createStart);

        // Shutdown already ran stopAll() and cannot see this runtime. Drop it
        // without registering or persisting: after an in-process update
        // restart, a replacement server shares this storage and owns the row.
        if (this.deps.isClosed?.()) {
          abandoned = true;
          await sdkBackend.dispose().catch(() => undefined);
          assertOpen();
        }

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

        if (DurableBackend && sdkBackend instanceof DurableBackend && durableHarness) {
          sdkBackend.startEvents();
          // submit/abort also enables the Harness-wide scheduler. Explicitly
          // resume after attaching the projection, never via a new user prompt.
          await durableHarness.resume();
        }
        void this.deps.bootstrapSessionState(key);

        return session;
      } catch (err) {
        if (!abandoned) {
          session.status = previousStatus;
          session.currentTurnStartedAt = undefined;
          session.lastActivity = Date.now();
          this.deps.persistSessionNow(key, session);
        }
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
    return definition;
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

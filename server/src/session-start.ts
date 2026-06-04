import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";

import { EventRing } from "./event-ring.js";
import type { SessionBackendEvent } from "./pi-events.js";
import { SdkBackend } from "./sdk-backend.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import type { ExtensionUIRequest, PendingAskState } from "./session-events.js";
import type { SessionMessageQueueStore } from "./session-queue.js";
import type { PendingStop } from "./session-stop.js";
import type { Storage } from "./storage.js";
import { TurnDedupeCache } from "./turn-cache.js";
import type { ServerConfig, ServerMessage, Session, Workspace } from "./types.js";
import type { WorkspaceRuntime, WorkspaceSessionIdentity } from "./workspace-runtime.js";
import type {
  ListChildSessions,
  SendSessionMessage,
  SpawnChildSession,
  SpawnDetachedSession,
  SubscribeToSession,
} from "./session-spawn-types.js";

export interface SessionStartActiveSession {
  session: Session;
  sdkBackend: SdkBackend;
  workspaceId: string;
  subscribers: Set<(msg: ServerMessage) => void>;
  pendingUIRequests: Map<string, ExtensionUIRequest>;
  persistentExtensionUINotifications?: Map<string, ExtensionUIRequest>;
  partialResults: Map<string, string>;
  streamedAssistantText: string;
  hasStreamedThinking: boolean;
  streamedThinkingContentIndexes: Set<number>;
  currentThinkingContentIndex?: number;
  toolNames: Map<string, string>;
  toolArgs: Map<string, Record<string, unknown>>;
  shellPreviewLastSent: Map<string, number>;
  streamingArgPreviews: Set<string>;
  streamingToolUpdatesSeen: Map<string, string>;
  pendingAsk?: PendingAskState;
  toolFullOutputPaths: Map<string, string>;
  messageQueue?: SessionMessageQueueStore;
  turnCache: TurnDedupeCache;
  pendingTurnStarts: string[];
  pendingStop?: PendingStop;
  seq: number;
  eventRing: EventRing;
  /** Output tokens when this activation started. Used to detect new work vs. prior-life tokens. */
  outputTokensAtStart: number;
}

export interface SessionStartCoordinatorDeps {
  storage: Storage;
  runtimeManager: WorkspaceRuntime;
  config: ServerConfig;
  eventRingCapacity: number;
  getSkillPathResolver: () => ((skillNames: string[]) => Promise<string[]>) | null;
  getAndClearPendingExtensionFactories: (sessionId: string) => ExtensionFactory[];
  onPiEvent: (key: string, event: SessionBackendEvent) => void;
  onSessionEnd: (key: string, reason: string) => void;
  registerActiveSession: (key: string, active: SessionStartActiveSession) => void;
  persistSessionNow: (key: string, session: Session) => void;
  resetIdleTimer: (key: string) => void;
  bootstrapSessionState: (key: string) => Promise<void>;
  // subagents extension support
  spawnChildSession: SpawnChildSession;
  spawnDetachedSession: SpawnDetachedSession;
  listChildSessions: ListChildSessions;
  subscribeToSession: SubscribeToSession;
  getAvailableModelIds: () => string[];
  stopSession: (sessionId: string) => Promise<void>;
  /** Resume a stopped session (restart its SDK process). */
  resumeSession: (sessionId: string) => Promise<Session>;
  /** Send a message to a session. Dispatches as prompt, steer, or follow-up based on state. */
  sendMessage: SendSessionMessage;
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
        const usePermissionGate = this.deps.config.permissionGate !== false;
        const skillPathResolver = this.deps.getSkillPathResolver();
        const skillPaths =
          workspace?.skills && skillPathResolver ? await skillPathResolver(workspace.skills) : [];
        const extraExtensionFactories = this.deps.getAndClearPendingExtensionFactories(sessionId);

        // Root/detached sessions get full tools (spawn, stop, send, inspect).
        // Child sessions get childMode (send, inspect only — no spawning).
        const isChildSession = !!session.parentSessionId;
        const subagentsCtx = {
          workspaceId: identity.workspaceId,
          sessionId: session.id,
          spawnChild: (params: {
            name?: string;
            model?: string;
            thinking?: string;
            prompt: string;
            activeTools?: string[];
            profileName?: string;
          }) => this.deps.spawnChildSession(session.id, params),
          spawnDetached: (params: {
            name?: string;
            model?: string;
            thinking?: string;
            prompt: string;
            activeTools?: string[];
            profileName?: string;
          }) => this.deps.spawnDetachedSession(session.id, params),
          listChildren: () => this.deps.listChildSessions(session.id),
          getSession: (id: string) => this.deps.storage.getSession(id),
          listWorkspaceSessions: () =>
            this.deps.storage.listSessions().filter((s) => s.workspaceId === identity.workspaceId),
          subscribe: (id: string, callback: (msg: ServerMessage) => void) =>
            this.deps.subscribeToSession(id, callback),
          getAvailableModelIds: () => this.deps.getAvailableModelIds(),
          stopSession: (id: string) => this.deps.stopSession(id),
          resumeSession: (id: string) => this.deps.resumeSession(id),
          sendMessage: (id: string, message: string, behavior?: "steer" | "followUp") =>
            this.deps.sendMessage(id, message, behavior),
        };
        const subagentConfig = this.deps.runtimeManager.getLimits().subagents;

        const createStart = Date.now();
        const sdkBackend = await SdkBackend.create({
          session,
          workspace,
          onEvent: (event) => this.deps.onPiEvent(key, event),
          onEnd: (reason) => this.deps.onSessionEnd(key, reason),
          permissionGate: usePermissionGate,
          skillPaths,
          builtInExtensionContext: {
            storage: this.deps.storage,
            subagents: {
              context: subagentsCtx,
              childMode: isChildSession,
              subagentConfig,
            },
          },
          extraExtensionFactories:
            extraExtensionFactories.length > 0 ? extraExtensionFactories : undefined,
          metrics: this.deps.metrics,
        });
        this.deps.metrics?.record("server.session_create_ms", Date.now() - createStart);

        const activeSession: SessionStartActiveSession = {
          session,
          sdkBackend,
          workspaceId: identity.workspaceId,
          subscribers: new Set(),
          pendingUIRequests: new Map(),
          persistentExtensionUINotifications: new Map(),
          partialResults: new Map(),
          streamedAssistantText: "",
          hasStreamedThinking: false,
          streamedThinkingContentIndexes: new Set(),
          toolNames: new Map(),
          toolArgs: new Map(),
          shellPreviewLastSent: new Map(),
          streamingArgPreviews: new Set(),
          streamingToolUpdatesSeen: new Map(),
          toolFullOutputPaths: new Map(),
          messageQueue: {
            version: 0,
            steering: [],
            followUp: [],
          },
          turnCache: new TurnDedupeCache(),
          pendingTurnStarts: [],
          seq: 0,
          eventRing: new EventRing(this.deps.eventRingCapacity),
          outputTokensAtStart: session.tokens.output,
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

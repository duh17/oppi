import type { ExtensionFactory } from "@mariozechner/pi-coding-agent";

import { createAutoresearchFactory } from "./autoresearch-extension.js";
import { EventRing } from "./event-ring.js";
import type { GateServer } from "./gate.js";
import type { SessionBackendEvent } from "./pi-events.js";
import { SdkBackend, resolveSdkSessionCwd } from "./sdk-backend.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import type { ExtensionUIRequest, PendingAskState } from "./session-events.js";
import type { SessionMessageQueueStore } from "./session-queue.js";
import type { PendingStop } from "./session-stop.js";
import { createSpawnAgentFactory } from "./spawn-agent-extension.js";
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
  toolNames: Map<string, string>;
  shellPreviewLastSent: Map<string, number>;
  streamingArgPreviews: Set<string>;
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
  gate: GateServer;
  eventRingCapacity: number;
  getSkillPathResolver: () => ((skillNames: string[]) => Promise<string[]>) | null;
  getAndClearPendingExtensionFactories: (sessionId: string) => ExtensionFactory[];
  onPiEvent: (key: string, event: SessionBackendEvent) => void;
  onSessionEnd: (key: string, reason: string) => void;
  registerActiveSession: (key: string, active: SessionStartActiveSession) => void;
  persistSessionNow: (key: string, session: Session) => void;
  resetIdleTimer: (key: string) => void;
  bootstrapSessionState: (key: string) => Promise<void>;
  // spawn_agent support
  spawnChildSession: (
    parentSessionId: string,
    params: { name?: string; model?: string; thinking?: string; prompt: string },
  ) => Promise<Session>;
  spawnDetachedSession: (
    originSessionId: string,
    params: { name?: string; model?: string; thinking?: string; prompt: string },
  ) => Promise<Session>;
  listChildSessions: (parentSessionId: string) => Session[];
  subscribeToSession: (sessionId: string, callback: (msg: ServerMessage) => void) => () => void;
  getAvailableModelIds: () => string[];
  stopSession: (sessionId: string) => Promise<void>;
  /** Resume a stopped session (restart its SDK process). */
  resumeSession: (sessionId: string) => Promise<Session>;
  /** Send a message to a session. Dispatches as prompt, steer, or follow-up based on state. */
  sendMessage: (
    sessionId: string,
    message: string,
    behavior?: "steer" | "followUp",
  ) => Promise<void>;
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

    return this.deps.runtimeManager.withWorkspaceLock(identity.workspaceId, async () => {
      this.deps.runtimeManager.reserveSessionStart(identity);

      try {
        const useGate = this.deps.config.permissionGate !== false;
        const skillPathResolver = this.deps.getSkillPathResolver();
        const skillPaths =
          workspace?.skills && skillPathResolver ? await skillPathResolver(workspace.skills) : [];
        const extraExtensionFactories = this.deps.getAndClearPendingExtensionFactories(sessionId);

        // Inject autoresearch extension for all workspace sessions.
        // Session ID scopes the worktree marker so different sessions
        // (parent, child, siblings) each get their own isolated worktree.
        const workspaceCwd = resolveSdkSessionCwd(workspace);
        extraExtensionFactories.push(
          createAutoresearchFactory(workspaceCwd, {
            sessionId: session.id,
          }),
        );

        // Inject spawn_agent extension for all sessions.
        // Root/detached sessions get full tools (spawn, stop, check, send, inspect).
        // Child sessions get childMode (check, send, inspect only — no spawning).
        const isChildSession = !!session.parentSessionId;
        const spawnAgentCtx = {
          workspaceId: identity.workspaceId,
          sessionId: session.id,
          spawnChild: (params: {
            name?: string;
            model?: string;
            thinking?: string;
            prompt: string;
          }) => this.deps.spawnChildSession(session.id, params),
          spawnDetached: (params: {
            name?: string;
            model?: string;
            thinking?: string;
            prompt: string;
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
        extraExtensionFactories.push(
          createSpawnAgentFactory(spawnAgentCtx, {
            childMode: isChildSession,
            subagentConfig,
          }),
        );

        const createStart = Date.now();
        const sdkBackend = await SdkBackend.create({
          session,
          workspace,
          onEvent: (event) => this.deps.onPiEvent(key, event),
          onEnd: (reason) => this.deps.onSessionEnd(key, reason),
          gate: useGate ? this.deps.gate : undefined,
          workspaceId: identity.workspaceId,
          permissionGate: useGate,
          skillPaths,
          storage: this.deps.storage,
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
          partialResults: new Map(),
          streamedAssistantText: "",
          hasStreamedThinking: false,
          toolNames: new Map(),
          shellPreviewLastSent: new Map(),
          streamingArgPreviews: new Set(),
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

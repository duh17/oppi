import type { AgentDefinition } from "./agent-launch-service.js";
import type { SessionBackendEvent } from "./pi-events.js";
import { resolveSdkSessionCwdAsync, SdkBackend } from "./sdk-backend.js";
import { isControlConversation } from "./control-session.js";
import {
  DURABLE_STORE_MISSING,
  durableStoreId,
  requireDurableStoreId,
  usesDurableEngine,
} from "./session-runtime-capabilities.js";
import type { DurableHarness, SessionHost } from "./durable-harness.js";
import type { DurableBackend as DurableBackendType } from "./durable-backend.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
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

const log = createLogger({ base: { component: "session_start" } });

export interface SessionStartActiveSession extends Omit<
  RuntimeSessionStateScaffold<SessionMessageQueueStore>,
  "messageQueue"
> {
  messageQueue?: SessionMessageQueueStore;
  sdkBackend: AgentBackend;
  workspaceId: string;
  releaseDurableHold?: () => void;
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
        // The flag decides whether durable sessions can be created. A bound
        // conversation always resumes on DurableBackend; a durable request that
        // never bound one goes back to the classic SDK backend while it is off.
        // The control conversation never falls back: it has no classic form, so a flag-off
        // start fails on the missing harness instead.
        if (
          session.serverDurable &&
          session.serverDurable.conversationId === undefined &&
          !isControlConversation(session) &&
          this.deps.config.experimental?.serverDurable !== true
        ) {
          delete session.serverDurable;
          session.warnings = [
            ...(session.warnings ?? []),
            "Durable sessions are no longer available on this server; this session uses the classic engine",
          ];
        }
        if (session.serverDurable && sandboxRequired && workspace?.runtime !== "sandbox") {
          throw new Error("Server durable sandbox sessions require a sandbox workspace");
        }
        const useDurable = usesDurableEngine(session);
        if (useDurable && durableStoreId(session) === undefined) {
          throw new Error(DURABLE_STORE_MISSING);
        }
        if (useDurable && !this.deps.durableHarness) {
          throw new Error(
            "Server durable session cannot start: the durable harness is unavailable",
          );
        }
        const durableHarness = useDurable ? await this.deps.durableHarness : undefined;
        const DurableBackend = useDurable
          ? (await import("./durable-backend.js")).DurableBackend
          : undefined;
        let durableHost: SessionHost | undefined;
        let releaseStart: (() => void) | undefined;
        if (DurableBackend && durableHarness) {
          const cwd = await resolveSdkSessionCwdAsync(workspace, session, {
            dataDir: this.deps.storage.getDataDir(),
          });
          const { durableStoreMetaFromSession } = await import("./durable-harness.js");
          durableHost = await durableHarness.openHost(
            requireDurableStoreId(session),
            durableStoreMetaFromSession(session, cwd),
          );
          releaseStart = durableHost.retain("start");
        }
        let sdkBackend: AgentBackend;
        try {
          sdkBackend =
            DurableBackend && durableHarness && durableHost
              ? await this.createDurableBackend(key, durableHost, session, workspace)
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

          if (sdkBackend.nativeMessageQueue) delete activeSession.messageQueue;
          if (durableHost) activeSession.releaseDurableHold = durableHost.retain("attach");
          this.deps.registerActiveSession(key, activeSession);
          this.deps.runtimeManager.markSessionReady(identity);

          session.status = "ready";
          session.currentTurnStartedAt = undefined;
          session.lastActivity = Date.now();
          this.deps.persistSessionNow(key, session);
          this.deps.resetIdleTimer(key);

          if (DurableBackend && sdkBackend instanceof DurableBackend && durableHost) {
            await sdkBackend.startEvents();
            // Snapshot replay can restore a live turn. Persist it before serving
            // reads: event projection normally saves on a debounce, which would
            // otherwise expose the earlier ready row during crash recovery.
            this.deps.persistSessionNow(key, session);
            // submit/abort also enables this store's scheduler. Explicitly
            // resume after attaching the projection, never via a new user prompt.
            await durableHost.resume();
          }
          void this.deps.bootstrapSessionState(key);

          return session;
        } finally {
          releaseStart?.();
        }
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

  private async createDurableBackend(
    key: string,
    host: SessionHost,
    session: Session,
    workspace: Workspace | undefined,
  ): Promise<DurableBackendType> {
    const { DurableBackend } = await import("./durable-backend.js");
    return DurableBackend.create({
      ...(await host.open()),
      host,
      session,
      workspace,
      agentDefinition: this.resolveAgentDefinition(session),
      dataDir: this.deps.storage.getDataDir(),
      persistBinding: () => this.deps.persistSessionNow(key, session),
      onEvent: (event) => this.deps.onPiEvent(key, event),
      onUIBridgeReady: (bridge) => this.deps.onUIBridgeReady?.(key, bridge),
      hasUI: () => this.deps.hasUI?.(key) ?? false,
      metrics: this.deps.metrics,
    });
  }

  /**
   * Swap a running durable session onto its store's reopened Harness after a storage error
   * closed the old one. Same as a start's attach, minus status changes: the session stays
   * active, and the new projection replays the conversation's live state to the socket.
   */
  async reattachDurable(
    key: string,
    active: SessionStartActiveSession,
    host: SessionHost,
  ): Promise<void> {
    const session = active.session;
    const workspace = session.workspaceId
      ? this.deps.storage.getWorkspace(session.workspaceId)
      : undefined;
    await this.deps.runtimeManager.withWorkspaceLock(active.workspaceId, async () => {
      // The old projection watched the failed Harness; its teardown may only find it closed.
      await active.sdkBackend.detachForRestart?.().catch((error: unknown) => {
        log.warn("session_start.durable_detach_failed", {
          sessionId: session.id,
          error: safeErrorMessage(error),
        });
      });
      const release = host.retain("reattach");
      try {
        const backend = await this.createDurableBackend(key, host, session, workspace);
        active.sdkBackend = backend;
        await backend.startEvents();
        this.deps.persistSessionNow(key, session);
        await host.resume();
      } finally {
        release();
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

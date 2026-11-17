/**
 * Session manager — pi agent lifecycle via SDK.
 *
 * Pi runs in-process via createAgentSession(). Permission prompts flow
 * through native Pi extensions and generic extension UI dialogs.
 *
 * Handles:
 * - Session lifecycle (start, stop, idle timeout)
 * - Agent event → simplified WebSocket message translation
 * - SDK command passthrough (model switching, compaction, etc.)
 */

import { EventEmitter } from "node:events";

import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { AgentRuntimeTransport, RuntimeClientCommand } from "./agent-runtime-transport.js";
import type { HeldTurnInput } from "./agent-runtime-transport.js";
import type { BackendRunState } from "./agent-backend.js";
import { SessionRestartHold } from "./session-restart-hold.js";
import { abandonQueuedResume, openQueuedStores } from "./session-restart-resume.js";
import type {
  ChatAttachmentRef,
  ConversationStreamAttach,
  ConversationStreamOlder,
  ConversationStreamServerMessage,
  ExtensionUISurfaceActionMessage,
  MessageQueueState,
  Session,
  ServerMessage,
  Workspace,
  ServerConfig,
} from "./types.js";
import type { Storage } from "./storage.js";
import { recordOwnerStop } from "./durable-ui.js";
import { WorkspaceRuntime, resolveRuntimeLimits } from "./workspace-runtime.js";
import { type SessionBackendEvent } from "./pi-events.js";
import { MobileRendererRegistry } from "./mobile-renderer.js";
import type { ServerTelemetry } from "./telemetry/server-telemetry.js";
import {
  createSessionCoordinatorBundle,
  type SessionCoordinatorBundle,
} from "./session-coordinators.js";
import type { SessionCatchUpResponse } from "./session-broadcast.js";
import { type SessionStartActiveSession } from "./session-start.js";
import { type SessionStateActiveSession } from "./session-state.js";
import { createLogger } from "./logger.js";
import { activeAwaitsNextTurn, type AutoStopGuard } from "./session-lifecycle.js";
import { isStopping, lifecyclePhase } from "./session-lifecycle-state.js";
import { safeErrorMessage } from "./log-utils.js";
import {
  buildPendingExtensionUIRequestMessages,
  cancelPendingAskRequest,
  handleExtensionUIRequest,
  respondToExtensionUIRequest,
  settleExtensionUIRequest,
  type ExtensionUIResponse,
} from "./extension-ui-state.js";
import type { DurableSearchSource, SearchIndex } from "./search-index.js";
import { updateSearchIndexForSessionEvent } from "./session-search-indexing.js";
import type { SessionRuntimeTransactionPermit } from "./session-runtime-transaction.js";
import { SDK_RUNTIME_LIFECYCLE_TIMEOUT_MS, SdkBackend } from "./sdk-backend.js";
import type { LiveEntryRendererSet, TraceEvent } from "./trace.js";
import { cacheMissNoticeSource, type CacheMissNoticeSource } from "./cache-miss.js";
import type { TracePageOptions, TracePageResult } from "./trace-paging.js";
import type { TraceOutlineResult } from "./trace-outline.js";
import type { SessionStopTimers } from "./session-stop.js";
import { sessionEventRingCapacity } from "./session-runtime-state.js";
import { notifySandboxWorkspaceActivity } from "./workspace-sandbox-lifecycle.js";
import { StartingRegistry } from "./session-starting.js";
import type { DurableSessionNaming } from "./durable-harness.js";
import type { SessionNotifyPort } from "./session-push-notifier.js";
import type { LayoutFiles } from "./layout-files.js";
import { SessionSurfaces, type SessionMessageSubscriber } from "./session-surfaces.js";
import type { ExtensionUISurfaceAudience } from "./extension-surface-runtime.js";
import type { LiveVoiceSpeech } from "./live-voice-speech.js";

const log = createLogger({ base: { component: "sessions" } });
/** A store-open fence at least this slow logs at info; faster ones log at debug. */
const FENCE_SLOW_MS = 50;

// ─── Types ───

type ActiveSession = SessionStartActiveSession;

// ─── Session Manager ───

import type { DurableExtensionReport, DurableHarness, SessionHost } from "./durable-harness.js";
import type { PluginCatalog } from "./plugin-host.js";
import { loadedScreens, type ScreenHost } from "./plugin-screens.js";
import { loadDurableHarness } from "./session-durable-harness.js";
import { createDurableSearchSource } from "./durable-search-source.js";
import {
  durableSessionConversations,
  durableStoreId,
  hasServerDurableBinding,
  requireDurableStoreId,
} from "./session-runtime-capabilities.js";
import type { ConversationId, EntryId, Harness } from "@earendil-works/pi-durable";

export class SessionManager extends EventEmitter implements AgentRuntimeTransport {
  private readonly loadDurableHarness: () => Promise<DurableHarness>;
  private durableHarnessLoad?: Promise<DurableHarness>;
  /**
   * The Harness loads on first use, not at construction: a manager that never needs it (a
   * unit-test Server that is built and dropped) leaves no import running behind it.
   */
  private get durableHarness(): Promise<DurableHarness> {
    this.durableHarnessLoad ??= this.loadDurableHarness();
    return this.durableHarnessLoad;
  }
  private storage: Storage;
  private active: Map<string, ActiveSession> = new Map();
  /** Sessions between `start_begun` and `start_registered`/`start_failed`; see `StartingRegistry`. */
  private readonly starting = new StartingRegistry();
  /** Callers of `withIncomingWork` per session whose work has not committed yet. */
  private readonly incomingWork = new Map<string, number>();
  private readonly config: ServerConfig;
  /**
   * `experimental.serverDurable` as this server runs it: read at startup, then set by the
   * Durable Sessions setting's save (`setDurableSessionsAvailable`).
   */
  private durableSessionsOn: boolean;
  private readonly runtimeManager: WorkspaceRuntime;

  /** Injected by the server to resolve context window for a model ID. */
  contextWindowResolver: ((modelId: string) => number) | null = null;

  /** Injected by the server to resolve skill names to host directory paths. */
  skillPathResolver: ((skillNames: string[]) => Promise<string[]>) | null = null;

  /** Injected by the server: who is offered the agent `notify` tool, and its send. */
  notifyPort: SessionNotifyPort | null = null;
  layoutFiles: LayoutFiles | null = null;

  /** Injected by the server: names a Session for durable extensions (the auto-name extension). */
  sessionNaming: DurableSessionNaming | null = null;

  /** Injected by the server for per-turn operational metrics. */
  opsMetrics: ServerTelemetry | null = null;

  /** Injected by the server for full-text search index updates. */
  searchIndex: SearchIndex | null = null;

  /** Injected by the server: the agent side of Live Voice calls (the `speak` tool). */
  liveVoiceSpeech: LiveVoiceSpeech | null = null;

  /** The session side of server restarts (session-restart-hold.ts). */
  readonly restartHold = new SessionRestartHold({
    storage: () => this.storage,
    liveSessions: () => this.active.values(),
    liveSession: (sessionId) => this.active.get(this.sessionKey(sessionId)),
    emit: (sessionId, event) => this.handlePiEvent(this.sessionKey(sessionId), event),
    broadcast: (sessionId, message) => this.broadcast(this.sessionKey(sessionId), message),
    sendPrompt: (sessionId, message, opts) => this.sendPrompt(sessionId, message, opts),
  });

  private readonly mobileRenderers: MobileRendererRegistry;
  private mobileRenderersLoadStarted = false;

  private readonly broadcaster: SessionCoordinatorBundle["broadcaster"];
  private readonly stateCoordinator: SessionCoordinatorBundle["stateCoordinator"];
  private readonly commandCoordinator: SessionCoordinatorBundle["commandCoordinator"];
  private readonly lifecycleCoordinator: SessionCoordinatorBundle["lifecycleCoordinator"];
  private readonly inputCoordinator: SessionCoordinatorBundle["inputCoordinator"];
  private readonly queueCoordinator: SessionCoordinatorBundle["queueCoordinator"];
  private readonly agentEventCoordinator: SessionCoordinatorBundle["agentEventCoordinator"];
  private readonly stopFlowCoordinator: SessionCoordinatorBundle["stopFlowCoordinator"];
  private readonly stopCoordinator: SessionCoordinatorBundle["stopCoordinator"];
  private readonly startCoordinator: SessionCoordinatorBundle["startCoordinator"];

  constructor(storage: Storage, metrics?: ServerTelemetry, stopTimers?: SessionStopTimers) {
    super();
    this.storage = storage;
    if (metrics) this.opsMetrics = metrics;
    const config = storage.getConfig();
    this.config = config;
    this.durableSessionsOn = config.experimental?.serverDurable === true;
    // Every server runs the Harness: Oppi Control sessions are durable whether or not
    // `experimental.serverDurable` is on. The flag gates only ordinary durable sessions
    // (`engine: "durable"` creates and `capabilities.durableSessions`).
    this.loadDurableHarness = () =>
      loadDurableHarness({
        storage,
        fenceStopped: (hosts) => this.fenceStopped(hosts),
        recoverSessions: (host, failure) => this.recoverDurableSessions(host, failure),
        threads: {
          withIncomingWork: (sessionId, workspace, submit) =>
            this.withIncomingWork(sessionId, workspace, submit),
          onCreated: (session) => this.emit("session_created", session),
          trace: (sessionId) => this.getServerDurableTrace(sessionId, "context"),
        },
        surfacesFor: (sessionId) => this.surfacesFor(sessionId),
        activeSession: (sessionId) => this.getActiveSession(sessionId),
        sessionNaming: () => this.sessionNaming,
        notifyPort: () => this.notifyPort,
        liveVoiceSpeech: () => this.liveVoiceSpeech,
      });
    const runtimeManager = new WorkspaceRuntime(resolveRuntimeLimits(config));
    this.runtimeManager = runtimeManager;
    this.mobileRenderers = new MobileRendererRegistry();

    const bundle = createSessionCoordinatorBundle({
      storage,
      config,
      durableHarness: () => this.durableHarness,
      durableSessionsAvailable: () => this.durableSessionsAvailable(),
      runtimeManager,
      active: this.active,
      mobileRenderers: this.mobileRenderers,
      eventRingCapacity: sessionEventRingCapacity(),
      stopAbortTimeoutMs: this.stopAbortTimeoutMs,
      stopAbortRetryTimeoutMs: this.stopAbortRetryTimeoutMs,
      stopSessionGraceMs: this.stopSessionGraceMs,
      stopSessionBoundMs: this.stopSessionBoundMs,
      stopTimers,
      getContextWindowResolver: () => this.contextWindowResolver,
      getSkillPathResolver: () => this.skillPathResolver,
      getNotifyPort: () => this.notifyPort,
      getLayoutFiles: () => this.layoutFiles,
      emitSessionEvent: (payload) => this.emit("session_event", payload),
      onProgramStatusChange: (session, change) =>
        this.emit("program_status_change", session, change),
      onPiEvent: (key, event) => this.handlePiEvent(key, event),
      onRunState: (key, state) => this.handleRunState(key, state),
      // Sockets streaming the branch left follow the session to its new one (`stream.ts`).
      onConversationSwitched: (key) => {
        const session = this.active.get(key)?.session;
        if (session) this.broadcast(key, { type: "state", session });
        if (session) this.searchIndex?.reindexSession(session.id);
      },
      hasUI: (key) =>
        (this.starting.get(key)?.subscribers.size ?? 0) > 0 ||
        (this.active.get(key)?.subscribers.size ?? 0) > 0,
      onUIBridgeReady: (key, bridge) => {
        const entry = this.starting.get(key);
        if (!entry) return;
        if (bridge)
          entry.dialogs = { bridge, state: { session: { id: key }, pendingUIRequests: new Map() } };
        else if (!entry.dialogs?.state.pendingUIRequests.size) entry.dialogs = undefined;
      },
      takeStartupUIRequests: (key) => {
        const entry = this.starting.get(key);
        const requests = entry?.dialogs?.state.pendingUIRequests;
        if (entry) entry.dialogs = undefined;
        return requests;
      },
      onSessionEnd: (key, reason, stopConfirmationReason) =>
        this.handleSessionEnd(key, reason, stopConfirmationReason),
      persistSessionNow: (key, session) => this.persistSessionNow(key, session),
      markSessionDirty: (key) => this.markSessionDirty(key),
      resetIdleTimer: (key) => this.resetIdleTimer(key),
      bootstrapSessionState: (key) => this.bootstrapSessionState(key),
      isClosed: () => this.closed,
      sendCommand: (key, command, permit, onPreflightAccepted) =>
        this.sendCommand(key, command, permit, onPreflightAccepted),
      sendCommandAsync: (key, command) => this.sendCommandAsync(key, command),
      broadcast: (key, message) => this.broadcast(key, message),
      stopSession: (sessionId) => this.stopSession(sessionId),
      autoStopSession: (sessionId, guard) => this.autoStopSession(sessionId, guard),
      metrics: this.opsMetrics ?? undefined,
      getLiveVoiceExtension: () => {
        const speech = this.liveVoiceSpeech;
        return speech ? (sessionId) => speech.extension(sessionId) : undefined;
      },
    });

    this.broadcaster = bundle.broadcaster;
    this.stateCoordinator = bundle.stateCoordinator;
    this.commandCoordinator = bundle.commandCoordinator;
    this.lifecycleCoordinator = bundle.lifecycleCoordinator;
    this.inputCoordinator = bundle.inputCoordinator;
    this.queueCoordinator = bundle.queueCoordinator;
    this.agentEventCoordinator = bundle.agentEventCoordinator;
    this.stopFlowCoordinator = bundle.stopFlowCoordinator;
    this.stopCoordinator = bundle.stopCoordinator;
    this.startCoordinator = bundle.startCoordinator;
    this.ensureMobileRenderersLoaded();
  }

  /** Focused streams can relay startup dialogs before the SDK runtime exists. */
  subscribeStartupUI(sessionId: string, send: (message: ServerMessage) => void): () => void {
    const key = this.sessionKey(sessionId);
    const entry = this.starting.claim(key);
    entry.subscribers.add(send);
    if (entry.dialogs)
      for (const message of buildPendingExtensionUIRequestMessages(entry.dialogs.state))
        send({ ...message, sessionId });
    let detached = false;
    return () => {
      if (detached) return;
      detached = true;
      entry.subscribers.delete(send);
      this.starting.release(key, entry);
    };
  }

  private broadcastStartupUI(key: string, message: ServerMessage): void {
    const framed: ServerMessage = { ...message, sessionId: key };
    // Same app-event ingress live notifies use (`emitSessionEvent` → mux).
    // Startup runs before `active`, so SessionBroadcaster cannot emit this.
    this.emit("session_event", { sessionId: key, event: framed });
    for (const send of this.starting.get(key)?.subscribers ?? []) send(framed);
  }

  get mobileRenderer(): MobileRendererRegistry {
    return this.mobileRenderers;
  }

  private resolveStoredWorkspace(sessionId: string): Workspace | undefined {
    const session = this.storage.getSession(sessionId);
    if (!session?.workspaceId) {
      return undefined;
    }

    return this.storage.getWorkspace(session.workspaceId) ?? undefined;
  }

  private ensureMobileRenderersLoaded(): void {
    if (this.mobileRenderersLoadStarted) return;
    this.mobileRenderersLoadStarted = true;

    this.mobileRenderers
      .loadAllRenderers()
      .then(({ loaded, errors }) => {
        if (loaded.length > 0) {
          log.info("sessions.mobile_renderer.loaded", {
            count: loaded.length,
            loaded,
          });
        }
        for (const err of errors) {
          log.error("sessions.mobile_renderer_load.error", {
            error: String(err),
          });
        }
      })
      .catch((err: unknown) => {
        const message = err instanceof Error ? err.message : String(err);
        log.error("sessions.mobile_renderer_load.error", {
          error: message,
        });
      });
  }

  // ─── Session Lifecycle ───

  /**
   * Single-user session key.
   */
  private sessionKey(sessionId: string): string {
    return sessionId;
  }

  /** Starts a session. Concurrent callers share one start; a stop before it registers wins. */
  async startSession(sessionId: string, workspace?: Workspace): Promise<Session> {
    const key = this.sessionKey(sessionId);
    this.ensureMobileRenderersLoaded();
    const startWorkspace = workspace ?? this.resolveStoredWorkspace(sessionId);

    const activeNow = this.active.get(key);
    if (activeNow) {
      this.resetIdleTimer(key);
      return activeNow.session;
    }

    const entry = this.starting.claim(key);
    if (entry.start) return entry.start.promise;
    // Read before the start can save `starting`.
    const priorStatus = this.storage.getSession(sessionId)?.status ?? "stopped";
    const promise = this.runtimeManager.withSessionLock(sessionId, async () => {
      const activeAgain = this.active.get(key);
      if (activeAgain) {
        this.resetIdleTimer(key);
        return activeAgain.session;
      }
      return this.startCoordinator.startSessionInner(
        key,
        sessionId,
        startWorkspace,
        () => entry.start?.stopRequested === true,
      );
    });
    entry.start = { promise, priorStatus, stopRequested: false };

    try {
      return await promise;
    } finally {
      entry.start = undefined;
      this.starting.release(key, entry);
    }
  }

  /**
   * Retarget a session without a live runtime so its next start seeds `model`.
   * Runs under the activation lock: a concurrent start reads either the old or the
   * new model. Returns undefined when the session went live; callers then forward
   * set_model to the runtime instead.
   */
  async setInactiveSessionModel(sessionId: string, model: string): Promise<Session | undefined> {
    const key = this.sessionKey(sessionId);
    return this.runtimeManager.withSessionLock(sessionId, async () => {
      if (this.active.has(key)) return undefined;
      const session = this.storage.getSession(sessionId);
      if (!session) throw new Error(`Session not found: ${sessionId}`);
      session.model = model;
      const contextWindow = this.contextWindowResolver?.(model);
      if (typeof contextWindow === "number") session.contextWindow = contextWindow;
      this.storage.saveSession(session);
      return session;
    });
  }

  /** Process a pi agent event from the SDK subscribe callback. */
  private handlePiEvent(key: string, data: SessionBackendEvent): void {
    try {
      const startup = !this.active.has(key) ? this.starting.get(key)?.dialogs : undefined;
      if (startup && data.type === "extension_ui_request") {
        handleExtensionUIRequest(startup.state, data, {
          broadcast: (message) => this.broadcastStartupUI(key, message),
        });
        return;
      }
      if (startup && data.type === "extension_ui_request_settled") {
        settleExtensionUIRequest(startup.state, data.id, {
          broadcastSettled: (message) => this.broadcastStartupUI(key, message),
        });
        return;
      }
      this.agentEventCoordinator.handlePiEvent(key, data);
      this.liveVoiceSpeech?.observe(key, data);
      updateSearchIndexForSessionEvent(this.searchIndex, key, data);
    } catch (error: unknown) {
      log.error("sessions.pi_event_handler.failed", {
        sessionId: key,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  /** A durable run's start, progress or settle. A throw would end the backend's view watch. */
  private handleRunState(key: string, state: BackendRunState): void {
    try {
      this.agentEventCoordinator.handleRunState(key, state);
    } catch (error: unknown) {
      log.error("sessions.run_state_handler.failed", {
        sessionId: key,
        state: typeof state === "string" ? state : "progress",
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  // ─── Extension UI Protocol ───

  /**
   * Send extension_ui_response back to pi (in-process gate).
   * Called by server.ts when phone responds to a UI dialog.
   */
  respondToUIRequest(sessionId: string, response: ExtensionUIResponse): boolean | Promise<boolean> {
    const key = this.sessionKey(sessionId);
    const active = this.active.get(key);
    if (!active) {
      const startup = this.starting.get(key)?.dialogs;
      return respondToExtensionUIRequest(startup?.state, response, {
        deliver: (payload) => startup?.bridge.respond(payload) ?? false,
        broadcastSettled: (message) => this.broadcastStartupUI(key, message),
      });
    }
    return respondToExtensionUIRequest(active, response, {
      metrics: this.opsMetrics ?? undefined,
      deliver: (payload) => {
        return active.sdkBackend.respondToExtensionUIRequest(payload);
      },
      broadcastSettled: (message) => this.broadcast(key, message),
    });
  }

  /**
   * Send a prompt to pi. Handles streaming state.
   *
   * SDK prompt rules:
   * - If agent is idle: send as `prompt`
   * - If agent is streaming: must specify behavior
   */
  async sendPrompt(
    sessionId: string,
    message: string,
    opts?: {
      attachments?: ChatAttachmentRef[];
      streamingBehavior?: "steer" | "followUp";
      clientTurnId?: string;
      requestId?: string;
      timestamp?: number;
    },
  ): Promise<void | HeldTurnInput> {
    const held = this.restartHold.hold(sessionId, message, opts);
    if (held) return held;
    const key = this.sessionKey(sessionId);
    await this.inputCoordinator.sendPrompt(key, message, {
      ...opts,
    });
    this.claimFromRestartResume(sessionId);
  }

  /**
   * Input to a session supersedes its pending post-restart continuation: the
   * sender now directs the turn. A client merely opening or reconnecting to the
   * session does not, so the continuation still goes out. The resume's own
   * continuation also lands here, after the entry has done its job.
   */
  private claimFromRestartResume(sessionId: string): void {
    this.storage.clearRestartResume(sessionId);
  }

  /**
   * Send a steer message (interrupt agent after current tool).
   *
   * Guard: steer is only valid while the session is actively streaming.
   * If called while idle, throw a deterministic error so the client can
   * surface feedback instead of appearing stuck.
   */
  async sendSteer(
    sessionId: string,
    message: string,
    opts?: {
      attachments?: ChatAttachmentRef[];
      clientTurnId?: string;
      requestId?: string;
    },
  ): Promise<void> {
    const key = this.sessionKey(sessionId);
    await this.inputCoordinator.sendSteer(key, message, opts);
    this.claimFromRestartResume(sessionId);
  }

  /**
   * Send a follow-up message (delivered after agent finishes).
   *
   * Guard: follow-up queueing is only meaningful while a turn is streaming.
   */
  async sendFollowUp(
    sessionId: string,
    message: string,
    opts?: {
      attachments?: ChatAttachmentRef[];
      clientTurnId?: string;
      requestId?: string;
    },
  ): Promise<void | HeldTurnInput> {
    const held = this.restartHold.hold(sessionId, message, opts, true);
    if (held) return held;
    const key = this.sessionKey(sessionId);
    await this.inputCoordinator.sendFollowUp(key, message, opts);
    this.claimFromRestartResume(sessionId);
  }

  getMessageQueue(sessionId: string): MessageQueueState | Promise<MessageQueueState> {
    const key = this.sessionKey(sessionId);
    return this.queueCoordinator.getQueue(key);
  }

  removeQueuedMessage(sessionId: string, itemId: string): Promise<MessageQueueState> {
    return this.queueCoordinator.removeQueuedMessage(this.sessionKey(sessionId), itemId);
  }

  takeMessageQueue(sessionId: string): Promise<MessageQueueState> {
    return this.queueCoordinator.takeQueue(this.sessionKey(sessionId));
  }

  /**
   * Best-effort bootstrap of pi session metadata (session file/UUID).
   *
   * Needed so stopped sessions can still reconstruct trace history.
   */
  private async bootstrapSessionState(key: string): Promise<void> {
    const active = this.active.get(key);
    if (!active) return;

    await this.stateCoordinator.bootstrapSessionState(key, active as SessionStateActiveSession);
  }

  /**
   * Refresh live pi state for an active session and return trace metadata.
   * Used by REST trace endpoint to recover session traces.
   */
  async refreshSessionState(
    sessionId: string,
  ): Promise<{ sessionFile?: string; sessionId?: string; leafId?: string | null } | null> {
    const key = this.sessionKey(sessionId);
    const active = this.active.get(key);
    if (!active) return null;

    return this.stateCoordinator.refreshSessionState(key, active as SessionStateActiveSession);
  }

  /** Conversation id when this session is bound to a durable conversation. */
  private boundConversationId(sessionId: string): ConversationId | undefined {
    const session = this.storage.getSession(sessionId);
    if (!session || !hasServerDurableBinding(session)) return undefined;
    return session.serverDurable.conversationId as ConversationId;
  }

  /** Runs `read` against the session's durable conversation; null without one. */
  async withDurableConversation<T>(
    sessionId: string,
    read: (harness: Harness, conversationId: ConversationId) => Promise<T>,
  ): Promise<T | null> {
    const session = this.storage.getSession(sessionId);
    const conversationId = this.boundConversationId(sessionId);
    if (!session || conversationId === undefined) return null;
    return (await this.durableHarness).withSession(session, (harness) =>
      read(harness, conversationId),
    );
  }

  /** The owner's Stop of a durable session (`recordOwnerStop`); auto-stop does not call it. */
  async recordOwnerStop(sessionId: string): Promise<void> {
    await this.withDurableConversation(sessionId, recordOwnerStop);
  }

  async getServerDurableInputCardOutput(
    sessionId: string,
    entryId: string,
  ): Promise<{ output: string } | null> {
    return this.withDurableConversation(sessionId, (harness, conversationId) =>
      import("./durable-input-cards.js").then(({ readDurableInputCardOutput }) =>
        readDurableInputCardOutput(harness, conversationId, entryId),
      ),
    );
  }

  async getServerDurableTracePage(
    sessionId: string,
    options: TracePageOptions,
  ): Promise<TracePageResult | null> {
    return this.withDurableConversation(sessionId, (harness, conversationId) =>
      import("./durable-history.js").then(({ readDurableTracePage }) => {
        // Same image scope the full trace and the stream use: the session bound to the
        // conversation, which is where the bytes are stored.
        const session = this.storage.getSession(sessionId);
        const images = session ? this.messageImageScope(session, conversationId) : undefined;
        return readDurableTracePage(harness, conversationId, {
          ...options,
          ...(images
            ? { attachmentDataDir: images.dataDir, attachmentSessionId: images.sessionId }
            : {}),
          entryRenderers: this.getEntryRenderers(sessionId),
          cacheMissNotices: this.getCacheMissNotices(sessionId),
        });
      }),
    );
  }

  async getServerDurableTraceOutline(sessionId: string): Promise<TraceOutlineResult | null> {
    return this.withDurableConversation(sessionId, (harness, conversationId) =>
      import("./durable-history.js").then(({ readDurableTraceOutline }) =>
        readDurableTraceOutline(
          harness,
          conversationId,
          this.mobileRenderer,
          this.getEntryRenderers(sessionId),
        ),
      ),
    );
  }

  /**
   * Whether create requests may ask for `engine: "durable"`. Read from config at startup and
   * changed live by the Durable Sessions setting; already-bound durable sessions run either way.
   * Every server runs the Harness (Oppi Control is durable), so nothing else follows it.
   */
  durableSessionsAvailable(): boolean {
    return this.durableSessionsOn;
  }

  /** Applies a saved Durable Sessions setting to new creates, without a restart. */
  setDurableSessionsAvailable(enabled: boolean): void {
    this.durableSessionsOn = enabled;
  }

  /** Discover and load every plugin again into the Harness registry. */
  async reloadDurableExtensions(): Promise<DurableExtensionReport> {
    return (await this.durableHarness).reloadExtensions();
  }

  /** The plugins' sidebar entries and screens, loading the plugins first. */
  async pluginScreens(): Promise<ScreenHost | undefined> {
    await (await this.durableHarness).ensureShared();
    return loadedScreens();
  }

  /** Every plugin, installed or failed, as the extension list shows it (`listPlugins`). */
  async listPlugins(): Promise<PluginCatalog> {
    const harness = await this.durableHarness;
    await harness.ensureShared();
    return harness.listPlugins();
  }

  /**
   * Enable or disable the installed durable extension `name` in the server config: in
   * `experimental.durableExtensions.enabled` for a built-in that ships off, else in `disabled`.
   * New sessions follow at once; a bound session at its next attach. A required built-in stays on
   * whatever the config says.
   */
  async setPluginEnabled(name: string, enabled: boolean): Promise<void> {
    const harness = await this.durableHarness;
    // The plugins say which built-ins ship off.
    await harness.ensureShared();
    const list = harness.offByDefault(name) ? "enabled" : "disabled";
    const listed = list === "enabled" ? enabled : !enabled;
    // From the file as it is now: `oppi config set` writes it from another process.
    this.storage.mutateConfig((latest) => {
      const experimental = latest.experimental ?? {};
      const switches = experimental.durableExtensions ?? {};
      const others = (switches[list] ?? []).filter((other) => other !== name);
      return {
        experimental: {
          ...experimental,
          durableExtensions: { ...switches, [list]: listed ? [...others, name] : others },
        },
      };
    });
  }

  /**
   * The conversation an `attach` on `session`'s socket streams: the session's own, or in `live`
   * mode any conversation it owns, directly or through its children. Fails for a session that
   * is not bound to a durable conversation, or a request for another session or for a
   * conversation outside that subtree.
   */
  async conversationStreamTarget(
    session: Session,
    request: ConversationStreamAttach,
  ): Promise<number> {
    const bound = this.boundConversationId(session.id);
    const runtime = this.durableHarness;
    if (bound === undefined) throw new Error("The conversation stream requires a durable session");
    if (request.sessionId !== undefined && request.sessionId !== session.id)
      throw new Error(`The conversation stream cannot target session ${request.sessionId}`);
    const target = (request.conversationId ?? bound) as ConversationId;
    if (target === bound) return bound;
    if (request.mode !== "live")
      throw new Error(`Conversation ${target} is not this session's conversation`);
    const harness = await runtime;
    const host = await harness.openHost(requireDurableStoreId(session));
    if (!(await harness.boundThreads?.ownsWithin(host, bound, target)))
      throw new Error(`Conversation ${target} is not in this session's thread`);
    return target;
  }

  /**
   * Where the images of a conversation's user messages and tool results are stored: the session
   * bound to it, in the server's data directory. Absent only when a conversation has no session
   * to own them.
   */
  private messageImageScope(
    session: Session,
    conversationId: number,
  ): { dataDir: string; sessionId: string } | undefined {
    const owner = this.storage.findSessionByDurableConversation(
      requireDurableStoreId(session),
      conversationId,
    );
    if (!owner) return undefined;
    return { dataDir: this.storage.getDataDir(), sessionId: owner.id };
  }

  /**
   * Attach a socket to conversation `conversationId`, which `conversationStreamTarget` allowed
   * for this request. Sends the first frame before resolving; the returned function ends the
   * stream.
   */
  async attachConversationStream(
    session: Session,
    conversationId: number,
    request: ConversationStreamAttach,
    send: (frame: ConversationStreamServerMessage) => void,
  ): Promise<() => void> {
    const host = await (await this.durableHarness).openHost(requireDurableStoreId(session));
    const images = this.messageImageScope(session, conversationId);
    return host.transcript(conversationId as ConversationId, {
      renderers: this.mobileRenderers,
      ...(images ? { images } : {}),
      cacheMissNotices: () => this.getCacheMissNotices(session.id),
      mode: request.mode ?? "full",
      ...(request.afterEntryId !== undefined ? { afterEntryId: request.afterEntryId } : {}),
      send,
    });
  }

  /** The conversation stream's `older` frame for the session's durable conversation. */
  async olderConversationEntries(
    session: Session,
    request: ConversationStreamOlder,
  ): Promise<Extract<ConversationStreamServerMessage, { type: "older" }>> {
    const conversationId = this.boundConversationId(session.id);
    if (conversationId === undefined)
      throw new Error("The conversation stream requires a durable session");
    const host = await (await this.durableHarness).openHost(requireDurableStoreId(session));
    const images = this.messageImageScope(session, conversationId);
    return host.olderEntries(conversationId, {
      renderers: this.mobileRenderers,
      ...(images ? { images } : {}),
      cacheMissNotices: this.getCacheMissNotices(session.id),
      beforeEntryId: request.beforeEntryId,
      ...(request.limit !== undefined ? { limit: request.limit } : {}),
    });
  }

  durableSearchSource(): DurableSearchSource {
    return createDurableSearchSource(this.storage, () => this.durableHarness);
  }

  async getServerDurableTrace(
    sessionId: string,
    view: "context" | "full",
  ): Promise<TraceEvent[] | null> {
    return this.withDurableConversation(sessionId, (harness, conversationId) =>
      import("./durable-history.js").then(({ readDurableTrace }) => {
        const session = this.storage.getSession(sessionId);
        const images = session ? this.messageImageScope(session, conversationId) : undefined;
        return readDurableTrace(
          harness,
          conversationId,
          view,
          this.getEntryRenderers(sessionId),
          images,
          this.getCacheMissNotices(sessionId),
        );
      }),
    );
  }

  /**
   * Fork a bound server durable conversation at a trace/fork-point entry id. Resolves the new
   * conversation id, or `undefined` when the entry is not part of the source's history.
   */
  async forkServerDurableConversation(
    sessionId: string,
    entryId: string,
  ): Promise<ConversationId | undefined> {
    const conversationId = this.boundConversationId(sessionId);
    if (conversationId === undefined) {
      throw new Error("Server durable fork requires a bound conversation");
    }
    // Trace entry ids are the decimal Durable entry ids.
    if (!/^[1-9]\d*$/.test(entryId) || !Number.isSafeInteger(Number(entryId))) return undefined;
    const session = this.storage.getSession(sessionId);
    if (!session) throw new Error("Server durable fork requires a bound conversation");
    return (await this.durableHarness).withSession(session, async (_harness, host) =>
      (await host.controller(conversationId)).fork(Number(entryId) as EntryId),
    );
  }

  /**
   * Delete durable store `storeId` once no session names it. One store holds a whole session
   * tree (its root, the children it spawned, and forks), so it goes with the tree's last
   * session. Resolves whether the store was deleted.
   */
  async deleteUnusedServerDurableStore(storeId: string): Promise<boolean> {
    if (this.storage.hasDurableStoreSessions(storeId)) return false;
    await (await this.durableHarness).deleteStore(storeId);
    return true;
  }

  /**
   * Run a SDK command against an active session and await response.
   * Used by HTTP workflows (e.g. server-orchestrated fork/session operations).
   */
  async runCommand(sessionId: string, command: Record<string, unknown>): Promise<unknown> {
    const key = this.sessionKey(sessionId);
    if (!this.active.has(key)) {
      throw new Error(`Session not active: ${sessionId}`);
    }

    return this.sendCommandAsync(key, { ...command });
  }

  // ─── SDK Command Handlers ───

  /**
   * Forward a client WebSocket command to the pi SDK.
   *
   * Used for commands that map 1:1 to SDK methods (model switching,
   * thinking level, session management, etc.). The response is
   * broadcast back as a `command_result` ServerMessage.
   */
  async forwardClientCommand(
    sessionId: string,
    message: RuntimeClientCommand,
    requestId?: string,
  ): Promise<void> {
    const key = this.sessionKey(sessionId);
    if (this.restartHold.refuseCommand(sessionId, message, requestId)) return;
    await this.commandCoordinator.forwardClientCommand(
      key,
      message,
      requestId,
      (commandKey, command) => this.sendCommandAsync(commandKey, command),
    );
  }

  /**
   * Abort the current agent operation.
   *
   * Abort the current turn. Does NOT stop the session — the SDK backend
   * stays alive and ready for the next prompt.
   */
  async sendAbort(sessionId: string): Promise<void> {
    const key = this.sessionKey(sessionId);
    // cancelPendingAsk runs inside the session lock (via preAbort callback)
    // to serialize with respondToUIRequest. This prevents the race where a
    // stop message arriving before an ask answer silently discards the answer.
    await this.stopFlowCoordinator.sendAbort(key, sessionId, () => {
      this.cancelPendingAsk(sessionId);
    });
  }

  /** Graceful abort budget before escalating. */
  private readonly stopAbortTimeoutMs = 8_000;

  /** After escalation, wait this long before giving up (session stays alive). */
  private readonly stopAbortRetryTimeoutMs = 5_000;

  /** Grace period between abort and dispose in force-stop flow. */
  private readonly stopSessionGraceMs = 1_000;

  /**
   * Documented stop/stopAll bound from permit wait through forced disposal.
   * Sessions stop in parallel, so the same bound applies to stopAll.
   */
  private readonly stopSessionBoundMs = this.stopSessionGraceMs + SDK_RUNTIME_LIFECYCLE_TIMEOUT_MS;

  // ─── SDK Commands ───

  /**
   * Send a fire-and-forget command to the SDK backend.
   */
  sendCommand(
    key: string,
    command: Record<string, unknown>,
    permit?: SessionRuntimeTransactionPermit,
    onPreflightAccepted?: () => void,
  ): void | Promise<unknown> {
    const result = this.commandCoordinator.sendCommand(key, command, permit, onPreflightAccepted);
    this.resetIdleTimer(key);
    return result;
  }

  /**
   * Send a command to the SDK backend and await the result.
   * Dispatches through the declarative SDK_HANDLERS map.
   */
  async sendCommandAsync(key: string, command: Record<string, unknown>): Promise<unknown> {
    return this.commandCoordinator.sendCommandAsync(key, command);
  }

  // ─── Persistence ───

  private markSessionDirty(key: string): void {
    const active = this.active.get(key);
    if (active) this.syncSandboxWorkspaceActivity(active.session);
    this.broadcaster.markSessionDirty(key);
  }

  private persistSessionNow(key: string, session: Session): void {
    this.broadcaster.persistSessionNow(key, session);
    this.syncSandboxWorkspaceActivity(session);
  }

  private syncSandboxWorkspaceActivity(session: Session): void {
    const workspace = session.workspaceId
      ? this.storage.getWorkspace(session.workspaceId)
      : undefined;
    notifySandboxWorkspaceActivity(session, workspace, SdkBackend);
  }

  // ─── Session End ───

  private async handleSessionEnd(
    key: string,
    reason: string,
    stopConfirmationReason?: string,
  ): Promise<void> {
    this.commandCoordinator.cancelQueuedCompactions(key);
    const releaseDurableHold = this.active.get(key)?.releaseDurableHold;
    await this.lifecycleCoordinator.handleSessionEnd(key, reason, stopConfirmationReason);
    releaseDurableHold?.();
  }

  // ─── Subscribe / Broadcast ───

  subscribe(sessionId: string, callback: SessionMessageSubscriber): () => void {
    return this.broadcaster.subscribe(this.sessionKey(sessionId), callback);
  }

  broadcastSessionMessage(sessionId: string, message: ServerMessage): number {
    return this.broadcaster.broadcast(this.sessionKey(sessionId), message);
  }

  // ─── Composable surfaces ───

  /**
   * The surface loop of a live Session, created on first use. It is the Session's own state: a
   * plugin publishes into it, a client taps into it, and it stops with the Session.
   */
  surfacesFor(sessionId: string): SessionSurfaces | undefined {
    const key = this.sessionKey(sessionId);
    const active = this.active.get(key);
    if (!active) {
      return undefined;
    }
    active.surfaces ??= new SessionSurfaces({
      sessionId: active.session.id,
      emit: (message, audience) => this.broadcaster.broadcast(key, message, audience),
    });
    return active.surfaces;
  }

  /** The live surfaces a client that has just subscribed draws, in the shape it draws. */
  getSurfaceMessages(sessionId: string, clientId: string): ServerMessage[] {
    return this.active.get(this.sessionKey(sessionId))?.surfaces?.messages(clientId) ?? [];
  }

  /**
   * What a client says it draws, on subscribe, and the frames that reconcile it: the live surfaces
   * in that shape, and the v1 widgets it held cleared when it starts drawing composites.
   */
  declareSurfaceCapabilities(
    sessionId: string,
    clientId: string,
    capabilities: readonly string[],
  ): ServerMessage[] {
    return this.surfacesFor(sessionId)?.declare(clientId, capabilities) ?? [];
  }

  /** Whether a tap could reach this Session's surface loop now; false when it is not live. */
  canActOnSurface(sessionId: string): boolean {
    return this.surfacesFor(sessionId)?.canAct() ?? false;
  }

  /** One tap from one client; false when the Session is not live. */
  actOnSurface(
    sessionId: string,
    message: ExtensionUISurfaceActionMessage,
    clientId: string,
  ): Promise<boolean> {
    const surfaces = this.surfacesFor(sessionId);
    return surfaces ? surfaces.act(message, clientId) : Promise.resolve(false);
  }

  /** The shape this client draws for this Session's surfaces; the v1 projection until it says. */
  surfaceAudience(sessionId: string, clientId: string): ExtensionUISurfaceAudience {
    return (
      this.active.get(this.sessionKey(sessionId))?.surfaces?.audience(clientId) ?? "v1-projection"
    );
  }

  /** A socket that closed: nothing else reads the shape it said it draws. */
  forgetSurfaceAudience(sessionId: string, clientId: string): void {
    this.active.get(this.sessionKey(sessionId))?.surfaces?.forget(clientId);
  }

  /** Persist an assistant fixture on the active Pi branch for deterministic E2E replay. */
  appendE2EAssistantMessage(sessionId: string, content: string): boolean {
    if (process.env.OPPI_E2E_UI_HARNESS !== "1") return false;

    const active = this.active.get(this.sessionKey(sessionId));
    if (!active) return false;

    active.sdkBackend.appendAssistantMessage(content, active.session.model);
    return true;
  }

  private broadcast(key: string, message: ServerMessage): void {
    this.broadcaster.broadcast(key, message);
  }

  // ─── Stop ───

  async stopSession(sessionId: string, preserveRestartResume = false): Promise<void> {
    if (!preserveRestartResume) this.storage.clearRestartResume(sessionId);
    const key = this.sessionKey(sessionId);
    // A start in flight sees `stopRequested` before it registers a runtime and ends without
    // one: the stop wins before the row is ever saved `ready`.
    const starting = this.starting.get(key);
    if (starting?.start) {
      starting.start.stopRequested = true;
      // A dialog an extension opened at startup holds the start until it is answered: Stop
      // dismisses it rather than wait for an answer that may never come.
      starting.dialogs?.bridge.cancelDialogs();
      await starting.start.promise.catch(() => undefined);
    }
    if (!this.isActive(sessionId)) {
      const session = this.storage.getSession(sessionId);
      const ids = session ? (durableSessionConversations(session) as ConversationId[]) : [];
      if (session && ids.length && durableStoreId(session)) {
        await (
          await this.durableHarness
        ).withSession(session, (_harness, host) => host.abortConversations(new Set(ids)));
      }
      return;
    }
    // cancelPendingAsk runs inside the session lock (via preStop callback)
    // so it serializes with respondToUIRequest, matching the sendAbort pattern.
    await this.stopFlowCoordinator.stopSession(key, sessionId, () => {
      this.cancelPendingAsk(sessionId);
    });
  }

  /**
   * Auto-stop's Stop. Under the session lock it reads the backend (`guard.idle`) and then,
   * with no await between, rechecks the session and the incoming work that
   * `withIncomingWork` announces, and marks the stop pending. Work announced first keeps
   * the session; work announced after waits for the stop and attaches the session again.
   */
  private async autoStopSession(sessionId: string, guard: AutoStopGuard): Promise<boolean> {
    const key = this.sessionKey(sessionId);
    const decided = await this.runtimeManager.withSessionLock(sessionId, async () => {
      if (!this.active.has(key) || this.incomingWork.has(sessionId)) return false;
      if (!(await guard.idle())) return false;
      const active = this.active.get(key);
      if (!active || isStopping(active.session)) return false;
      if (this.incomingWork.has(sessionId) || !guard.still()) return false;
      this.stopCoordinator.beginPendingStop(key, active, "terminate", "user");
      return true;
    });
    if (decided) await this.stopSession(sessionId);
    return decided;
  }

  /**
   * Attach a session for work that reaches it from outside its socket (a parent's message to
   * its durable child), then run `submit`, the commit that delivers the work. From this call
   * until `submit` settles the session counts as having incoming work, so auto-stop keeps it;
   * a stop already under way finishes first and the session starts again. When the count
   * drops to zero on a ready session, auto-stop decides again: the work either started a run
   * (which settles later) or never came (its caller went away, or it was already answered).
   */
  private async withIncomingWork<T>(
    sessionId: string,
    workspace: Workspace | undefined,
    submit: () => Promise<T>,
  ): Promise<{ attached: true; value: T } | { attached: false; error: unknown; closing: boolean }> {
    this.incomingWork.set(sessionId, (this.incomingWork.get(sessionId) ?? 0) + 1);
    try {
      try {
        await this.attachForWork(sessionId, workspace);
      } catch (error) {
        return { attached: false, error, closing: this.closed };
      }
      return { attached: true, value: await submit() };
    } finally {
      this.releaseIncomingWork(sessionId);
    }
  }

  private async attachForWork(sessionId: string, workspace?: Workspace): Promise<void> {
    const key = this.sessionKey(sessionId);
    const state = await this.runtimeManager.withSessionLock(sessionId, async () => {
      const active = this.active.get(key);
      if (!active) return "stopped";
      if (lifecyclePhase(active.session).name === "terminating") return "stopping";
      this.resetIdleTimer(key);
      return "running";
    });
    if (state === "running") return;
    if (state === "stopping") await this.stopSession(sessionId);
    await this.startSession(sessionId, workspace);
  }

  private releaseIncomingWork(sessionId: string): void {
    const left = (this.incomingWork.get(sessionId) ?? 1) - 1;
    if (left > 0) {
      this.incomingWork.set(sessionId, left);
      return;
    }
    this.incomingWork.delete(sessionId);
    const key = this.sessionKey(sessionId);
    const active = this.active.get(key);
    if (active?.session.status === "ready") this.lifecycleCoordinator.handleSessionSettled(key);
  }

  /** Set by close(); no session starts or registers afterward. */
  private closed = false;

  /**
   * Server shutdown: refuse new starts, drop starts still in flight, and stop
   * every running session. A SessionManager is not reopened after this.
   */
  async close(): Promise<void> {
    this.closed = true;
    // A Harness that never loaded has nothing to close; do not load one to close it.
    const runtime = await this.durableHarnessLoad;
    if (runtime) runtime.shuttingDown = true;
    const pending = new Set(this.storage.listRestartResume().map((entry) => entry.sessionId));
    try {
      await Promise.all(
        [...this.active.entries()].map(async ([key, active]) => {
          if (pending.has(active.session.id) && active.sdkBackend.detachForRestart) {
            await active.sdkBackend.detachForRestart();
            await this.handleSessionEnd(key, "server_restart");
          } else await this.stopSession(active.session.id, pending.has(active.session.id));
        }),
      );
    } finally {
      await runtime?.closeAll();
    }
  }

  /** Fail closed if production opens the Harness without the catalog model runtime. */
  async expectDurableModelRuntime(): Promise<void> {
    await this.durableHarness.then((harness) => harness.requireDiscoveredModels());
  }

  /** Share the server ModelRuntime so global provider overlays apply to durable inference. */
  async bindDurableModels(models: ModelRuntime): Promise<void> {
    await this.durableHarness.then((harness) => harness.bindModelRuntime(models));
    log.info("sessions.durable_models_bound");
  }

  /**
   * A storage error closed a store's Harness. Recovered: move each running session of that
   * tree onto the reopened Harness and say so once. Given up: end those sessions with the error,
   * since nothing can run or commit there.
   */
  private async recoverDurableSessions(host: SessionHost, failure: unknown): Promise<void> {
    for (const [key, active] of [...this.active]) {
      if (durableStoreId(active.session) !== host.storeId) continue;
      let error: string;
      if (failure === undefined) {
        try {
          await this.startCoordinator.reattachDurable(key, active, host);
          this.handlePiEvent(key, {
            type: "notice",
            id: `durable-store-recovered:${Date.now()}`,
            message: "Session store recovered after a storage error",
          });
          continue;
        } catch (reattachError) {
          log.error("sessions.durable_reattach_failed", {
            sessionId: active.session.id,
            error: safeErrorMessage(reattachError),
          });
          // The store failed again while this re-attached: its next recovery re-attaches
          // the session or ends it.
          if (host.failedWithStore(reattachError)) continue;
          // Only this session: the store reopened, and the others re-attach on their own.
          error = `This session could not re-attach after a storage error: ${safeErrorMessage(reattachError)}`;
        }
      } else {
        error = `This session's store failed and could not reopen: ${safeErrorMessage(failure)}`;
      }
      this.handlePiEvent(key, { type: "prompt_error", error });
      // The backend's own dispose would need the store; release its sandbox work directly.
      await active.sdkBackend.detachForRestart?.().catch(() => undefined);
      for (const conversationId of durableSessionConversations(active.session))
        await host.unbindSandboxEnv(conversationId as ConversationId, true).catch(() => undefined);
      await this.handleSessionEnd(key, "store_failed");
    }
  }

  /** Abort leftover work of conversations that are neither active nor queued to resume. */
  private async fenceStopped(hosts: readonly SessionHost[]): Promise<void> {
    if (!hosts.length) return;
    const queued = new Set(this.storage.listRestartResume().map((entry) => entry.sessionId));
    for (const host of hosts) {
      // Each store open fences, and a startup opens hundreds of stores: read only this store's
      // sessions, not a sorted copy of every session on the server.
      const ids = new Set<ConversationId>();
      for (const session of this.storage.listDurableStoreSessions(host.storeId)) {
        const conversationId = session.serverDurable?.conversationId as ConversationId | undefined;
        if (conversationId === undefined) continue;
        // Only a queued session needs its workspace read (a file read per session per open).
        const workspaceGone = (): boolean =>
          Boolean(session.workspaceId && !this.storage.getWorkspace(session.workspaceId));
        if (this.isActive(session.id) || (queued.has(session.id) && !workspaceGone())) continue;
        // `startSession` opens the store after writing "starting": keep a live session's work, but
        // still fence a stopped one being reopened so leftover jobs stay aborted.
        const prior = this.starting.get(this.sessionKey(session.id))?.start?.priorStatus;
        if (prior !== undefined && prior !== "stopped" && prior !== "stopping") continue;
        for (const id of durableSessionConversations(session)) ids.add(id as ConversationId);
      }
      if (!ids.size) continue;
      const started = Date.now();
      await host.abortConversations(ids, { background: true });
      const elapsedMs = Date.now() - started;
      // A first start after an upgrade opens every store; only a slow fence is worth an info line.
      (elapsedMs >= FENCE_SLOW_MS ? log.info : log.debug)("sessions.fence_stopped", {
        storeId: host.storeId,
        count: ids.size,
        elapsedMs,
      });
    }
  }

  /** Attach every crash-resumed projection before enabling each store's scheduler. */
  async resumeDurableSessions(): Promise<void> {
    const runtime = await this.durableHarness;
    runtime.startupHeld = true;
    const bound = this.storage
      .listSessions()
      .filter((session) => hasServerDurableBinding(session) && durableStoreId(session));
    const queued = new Set(this.storage.listRestartResume().map((entry) => entry.sessionId));
    const storeIds = new Set<string>();
    for (const session of bound) {
      const storeId = durableStoreId(session);
      if (storeId && queued.has(session.id)) storeIds.add(storeId);
    }
    if (!storeIds.size) {
      await runtime.finishStartup();
      return;
    }
    const unusable = await openQueuedStores(runtime, storeIds, (hosts) => this.fenceStopped(hosts));
    for (const session of bound) {
      const workspace = session.workspaceId
        ? this.storage.getWorkspace(session.workspaceId)
        : undefined;
      if (session.workspaceId && !workspace) continue;
      if (!this.storage.listRestartResume().some((entry) => entry.sessionId === session.id))
        continue;
      const storeFailure = unusable.get(durableStoreId(session) ?? "");
      if (storeFailure !== undefined) {
        abandonQueuedResume(this.storage, session.id, storeFailure);
        continue;
      }
      try {
        await this.startSession(session.id, workspace);
      } catch (error) {
        abandonQueuedResume(this.storage, session.id, error);
      }
    }
    for (;;) {
      const pending = new Set(this.storage.listRestartResume().map((entry) => entry.sessionId));
      const attachedStops = bound.filter((session) => {
        const workspaceGone = Boolean(
          session.workspaceId && !this.storage.getWorkspace(session.workspaceId),
        );
        return this.isActive(session.id) && (!pending.has(session.id) || workspaceGone);
      });
      await this.fenceStopped(runtime.openHosts());
      if (!attachedStops.length) break;
      for (const session of attachedStops) await this.stopSession(session.id);
    }
    for (const session of bound) this.storage.clearRestartResume(session.id);
    await runtime.finishStartup();
  }

  async stopAll(): Promise<void> {
    const sessionIds = Array.from(this.active.values()).map((active) => active.session.id);
    await Promise.all(sessionIds.map((sessionId) => this.stopSession(sessionId)));
  }

  // ─── State Queries ───

  isActive(sessionId: string): boolean {
    return this.active.has(this.sessionKey(sessionId));
  }

  isSessionConnected(sessionId: string): boolean {
    return this.isActive(sessionId);
  }

  /**
   * Whether a `ready` live session will start its next turn: a background job or supervised
   * child still waits to wake it, or the turn it started is not running yet. A job or child
   * clears its wake as it starts that turn, but status turns `busy` only on `agent_start`,
   * after Pi's before-start hooks, so the pending-work check closes that gap (auto-stop reads
   * the same pair). Any other status skips the backend read. A failed check reads as no wake:
   * a supervisor's wait must settle, not hang.
   */
  async awaitsNextTurn(sessionId: string): Promise<boolean> {
    const active = this.active.get(this.sessionKey(sessionId));
    if (!active) return false;
    return activeAwaitsNextTurn(active);
  }

  /** Number of bound session-stream subscribers for the active session. */
  getSubscriberCount(sessionId: string): number {
    return this.active.get(this.sessionKey(sessionId))?.subscribers.size ?? 0;
  }

  /** Set of session IDs currently held in memory (genuinely running). */
  getActiveSessionIds(): Set<string> {
    const ids = new Set<string>();
    for (const active of this.active.values()) {
      ids.add(active.session.id);
    }
    return ids;
  }

  getActiveSession(sessionId: string): Session | undefined {
    return this.active.get(this.sessionKey(sessionId))?.session;
  }

  /** Return replayable extension UI notifications and pending dialogs for stream re-subscribe. */
  getPendingUIRequestMessages(sessionId: string): ServerMessage[] {
    return buildPendingExtensionUIRequestMessages(this.active.get(this.sessionKey(sessionId)));
  }

  /** Inject a synthetic extension UI request into runtime state, then broadcast it. */
  injectExtensionUIRequest(
    sessionId: string,
    message: Extract<ServerMessage, { type: "extension_ui_request" }>,
  ): number {
    const key = this.sessionKey(sessionId);
    const active = this.active.get(key);
    if (!active) {
      return 0;
    }

    handleExtensionUIRequest(active, message, {
      broadcast: (broadcastMessage) => this.broadcast(key, broadcastMessage),
    });
    return active.subscribers.size;
  }

  /** Cancel a pending ask request. */
  cancelPendingAsk(sessionId: string): void {
    const key = this.sessionKey(sessionId);
    const active = this.active.get(key);
    if (!active) {
      return;
    }

    if (active.sdkBackend.cancelsExtensionUIOnAbort) return;
    cancelPendingAskRequest(active, {
      metrics: this.opsMetrics ?? undefined,
      deliver: (payload) => {
        const delivered = active.sdkBackend.respondToExtensionUIRequest(payload);
        if (typeof delivered !== "boolean")
          throw new Error("Backends with async UI answers must own Abort cancellation");
        return delivered;
      },
      broadcastSettled: (message) => this.broadcast(key, message),
    });
  }

  getEntryRenderers(sessionId: string): LiveEntryRendererSet | undefined {
    return this.active.get(this.sessionKey(sessionId))?.sdkBackend.getEntryRenderers();
  }

  /** Where history derives its cache-miss notices: set while the session's Pi settings show them. */
  getCacheMissNotices(sessionId: string): CacheMissNoticeSource | undefined {
    return cacheMissNoticeSource(this.active.get(this.sessionKey(sessionId))?.sdkBackend);
  }

  getToolFullOutputPath(sessionId: string, toolCallId: string): string | null {
    const active = this.active.get(this.sessionKey(sessionId));
    if (!active) {
      return null;
    }

    const normalizedToolCallId = toolCallId.trim();
    if (normalizedToolCallId.length === 0) {
      return null;
    }

    return active.toolFullOutputPaths.get(normalizedToolCallId) ?? null;
  }

  getToolPartialOutput(sessionId: string, toolCallId: string): string | null {
    const key = toolCallId.trim();
    return key
      ? (this.active.get(this.sessionKey(sessionId))?.toolOutputSnapshots.fullOutput(key) ?? null)
      : null;
  }

  /** Return the event ring for an active session (for utilization sampling). */
  getEventRing(sessionId: string): { length: number; capacity: number } | null {
    const active = this.active.get(this.sessionKey(sessionId));
    if (!active) return null;
    return { length: active.eventRing.length, capacity: active.eventRing.capacity };
  }

  getCurrentSeq(sessionId: string): number {
    return this.broadcaster.getCurrentSeq(this.sessionKey(sessionId));
  }

  getCatchUp(sessionId: string, sinceSeq: number): SessionCatchUpResponse | null {
    return this.broadcaster.getCatchUp(this.sessionKey(sessionId), sinceSeq);
  }

  hasPendingUIRequest(sessionId: string, requestId: string): boolean {
    return this.active.get(this.sessionKey(sessionId))?.pendingUIRequests.has(requestId) ?? false;
  }

  // ─── Idle Management ───

  private resetIdleTimer(key: string): void {
    this.lifecycleCoordinator.resetIdleTimer(key);
  }
}

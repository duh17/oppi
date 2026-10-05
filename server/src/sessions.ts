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
import type {
  ChatAttachmentRef,
  MessageQueueState,
  Session,
  SessionPromptCacheWarmer,
  ServerMessage,
  Workspace,
  ServerConfig,
} from "./types.js";
import type { Storage } from "./storage.js";
import { WorkspaceRuntime, resolveRuntimeLimits } from "./workspace-runtime.js";
import { type SessionBackendEvent } from "./pi-events.js";
import { MobileRendererRegistry } from "./mobile-renderer.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import {
  createSessionCoordinatorBundle,
  type SessionCoordinatorBundle,
} from "./session-coordinators.js";
import type { SessionCatchUpResponse } from "./session-broadcast.js";
import { type SessionStartActiveSession } from "./session-start.js";
import { type SessionStateActiveSession } from "./session-state.js";
import { createLogger } from "./logger.js";
import {
  buildPendingExtensionUIRequestMessages,
  cancelPendingAskRequest,
  handleExtensionUIRequest,
  respondToExtensionUIRequest,
  settleExtensionUIRequest,
  type ExtensionUIState,
  type ExtensionUIResponse,
} from "./extension-ui-state.js";
import type { DurableSearchSource, SearchIndex } from "./search-index.js";
import { updateSearchIndexForSessionEvent } from "./session-search-indexing.js";
import type { SessionRuntimeTransactionPermit } from "./session-runtime-transaction.js";
import { SDK_RUNTIME_LIFECYCLE_TIMEOUT_MS, SdkBackend } from "./sdk-backend.js";
import type { LiveEntryRendererSet, TraceEvent } from "./trace.js";
import type { TracePageOptions, TracePageResult } from "./trace-paging.js";
import type { TraceOutlineResult } from "./trace-outline.js";
import type { SessionStopTimers } from "./session-stop.js";
import { notifySandboxWorkspaceActivity } from "./workspace-sandbox-lifecycle.js";
import type { SdkUiBridge } from "./sdk-ui-bridge.js";

const log = createLogger({ base: { component: "sessions" } });

function parsePositiveIntEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) {
    return fallback;
  }

  const parsed = Number.parseInt(raw, 10);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    return fallback;
  }

  return parsed;
}

// ─── Types ───

type ActiveSession = SessionStartActiveSession;

// ─── Session Manager ───

import type { DurableHarness } from "./durable-harness.js";
import { hasServerDurableBinding } from "./session-runtime-capabilities.js";
import type { ConversationId, EntryId, Harness } from "@earendil-works/pi-durable";

export class SessionManager extends EventEmitter implements AgentRuntimeTransport {
  private readonly durableHarness?: Promise<DurableHarness>;
  private storage: Storage;
  private active: Map<string, ActiveSession> = new Map();
  private readonly config: ServerConfig;
  private readonly runtimeManager: WorkspaceRuntime;
  private readonly startupUI = new Map<string, { bridge: SdkUiBridge; state: ExtensionUIState }>();
  private readonly startupUISubscribers = new Map<string, Set<(message: ServerMessage) => void>>();

  /** Injected by the server to resolve context window for a model ID. */
  contextWindowResolver: ((modelId: string) => number) | null = null;

  /** Injected by the server to resolve skill names to host directory paths. */
  skillPathResolver: ((skillNames: string[]) => Promise<string[]>) | null = null;

  /** Injected by the server for auto-title generation on first message. */
  onFirstMessage: ((session: Session) => void) | null = null;

  /** Injected by the server for per-turn operational metrics. */
  opsMetrics: ServerMetricCollector | null = null;

  /** Injected by the server for full-text search index updates. */
  searchIndex: SearchIndex | null = null;

  private readonly mobileRenderers: MobileRendererRegistry;
  private mobileRenderersLoadStarted = false;

  private readonly broadcaster: SessionCoordinatorBundle["broadcaster"];
  private readonly stateCoordinator: SessionCoordinatorBundle["stateCoordinator"];
  private readonly commandCoordinator: SessionCoordinatorBundle["commandCoordinator"];
  private readonly activationCoordinator: SessionCoordinatorBundle["activationCoordinator"];
  private readonly lifecycleCoordinator: SessionCoordinatorBundle["lifecycleCoordinator"];
  private readonly inputCoordinator: SessionCoordinatorBundle["inputCoordinator"];
  private readonly queueCoordinator: SessionCoordinatorBundle["queueCoordinator"];
  private readonly agentEventCoordinator: SessionCoordinatorBundle["agentEventCoordinator"];
  private readonly stopFlowCoordinator: SessionCoordinatorBundle["stopFlowCoordinator"];

  constructor(storage: Storage, metrics?: ServerMetricCollector, stopTimers?: SessionStopTimers) {
    super();
    this.storage = storage;
    if (metrics) this.opsMetrics = metrics;
    const config = storage.getConfig();
    this.config = config;
    // The flag only gates enrolling NEW sessions. Rows already bound to a
    // conversation still need the Harness for history, resume, and Stop, so a
    // flag-off host with none stays zero-cost and never imports durable code.
    if (
      config.experimental?.serverDurable === true ||
      storage.listSessions().some(hasServerDurableBinding)
    ) {
      this.durableHarness = Promise.all([
        import("./durable-harness.js"),
        import("./durable-threads.js"),
      ]).then(([{ DurableHarness }, { DurableThreads }]) => {
        const owner = new DurableHarness(storage.getDataDir());
        owner.bindThreads(
          new DurableThreads({
            owner,
            storage,
            startSession: (sessionId, workspace) => this.startSession(sessionId, workspace),
            isActive: (sessionId) => this.isActive(sessionId),
            onCreated: (session) => this.emit("session_created", session),
          }),
        );
        return owner;
      });
    }
    const runtimeManager = new WorkspaceRuntime(resolveRuntimeLimits(config));
    this.runtimeManager = runtimeManager;
    this.mobileRenderers = new MobileRendererRegistry();
    const eventRingCapacity = parsePositiveIntEnv("OPPI_SESSION_EVENT_RING_CAPACITY", 500);

    const bundle = createSessionCoordinatorBundle({
      storage,
      config,
      durableHarness: this.durableHarness,
      runtimeManager,
      active: this.active,
      mobileRenderers: this.mobileRenderers,
      eventRingCapacity,
      stopAbortTimeoutMs: this.stopAbortTimeoutMs,
      stopAbortRetryTimeoutMs: this.stopAbortRetryTimeoutMs,
      stopSessionGraceMs: this.stopSessionGraceMs,
      stopSessionBoundMs: this.stopSessionBoundMs,
      stopTimers,
      getContextWindowResolver: () => this.contextWindowResolver,
      getSkillPathResolver: () => this.skillPathResolver,
      emitSessionEvent: (payload) => this.emit("session_event", payload),
      onPiEvent: (key, event) => this.handlePiEvent(key, event),
      hasUI: (key) =>
        (this.startupUISubscribers.get(key)?.size ?? 0) > 0 ||
        (this.active.get(key)?.subscribers.size ?? 0) > 0,
      onUIBridgeReady: (key, bridge) => {
        if (bridge)
          this.startupUI.set(key, {
            bridge,
            state: { session: { id: key }, pendingUIRequests: new Map() },
          });
        else if (!this.startupUI.get(key)?.state.pendingUIRequests.size) this.startupUI.delete(key);
      },
      takeStartupUIRequests: (key) => {
        const requests = this.startupUI.get(key)?.state.pendingUIRequests;
        this.startupUI.delete(key);
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
      onFirstMessage: (session) => this.onFirstMessage?.(session),
      metrics: this.opsMetrics ?? undefined,
    });

    this.broadcaster = bundle.broadcaster;
    this.stateCoordinator = bundle.stateCoordinator;
    this.commandCoordinator = bundle.commandCoordinator;
    this.activationCoordinator = bundle.activationCoordinator;
    this.lifecycleCoordinator = bundle.lifecycleCoordinator;
    this.inputCoordinator = bundle.inputCoordinator;
    this.queueCoordinator = bundle.queueCoordinator;
    this.agentEventCoordinator = bundle.agentEventCoordinator;
    this.stopFlowCoordinator = bundle.stopFlowCoordinator;
    this.ensureMobileRenderersLoaded();
  }

  /** Focused streams can relay startup dialogs before the SDK runtime exists. */
  subscribeStartupUI(sessionId: string, send: (message: ServerMessage) => void): () => void {
    let subscribers = this.startupUISubscribers.get(sessionId);
    if (!subscribers) {
      subscribers = new Set();
      this.startupUISubscribers.set(sessionId, subscribers);
    }
    subscribers.add(send);
    const state = this.startupUI.get(sessionId)?.state;
    if (state)
      for (const message of buildPendingExtensionUIRequestMessages(state)) {
        send({ ...message, sessionId });
      }
    let detached = false;
    return () => {
      if (detached) return;
      detached = true;
      subscribers.delete(send);
      if (subscribers.size === 0 && this.startupUISubscribers.get(sessionId) === subscribers)
        this.startupUISubscribers.delete(sessionId);
    };
  }

  private broadcastStartupUI(key: string, message: ServerMessage): void {
    for (const send of this.startupUISubscribers.get(key) ?? [])
      send({ ...message, sessionId: key });
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

  /**
   * Start a new session — creates an in-process pi SDK session.
   */
  async startSession(sessionId: string, workspace?: Workspace): Promise<Session> {
    const key = this.sessionKey(sessionId);
    this.ensureMobileRenderersLoaded();
    const startWorkspace = workspace ?? this.resolveStoredWorkspace(sessionId);
    const session = await this.activationCoordinator.startSession(key, sessionId, startWorkspace);

    return session;
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
      const startup = !this.active.has(key) ? this.startupUI.get(key) : undefined;
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
    } catch (error: unknown) {
      log.error("sessions.pi_event_handler.failed", {
        sessionId: key,
        error: error instanceof Error ? error.message : String(error),
      });
    }

    updateSearchIndexForSessionEvent(this.searchIndex, this.storage, key, data);
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
      const startup = this.startupUI.get(key);
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
  ): Promise<void> {
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
  ): Promise<void> {
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

  async getServerDurableInputCardOutput(
    sessionId: string,
    entryId: string,
  ): Promise<{ output: string } | null> {
    const id = this.storage.getSession(sessionId)?.serverDurable?.conversationId;
    if (id === undefined || !this.durableHarness) return null;
    const { harness } = await (await this.durableHarness).open();
    const { readDurableInputCardOutput } = await import("./durable-input-cards.js");
    return readDurableInputCardOutput(harness, id as ConversationId, entryId);
  }

  async getServerDurableTracePage(
    sessionId: string,
    options: TracePageOptions,
  ): Promise<TracePageResult | null> {
    const id = this.storage.getSession(sessionId)?.serverDurable?.conversationId;
    if (id === undefined || !this.durableHarness) return null;
    const { harness } = await (await this.durableHarness).open();
    const { readDurableTracePage } = await import("./durable-history.js");
    return readDurableTracePage(harness, id as ConversationId, {
      ...options,
      entryRenderers: this.getEntryRenderers(sessionId),
    });
  }

  async getServerDurableTraceOutline(sessionId: string): Promise<TraceOutlineResult | null> {
    const id = this.storage.getSession(sessionId)?.serverDurable?.conversationId;
    if (id === undefined || !this.durableHarness) return null;
    const { harness } = await (await this.durableHarness).open();
    const { readDurableTraceOutline } = await import("./durable-history.js");
    return readDurableTraceOutline(
      harness,
      id as ConversationId,
      this.mobileRenderer,
      this.getEntryRenderers(sessionId),
    );
  }

  /**
   * Whether create requests may ask for `engine: "durable"`. Read at startup,
   * like the Harness it implies; already-bound durable sessions run either way.
   */
  durableSessionsAvailable(): boolean {
    return this.config.experimental?.serverDurable === true;
  }

  /** Read-only Harness access for the search index; undefined when no Harness exists (flag off, nothing bound). */
  durableSearchSource(): DurableSearchSource | undefined {
    const durableHarness = this.durableHarness;
    if (!durableHarness) return undefined;
    const openHarness = async (): Promise<Harness> => (await (await durableHarness).open()).harness;
    return {
      readTipEntryId: async (id) => {
        const harness = await openHarness();
        const { readDurableTipEntryId } = await import("./durable-history.js");
        return readDurableTipEntryId(harness, id as ConversationId);
      },
      readTranscript: async (id) => {
        const harness = await openHarness();
        const { readDurableSearchTranscript } = await import("./durable-history.js");
        return readDurableSearchTranscript(harness, id as ConversationId);
      },
    };
  }

  async getServerDurableTrace(
    sessionId: string,
    view: "context" | "full",
  ): Promise<TraceEvent[] | null> {
    const id = this.storage.getSession(sessionId)?.serverDurable?.conversationId;
    if (id === undefined || !this.durableHarness) return null;
    const { harness } = await (await this.durableHarness).open();
    const { readDurableTrace } = await import("./durable-history.js");
    return readDurableTrace(harness, id as ConversationId, view, this.getEntryRenderers(sessionId));
  }

  /**
   * Fork a bound server durable conversation at a trace/fork-point entry id. Resolves the new
   * conversation id, or `undefined` when the entry is not part of the source's history.
   */
  async forkServerDurableConversation(
    sessionId: string,
    entryId: string,
  ): Promise<ConversationId | undefined> {
    const id = this.storage.getSession(sessionId)?.serverDurable?.conversationId;
    if (id === undefined || !this.durableHarness) {
      throw new Error("Server durable fork requires a bound conversation");
    }
    // Trace entry ids are the decimal Durable entry ids.
    if (!/^[1-9]\d*$/.test(entryId) || !Number.isSafeInteger(Number(entryId))) return undefined;
    return (await this.durableHarness).forkConversation(
      id as ConversationId,
      Number(entryId) as EntryId,
    );
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

  private handleSessionEnd(
    key: string,
    reason: string,
    stopConfirmationReason?: string,
  ): Promise<void> {
    this.commandCoordinator.cancelQueuedCompactions(key);
    return this.lifecycleCoordinator.handleSessionEnd(key, reason, stopConfirmationReason);
  }

  // ─── Subscribe / Broadcast ───

  subscribe(sessionId: string, callback: (msg: ServerMessage) => void): () => void {
    return this.broadcaster.subscribe(this.sessionKey(sessionId), callback);
  }

  broadcastSessionMessage(sessionId: string, message: ServerMessage): number {
    return this.broadcaster.broadcast(this.sessionKey(sessionId), message);
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
    if (!this.isActive(sessionId)) {
      if (!this.durableHarness) return;
      const id = this.storage.getSession(sessionId)?.serverDurable?.conversationId;
      if (id !== undefined) {
        await (await this.durableHarness).abortConversations(new Set([id as ConversationId]));
      }
      return;
    }
    // cancelPendingAsk runs inside the session lock (via preStop callback)
    // so it serializes with respondToUIRequest, matching the sendAbort pattern.
    await this.stopFlowCoordinator.stopSession(key, sessionId, () => {
      this.cancelPendingAsk(sessionId);
    });
  }

  /** Set by close(); no session starts or registers afterward. */
  private closed = false;

  /**
   * Server shutdown: refuse new starts, drop starts still in flight, and stop
   * every running session. A SessionManager is not reopened after this.
   */
  async close(): Promise<void> {
    this.closed = true;
    const pending = new Set(this.storage.listRestartResume().map((entry) => entry.sessionId));
    const resumeIds = new Set<ConversationId>();
    for (const sessionId of pending) {
      const id = this.storage.getSession(sessionId)?.serverDurable?.conversationId;
      if (id !== undefined) resumeIds.add(id as ConversationId);
    }
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
      await (await this.durableHarness)?.close(resumeIds);
    }
  }

  /** Fail closed if production opens the Harness without the catalog model runtime. */
  async expectDurableModelRuntime(): Promise<void> {
    await this.durableHarness?.then((harness) => harness.requireDiscoveredModels());
  }

  /** Share the server ModelRuntime so global provider overlays apply to durable inference. */
  async bindDurableModels(models: ModelRuntime): Promise<void> {
    if (!this.durableHarness) return;
    await this.durableHarness.then((harness) => harness.bindModelRuntime(models));
    log.info("sessions.durable_models_bound");
  }

  /** Attach every crash-resumed projection before enabling the shared scheduler. */
  async resumeDurableSessions(): Promise<void> {
    if (!this.durableHarness) return;
    const bound = this.storage.listSessions().filter(hasServerDurableBinding);
    const durableHarness = await this.durableHarness;
    if (!bound.length) {
      await durableHarness.releaseResume();
      return;
    }
    durableHarness.holdResume();
    await durableHarness.open();
    // A mounted conversation can accept input, which itself enables scheduling.
    // Fence known stops before exposing even the first resumable projection.
    const queued = new Set(this.storage.listRestartResume().map((entry) => entry.sessionId));
    const marked = new Set(
      bound
        .filter(
          (session) =>
            !queued.has(session.id) ||
            (session.workspaceId && !this.storage.getWorkspace(session.workspaceId)),
        )
        .map((session) => session.serverDurable!.conversationId! as ConversationId),
    );
    // Ordinary Stop leaves promoted jobs alive in the current process. At
    // startup an explicitly stopped session must resume no work, including
    // its old background reporters. Orphan healing queues idle live sessions
    // too, so their background tasks remain outside this stopped-session fence.
    await durableHarness.abortConversations(marked, { background: true });
    for (const session of bound) {
      const workspace = session.workspaceId
        ? this.storage.getWorkspace(session.workspaceId)
        : undefined;
      if (session.workspaceId && !workspace) continue;
      if (!this.storage.listRestartResume().some((entry) => entry.sessionId === session.id))
        continue;
      await this.startSession(session.id, workspace);
    }
    // Re-evaluate after every await: stops and workspace deletion can change
    // the decision while attachments/cancellation marks are being committed.
    // The owner gate rejects prompts and routes all stops to paused cancellation.
    for (;;) {
      const pending = new Set(this.storage.listRestartResume().map((entry) => entry.sessionId));
      const stopped = bound.filter(
        (session) =>
          !pending.has(session.id) ||
          !this.isActive(session.id) ||
          (session.workspaceId && !this.storage.getWorkspace(session.workspaceId)),
      );
      const unmarked = stopped.filter(
        (session) => !marked.has(session.serverDurable!.conversationId! as ConversationId),
      );
      const attachedStops = stopped.filter((session) => this.isActive(session.id));
      if (!unmarked.length && !attachedStops.length) break;
      if (unmarked.length)
        await durableHarness.abortConversations(
          new Set(
            unmarked.map((session) => session.serverDurable!.conversationId! as ConversationId),
          ),
          { background: true },
        );
      for (const session of unmarked)
        marked.add(session.serverDurable!.conversationId! as ConversationId);
      for (const session of attachedStops) await this.stopSession(session.id);
    }
    for (const session of bound) this.storage.clearRestartResume(session.id);
    await durableHarness.releaseResume();
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

  /** Live prompt-cache warmer state and the running model's cache tiers. */
  getPromptCacheRuntime(
    sessionId: string,
  ):
    | { warmer?: SessionPromptCacheWarmer; promptCache?: { short?: number; long?: number } }
    | undefined {
    return this.active.get(this.sessionKey(sessionId))?.sdkBackend.promptCacheRuntime();
  }

  /**
   * Membership of a durable session's thread, from the Harness ownership edges. Undefined
   * for a session that is not bound to a durable conversation.
   */
  async getDurableThread(
    sessionId: string,
  ): Promise<{ rootSessionId: string; sessionIds: Set<string> } | undefined> {
    return (await this.durableHarness)?.boundThreads?.threadSessions(sessionId);
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

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

import type { AgentRuntimeTransport } from "./agent-runtime-transport.js";
import type {
  ChatAttachmentRef,
  MessageQueueDraftItem,
  MessageQueueState,
  Session,
  ServerMessage,
  Workspace,
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
  type ExtensionUIResponse,
} from "./extension-ui-state.js";
import type { SearchIndex } from "./search-index.js";
import { updateSearchIndexForSessionEvent } from "./session-search-indexing.js";
import type { SessionRuntimeTransactionPermit } from "./session-runtime-transaction.js";
import { SDK_RUNTIME_LIFECYCLE_TIMEOUT_MS } from "./sdk-backend.js";
import type { SessionStopTimers } from "./session-stop.js";

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

export class SessionManager extends EventEmitter implements AgentRuntimeTransport {
  private storage: Storage;
  private active: Map<string, ActiveSession> = new Map();

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
    const runtimeManager = new WorkspaceRuntime(resolveRuntimeLimits(config));
    this.mobileRenderers = new MobileRendererRegistry();
    const eventRingCapacity = parsePositiveIntEnv("OPPI_SESSION_EVENT_RING_CAPACITY", 500);

    const bundle = createSessionCoordinatorBundle({
      storage,
      config,
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
      onSessionEnd: (key, reason, stopConfirmationReason) =>
        this.handleSessionEnd(key, reason, stopConfirmationReason),
      persistSessionNow: (key, session) => this.persistSessionNow(key, session),
      markSessionDirty: (key) => this.markSessionDirty(key),
      resetIdleTimer: (key) => this.resetIdleTimer(key),
      bootstrapSessionState: (key) => this.bootstrapSessionState(key),
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

  /** Process a pi agent event from the SDK subscribe callback. */
  private handlePiEvent(key: string, data: SessionBackendEvent): void {
    try {
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
  respondToUIRequest(sessionId: string, response: ExtensionUIResponse): boolean {
    const key = this.sessionKey(sessionId);
    const active = this.active.get(key);
    if (!active) {
      return false;
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
  }

  getMessageQueue(sessionId: string): MessageQueueState {
    const key = this.sessionKey(sessionId);
    return this.queueCoordinator.getQueue(key);
  }

  async setMessageQueue(
    sessionId: string,
    payload: {
      baseVersion: number;
      steering: MessageQueueDraftItem[];
      followUp: MessageQueueDraftItem[];
    },
  ): Promise<MessageQueueState> {
    const key = this.sessionKey(sessionId);
    return this.queueCoordinator.setQueue(key, payload);
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
    message: Record<string, unknown>,
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
  ): void | Promise<void> {
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
    this.broadcaster.markSessionDirty(key);
  }

  private persistSessionNow(key: string, session: Session): void {
    this.broadcaster.persistSessionNow(key, session);
  }

  // ─── Session End ───

  private handleSessionEnd(
    key: string,
    reason: string,
    stopConfirmationReason?: string,
  ): Promise<void> {
    return this.lifecycleCoordinator.handleSessionEnd(key, reason, stopConfirmationReason);
  }

  // ─── Subscribe / Broadcast ───

  subscribe(sessionId: string, callback: (msg: ServerMessage) => void): () => void {
    return this.broadcaster.subscribe(this.sessionKey(sessionId), callback);
  }

  broadcastSessionMessage(sessionId: string, message: ServerMessage): number {
    return this.broadcaster.broadcast(this.sessionKey(sessionId), message);
  }

  private broadcast(key: string, message: ServerMessage): void {
    this.broadcaster.broadcast(key, message);
  }

  // ─── Stop ───

  async stopSession(sessionId: string): Promise<void> {
    const key = this.sessionKey(sessionId);
    // cancelPendingAsk runs inside the session lock (via preStop callback)
    // so it serializes with respondToUIRequest, matching the sendAbort pattern.
    await this.stopFlowCoordinator.stopSession(key, sessionId, () => {
      this.cancelPendingAsk(sessionId);
    });
  }

  async stopAll(): Promise<void> {
    const sessionIds = Array.from(this.active.values()).map((active) => active.session.id);
    await Promise.all(sessionIds.map((sessionId) => this.stopSession(sessionId)));
  }

  // ─── State Queries ───

  isActive(sessionId: string): boolean {
    return this.active.has(this.sessionKey(sessionId));
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

    cancelPendingAskRequest(active, {
      metrics: this.opsMetrics ?? undefined,
      deliver: (payload) => active.sdkBackend.respondToExtensionUIRequest(payload),
      broadcastSettled: (message) => this.broadcast(key, message),
    });
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

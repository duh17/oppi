/**
 * Session manager — pi agent lifecycle via SDK.
 *
 * Pi runs in-process via createAgentSession().
 *
 * Handles:
 * - Session lifecycle (start, stop, idle timeout)
 * - Agent event → simplified WebSocket message translation
 * - In-process permission gate (via ExtensionFactory)
 */

import { EventEmitter } from "node:events";

import type {
  Session,
  ServerMessage,
  ServerConfig,
  TurnAckStage,
  TurnCommand,
  Workspace,
} from "./types.js";
import type { Storage } from "./storage.js";
import type { GateServer } from "./gate.js";

import {
  WorkspaceRuntime,
  resolveRuntimeLimits,
  type WorkspaceSessionIdentity,
} from "./workspace-runtime.js";
import { EventRing } from "./event-ring.js";
import { TurnDedupeCache, computeTurnPayloadHash } from "./turn-cache.js";
import {
  translatePiEvent,
  extractAssistantText,
  normalizeRpcError,
  updateSessionChangeStats,
  appendSessionMessage,
  applyMessageEndToSession,
  type TranslationContext,
} from "./session-protocol.js";
import { getGitStatus } from "./git-status.js";
import { MobileRendererRegistry } from "./mobile-renderer.js";
import { SdkBackend } from "./sdk-backend.js";

/** Compact HH:MM:SS.mmm timestamp for log lines. */
function ts(): string {
  const d = new Date();
  const h = String(d.getHours()).padStart(2, "0");
  const m = String(d.getMinutes()).padStart(2, "0");
  const s = String(d.getSeconds()).padStart(2, "0");
  const ms = String(d.getMilliseconds()).padStart(3, "0");
  return `${h}:${m}:${s}.${ms}`;
}

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

function toRecord(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : {};
}

/**
 * Compose a canonical `provider/modelId` string.
 *
 * Handles nested providers like openrouter where the model ID itself
 * contains slashes (e.g. provider="openrouter", modelId="z.ai/glm-5"
 * → "openrouter/z.ai/glm-5").  Avoids double-prefixing when the
 * model ID already starts with the provider name.
 */
export function composeModelId(provider: string, modelId: string): string {
  return modelId.startsWith(`${provider}/`) ? modelId : `${provider}/${modelId}`;
}

export interface SessionCatchUpResponse {
  events: ServerMessage[];
  currentSeq: number;
  session: Session;
  catchUpComplete: boolean;
}

export interface SessionBroadcastEvent {
  sessionId: string;
  event: ServerMessage;
  durable: boolean;
}

// ─── Types ───

interface ActiveSession {
  session: Session;
  sdkBackend: SdkBackend;
  workspaceId: string;
  subscribers: Set<(msg: ServerMessage) => void>;
  /** Pending extension UI requests keyed by request id */
  pendingUIRequests: Map<string, ExtensionUIRequest>;
  /**
   * Tracks last partialResult text per toolCallId for delta computation.
   *
   * Pi SDK tool_execution_update sends partialResult with replace semantics
   * (accumulated output so far). We compute deltas here so the client can
   * use simple append semantics for tool_output events.
   */
  partialResults: Map<string, string>;
  /**
   * Assistant text already streamed via text_delta for the current turn.
   * Used to recover missing final text from message_end when pi skips deltas.
   */
  streamedAssistantText: string;
  /** True when thinking_delta events were forwarded for the current message. */
  hasStreamedThinking: boolean;
  /** Per-session dedupe cache for idempotent prompt/steer/follow_up retries. */
  turnCache: TurnDedupeCache;
  /** Ordered turn IDs waiting for `agent_start` -> `started` ACK emission. */
  pendingTurnStarts: string[];
  /** In-flight stop lifecycle contract (graceful abort or session terminate). */
  pendingStop?: PendingStop;
  /** Monotonic durable-event sequence for reconnect catch-up. */
  seq: number;
  /** Ring buffer of recent durable events. */
  eventRing: EventRing;
}

type StopRequestSource = "user" | "timeout" | "server";

interface PendingStop {
  mode: "abort" | "terminate";
  source: StopRequestSource;
  requestedAt: number;
  previousStatus: Session["status"];
  timeoutHandle?: NodeJS.Timeout;
}

/** Extension UI request from pi SDK (stdout) */
export interface ExtensionUIRequest {
  type: "extension_ui_request";
  id: string;
  method: string;
  title?: string;
  options?: string[];
  message?: string;
  placeholder?: string;
  prefill?: string;
  notifyType?: "info" | "warning" | "error";
  statusKey?: string;
  statusText?: string;
  widgetKey?: string;
  widgetLines?: string[];
  widgetPlacement?: string;
  text?: string;
  timeout?: number;
}

/** Extension UI response sent to pi */
export interface ExtensionUIResponse {
  type: "extension_ui_response";
  id: string;
  value?: string;
  confirmed?: boolean;
  cancelled?: boolean;
}

/** Fire-and-forget UI methods (no response needed) */
const FIRE_AND_FORGET_METHODS = new Set([
  "notify",
  "setStatus",
  "setWidget",
  "setTitle",
  "set_editor_text",
]);

// ─── Session Manager ───

export class SessionManager extends EventEmitter {
  private storage: Storage;
  private config: ServerConfig;
  private gate: GateServer;
  private runtimeManager: WorkspaceRuntime;
  private active: Map<string, ActiveSession> = new Map();
  private idleTimers: Map<string, NodeJS.Timeout> = new Map();
  private readonly mobileRenderers = new MobileRendererRegistry();
  private readonly eventRingCapacity = parsePositiveIntEnv("OPPI_SESSION_EVENT_RING_CAPACITY", 500);
  private readonly resolveSkillPath?: (name: string) => string | undefined;

  /** Injected by the server to resolve context window for a model ID. */
  contextWindowResolver: ((modelId: string) => number) | null = null;

  // Persist active session metadata in batches to avoid sync I/O on every event.
  private dirtySessions: Set<string> = new Set();
  private saveTimer: NodeJS.Timeout | null = null;
  private readonly saveDebounceMs = 1000;

  constructor(
    storage: Storage,
    gate: GateServer,
    opts?: { resolveSkillPath?: (name: string) => string | undefined },
  ) {
    super();
    this.storage = storage;
    this.config = storage.getConfig();
    this.gate = gate;
    this.resolveSkillPath = opts?.resolveSkillPath;
    this.runtimeManager = new WorkspaceRuntime(resolveRuntimeLimits(this.config));

    // Load user-provided mobile renderers (async, fire-and-forget at startup).
    this.mobileRenderers.loadAllRenderers().then(({ loaded, errors }) => {
      if (loaded.length > 0) {
        console.log(`${ts()} [mobile-renderer] loaded: ${loaded.join(", ")}`);
      }
      for (const err of errors) {
        console.error(`${ts()} [mobile-renderer] ${err}`);
      }
    });
  }

  // ─── Session Lifecycle ───

  /** In-flight startSession calls — deduplicates concurrent spawns from iOS reconnect races. */
  private starting: Map<string, Promise<Session>> = new Map();

  /**
   * Single-user session key.
   */
  private sessionKey(sessionId: string): string {
    return sessionId;
  }

  /**
   * Start a new session — spawns pi as a local process.
   */
  async startSession(
    sessionId: string,
    userName?: string,
    workspace?: Workspace,
  ): Promise<Session> {
    const key = this.sessionKey(sessionId);

    const existing = this.active.get(key);
    if (existing) {
      // Reset idle timer on reconnect — prevents session from being killed
      // during brief WS disconnects (app backgrounding, network blips).
      this.resetIdleTimer(key);
      return existing.session;
    }

    // Deduplicate concurrent start requests (iOS reconnect race)
    const pending = this.starting.get(key);
    if (pending) {
      return pending;
    }

    const promise = this.runtimeManager.withSessionLock(sessionId, async () => {
      const active = this.active.get(key);
      if (active) {
        this.resetIdleTimer(key);
        return active.session;
      }
      return this.startSessionInner(sessionId, userName, workspace);
    });

    this.starting.set(key, promise);
    try {
      return await promise;
    } finally {
      this.starting.delete(key);
    }
  }

  private async startSessionInner(
    sessionId: string,
    userName?: string,
    workspace?: Workspace,
  ): Promise<Session> {
    const key = this.sessionKey(sessionId);

    const session = this.storage.getSession(sessionId);
    if (!session) throw new Error(`Session not found: ${sessionId}`);

    const identity = this.buildWorkspaceIdentity(session, workspace);

    return this.runtimeManager.withWorkspaceLock(identity.workspaceId, async () => {
      this.runtimeManager.reserveSessionStart(identity);

      try {
        const useGate = this.config.permissionGate !== false;
        const sdkBackend = await SdkBackend.create({
          session,
          workspace,
          onEvent: (event) => this.handlePiEvent(key, event),
          onEnd: (reason) => this.handleSessionEnd(key, reason),
          gate: useGate ? this.gate : undefined,
          workspaceId: identity.workspaceId,
          permissionGate: useGate,
        });

        const activeSession: ActiveSession = {
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
          eventRing: new EventRing(this.eventRingCapacity),
        };

        this.active.set(key, activeSession);
        this.runtimeManager.markSessionReady(identity);

        session.status = "ready";
        session.lastActivity = Date.now();
        this.persistSessionNow(key, session);
        this.resetIdleTimer(key);

        void this.bootstrapSessionState(key);

        return session;
      } catch (err) {
        this.gate.destroySessionGuard(sessionId);
        this.runtimeManager.releaseSession(identity);
        throw err;
      }
    });
  }

  private buildWorkspaceIdentity(
    session: Session,
    workspace?: Workspace,
  ): WorkspaceSessionIdentity {
    return {
      workspaceId: this.resolveSessionWorkspaceId(session, workspace),
      sessionId: session.id,
    };
  }

  private resolveSessionWorkspaceId(session: Session, workspace?: Workspace): string {
    if (workspace?.id && workspace.id.trim().length > 0) {
      return workspace.id;
    }

    if (session.workspaceId && session.workspaceId.trim().length > 0) {
      return session.workspaceId;
    }

    return `session-${session.id}`;
  }

  /**
   * Process a pi agent event from the SDK subscribe callback.
   */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- pi event JSON is untyped
  private handlePiEvent(key: string, data: any): void {
    const active = this.active.get(key);
    if (!active) return;

    // Extension UI request — forward to subscribers (phone handles it)
    if (data.type === "extension_ui_request") {
      this.handleExtensionUIRequest(key, data as ExtensionUIRequest);
      return;
    }

    // Log lifecycle events (not high-frequency deltas)
    if (
      data.type === "agent_start" ||
      data.type === "agent_end" ||
      data.type === "turn_start" ||
      data.type === "turn_end" ||
      data.type === "message_end" ||
      data.type === "tool_execution_start" ||
      data.type === "tool_execution_end" ||
      data.type === "auto_compaction_start" ||
      data.type === "auto_compaction_end" ||
      data.type === "auto_retry_start" ||
      data.type === "auto_retry_end"
    ) {
      const tool = data.toolName ? ` tool=${data.toolName}` : "";
      console.log(
        `${ts()} [pi:${active.session.id}] EVENT ${data.type}${tool} (subs=${active.subscribers.size})`,
      );
    }

    const ctx = this.translationContext(active);
    const messages = translatePiEvent(data, ctx);
    active.streamedAssistantText = ctx.streamedAssistantText;
    active.hasStreamedThinking = ctx.hasStreamedThinking;
    for (const message of messages) {
      this.broadcast(key, message);
    }

    if (data.type === "agent_start") {
      this.markNextTurnStarted(key, active);
    }

    this.updateSessionFromEvent(key, active.session, data);

    if (data.type === "agent_end") {
      this.finishPendingAbortWithSuccess(key, active);
    }

    if (data.type === "message_end") {
      const role = data.message?.role;
      if (role === "assistant" || role === "user") {
        this.broadcast(key, {
          type: "message_end",
          role,
          content: extractAssistantText(data.message),
        });
      }
    }

    if (
      data.type === "agent_start" ||
      data.type === "agent_end" ||
      data.type === "message_end" ||
      data.type === "tool_execution_start"
    ) {
      console.log(`${ts()} [pi:${active.session.id}] STATUS → ${active.session.status}`);
      this.broadcast(key, { type: "state", session: active.session });
    }

    this.resetIdleTimer(key);
  }

  // ─── Extension UI Protocol ───

  /**
   * Handle extension_ui_request from pi.
   * Fire-and-forget methods are forwarded as notifications.
   * Dialog methods (select, confirm, input, editor) are forwarded
   * to the phone and held until respondToUIRequest() is called.
   */
  private handleExtensionUIRequest(key: string, req: ExtensionUIRequest): void {
    const active = this.active.get(key);
    if (!active) return;

    if (FIRE_AND_FORGET_METHODS.has(req.method)) {
      // Forward as notification (pick relevant fields)
      this.broadcast(key, {
        type: "extension_ui_notification",
        method: req.method,
        message: req.message,
        notifyType: req.notifyType,
        statusKey: req.statusKey,
        statusText: req.statusText,
      });
      return;
    }

    // Dialog method — track and forward to phone
    active.pendingUIRequests.set(req.id, req);
    this.broadcast(key, {
      type: "extension_ui_request",
      id: req.id,
      sessionId: active.session.id,
      method: req.method,
      title: req.title,
      options: req.options,
      message: req.message,
      placeholder: req.placeholder,
      prefill: req.prefill,
      timeout: req.timeout,
    });
  }

  /**
   * Send extension_ui_response back to pi (in-process gate).
   * Called by server.ts when phone responds to a UI dialog.
   */
  respondToUIRequest(sessionId: string, response: ExtensionUIResponse): boolean {
    const key = this.sessionKey(sessionId);
    const active = this.active.get(key);
    if (!active) return false;

    const req = active.pendingUIRequests.get(response.id);
    if (!req) return false;

    active.pendingUIRequests.delete(response.id);

    // SDK sessions handle extension UI internally via the in-process gate.
    return true;
  }

  // ─── Turn Commands ───

  private emitTurnAck(
    key: string,
    payload: {
      command: TurnCommand;
      clientTurnId: string;
      stage: TurnAckStage;
      requestId?: string;
      duplicate?: boolean;
    },
  ): void {
    this.broadcast(key, {
      type: "turn_ack",
      command: payload.command,
      clientTurnId: payload.clientTurnId,
      stage: payload.stage,
      requestId: payload.requestId,
      duplicate: payload.duplicate,
    });
  }

  private beginTurnIntent(
    key: string,
    active: ActiveSession,
    command: TurnCommand,
    payload: unknown,
    clientTurnId?: string,
    requestId?: string,
  ): { clientTurnId?: string; duplicate: boolean } {
    if (!clientTurnId) {
      return { duplicate: false };
    }

    const payloadHash = computeTurnPayloadHash(command, payload);
    const existing = active.turnCache.get(clientTurnId);
    if (existing) {
      if (existing.command !== command || existing.payloadHash !== payloadHash) {
        throw new Error(`clientTurnId conflict: ${clientTurnId}`);
      }

      this.emitTurnAck(key, {
        command,
        clientTurnId,
        stage: existing.stage,
        requestId,
        duplicate: true,
      });

      return { clientTurnId, duplicate: true };
    }

    const now = Date.now();
    active.turnCache.set(clientTurnId, {
      command,
      payloadHash,
      stage: "accepted",
      acceptedAt: now,
      updatedAt: now,
    });

    this.emitTurnAck(key, {
      command,
      clientTurnId,
      stage: "accepted",
      requestId,
    });

    return { clientTurnId, duplicate: false };
  }

  private markTurnDispatched(
    key: string,
    active: ActiveSession,
    command: TurnCommand,
    turn: { clientTurnId?: string; duplicate: boolean },
    requestId?: string,
  ): void {
    const clientTurnId = turn.clientTurnId;
    if (!clientTurnId || turn.duplicate) {
      return;
    }

    active.turnCache.updateStage(clientTurnId, "dispatched");
    active.pendingTurnStarts.push(clientTurnId);

    this.emitTurnAck(key, {
      command,
      clientTurnId,
      stage: "dispatched",
      requestId,
    });
  }

  private markNextTurnStarted(key: string, active: ActiveSession): void {
    while (active.pendingTurnStarts.length > 0) {
      const clientTurnId = active.pendingTurnStarts.shift();
      if (!clientTurnId) {
        break;
      }

      const record = active.turnCache.updateStage(clientTurnId, "started");
      if (!record) {
        continue;
      }

      this.emitTurnAck(key, {
        command: record.command,
        clientTurnId,
        stage: "started",
      });
      break;
    }
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
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      streamingBehavior?: "steer" | "followUp";
      clientTurnId?: string;
      requestId?: string;
      timestamp?: number;
    },
  ): Promise<void> {
    const key = this.sessionKey(sessionId);
    const active = this.active.get(key);
    if (!active) throw new Error(`Session not active: ${sessionId}`);

    const turn = this.beginTurnIntent(
      key,
      active,
      "prompt",
      {
        message,
        images: opts?.images ?? [],
        streamingBehavior: opts?.streamingBehavior,
      },
      opts?.clientTurnId,
      opts?.requestId,
    );

    if (turn.duplicate) {
      return;
    }

    appendSessionMessage(
      active.session,
      {
        role: "user",
        content: message,
        timestamp: opts?.timestamp ?? Date.now(),
      },
      (sid, msg) => {
        this.storage.addSessionMessage(sid, msg);
      },
    );

    const cmd: Record<string, unknown> = {
      type: "prompt",
      message,
    };

    // SDK image format: {type:"image", data:"base64...", mimeType:"image/png"}
    if (opts?.images?.length) {
      cmd.images = opts.images;
    }

    // If agent is busy, add streaming behavior
    if (active.session.status === "busy" && opts?.streamingBehavior) {
      cmd.streamingBehavior = opts.streamingBehavior;
    }

    // In-process gate — no health check needed (virtual guard is always ready).

    console.log(
      `${ts()} [sdk] prompt → pi (session=${sessionId}, status=${active.session.status})`,
    );
    this.sendRpcCommand(key, cmd);
    this.markTurnDispatched(key, active, "prompt", turn, opts?.requestId);
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
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      clientTurnId?: string;
      requestId?: string;
    },
  ): Promise<void> {
    const key = this.sessionKey(sessionId);
    const active = this.active.get(key);
    if (!active) throw new Error(`Session not active: ${sessionId}`);

    if (active.session.status !== "busy") {
      throw new Error("Steer requires an active streaming turn");
    }

    const turn = this.beginTurnIntent(
      key,
      active,
      "steer",
      {
        message,
        images: opts?.images ?? [],
      },
      opts?.clientTurnId,
      opts?.requestId,
    );

    if (turn.duplicate) {
      return;
    }

    const cmd: Record<string, unknown> = { type: "steer", message };
    if (opts?.images?.length) cmd.images = opts.images;
    this.sendRpcCommand(key, cmd);
    this.markTurnDispatched(key, active, "steer", turn, opts?.requestId);
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
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      clientTurnId?: string;
      requestId?: string;
    },
  ): Promise<void> {
    const key = this.sessionKey(sessionId);
    const active = this.active.get(key);
    if (!active) throw new Error(`Session not active: ${sessionId}`);

    if (active.session.status !== "busy") {
      throw new Error("Follow-up requires an active streaming turn");
    }

    const turn = this.beginTurnIntent(
      key,
      active,
      "follow_up",
      {
        message,
        images: opts?.images ?? [],
      },
      opts?.clientTurnId,
      opts?.requestId,
    );

    if (turn.duplicate) {
      return;
    }

    const cmd: Record<string, unknown> = { type: "follow_up", message };
    if (opts?.images?.length) cmd.images = opts.images;
    this.sendRpcCommand(key, cmd);
    this.markTurnDispatched(key, active, "follow_up", turn, opts?.requestId);
  }

  /**
   * Best-effort bootstrap of pi session metadata (session file/UUID).
   *
   * Needed so stopped sessions can still reconstruct trace history.
   */
  private async bootstrapSessionState(key: string): Promise<void> {
    const active = this.active.get(key);
    if (!active) return;

    try {
      const snapshot = active.sdkBackend.getStateSnapshot();
      if (this.applyPiStateSnapshot(active.session, snapshot)) {
        this.persistSessionNow(key, active.session);
      }

      await this.applyRememberedThinkingLevel(key, active);
    } catch {
      // Non-fatal; history remains recoverable from pi trace metadata/files.
    }
  }

  /**
   * Refresh live pi state for an active session and return trace metadata.
   * Used by REST trace endpoint to recover session traces.
   */
  async refreshSessionState(
    sessionId: string,
  ): Promise<{ sessionFile?: string; sessionId?: string } | null> {
    const key = this.sessionKey(sessionId);
    const active = this.active.get(key);
    if (!active) return null;

    try {
      const snapshot = active.sdkBackend.getStateSnapshot();
      if (this.applyPiStateSnapshot(active.session, snapshot)) {
        this.persistSessionNow(key, active.session);
      }
      return {
        sessionFile: active.session.piSessionFile,
        sessionId: active.session.piSessionId,
      };
    } catch {
      return null;
    }
  }

  private getRememberedThinkingLevel(modelId: string | undefined): string | undefined {
    const normalizedModelId = modelId?.trim();
    if (!normalizedModelId) {
      return undefined;
    }

    const storageWithPrefs = this.storage as unknown as {
      getModelThinkingLevelPreference?: (modelId: string) => string | undefined;
    };

    return storageWithPrefs.getModelThinkingLevelPreference?.(normalizedModelId);
  }

  private persistThinkingPreference(session: Session): void {
    const modelId = session.model?.trim();
    const level = session.thinkingLevel?.trim();
    if (!modelId || !level) {
      return;
    }

    const storageWithPrefs = this.storage as unknown as {
      setModelThinkingLevelPreference?: (modelId: string, level: string) => void;
    };

    storageWithPrefs.setModelThinkingLevelPreference?.(modelId, level);
  }

  /**
   * Persist the last-used model on the workspace so new sessions
   * default to it (sticky model per workspace).
   */
  private persistWorkspaceLastUsedModel(session: Session): void {
    const model = session.model?.trim();
    if (!model || !session.workspaceId) return;

    const workspace = this.storage.getWorkspace(session.workspaceId);
    if (!workspace || workspace.lastUsedModel === model) return;

    workspace.lastUsedModel = model;
    workspace.updatedAt = Date.now();
    this.storage.saveWorkspace(workspace);
  }

  private async applyRememberedThinkingLevel(key: string, active: ActiveSession): Promise<boolean> {
    const preferred = this.getRememberedThinkingLevel(active.session.model);
    if (!preferred) {
      return false;
    }

    if (active.session.thinkingLevel === preferred) {
      return false;
    }

    try {
      await this.sendRpcCommandAsync(key, { type: "set_thinking_level", level: preferred }, 8_000);

      try {
        const state = await this.sendRpcCommandAsync(key, { type: "get_state" }, 8_000);
        if (this.applyPiStateSnapshot(active.session, state)) {
          this.persistSessionNow(key, active.session);
        }
      } catch {
        active.session.thinkingLevel = preferred;
        this.persistSessionNow(key, active.session);
      }

      this.persistThinkingPreference(active.session);

      // Broadcast corrected session so iOS subscribers see the restored level.
      this.broadcast(key, { type: "state", session: active.session });

      return true;
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      console.warn(
        `${ts()} [session:${active.session.id}] failed to apply remembered thinking level: ${message}`,
      );
      return false;
    }
  }

  /**
   * Run a raw pi SDK command against an active session and await response.
   * Used by HTTP workflows (e.g. server-orchestrated fork/session operations).
   */
  async runRpcCommand(
    sessionId: string,
    command: Record<string, unknown>,
    timeoutMs = 30_000,
  ): Promise<unknown> {
    const key = this.sessionKey(sessionId);
    if (!this.active.has(key)) {
      throw new Error(`Session not active: ${sessionId}`);
    }

    return this.sendRpcCommandAsync(key, { ...command }, timeoutMs);
  }

  /**
   * Apply fields we care about from pi `get_state` response payload.
   * Returns true if the session object changed.
   */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- pi state shape is untyped
  private applyPiStateSnapshot(session: Session, state: any): boolean {
    if (!state || typeof state !== "object") {
      return false;
    }

    let changed = false;

    if (typeof state.sessionFile === "string" && state.sessionFile.length > 0) {
      if (session.piSessionFile !== state.sessionFile) {
        session.piSessionFile = state.sessionFile;
        changed = true;
      }

      const knownFiles = new Set(session.piSessionFiles || []);
      if (!knownFiles.has(state.sessionFile)) {
        session.piSessionFiles = [...knownFiles, state.sessionFile];
        changed = true;
      }
    }

    if (typeof state.sessionId === "string" && state.sessionId.length > 0) {
      if (session.piSessionId !== state.sessionId) {
        session.piSessionId = state.sessionId;
        changed = true;
      }
    }

    if (typeof state.sessionName === "string") {
      const nextName = state.sessionName.trim();
      if (nextName.length > 0 && session.name !== nextName) {
        session.name = nextName;
        changed = true;
      }
    }

    const rawModelId = state.model?.id;
    const rawProvider = state.model?.provider;
    const fullModelId =
      typeof rawProvider === "string" && typeof rawModelId === "string"
        ? composeModelId(rawProvider, rawModelId)
        : rawModelId;
    if (typeof fullModelId === "string" && fullModelId.length > 0) {
      let effectiveModelId = fullModelId;
      if (
        this.contextWindowResolver &&
        typeof session.model === "string" &&
        session.model.length > 0
      ) {
        const candidateWindow = this.contextWindowResolver(fullModelId);
        const existingWindow = this.contextWindowResolver(session.model);

        // Guard against malformed SDK model payloads (e.g. provider/model both
        // reported as display labels) that would downgrade a known non-200k
        // model back to fallback 200k on reconnect.
        if (candidateWindow === 200000 && existingWindow !== 200000) {
          effectiveModelId = session.model;
        }
      }

      if (session.model !== effectiveModelId) {
        session.model = effectiveModelId;
        this.persistWorkspaceLastUsedModel(session);
        changed = true;
      }

      if (this.contextWindowResolver) {
        const resolved = this.contextWindowResolver(effectiveModelId);
        const current = session.contextWindow;
        if (
          current !== resolved &&
          (resolved !== 200000 || !current || current <= 0 || current === 200000)
        ) {
          session.contextWindow = resolved;
          changed = true;
        }
      }
    }

    const observedThinkingLevel =
      typeof state.thinkingLevel === "string" && state.thinkingLevel.trim().length > 0
        ? state.thinkingLevel.trim()
        : undefined;

    if (observedThinkingLevel && observedThinkingLevel !== session.thinkingLevel) {
      session.thinkingLevel = observedThinkingLevel;
      changed = true;
    }

    // NOTE: Do NOT persist thinking preference here. This method is called
    // during bootstrap (get_state) when pi reports its factory-default level.
    // Persisting would clobber the user's real preference with the default,
    // making applyRememberedThinkingLevel a permanent no-op.
    // Callers that handle user-initiated changes (forwardRpcCommand for
    // set_thinking_level/cycle_thinking_level/cycle_model) persist explicitly.

    return changed;
  }

  // ─── SDK Passthrough ───

  /**
   * Allowlisted SDK commands that can be forwarded from the client.
   * Each maps to the pi SDK command type. Fire-and-forget commands
   * (no response needed) are sent without correlation. Commands that
   * return data are awaited and the result broadcast as rpc_result.
   */
  private static readonly SDK_PASSTHROUGH: ReadonlySet<string> = new Set([
    // State
    "get_state",
    "get_messages",
    "get_session_stats",
    // Model
    "set_model",
    "cycle_model",
    "get_available_models",
    // Thinking
    "set_thinking_level",
    "cycle_thinking_level",
    // Session
    "new_session",
    "set_session_name",
    "compact",
    "set_auto_compaction",
    "fork",
    "get_fork_messages",
    "switch_session",
    // Queue modes
    "set_steering_mode",
    "set_follow_up_mode",
    // Retry
    "set_auto_retry",
    "abort_retry",
    // Bash
    "bash",
    "abort_bash",
    // Commands
    "get_commands",
  ]);

  /**
   * Forward a client WebSocket message to pi via SDK.
   *
   * Used for commands that map 1:1 to pi SDK (model switching,
   * thinking level, session management, etc.). The response is
   * broadcast back as an `rpc_result` ServerMessage.
   */
  async forwardRpcCommand(
    sessionId: string,
    message: Record<string, unknown>,
    requestId?: string,
  ): Promise<void> {
    const cmdType = message.type as string;
    if (!SessionManager.SDK_PASSTHROUGH.has(cmdType)) {
      throw new Error(`Command not allowed: ${cmdType}`);
    }

    const key = this.sessionKey(sessionId);
    const active = this.active.get(key);
    if (!active) throw new Error(`Session not active: ${sessionId}`);

    try {
      let rpcData: unknown = await this.sendRpcCommandAsync(key, { ...message }, 30_000);
      const rpcObject = toRecord(rpcData);

      if (cmdType === "get_state") {
        if (this.applyPiStateSnapshot(active.session, rpcData)) {
          this.persistSessionNow(key, active.session);
          // Broadcast updated session so clients see model/thinking/name changes
          this.broadcast(key, { type: "state", session: active.session });
        }
      }

      // Track thinking level changes so the session object stays in sync
      if (cmdType === "cycle_thinking_level" || cmdType === "set_thinking_level") {
        const levelFromResponse =
          typeof rpcObject.level === "string" && rpcObject.level.trim().length > 0
            ? rpcObject.level.trim()
            : undefined;
        const levelFromRequest =
          cmdType === "set_thinking_level" &&
          typeof message.level === "string" &&
          message.level.trim().length > 0
            ? message.level.trim()
            : undefined;

        const effectiveLevel = levelFromResponse ?? levelFromRequest;
        if (effectiveLevel && active.session.thinkingLevel !== effectiveLevel) {
          active.session.thinkingLevel = effectiveLevel;
          this.persistSessionNow(key, active.session);
        }

        this.persistThinkingPreference(active.session);
      }

      // Track model changes so the session object stays in sync
      if (cmdType === "set_model" || cmdType === "cycle_model") {
        // set_model returns the model object, cycle_model returns { model, thinkingLevel, isScoped }
        const modelData = cmdType === "cycle_model" ? toRecord(rpcObject.model) : rpcObject;
        const provider = modelData.provider;
        const modelId = modelData.id;
        if (typeof provider === "string" && typeof modelId === "string") {
          const fullId = composeModelId(provider, modelId);
          if (active.session.model !== fullId) {
            active.session.model = fullId;
            if (this.contextWindowResolver) {
              active.session.contextWindow = this.contextWindowResolver(fullId);
            }
            this.persistWorkspaceLastUsedModel(active.session);
            this.persistSessionNow(key, active.session);
          }
        }

        // cycle_model also returns thinkingLevel
        if (
          cmdType === "cycle_model" &&
          typeof rpcObject.thinkingLevel === "string" &&
          rpcObject.thinkingLevel.trim().length > 0
        ) {
          active.session.thinkingLevel = rpcObject.thinkingLevel.trim();
          this.persistThinkingPreference(active.session);
        }

        const appliedRememberedThinking = await this.applyRememberedThinkingLevel(key, active);

        // Keep rpc_result payload consistent with server-authoritative session state.
        if (
          cmdType === "cycle_model" &&
          appliedRememberedThinking &&
          active.session.thinkingLevel
        ) {
          rpcObject.thinkingLevel = active.session.thinkingLevel;
          rpcData = rpcObject;
        }
      }

      // Track session name changes so optimistic client renames don't get
      // overwritten by stale local get_state snapshots.
      if (cmdType === "set_session_name") {
        const requestedName = typeof message.name === "string" ? message.name.trim() : "";
        const responseName = typeof rpcObject.name === "string" ? rpcObject.name.trim() : "";
        const nextName = responseName.length > 0 ? responseName : requestedName;
        if (nextName.length > 0 && active.session.name !== nextName) {
          active.session.name = nextName;
          this.persistSessionNow(key, active.session);
        }
      }

      // Session-branching commands mutate pi session identity/file in-place.
      // Refresh state immediately so reconnect/resume uses the new branch.
      if (cmdType === "fork" || cmdType === "new_session" || cmdType === "switch_session") {
        try {
          const refreshed = await this.sendRpcCommandAsync(key, { type: "get_state" }, 8_000);
          if (this.applyPiStateSnapshot(active.session, refreshed)) {
            this.persistSessionNow(key, active.session);
            this.broadcast(key, { type: "state", session: active.session });
          }
        } catch (stateErr) {
          const message = stateErr instanceof Error ? stateErr.message : String(stateErr);
          console.warn(
            `[sdk] ${cmdType} state refresh failed for ${active.session.id}: ${message}`,
          );
        }
      }

      this.broadcast(key, {
        type: "rpc_result",
        command: cmdType,
        requestId,
        success: true,
        data: rpcData,
      });

      // Broadcast updated session state after model/thinking/name changes
      // so clients see the change immediately without waiting for next agent event
      if (
        cmdType === "set_model" ||
        cmdType === "cycle_model" ||
        cmdType === "set_thinking_level" ||
        cmdType === "cycle_thinking_level" ||
        cmdType === "set_session_name"
      ) {
        this.broadcast(key, { type: "state", session: active.session });
      }
    } catch (err) {
      const rawError = err instanceof Error ? err.message : String(err);
      this.broadcast(key, {
        type: "rpc_result",
        command: cmdType,
        requestId,
        success: false,
        error: normalizeRpcError(cmdType, rawError),
      });
    }
  }

  /**
   * Abort the current agent operation.
   *
   * Abort the current turn. Does NOT stop the session — the pi process
   * stays alive and ready for the next prompt.
   */
  async sendAbort(sessionId: string): Promise<void> {
    const key = this.sessionKey(sessionId);

    await this.runtimeManager.withSessionLock(sessionId, async () => {
      const active = this.active.get(key);
      if (!active) {
        return;
      }

      // If nothing is currently streaming, treat abort as immediately satisfied.
      // This prevents false timeout errors when users tap Stop right after a
      // turn already ended.
      if (active.session.status !== "busy") {
        this.broadcast(key, {
          type: "stop_confirmed",
          source: "user",
          reason: "Session already idle",
        });
        return;
      }

      if (!this.beginPendingStop(key, active, "abort", "user")) {
        return;
      }

      this.sendRpcCommand(key, { type: "abort" });
      this.scheduleAbortStopTimeout(key, active);
    });
  }

  /** Graceful abort budget before escalating. */
  private readonly stopAbortTimeoutMs = 8_000;

  /** After escalation, wait this long before giving up (session stays alive). */
  private readonly stopAbortRetryTimeoutMs = 5_000;

  /** Grace period between abort and dispose in force-stop flow. */
  private readonly stopSessionGraceMs = 1_000;

  /**
   * After the first prompt, check that the permission gate extension
   * connected and reached "guarded" state. If not, surface a warning.
   *
   * Why after first prompt: the extension connects in `before_agent_start`
   * which only fires when pi processes its first prompt.
   */
  // ─── SDK Commands ───

  /**
   * Send a fire-and-forget command to the SDK backend.
   */
  sendRpcCommand(key: string, command: Record<string, unknown>): void {
    const active = this.active.get(key);
    if (!active) return;
    this.routeSdkCommand(active.sdkBackend, command);
    this.resetIdleTimer(key);
  }

  /**
   * Send a command to the SDK backend and await the result.
   */
  sendRpcCommandAsync(
    key: string,
    command: Record<string, unknown>,
    _timeoutMs = 10_000,
  ): Promise<unknown> {
    const active = this.active.get(key);
    if (!active) return Promise.reject(new Error("Session not active"));
    return this.routeSdkCommandAsync(active.sdkBackend, command);
  }

  /**
   * Route a fire-and-forget command to the SDK backend.
   */
  private routeSdkCommand(backend: SdkBackend, command: Record<string, unknown>): void {
    const type = command.type as string;
    switch (type) {
      case "prompt":
        backend.prompt(command.message as string, {
          images: command.images as Array<{ type: "image"; data: string; mimeType: string }>,
        });
        break;
      case "steer":
        backend.prompt(command.message as string, {
          images: command.images as Array<{ type: "image"; data: string; mimeType: string }>,
          streamingBehavior: "steer",
        });
        break;
      case "follow_up":
        backend.prompt(command.message as string, {
          images: command.images as Array<{ type: "image"; data: string; mimeType: string }>,
          streamingBehavior: "followUp",
        });
        break;
      case "abort":
        void backend.abort();
        break;
      default:
        console.warn(`${ts()} [sdk] Unhandled fire-and-forget command: ${type}`);
    }
  }

  /**
   * Route an async command to the SDK backend and return its result.
   * Maps command types to direct SDK method calls.
   */
  private async routeSdkCommandAsync(
    backend: SdkBackend,
    command: Record<string, unknown>,
  ): Promise<unknown> {
    const type = command.type as string;
    switch (type) {
      // State
      case "get_state":
        return backend.getStateSnapshot();
      case "get_messages":
        return backend.getMessages();
      case "get_session_stats":
        return backend.getSessionStats();

      // Model
      case "set_model": {
        const modelFromCommand =
          typeof command.model === "string" && command.model.trim().length > 0
            ? command.model.trim()
            : undefined;
        const modelFromParts =
          typeof command.provider === "string" &&
          command.provider.trim().length > 0 &&
          typeof command.modelId === "string" &&
          command.modelId.trim().length > 0
            ? composeModelId(command.provider.trim(), command.modelId.trim())
            : undefined;

        const model = modelFromCommand ?? modelFromParts;
        if (!model) {
          throw new Error("Invalid set_model payload: expected model or provider+modelId");
        }

        const result = await backend.setModel(model);
        if (!result.success) throw new Error(result.error);
        return result;
      }
      case "cycle_model":
        return backend.cycleModel(command.direction as string);
      case "get_available_models":
        // SDK doesn't have a direct equivalent — return empty for now
        return [];

      // Thinking
      case "set_thinking_level":
        backend.setThinkingLevel(command.level as string);
        return { level: command.level };
      case "cycle_thinking_level": {
        const level = backend.cycleThinkingLevel();
        return { level };
      }

      // Session
      case "new_session":
        await backend.newSession();
        return { success: true };
      case "set_session_name":
        backend.setSessionName(command.name as string);
        return { name: command.name };
      case "compact":
        return backend.compact(command.instructions as string | undefined);
      case "set_auto_compaction":
        backend.setAutoCompaction(!!command.enabled);
        return { enabled: !!command.enabled };
      case "fork":
        return backend.fork(command.entryId as string);
      case "switch_session":
        return backend.switchSession(command.sessionPath as string);

      // Queue modes
      case "set_steering_mode":
        backend.setSteeringMode(command.mode as string);
        return { mode: command.mode };
      case "set_follow_up_mode":
        backend.setFollowUpMode(command.mode as string);
        return { mode: command.mode };

      // Retry
      case "set_auto_retry":
        backend.setAutoRetry(!!command.enabled);
        return { enabled: !!command.enabled };
      case "abort_retry":
        backend.abortRetry();
        return { success: true };

      // Bash
      case "abort_bash":
        backend.abortBash();
        return { success: true };

      default:
        throw new Error(`Unhandled SDK command: ${type}`);
    }
  }

  // ─── Event Translation (delegated to session-protocol module) ───

  /**
   * Build the TranslationContext for an active session.
   * The context holds mutable streaming state that translatePiEvent reads/writes.
   */
  private translationContext(active: ActiveSession): TranslationContext {
    return {
      sessionId: active.session.id,
      partialResults: active.partialResults,
      streamedAssistantText: active.streamedAssistantText,
      hasStreamedThinking: active.hasStreamedThinking,
      mobileRenderers: this.mobileRenderers,
    };
  }

  /**
   * Update session state from pi events.
   * Delegates extraction to session-protocol functions; handles persistence here.
   */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- pi event JSON is untyped
  private updateSessionFromEvent(key: string, session: Session, event: any): void {
    let shouldFlushNow = false;
    const pendingStopMode = this.active.get(key)?.pendingStop?.mode;

    switch (event.type) {
      case "agent_start":
        if (session.status !== "stopping") {
          session.status = "busy";
        }
        break;

      case "agent_end":
        session.status = pendingStopMode === "terminate" ? "stopping" : "ready";
        shouldFlushNow = true;
        break;

      case "tool_execution_start":
        updateSessionChangeStats(session, event.toolName, event.args);
        this.maybeEmitGitStatus(key, session, event.toolName);
        break;

      case "message_end":
        applyMessageEndToSession(session, event.message, (sessionId, msg) => {
          this.storage.addSessionMessage(sessionId, msg);
        });
        break;
    }

    session.lastActivity = Date.now();

    if (shouldFlushNow) {
      this.persistSessionNow(key, session);
      return;
    }

    this.markSessionDirty(key);
  }

  /**
   * After a file-mutating tool call, asynchronously fetch git status
   * and broadcast it to connected clients. Non-blocking — errors are
   * silently ignored (git status is best-effort).
   *
   * Debounced per workspace: rapid-fire edits coalesce into one git
   * call at most every 2 seconds. This avoids spawning 60+ git
   * processes when the agent edits 10 files in quick succession.
   */
  private gitStatusTimers: Map<string, NodeJS.Timeout> = new Map();
  private static readonly GIT_STATUS_DEBOUNCE_MS = 2000;

  private maybeEmitGitStatus(key: string, session: Session, toolName: unknown): void {
    const name = typeof toolName === "string" ? toolName.toLowerCase() : "";
    if (name !== "edit" && name !== "write" && name !== "bash") return;

    const wsId = session.workspaceId;
    if (!wsId) return;

    // Debounce per workspace — cancel any pending timer and restart
    const existing = this.gitStatusTimers.get(wsId);
    if (existing) clearTimeout(existing);

    this.gitStatusTimers.set(
      wsId,
      setTimeout(() => {
        this.gitStatusTimers.delete(wsId);
        this.emitGitStatusNow(key, wsId);
      }, SessionManager.GIT_STATUS_DEBOUNCE_MS),
    );
  }

  private emitGitStatusNow(key: string, wsId: string): void {
    const workspace = this.storage.getWorkspace(wsId);
    if (!workspace?.hostMount) return;
    if (workspace.gitStatusEnabled === false) return;

    void getGitStatus(workspace.hostMount)
      .then((status) => {
        if (!status.isGitRepo) return;
        this.broadcast(key, {
          type: "git_status",
          workspaceId: wsId,
          status,
        });
      })
      .catch(() => {
        // Silently ignore git errors
      });
  }

  private markSessionDirty(key: string): void {
    this.dirtySessions.add(key);

    if (this.saveTimer) {
      return;
    }

    this.saveTimer = setTimeout(() => {
      this.flushDirtySessions();
    }, this.saveDebounceMs);
  }

  private flushDirtySessions(): void {
    const keys = Array.from(this.dirtySessions);
    this.dirtySessions.clear();
    this.saveTimer = null;

    for (const key of keys) {
      const active = this.active.get(key);
      if (!active) {
        continue;
      }

      this.storage.saveSession(active.session);
    }
  }

  private persistSessionNow(key: string, session: Session): void {
    this.dirtySessions.delete(key);
    this.storage.saveSession(session);
  }

  // ─── Session End ───

  private handleSessionEnd(key: string, reason: string): void {
    const active = this.active.get(key);
    if (!active) return;

    const pendingStop = this.clearPendingStop(active);
    if (pendingStop?.mode === "terminate") {
      this.broadcast(key, {
        type: "stop_confirmed",
        source: pendingStop.source,
        reason: "Session terminated",
      });
    } else if (pendingStop?.mode === "abort") {
      this.broadcast(key, {
        type: "stop_failed",
        source: "server",
        reason: `Session ended before stop completed (${reason})`,
      });
    }

    active.session.status = "stopped";
    this.persistSessionNow(key, active.session);

    // Clean up gate socket
    this.gate.destroySessionGuard(active.session.id);

    // Cancel pending UI requests
    active.pendingUIRequests.clear();

    // Dispose SDK backend
    if (!active.sdkBackend.isDisposed) {
      active.sdkBackend.dispose();
    }

    this.broadcast(key, { type: "session_ended", reason });
    this.clearIdleTimer(key);
    this.active.delete(key);

    this.runtimeManager.releaseSession({
      workspaceId: active.workspaceId,
      sessionId: active.session.id,
    });
  }

  // ─── Subscribe / Broadcast ───

  subscribe(sessionId: string, callback: (msg: ServerMessage) => void): () => void {
    const key = this.sessionKey(sessionId);
    const active = this.active.get(key);
    if (active) {
      active.subscribers.add(callback);
      return () => active.subscribers.delete(callback);
    }
    return () => {};
  }

  private static readonly DURABLE_MESSAGE_TYPES = new Set<ServerMessage["type"]>([
    "agent_start",
    "agent_end",
    "message_end",
    "tool_start",
    "tool_end",
    "permission_request",
    "permission_expired",
    "permission_cancelled",
    "stop_requested",
    "stop_confirmed",
    "stop_failed",
    "session_ended",
    "error",
  ]);

  private isDurableMessage(message: ServerMessage): boolean {
    return SessionManager.DURABLE_MESSAGE_TYPES.has(message.type);
  }

  private broadcastDurable(key: string, message: ServerMessage): void {
    const active = this.active.get(key);
    if (!active) return;

    active.seq += 1;
    const sequenced: ServerMessage = { ...message, seq: active.seq };

    active.eventRing.push({
      seq: active.seq,
      event: sequenced,
      timestamp: Date.now(),
    });

    this.emit("session_event", {
      sessionId: active.session.id,
      event: sequenced,
      durable: true,
    } satisfies SessionBroadcastEvent);

    for (const cb of active.subscribers) {
      try {
        cb(sequenced);
      } catch (err) {
        console.error("Subscriber error:", err);
      }
    }
  }

  private broadcastEphemeral(key: string, message: ServerMessage): void {
    const active = this.active.get(key);
    if (!active) return;

    // Only emit low-frequency ephemeral events to global observers.
    // High-frequency deltas (text/thinking/tool_output) should not fan out
    // through EventEmitter to avoid hot-path overhead.
    if (message.type === "state") {
      this.emit("session_event", {
        sessionId: active.session.id,
        event: message,
        durable: false,
      } satisfies SessionBroadcastEvent);
    }

    for (const cb of active.subscribers) {
      try {
        cb(message);
      } catch (err) {
        console.error("Subscriber error:", err);
      }
    }
  }

  private broadcast(key: string, message: ServerMessage): void {
    if (this.isDurableMessage(message)) {
      this.broadcastDurable(key, message);
      return;
    }

    this.broadcastEphemeral(key, message);
  }

  // ─── Stop ───

  private clearPendingStop(active: ActiveSession): PendingStop | null {
    const pending = active.pendingStop;
    if (!pending) {
      return null;
    }

    if (pending.timeoutHandle) {
      clearTimeout(pending.timeoutHandle);
      pending.timeoutHandle = undefined;
    }

    active.pendingStop = undefined;
    return pending;
  }

  private beginPendingStop(
    key: string,
    active: ActiveSession,
    mode: PendingStop["mode"],
    source: StopRequestSource,
    reason?: string,
  ): boolean {
    if (active.pendingStop) {
      return false;
    }

    active.pendingStop = {
      mode,
      source,
      requestedAt: Date.now(),
      previousStatus: active.session.status,
    };

    active.session.status = "stopping";
    active.session.lastActivity = Date.now();
    this.persistSessionNow(key, active.session);

    this.broadcast(key, { type: "stop_requested", source, reason });
    this.broadcast(key, { type: "state", session: active.session });
    return true;
  }

  private promotePendingStop(
    key: string,
    active: ActiveSession,
    mode: PendingStop["mode"],
    source: StopRequestSource,
    reason?: string,
    emitLifecycleEvent = false,
  ): void {
    if (!active.pendingStop) {
      this.beginPendingStop(key, active, mode, source, reason);
      return;
    }

    const pending = active.pendingStop;

    if (pending.timeoutHandle) {
      clearTimeout(pending.timeoutHandle);
      pending.timeoutHandle = undefined;
    }

    pending.mode = mode;
    pending.source = source;

    if (active.session.status !== "stopping") {
      active.session.status = "stopping";
      active.session.lastActivity = Date.now();
      this.persistSessionNow(key, active.session);
    }

    if (emitLifecycleEvent) {
      this.broadcast(key, { type: "stop_requested", source, reason });
      this.broadcast(key, { type: "state", session: active.session });
    }
  }

  private finishPendingStopWithFailure(
    key: string,
    active: ActiveSession,
    source: StopRequestSource,
    reason: string,
  ): void {
    const pending = this.clearPendingStop(active);
    if (!pending) {
      return;
    }

    if (active.session.status === "stopping") {
      const fallbackStatus =
        pending.previousStatus === "stopping" ? "busy" : pending.previousStatus;
      active.session.status = fallbackStatus;
      active.session.lastActivity = Date.now();
      this.persistSessionNow(key, active.session);
      this.broadcast(key, { type: "state", session: active.session });
    }

    this.broadcast(key, { type: "stop_failed", source, reason });
  }

  private finishPendingAbortWithSuccess(key: string, active: ActiveSession): void {
    const pending = this.clearPendingStop(active);
    if (!pending || pending.mode !== "abort") {
      return;
    }

    this.broadcast(key, { type: "stop_confirmed", source: pending.source });
  }

  private forceTerminateSessionProcess(
    key: string,
    active: ActiveSession,
    source: StopRequestSource,
    reason?: string,
  ): void {
    try {
      active.sdkBackend.dispose();

      const pending = this.clearPendingStop(active);
      this.broadcast(key, {
        type: "stop_confirmed",
        source: pending?.source ?? source,
        reason,
      });
      this.handleSessionEnd(key, "stopped");
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      this.finishPendingStopWithFailure(key, active, "server", `Force stop failed: ${message}`);
    }
  }

  private scheduleAbortStopTimeout(key: string, active: ActiveSession): void {
    const pending = active.pendingStop;
    if (!pending || pending.mode !== "abort") {
      return;
    }

    pending.timeoutHandle = setTimeout(() => {
      const current = this.active.get(key);
      if (!current || current.pendingStop?.mode !== "abort") {
        return;
      }

      // Phase 1: first abort timed out — retry abort to interrupt running tools
      console.log(
        `${ts()} [session] Abort timed out after ${this.stopAbortTimeoutMs}ms; retrying abort`,
      );
      this.broadcast(key, {
        type: "stop_requested",
        source: "server",
        reason: `Graceful stop timed out after ${this.stopAbortTimeoutMs}ms; retrying abort`,
      });

      try {
        void current.sdkBackend.abort();
      } catch {
        // process may have already exited
      }

      // Phase 2: if retry doesn't resolve the abort, give up but keep session alive
      const currentPendingStop = current.pendingStop;
      if (!currentPendingStop || currentPendingStop.mode !== "abort") {
        return;
      }

      currentPendingStop.timeoutHandle = setTimeout(() => {
        const still = this.active.get(key);
        if (!still || still.pendingStop?.mode !== "abort") {
          return;
        }

        console.warn(
          `${ts()} [session] Abort still pending after retry + ${this.stopAbortRetryTimeoutMs}ms; giving up (session stays alive)`,
        );
        this.finishPendingStopWithFailure(
          key,
          still,
          "server",
          `Stop timed out — the agent may still be processing. You can send another message or stop the session.`,
        );
      }, this.stopAbortRetryTimeoutMs);
    }, this.stopAbortTimeoutMs);
  }

  async stopSession(sessionId: string): Promise<void> {
    const key = this.sessionKey(sessionId);

    await this.runtimeManager.withSessionLock(sessionId, async () => {
      const active = this.active.get(key);
      if (!active) return;

      await this.runtimeManager.withWorkspaceLock(active.workspaceId, async () => {
        if (!this.beginPendingStop(key, active, "terminate", "user")) {
          this.promotePendingStop(key, active, "terminate", "user");
        }

        // Graceful: abort current operation
        void active.sdkBackend.abort();

        // Wait briefly then stop
        await new Promise((r) => setTimeout(r, this.stopSessionGraceMs));

        // Stop the session process directly.
        this.forceTerminateSessionProcess(key, active, "user");
      });
    });
  }

  async stopAll(): Promise<void> {
    const keys = Array.from(this.active.keys());
    await Promise.all(
      keys.map((key) => {
        const active = this.active.get(key);
        if (!active) {
          return Promise.resolve();
        }
        return this.stopSession(active.session.id);
      }),
    );
  }

  // ─── State Queries ───

  isActive(sessionId: string): boolean {
    return this.active.has(this.sessionKey(sessionId));
  }

  getActiveSession(sessionId: string): Session | undefined {
    return this.active.get(this.sessionKey(sessionId))?.session;
  }

  getCurrentSeq(sessionId: string): number {
    const active = this.active.get(this.sessionKey(sessionId));
    return active?.seq ?? 0;
  }

  getCatchUp(sessionId: string, sinceSeq: number): SessionCatchUpResponse | null {
    const active = this.active.get(this.sessionKey(sessionId));
    if (!active) {
      return null;
    }

    const canServe = active.eventRing.canServe(sinceSeq);
    const events = canServe ? active.eventRing.since(sinceSeq).map((entry) => entry.event) : [];

    return {
      events,
      currentSeq: active.seq,
      session: active.session,
      catchUpComplete: canServe,
    };
  }

  hasPendingUIRequest(sessionId: string, requestId: string): boolean {
    const active = this.active.get(this.sessionKey(sessionId));
    return active?.pendingUIRequests.has(requestId) ?? false;
  }

  // ─── Idle Management ───

  private resetIdleTimer(key: string): void {
    this.clearIdleTimer(key);

    const timeoutMs = this.runtimeManager.getLimits().sessionIdleTimeoutMs;
    const timer = setTimeout(() => {
      console.log(`${ts()} [session] idle timeout: ${key}`);
      const active = this.active.get(key);
      if (!active) return;
      void this.stopSession(active.session.id);
    }, timeoutMs);

    this.idleTimers.set(key, timer);
  }

  private clearIdleTimer(key: string): void {
    const timer = this.idleTimers.get(key);
    if (timer) {
      clearTimeout(timer);
      this.idleTimers.delete(key);
    }
  }
}

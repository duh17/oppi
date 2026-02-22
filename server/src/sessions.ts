/**
 * Session manager — pi agent lifecycle via SDK.
 *
 * Pi runs in-process via createAgentSession(). Tool calls are gated
 * through the in-process permission extension factory.
 *
 * Handles:
 * - Session lifecycle (start, stop, idle timeout)
 * - Agent event → simplified WebSocket message translation
 * - SDK command passthrough (model switching, compaction, etc.)
 */

import { EventEmitter } from "node:events";

import type { Session, ServerMessage, Workspace } from "./types.js";
import type { Storage } from "./storage.js";
import type { GateServer } from "./gate.js";

import { WorkspaceRuntime, resolveRuntimeLimits } from "./workspace-runtime.js";
import { type PiEvent, type PiStateSnapshot } from "./pi-events.js";
import { MobileRendererRegistry } from "./mobile-renderer.js";
import {
  createSessionCoordinatorBundle,
  type SessionCoordinatorBundle,
} from "./session-coordinators.js";
import type { SessionCatchUpResponse } from "./session-broadcast.js";
import { type SessionStartActiveSession } from "./session-start.js";
import { type SessionStateActiveSession } from "./session-state.js";
import { type ExtensionUIResponse } from "./session-ui.js";
import { ts } from "./log-utils.js";

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

export { composeModelId } from "./session-state.js";
export type { SessionCatchUpResponse, SessionBroadcastEvent } from "./session-broadcast.js";

// ─── Types ───

type ActiveSession = SessionStartActiveSession;

export type { ExtensionUIRequest } from "./session-events.js";
export type { ExtensionUIResponse } from "./session-ui.js";

// ─── Session Manager ───

export class SessionManager extends EventEmitter {
  private storage: Storage;
  private active: Map<string, ActiveSession> = new Map();

  /** Injected by the server to resolve context window for a model ID. */
  contextWindowResolver: ((modelId: string) => number) | null = null;

  /** Injected by the server to resolve skill names to host directory paths. */
  skillPathResolver: ((skillNames: string[]) => string[]) | null = null;

  private readonly broadcaster: SessionCoordinatorBundle["broadcaster"];
  private readonly stateCoordinator: SessionCoordinatorBundle["stateCoordinator"];
  private readonly commandCoordinator: SessionCoordinatorBundle["commandCoordinator"];
  private readonly activationCoordinator: SessionCoordinatorBundle["activationCoordinator"];
  private readonly lifecycleCoordinator: SessionCoordinatorBundle["lifecycleCoordinator"];
  private readonly inputCoordinator: SessionCoordinatorBundle["inputCoordinator"];
  private readonly agentEventCoordinator: SessionCoordinatorBundle["agentEventCoordinator"];
  private readonly stopFlowCoordinator: SessionCoordinatorBundle["stopFlowCoordinator"];
  private readonly uiCoordinator: SessionCoordinatorBundle["uiCoordinator"];

  constructor(storage: Storage, gate: GateServer) {
    super();
    this.storage = storage;
    const config = storage.getConfig();
    const runtimeManager = new WorkspaceRuntime(resolveRuntimeLimits(config));
    const mobileRenderers = new MobileRendererRegistry();
    const eventRingCapacity = parsePositiveIntEnv("OPPI_SESSION_EVENT_RING_CAPACITY", 500);

    const bundle = createSessionCoordinatorBundle({
      storage,
      config,
      gate,
      runtimeManager,
      active: this.active,
      mobileRenderers,
      eventRingCapacity,
      stopAbortTimeoutMs: this.stopAbortTimeoutMs,
      stopAbortRetryTimeoutMs: this.stopAbortRetryTimeoutMs,
      stopSessionGraceMs: this.stopSessionGraceMs,
      getContextWindowResolver: () => this.contextWindowResolver,
      getSkillPathResolver: () => this.skillPathResolver,
      emitSessionEvent: (payload) => this.emit("session_event", payload),
      onPiEvent: (key, event) => this.handlePiEvent(key, event),
      onSessionEnd: (key, reason) => this.handleSessionEnd(key, reason),
      persistSessionNow: (key, session) => this.persistSessionNow(key, session),
      markSessionDirty: (key) => this.markSessionDirty(key),
      resetIdleTimer: (key) => this.resetIdleTimer(key),
      bootstrapSessionState: (key) => this.bootstrapSessionState(key),
      sendCommand: (key, command) => this.sendCommand(key, command),
      sendCommandAsync: (key, command, timeoutMs) => this.sendCommandAsync(key, command, timeoutMs),
      broadcast: (key, message) => this.broadcast(key, message),
      stopSession: (sessionId) => this.stopSession(sessionId),
    });

    this.broadcaster = bundle.broadcaster;
    this.stateCoordinator = bundle.stateCoordinator;
    this.commandCoordinator = bundle.commandCoordinator;
    this.activationCoordinator = bundle.activationCoordinator;
    this.lifecycleCoordinator = bundle.lifecycleCoordinator;
    this.inputCoordinator = bundle.inputCoordinator;
    this.agentEventCoordinator = bundle.agentEventCoordinator;
    this.stopFlowCoordinator = bundle.stopFlowCoordinator;
    this.uiCoordinator = bundle.uiCoordinator;

    // Load user-provided mobile renderers (async, fire-and-forget at startup).
    mobileRenderers.loadAllRenderers().then(({ loaded, errors }) => {
      if (loaded.length > 0) {
        console.log(`${ts()} [mobile-renderer] loaded: ${loaded.join(", ")}`);
      }
      for (const err of errors) {
        console.error(`${ts()} [mobile-renderer] ${err}`);
      }
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
  async startSession(
    sessionId: string,
    userName?: string,
    workspace?: Workspace,
  ): Promise<Session> {
    const key = this.sessionKey(sessionId);
    return this.activationCoordinator.startSession(key, sessionId, workspace);
  }

  /** Process a pi agent event from the SDK subscribe callback. */
  private handlePiEvent(key: string, data: PiEvent): void {
    this.agentEventCoordinator.handlePiEvent(key, data);
  }

  // ─── Extension UI Protocol ───

  /**
   * Send extension_ui_response back to pi (in-process gate).
   * Called by server.ts when phone responds to a UI dialog.
   */
  respondToUIRequest(sessionId: string, response: ExtensionUIResponse): boolean {
    const key = this.sessionKey(sessionId);
    return this.uiCoordinator.respondToUIRequest(key, response);
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
    await this.inputCoordinator.sendPrompt(key, message, opts);
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
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      clientTurnId?: string;
      requestId?: string;
    },
  ): Promise<void> {
    const key = this.sessionKey(sessionId);
    await this.inputCoordinator.sendFollowUp(key, message, opts);
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
  ): Promise<{ sessionFile?: string; sessionId?: string } | null> {
    const key = this.sessionKey(sessionId);
    const active = this.active.get(key);
    if (!active) return null;

    return this.stateCoordinator.refreshSessionState(key, active as SessionStateActiveSession);
  }

  /**
   * Run a SDK command against an active session and await response.
   * Used by HTTP workflows (e.g. server-orchestrated fork/session operations).
   */
  async runCommand(
    sessionId: string,
    command: Record<string, unknown>,
    timeoutMs = 30_000,
  ): Promise<unknown> {
    const key = this.sessionKey(sessionId);
    if (!this.active.has(key)) {
      throw new Error(`Session not active: ${sessionId}`);
    }

    return this.sendCommandAsync(key, { ...command }, timeoutMs);
  }

  /**
   * Apply fields we care about from pi `get_state` response payload.
   * Returns true if the session object changed.
   */
  private applyPiStateSnapshot(
    session: Session,
    state: PiStateSnapshot | null | undefined,
  ): boolean {
    return this.stateCoordinator.applyPiStateSnapshot(session, state);
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
      (commandKey, command, timeoutMs) => this.sendCommandAsync(commandKey, command, timeoutMs),
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
    await this.stopFlowCoordinator.sendAbort(key, sessionId);
  }

  /** Graceful abort budget before escalating. */
  private readonly stopAbortTimeoutMs = 8_000;

  /** After escalation, wait this long before giving up (session stays alive). */
  private readonly stopAbortRetryTimeoutMs = 5_000;

  /** Grace period between abort and dispose in force-stop flow. */
  private readonly stopSessionGraceMs = 1_000;

  // ─── SDK Commands ───

  /**
   * Send a fire-and-forget command to the SDK backend.
   */
  sendCommand(key: string, command: Record<string, unknown>): void {
    this.commandCoordinator.sendCommand(key, command);
    this.resetIdleTimer(key);
  }

  /**
   * Send a command to the SDK backend and await the result.
   * Dispatches through the declarative SDK_HANDLERS map.
   */
  async sendCommandAsync(
    key: string,
    command: Record<string, unknown>,
    timeoutMs = 10_000,
  ): Promise<unknown> {
    return this.commandCoordinator.sendCommandAsync(key, command, timeoutMs);
  }

  // ─── Persistence ───

  private markSessionDirty(key: string): void {
    this.broadcaster.markSessionDirty(key);
  }

  private persistSessionNow(key: string, session: Session): void {
    this.broadcaster.persistSessionNow(key, session);
  }

  // ─── Session End ───

  private handleSessionEnd(key: string, reason: string): void {
    this.lifecycleCoordinator.handleSessionEnd(key, reason);
  }

  // ─── Subscribe / Broadcast ───

  subscribe(sessionId: string, callback: (msg: ServerMessage) => void): () => void {
    return this.broadcaster.subscribe(this.sessionKey(sessionId), callback);
  }

  private broadcast(key: string, message: ServerMessage): void {
    this.broadcaster.broadcast(key, message);
  }

  // ─── Stop ───

  async stopSession(sessionId: string): Promise<void> {
    const key = this.sessionKey(sessionId);
    await this.stopFlowCoordinator.stopSession(key, sessionId);
  }

  async stopAll(): Promise<void> {
    const sessionIds = Array.from(this.active.values()).map((active) => active.session.id);
    await Promise.all(sessionIds.map((sessionId) => this.stopSession(sessionId)));
  }

  // ─── State Queries ───

  isActive(sessionId: string): boolean {
    return this.active.has(this.sessionKey(sessionId));
  }

  getActiveSession(sessionId: string): Session | undefined {
    return this.active.get(this.sessionKey(sessionId))?.session;
  }

  getCurrentSeq(sessionId: string): number {
    return this.broadcaster.getCurrentSeq(this.sessionKey(sessionId));
  }

  getCatchUp(sessionId: string, sinceSeq: number): SessionCatchUpResponse | null {
    return this.broadcaster.getCatchUp(this.sessionKey(sessionId), sinceSeq);
  }

  hasPendingUIRequest(sessionId: string, requestId: string): boolean {
    return this.uiCoordinator.hasPendingUIRequest(this.sessionKey(sessionId), requestId);
  }

  // ─── Idle Management ───

  private resetIdleTimer(key: string): void {
    this.lifecycleCoordinator.resetIdleTimer(key);
  }
}

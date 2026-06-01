import { EventEmitter } from "node:events";
import { closeSync, existsSync, openSync, readSync, realpathSync } from "node:fs";
import { homedir, hostname } from "node:os";
import { join, resolve } from "node:path";

import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";
import { WebSocket, type RawData } from "ws";

import {
  applyForwardedCommandResultToSession,
  type AgentRuntimeTransport,
} from "./agent-runtime-transport.js";
import {
  buildExtensionUIRequestMessage,
  buildExtensionUISettledMessage,
} from "./extension-ui-contract.js";
import { EventRing } from "./event-ring.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import {
  MirrorBridgeCommandDriver,
  type MirrorBridgeCommandConnection,
  type MirrorBridgeCommandDriverEvent,
} from "./mirror-bridge-command-driver.js";
import {
  RuntimeCommandCoordinator,
  type RuntimeCommandExecutionContext,
} from "./runtime-command-coordinator.js";
import type { SessionBackendEvent } from "./pi-events.js";
import { SessionAgentEventCoordinator } from "./session-agent-events.js";
import { normalizeCommandError } from "./session-protocol.js";
import { buildSessionSummary, sessionSummaryFingerprint } from "./session-summary.js";
import { composeModelId } from "./session-state.js";
import { SessionBroadcaster, type SessionCatchUpResponse } from "./session-broadcast.js";
import {
  SessionEventProcessor,
  type EventProcessorSessionState,
  type ExtensionUIRequest,
} from "./session-events.js";
import type { ExtensionUIResponse } from "./session-ui.js";
import { SessionInputCoordinator, type SessionInputSessionState } from "./session-input.js";
import {
  assertQueueBaseVersion,
  cloneQueueState,
  dequeueQueueItemByText,
  extractQueuedUserText,
  parseQueueState,
  queueItemStartedMessage,
  queueStateMessage,
  removeQueueItemStartedByRuntime,
  requireQueueState,
} from "./session-queue-utils.js";
import { SessionTurnCoordinator } from "./session-turns.js";
import type { Storage } from "./storage.js";
import { TurnDedupeCache } from "./turn-cache.js";
import { resolveUploadStoreConfig } from "./uploads/local-upload-store.js";
import type {
  ChatAttachmentRef,
  MessageQueueDraftItem,
  MessageQueueItem,
  MessageQueueKind,
  MessageQueueState,
  ServerMessage,
  Session,
  Workspace,
} from "./types.js";

const log = createLogger({ base: { component: "pi_tui_mirror_runtime" } });

const BRIDGE_PROTOCOL_VERSION = 1;
const EVENT_RING_CAPACITY = 500;
const OPPI_RUNTIME_CONFLICT_RETRY_MS = 10_000;
const PI_TUI_STOP_TIMEOUT_MS = 15_000;
const MIRROR_RUNTIME_LOG_TAG = "pi-tui";

class BridgeRegistrationError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly details: Record<string, unknown> = {},
  ) {
    super(message);
  }
}

const SUPPORTED_REMOTE_COMMANDS = new Set([
  "get_state",
  "get_messages",
  "get_fork_messages",
  "get_session_tree",
  "navigate_tree",
  "get_session_stats",
  "get_commands",
  "set_model",
  "cycle_model",
  "get_available_models",
  "set_thinking_level",
  "cycle_thinking_level",
  "set_session_name",
  "compact",
  "set_auto_compaction",
  "set_steering_mode",
  "set_follow_up_mode",
  "set_auto_retry",
  "abort_retry",
  "abort_bash",
  "abort",
  "reload",
  "get_queue",
  "set_queue",
]);

const UNSUPPORTED_REMOTE_COMMAND_REASONS = new Map([
  ["share_session", "sharing needs a server-owned AgentSession export path"],
  ["new_session", "session replacement is terminal-owned; start it from the terminal"],
  ["fork", "session-file replacement is terminal-owned; fork from the terminal"],
  ["switch_session", "session-file replacement is terminal-owned; switch from the terminal"],
]);

export interface PiBridgeStateSnapshot {
  sessionFile?: string;
  piSessionId?: string;
  sessionName?: string;
  model?: string | { provider?: unknown; id?: unknown; modelId?: unknown } | null;
  thinkingLevel?: string;
  isIdle?: boolean;
  contextUsage?: { tokens?: unknown; contextWindow?: unknown } | null;
  cwd?: string;
}

interface PiBridgeHelloMessage {
  type: "hello";
  protocolVersion?: number;
  bridgeId?: string;
  pid?: number;
  hostname?: string;
  cwd?: string;
  workspaceId?: string;
  capabilities?: string[];
  state?: PiBridgeStateSnapshot;
}

interface PiBridgeStateMessage {
  type: "state";
  state: PiBridgeStateSnapshot;
}

interface PiBridgeAgentEventMessage {
  type: "event";
  event: AgentSessionEvent;
  state?: PiBridgeStateSnapshot;
}

interface PiBridgeCommandResultMessage {
  type: "command_result";
  id: string;
  success: boolean;
  data?: unknown;
  error?: string;
  state?: PiBridgeStateSnapshot;
}

interface PiBridgeHeartbeatMessage {
  type: "heartbeat";
  state?: PiBridgeStateSnapshot;
  queue?: MessageQueueState;
}

interface PiBridgeQueueStateMessage {
  type: "queue_state";
  queue: MessageQueueState;
}

interface PiBridgeQueueItemStartedMessage {
  type: "queue_item_started";
  kind: MessageQueueKind;
  item: MessageQueueItem;
  queueVersion: number;
  queue?: MessageQueueState;
}

interface PiBridgeGoodbyeMessage {
  type: "goodbye";
  reason?: string;
  state?: PiBridgeStateSnapshot;
}

type PiBridgeExtensionUIRequestMessage = ExtensionUIRequest;

interface PiBridgeExtensionUIRequestSettledMessage {
  type: "extension_ui_request_settled";
  id: string;
}

type PiBridgeInboundMessage =
  | PiBridgeHelloMessage
  | PiBridgeStateMessage
  | PiBridgeAgentEventMessage
  | PiBridgeCommandResultMessage
  | PiBridgeHeartbeatMessage
  | PiBridgeQueueStateMessage
  | PiBridgeQueueItemStartedMessage
  | PiBridgeGoodbyeMessage
  | PiBridgeExtensionUIRequestMessage
  | PiBridgeExtensionUIRequestSettledMessage;

interface MirrorActiveSession extends EventProcessorSessionState, SessionInputSessionState {
  session: Session;
  subscribers: Set<(msg: ServerMessage) => void>;
  seq: number;
  eventRing: EventRing;
  partialResults: Map<string, string>;
  streamedAssistantText: string;
  hasStreamedThinking: boolean;
  streamedThinkingContentIndexes: Set<number>;
  currentThinkingContentIndex?: number;
  toolNames: Map<string, string>;
  shellPreviewLastSent: Map<string, number>;
  streamingArgPreviews: Set<string>;
  streamingToolUpdatesSeen: Map<string, string>;
  toolFullOutputPaths: Map<string, string>;
  messageQueue: MessageQueueState;
  lastSummaryFingerprint?: string;
  sdkBackend: never;
}

interface PendingBridgeStopWaiter {
  resolve: () => void;
  reject: (error: Error) => void;
  timeout: ReturnType<typeof setTimeout>;
}

interface BridgeConnection extends MirrorBridgeCommandConnection {
  cwd?: string;
  capabilities: string[];
  protocolVersion: number;
  connectedAt: number;
  lastSeenAt: number;
  stopRequestedAt?: number;
  fireAndForgetCommandIds: Set<string>;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function trustedSessionAttachmentSourceRoots(): string[] {
  return [join(homedir(), "Library/Application Support/Yuwp/Audio/pi-voice")];
}

function rawDataToText(data: RawData): string {
  if (typeof data === "string") return data;
  if (Buffer.isBuffer(data)) return data.toString("utf8");
  if (Array.isArray(data)) return Buffer.concat(data).toString("utf8");
  return Buffer.from(data).toString("utf8");
}

function isMirrorReloadPrompt(
  message: string,
  opts: {
    images?: unknown[];
    attachments?: unknown[];
    streamingBehavior?: "steer" | "followUp";
  },
): boolean {
  return (
    message.trim() === "/reload" &&
    !opts.streamingBehavior &&
    !opts.images?.length &&
    !opts.attachments?.length
  );
}

function isTerminalStoppedReason(reason: string): boolean {
  const normalized = reason.trim().toLowerCase();
  return normalized === "stopped" || normalized === "session_shutdown";
}

function meaningfulSessionName(name: string | undefined, sessionId?: string): string | undefined {
  const trimmed = name?.trim();
  if (!trimmed) return undefined;
  if (trimmed === "Session") return undefined;
  if (sessionId && trimmed === `Session ${sessionId}`) return undefined;
  if (/^Session\s+[A-Za-z0-9_-]{4,}$/.test(trimmed)) return undefined;
  return trimmed;
}

function firstUserMessageFromSessionFile(path: string | undefined): string | undefined {
  const file = canonicalSessionFilePath(path);
  if (!file || !existsSync(file)) return undefined;

  let fd: number | undefined;
  try {
    fd = openSync(file, "r");
    const buffer = Buffer.alloc(1024 * 1024);
    const bytesRead = readSync(fd, buffer, 0, buffer.length, 0);
    const lines = buffer.toString("utf8", 0, bytesRead).split("\n");
    for (const line of lines) {
      const trimmedLine = line.trim();
      if (!trimmedLine) continue;
      const parsed = JSON.parse(trimmedLine) as unknown;
      const record = asRecord(parsed);
      const message = asRecord(record?.message) ?? record;
      if (message?.role !== "user") continue;
      const text = extractQueuedUserText(message).trim();
      if (text) return text.slice(0, 200);
    }
  } catch {
    return undefined;
  } finally {
    if (fd !== undefined) closeSync(fd);
  }

  return undefined;
}

function parseBridgeMessage(data: RawData): PiBridgeInboundMessage {
  const parsed = JSON.parse(rawDataToText(data)) as unknown;
  const record = asRecord(parsed);
  if (!record || typeof record.type !== "string") {
    throw new Error("Bridge message must be an object with a string type");
  }
  return record as unknown as PiBridgeInboundMessage;
}

function expandHomePath(path: string): string {
  const trimmed = path.trim();
  if (trimmed === "~") return homedir();
  if (trimmed.startsWith("~/")) return resolve(homedir(), trimmed.slice(2));
  return trimmed;
}

function normalizePath(path: string): string {
  return resolve(expandHomePath(path));
}

function canonicalSessionFilePath(path: string | undefined): string | undefined {
  const trimmed = path?.trim();
  if (!trimmed) return undefined;
  const resolved = normalizePath(trimmed);
  if (!existsSync(resolved)) return resolved;
  try {
    return realpathSync(resolved);
  } catch {
    return resolved;
  }
}

function pathContains(parent: string, child: string): boolean {
  const resolvedParent = normalizePath(parent);
  const resolvedChild = normalizePath(child);
  return resolvedChild === resolvedParent || resolvedChild.startsWith(`${resolvedParent}/`);
}

function normalizeModelId(model: PiBridgeStateSnapshot["model"]): string | undefined {
  if (!model) return undefined;
  if (typeof model === "string") return model.trim() || undefined;
  const provider = typeof model.provider === "string" ? model.provider.trim() : "";
  const modelId =
    typeof model.id === "string"
      ? model.id.trim()
      : typeof model.modelId === "string"
        ? model.modelId.trim()
        : "";
  return provider && modelId ? composeModelId(provider, modelId) : undefined;
}

function mergePiSessionFile(session: Session, file: string | undefined): void {
  const canonical = canonicalSessionFilePath(file);
  if (!canonical) return;
  session.piSessionFile = canonical;
  const files = new Set(
    (session.piSessionFiles ?? []).map((item) => canonicalSessionFilePath(item) ?? item),
  );
  files.add(canonical);
  session.piSessionFiles = [...files];
}

function emptyQueue(): MessageQueueState {
  return { version: 0, steering: [], followUp: [] };
}

function queueCounts(queue: MessageQueueState): {
  version: number;
  steeringCount: number;
  followUpCount: number;
} {
  return {
    version: queue.version,
    steeringCount: queue.steering.length,
    followUpCount: queue.followUp.length,
  };
}

function queueShapeChanged(previous: MessageQueueState, next: MessageQueueState): boolean {
  return (
    previous.version !== next.version ||
    previous.steering.length !== next.steering.length ||
    previous.followUp.length !== next.followUp.length
  );
}

export interface PiTuiMirrorRuntimeOptions {
  isOppiSessionActive?: (sessionId: string) => boolean;
}

export class PiTuiMirrorRuntime extends EventEmitter implements AgentRuntimeTransport {
  private readonly active = new Map<string, MirrorActiveSession>();
  private readonly bridges = new Map<string, BridgeConnection>();
  private readonly bridgeBySession = new Map<string, string>();
  private readonly broadcaster: SessionBroadcaster;
  private readonly eventProcessor: SessionEventProcessor;
  private readonly turnCoordinator: SessionTurnCoordinator;
  private readonly agentEventCoordinator: SessionAgentEventCoordinator;
  private readonly inputCoordinator: SessionInputCoordinator;
  private readonly runtimeCommandCoordinator: RuntimeCommandCoordinator;
  private readonly bridgeCommandDriver: MirrorBridgeCommandDriver;
  private readonly pendingStopWaiters = new Map<string, Set<PendingBridgeStopWaiter>>();

  constructor(
    private readonly storage: Storage,
    private readonly options: PiTuiMirrorRuntimeOptions = {},
  ) {
    super();
    this.bridgeCommandDriver = new MirrorBridgeCommandDriver(undefined, {
      onCommandEvent: (event) => this.logBridgeCommandEvent(event),
    });
    this.broadcaster = new SessionBroadcaster({
      getActiveSession: (sessionId) => this.active.get(sessionId),
      emitSessionEvent: (payload) => this.emit("session_event", payload),
      saveSession: (session) => this.storage.saveSession(session),
    });
    this.eventProcessor = new SessionEventProcessor({
      storage: this.storage,
      broadcast: (sessionId, message) => this.broadcast(sessionId, message),
      persistSessionNow: (_sessionId, session) => this.storage.saveSession(session),
      markSessionDirty: (sessionId) => {
        const active = this.active.get(sessionId);
        if (active) this.storage.saveSession(active.session);
      },
      respondToUIRequest: () => false,
      recordUserMessagesFromEvents: true,
    });
    this.turnCoordinator = new SessionTurnCoordinator({
      broadcast: (sessionId, message) => this.broadcast(sessionId, message),
    });
    this.agentEventCoordinator = new SessionAgentEventCoordinator({
      getActiveSession: (sessionId) => this.active.get(sessionId),
      eventProcessor: this.eventProcessor,
      stopCoordinator: {
        finishPendingStopOnAgentEnd: () => {},
      } as never,
      turnCoordinator: this.turnCoordinator,
      broadcast: (sessionId, message) => this.broadcast(sessionId, message),
      resetIdleTimer: () => {},
      markQueuedMessageStarted: (sessionId, message) => {
        const active = this.active.get(sessionId);
        if (!active) return;
        this.markQueuedMessageStarted(active, extractQueuedUserText(message));
      },
      dataDir: (this.storage as { getDataDir?: () => string }).getDataDir?.(),
      trustedAttachmentSourceRoots: trustedSessionAttachmentSourceRoots(),
    });

    const uploadStoreConfig = resolveUploadStoreConfig(this.storage.getConfig());
    this.inputCoordinator = new SessionInputCoordinator({
      getActiveSession: (sessionId) => this.active.get(sessionId),
      beginTurnIntent: (sessionId, active, command, payload, clientTurnId, requestId) =>
        this.turnCoordinator.beginTurnIntent(
          sessionId,
          active,
          command,
          payload,
          clientTurnId,
          requestId,
        ),
      isDuplicateTurnIntent: (active, command, clientTurnId, payload) =>
        this.turnCoordinator.isDuplicateTurnIntent(active, command, clientTurnId, payload),
      markTurnDispatched: (sessionId, active, command, turn, requestId) =>
        this.turnCoordinator.markTurnDispatched(sessionId, active, command, turn, requestId),
      sendCommand: (sessionId, command) => this.dispatchBridgeCommand(sessionId, command),
      onCommandResult: (sessionId, command, data) => {
        const commandType = typeof command.type === "string" ? command.type : "unknown";
        this.applyQueueFromCommandData(sessionId, data, `command_result:${commandType}`);
      },
      resolveWorkspaceRoot: (session) => this.resolveWorkspaceRoot(session),
      maxTurnAttachmentBytes: uploadStoreConfig.maxTurnBytes,
      uploadStoreConfig,
      recordPromptLocally: false,
      promptBusyErrorMessage:
        "Prompt requires an idle terminal session; use steer or follow_up while a turn is streaming",
      streamingInputBusyErrorMessage: (kind) => {
        const label = kind === "steer" ? "Steer" : "Follow-up";
        return `${label} requires an active streaming terminal turn`;
      },
      attachmentWorkspaceErrorMessage: "Attachments require a workspace-backed pi-tui session",
    });

    this.runtimeCommandCoordinator = new RuntimeCommandCoordinator({
      runtimeName: "pi-tui runtime",
      isCommandSupported: (commandType) => SUPPORTED_REMOTE_COMMANDS.has(commandType),
      unsupportedReason: (commandType) => UNSUPPORTED_REMOTE_COMMAND_REASONS.get(commandType),
      normalizeError: normalizeCommandError,
      broadcast: (sessionId, message) => this.broadcast(sessionId, message),
      onCommandSuccess: (sessionId, context) =>
        this.handleForwardedCommandSuccess(sessionId, context),
      preflightFailureMode: "broadcast",
    });
  }

  isMirrorSession(session: Session | undefined | null): boolean {
    return session?.runtime === "pi-tui";
  }

  handleBridgeWebSocket(ws: WebSocket): void {
    let connection: BridgeConnection | undefined;
    let rejectedBeforeHello = false;

    ws.on("message", (data, isBinary) => {
      if (rejectedBeforeHello) {
        return;
      }
      if (isBinary) {
        ws.close(1003, "Binary bridge messages are not supported");
        return;
      }

      try {
        const message = parseBridgeMessage(data);
        if (message.type === "hello") {
          if (connection) {
            throw new Error("Bridge already registered");
          }
          connection = this.registerBridge(ws, message);
          return;
        }

        if (!connection) {
          throw new Error("Bridge must send hello before other messages");
        }

        this.handleBridgeMessage(connection, message);
      } catch (error) {
        const message = safeErrorMessage(error);
        const details = error instanceof BridgeRegistrationError ? error.details : {};
        log.warn("mirror_bridge.message_rejected", {
          runtime: MIRROR_RUNTIME_LOG_TAG,
          error: message,
          ...(error instanceof BridgeRegistrationError ? { code: error.code, ...details } : {}),
        });
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(
            JSON.stringify({
              type: "error",
              error: message,
              ...(error instanceof BridgeRegistrationError ? { code: error.code, ...details } : {}),
            }),
          );
          if (!connection) {
            rejectedBeforeHello = true;
            ws.close(1008, message);
          }
        }
      }
    });

    ws.on("close", () => {
      if (connection) {
        this.detachBridge(connection, "closed");
      }
    });

    ws.on("error", (error) => {
      log.warn("mirror_bridge.ws_error", {
        runtime: MIRROR_RUNTIME_LOG_TAG,
        error: safeErrorMessage(error),
      });
    });
  }

  getActiveSessionIds(): Set<string> {
    return new Set(this.active.keys());
  }

  getActiveSession(sessionId: string): Session | undefined {
    return this.active.get(sessionId)?.session ?? this.storage.getSession(sessionId);
  }

  isSessionConnected(sessionId: string): boolean {
    return this.connectedBridgeForSession(sessionId) !== undefined;
  }

  private connectedBridgeForSession(sessionId: string): BridgeConnection | undefined {
    const bridgeId = this.bridgeBySession.get(sessionId);
    const connection = bridgeId ? this.bridges.get(bridgeId) : undefined;
    return connection?.ws.readyState === WebSocket.OPEN ? connection : undefined;
  }

  private settleExtensionUIRequest(
    active: MirrorActiveSession,
    requestId: string,
    cancelled: boolean,
  ): boolean {
    const req = active.pendingUIRequests.get(requestId);
    if (!req) return false;

    active.pendingUIRequests.delete(requestId);
    if (req.method === "ask") {
      this.eventProcessor.completeAskRequest(active, cancelled);
    } else if (active.pendingAsk?.requestId === requestId) {
      active.pendingAsk = undefined;
    }

    this.broadcast(active.session.id, buildExtensionUISettledMessage(active.session.id, requestId));
    return true;
  }

  subscribe(sessionId: string, callback: (msg: ServerMessage) => void): () => void {
    this.ensureActiveFromStorage(sessionId);
    return this.broadcaster.subscribe(sessionId, callback);
  }

  getCurrentSeq(sessionId: string): number {
    return this.broadcaster.getCurrentSeq(sessionId);
  }

  getCatchUp(sessionId: string, sinceSeq: number): SessionCatchUpResponse | null {
    return this.broadcaster.getCatchUp(sessionId, sinceSeq);
  }

  getPendingAskMessage(sessionId: string): ServerMessage | undefined {
    return this.ensureActiveFromStorage(sessionId)?.pendingAsk?.broadcastMessage;
  }

  getPendingUIRequestMessages(sessionId: string): ServerMessage[] {
    const active = this.ensureActiveFromStorage(sessionId);
    if (!active) {
      return [];
    }

    const messages: ServerMessage[] = [];
    for (const req of active.pendingUIRequests.values()) {
      if (req.method === "ask") {
        continue;
      }
      messages.push(buildExtensionUIRequestMessage(sessionId, req));
    }
    return messages;
  }

  private resolveWorkspaceRoot(session: Session): string | null {
    if (!session.workspaceId) return null;
    const workspace = this.storage.getWorkspace(session.workspaceId);
    if (!workspace?.hostMount) return null;
    return normalizePath(workspace.hostMount);
  }

  async sendPrompt(
    sessionId: string,
    message: string,
    opts: {
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      attachments?: ChatAttachmentRef[];
      clientTurnId?: string;
      requestId?: string;
      streamingBehavior?: "steer" | "followUp";
      timestamp: number;
    },
  ): Promise<void> {
    const active = this.requireActive(sessionId);
    if (isMirrorReloadPrompt(message, opts)) {
      await this.dispatchBridgeCommand(sessionId, { type: "reload" });
      active.session.lastActivity = opts.timestamp;
      this.storage.saveSession(active.session);
      return;
    }

    const result = await this.inputCoordinator.sendPrompt(sessionId, message, opts);
    if (result.duplicate) return;

    active.session.lastActivity = opts.timestamp;
    this.storage.saveSession(active.session);
  }

  async sendSteer(
    sessionId: string,
    message: string,
    opts: {
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      attachments?: ChatAttachmentRef[];
      clientTurnId?: string;
      requestId?: string;
    },
  ): Promise<void> {
    await this.inputCoordinator.sendSteer(sessionId, message, opts);
  }

  async sendFollowUp(
    sessionId: string,
    message: string,
    opts: {
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      attachments?: ChatAttachmentRef[];
      clientTurnId?: string;
      requestId?: string;
    },
  ): Promise<void> {
    await this.inputCoordinator.sendFollowUp(sessionId, message, opts);
  }

  async getMessageQueue(sessionId: string): Promise<MessageQueueState> {
    return this.dispatchBridgeQueueCommand(sessionId, { type: "get_queue" });
  }

  async setMessageQueue(
    sessionId: string,
    payload: {
      baseVersion: number;
      steering: MessageQueueDraftItem[];
      followUp: MessageQueueDraftItem[];
    },
  ): Promise<MessageQueueState> {
    const active = this.requireActive(sessionId);
    assertQueueBaseVersion(active.messageQueue, payload.baseVersion);

    return this.dispatchBridgeQueueCommand(sessionId, {
      type: "set_queue",
      baseVersion: payload.baseVersion,
      steering: payload.steering,
      followUp: payload.followUp,
    });
  }

  async sendAbort(sessionId: string): Promise<void> {
    const data = await this.dispatchBridgeCommand(sessionId, { type: "abort" });
    this.applyQueueFromCommandData(sessionId, data, "command_result:abort");
  }

  async stopSession(sessionId: string): Promise<void> {
    const bridgeId = this.bridgeBySession.get(sessionId);
    const connection = bridgeId ? this.bridges.get(bridgeId) : undefined;

    if (!connection || connection.ws.readyState !== WebSocket.OPEN) {
      throw new Error("pi-tui is not connected; stop it from the terminal");
    }

    connection.stopRequestedAt = Date.now();
    const waitForStop = this.waitForBridgeStop(connection);

    try {
      await this.sendFireAndForgetBridgeCommand(connection, { type: "stop" });
    } catch (error) {
      connection.stopRequestedAt = undefined;
      this.rejectPendingBridgeStops(connection, error);
      throw error;
    }

    await waitForStop;
  }

  private async sendFireAndForgetBridgeCommand(
    connection: BridgeConnection,
    command: Record<string, unknown>,
  ): Promise<void> {
    const commandId = `mirror_ff_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`;
    const payload = JSON.stringify({ type: "command", id: commandId, command });
    connection.fireAndForgetCommandIds.add(commandId);

    try {
      await new Promise<void>((resolve, reject) => {
        const ws = connection.ws as WebSocket & {
          send: (data: string, cb?: (error?: Error | null) => void) => void;
        };
        if (ws.send.length >= 2) {
          ws.send(payload, (error) => {
            if (error) reject(error);
            else resolve();
          });
          return;
        }
        ws.send(payload);
        resolve();
      });
    } catch (error) {
      connection.fireAndForgetCommandIds.delete(commandId);
      throw error instanceof Error ? error : new Error(safeErrorMessage(error));
    }
  }

  private waitForBridgeStop(connection: BridgeConnection): Promise<void> {
    return new Promise((resolve, reject) => {
      const waiters = this.pendingStopWaiters.get(connection.bridgeId) ?? new Set();
      const waiter: PendingBridgeStopWaiter = {
        resolve,
        reject,
        timeout: setTimeout(() => {
          waiters.delete(waiter);
          if (waiters.size === 0) {
            this.pendingStopWaiters.delete(connection.bridgeId);
          }
          if (connection.stopRequestedAt !== undefined) {
            connection.stopRequestedAt = undefined;
          }
          reject(new Error("pi-tui did not shut down in time"));
        }, PI_TUI_STOP_TIMEOUT_MS),
      };
      waiters.add(waiter);
      this.pendingStopWaiters.set(connection.bridgeId, waiters);
    });
  }

  private resolvePendingBridgeStops(connection: BridgeConnection, reason: string): void {
    const waiters = this.pendingStopWaiters.get(connection.bridgeId);
    if (!waiters) {
      connection.stopRequestedAt = undefined;
      return;
    }

    this.pendingStopWaiters.delete(connection.bridgeId);
    connection.stopRequestedAt = undefined;
    for (const waiter of waiters) {
      clearTimeout(waiter.timeout);
      if (isTerminalStoppedReason(reason)) {
        waiter.resolve();
      } else {
        waiter.reject(new Error(`pi-tui disconnected before stop completed (${reason})`));
      }
    }
  }

  private rejectPendingBridgeStops(connection: BridgeConnection, error: unknown): void {
    const waiters = this.pendingStopWaiters.get(connection.bridgeId);
    if (!waiters) {
      connection.stopRequestedAt = undefined;
      return;
    }

    this.pendingStopWaiters.delete(connection.bridgeId);
    connection.stopRequestedAt = undefined;
    const resolvedError = error instanceof Error ? error : new Error(safeErrorMessage(error));
    for (const waiter of waiters) {
      clearTimeout(waiter.timeout);
      waiter.reject(resolvedError);
    }
  }

  respondToUIRequest(sessionId: string, response: ExtensionUIResponse): boolean {
    const active = this.ensureActiveFromStorage(sessionId);
    if (!active) return false;

    const req = active.pendingUIRequests.get(response.id);
    if (!req) return false;

    const connection = this.connectedBridgeForSession(sessionId);
    if (!connection) return false;

    try {
      connection.ws.send(
        JSON.stringify({
          type: "extension_ui_response",
          id: response.id,
          value: response.value,
          confirmed: response.confirmed,
          cancelled: response.cancelled,
        }),
      );
    } catch (error) {
      log.warn("mirror_bridge.extension_ui_response_send_failed", {
        runtime: MIRROR_RUNTIME_LOG_TAG,
        sessionId,
        bridgeId: connection.bridgeId,
        requestId: response.id,
        error: safeErrorMessage(error),
      });
      return false;
    }

    this.settleExtensionUIRequest(active, response.id, !!response.cancelled);
    return true;
  }

  async forwardClientCommand(
    sessionId: string,
    message: Record<string, unknown>,
    requestId: string | undefined,
  ): Promise<void> {
    await this.runtimeCommandCoordinator.forwardClientCommand(
      sessionId,
      message,
      requestId,
      (command) => this.dispatchBridgeCommand(sessionId, command),
    );
  }

  private handleForwardedCommandSuccess(
    sessionId: string,
    context: RuntimeCommandExecutionContext,
  ): void {
    this.applyQueueFromCommandData(
      sessionId,
      context.data,
      `command_result:${context.commandType}`,
    );
    this.applyCommandResult(sessionId, context.commandType, context.request, context.data);
  }

  private registerBridge(ws: WebSocket, hello: PiBridgeHelloMessage): BridgeConnection {
    const now = Date.now();
    const protocolVersion = hello.protocolVersion ?? BRIDGE_PROTOCOL_VERSION;
    const bridgeId = hello.bridgeId?.trim() || `pi-tui-${process.pid}-${now}`;
    const workspace = this.resolveWorkspace(hello);
    const state = { ...hello.state, cwd: hello.state?.cwd ?? hello.cwd };
    const session = this.resolveOrCreateSession(workspace, state);
    const active = this.ensureActive(session);

    const existingBridgeId = this.bridgeBySession.get(session.id);
    if (existingBridgeId) {
      const existing = this.bridges.get(existingBridgeId);
      existing?.ws.close(4000, "Mirror bridge replaced by a newer terminal connection");
      if (existing) this.detachBridge(existing, "replaced");
    }

    const connection: BridgeConnection = {
      bridgeId,
      sessionId: session.id,
      ws,
      cwd: hello.cwd,
      capabilities: [...(hello.capabilities ?? [])],
      protocolVersion,
      connectedAt: now,
      lastSeenAt: now,
      pendingCommands: new Map(),
      fireAndForgetCommandIds: new Set(),
    };

    this.bridges.set(bridgeId, connection);
    this.bridgeBySession.set(session.id, bridgeId);
    this.markMirrorConnected(active, connection, state);

    ws.send(
      JSON.stringify({
        type: "hello_ack",
        protocolVersion: BRIDGE_PROTOCOL_VERSION,
        bridgeId,
        sessionId: session.id,
        workspaceId: workspace.id,
        serverHostname: hostname(),
      }),
    );

    this.broadcast(session.id, { type: "state", session: active.session });
    log.info("mirror_bridge.connected", {
      runtime: MIRROR_RUNTIME_LOG_TAG,
      bridgeId,
      sessionId: session.id,
      workspaceId: workspace.id,
      cwd: hello.cwd,
      terminalPid: hello.pid,
      terminalHostname: hello.hostname,
      protocolVersion,
      capabilityCount: connection.capabilities.length,
    });

    return connection;
  }

  private handleBridgeMessage(connection: BridgeConnection, message: PiBridgeInboundMessage): void {
    connection.lastSeenAt = Date.now();
    const active = this.requireActive(connection.sessionId);
    if (message.type === "event" && message.state) {
      this.applyBridgeState(active, message.state, connection);
    }

    switch (message.type) {
      case "state":
        this.applyBridgeState(active, message.state ?? {}, connection);
        this.broadcast(connection.sessionId, { type: "state", session: active.session });
        return;

      case "heartbeat":
        this.applyBridgeState(active, message.state ?? {}, connection);
        if (message.queue) {
          this.applyBridgeQueueState(
            active,
            requireQueueState(message.queue, "pi-tui sent invalid heartbeat queue state"),
            "heartbeat",
          );
        }
        this.broadcast(connection.sessionId, { type: "state", session: active.session });
        return;

      case "queue_state":
        this.applyBridgeQueueState(
          active,
          requireQueueState(message.queue, "pi-tui sent invalid queue state"),
          "queue_state",
        );
        return;

      case "queue_item_started":
        this.applyBridgeQueueItemStarted(active, message);
        return;

      case "event":
        this.ingestAgentEvent(active, message.event);
        return;

      case "extension_ui_request":
        this.eventProcessor.handleExtensionUIRequest(connection.sessionId, active, message);
        return;

      case "extension_ui_request_settled":
        this.settleExtensionUIRequest(active, message.id, false);
        return;

      case "command_result":
        this.resolveCommandResult(connection, message);
        return;

      case "goodbye":
        this.applyBridgeState(active, message.state ?? {}, connection);
        connection.ws.close(1000, message.reason ?? "Bridge stopped");
        this.detachBridge(connection, message.reason ?? "goodbye");
        return;

      case "hello":
        throw new Error("Duplicate bridge hello");
    }
  }

  private async dispatchBridgeQueueCommand(
    sessionId: string,
    command: Record<string, unknown>,
  ): Promise<MessageQueueState> {
    const active = this.requireActive(sessionId);
    const data = await this.dispatchBridgeCommand(sessionId, command);
    const commandType = typeof command.type === "string" ? command.type : "unknown";
    return this.applyBridgeQueueState(
      active,
      requireQueueState(data, "pi-tui did not return queue state"),
      `command_result:${commandType}`,
    );
  }

  private applyQueueFromCommandData(
    sessionId: string,
    data: unknown,
    source = "command_result",
  ): MessageQueueState | undefined {
    const queue = parseQueueState(data);
    if (!queue) return undefined;
    const active = this.requireActive(sessionId);
    return this.applyBridgeQueueState(active, queue, source);
  }

  private markQueuedMessageStarted(active: MirrorActiveSession, text: string | undefined): void {
    const started = dequeueQueueItemByText(active.messageQueue, text);
    if (!started) return;

    this.broadcast(active.session.id, queueItemStartedMessage(started));
    this.broadcast(active.session.id, queueStateMessage(active.messageQueue));
  }

  private applyBridgeQueueState(
    active: MirrorActiveSession,
    queue: MessageQueueState,
    source: string,
  ): MessageQueueState {
    const previousQueue = active.messageQueue;
    const changed = queueShapeChanged(previousQueue, queue);
    active.messageQueue = cloneQueueState(queue);
    if (changed) {
      const previous = queueCounts(previousQueue);
      const next = queueCounts(active.messageQueue);
      log.info("mirror_bridge.queue_state_applied", {
        runtime: MIRROR_RUNTIME_LOG_TAG,
        sessionId: active.session.id,
        source,
        previousVersion: previous.version,
        version: next.version,
        previousSteeringCount: previous.steeringCount,
        steeringCount: next.steeringCount,
        previousFollowUpCount: previous.followUpCount,
        followUpCount: next.followUpCount,
      });
    }
    this.broadcast(active.session.id, queueStateMessage(active.messageQueue));
    return cloneQueueState(active.messageQueue);
  }

  private applyBridgeQueueItemStarted(
    active: MirrorActiveSession,
    message: PiBridgeQueueItemStartedMessage,
  ): void {
    const previousQueue = active.messageQueue;
    if (message.queue) {
      active.messageQueue = cloneQueueState(
        requireQueueState(message.queue, "pi-tui sent invalid started-item queue state"),
      );
    } else {
      removeQueueItemStartedByRuntime(
        active.messageQueue,
        message.kind,
        message.item,
        message.queueVersion,
      );
    }
    const next = queueCounts(active.messageQueue);
    log.info("mirror_bridge.queue_item_started", {
      runtime: MIRROR_RUNTIME_LOG_TAG,
      sessionId: active.session.id,
      kind: message.kind,
      itemId: message.item.id,
      previousVersion: previousQueue.version,
      version: next.version,
      steeringCount: next.steeringCount,
      followUpCount: next.followUpCount,
      hasQueueSnapshot: Boolean(message.queue),
    });
    this.broadcast(
      active.session.id,
      queueItemStartedMessage({
        kind: message.kind,
        item: message.item,
        queueVersion: active.messageQueue.version,
      }),
    );
    this.broadcast(active.session.id, queueStateMessage(active.messageQueue));
  }

  private resolveCommandResult(
    connection: BridgeConnection,
    message: PiBridgeCommandResultMessage,
  ): void {
    const matched = this.bridgeCommandDriver.resolveResult(connection, message, () => {
      if (message.state) {
        this.applyBridgeState(this.requireActive(connection.sessionId), message.state, connection);
      }
    });
    if (matched) return;
    if (connection.fireAndForgetCommandIds.delete(message.id)) {
      if (!message.success) {
        const error = new Error(message.error || "pi-tui command failed");
        this.rejectPendingBridgeStops(connection, error);
        log.warn("mirror_bridge.fire_and_forget_command_failed", {
          runtime: MIRROR_RUNTIME_LOG_TAG,
          bridgeId: connection.bridgeId,
          sessionId: connection.sessionId,
          commandId: message.id,
          error: error.message,
        });
      }
      return;
    }

    log.warn("mirror_bridge.command_result_unmatched", {
      runtime: MIRROR_RUNTIME_LOG_TAG,
      bridgeId: connection.bridgeId,
      sessionId: connection.sessionId,
      commandId: message.id,
    });
  }

  private detachBridge(connection: BridgeConnection, reason: string): void {
    if (this.bridges.get(connection.bridgeId) !== connection) return;

    const effectiveReason =
      connection.stopRequestedAt !== undefined && (reason === "closed" || reason === "goodbye")
        ? "stopped"
        : reason;
    const pendingCommandCount = connection.pendingCommands.size;
    this.bridges.delete(connection.bridgeId);
    this.bridgeBySession.delete(connection.sessionId);
    connection.fireAndForgetCommandIds.clear();

    this.bridgeCommandDriver.rejectPending(connection, new Error("pi-tui disconnected"));
    this.resolvePendingBridgeStops(connection, effectiveReason);

    const active = this.active.get(connection.sessionId);
    if (active) {
      const disconnectedAt = Date.now();
      const terminal = {
        ...(active.session.mirror?.terminal ?? {}),
        bridgeId: connection.bridgeId,
        cwd: connection.cwd ?? active.session.mirror?.terminal?.cwd,
        disconnectedAt,
        disconnectReason: effectiveReason,
        lastSeenAt: connection.lastSeenAt,
      };

      if (effectiveReason === "reload") {
        active.session.mirror = {
          ...(active.session.mirror ?? { status: "connected" }),
          status: "connected",
          terminal,
        };
        this.storage.saveSession(active.session);
      } else {
        active.session.mirror = {
          ...(active.session.mirror ?? { status: "disconnected" }),
          status: "disconnected",
          terminal,
        };
        if (isTerminalStoppedReason(effectiveReason)) {
          active.session.status = "stopped";
          active.session.currentTurnStartedAt = undefined;
          active.session.lastActivity = disconnectedAt;
        }
        this.storage.saveSession(active.session);
        this.broadcast(connection.sessionId, { type: "state", session: active.session });
        this.broadcastSessionSummaryIfChanged(active, `mirror_${effectiveReason}`);
      }
    }

    log.info("mirror_bridge.disconnected", {
      runtime: MIRROR_RUNTIME_LOG_TAG,
      bridgeId: connection.bridgeId,
      sessionId: connection.sessionId,
      reason: effectiveReason,
      pendingCommandCount,
    });
  }

  private resolveWorkspace(hello: PiBridgeHelloMessage): Workspace {
    const cwd = hello.cwd ?? hello.state?.cwd;
    if (hello.workspaceId) {
      const workspace = this.storage.getWorkspace(hello.workspaceId);
      if (workspace) {
        if (!cwd) {
          throw new Error("Bridge hello must include cwd when workspaceId is supplied");
        }
        if (!workspace.hostMount) {
          throw new Error(`Oppi workspace ${workspace.id} has no hostMount for pi-tui`);
        }
        if (!pathContains(workspace.hostMount, cwd)) {
          throw new Error(`Terminal cwd is outside Oppi workspace hostMount: ${cwd}`);
        }
        return workspace;
      }
    }

    if (!cwd) {
      throw new Error("Bridge hello must include cwd or workspaceId");
    }

    const candidates = this.storage
      .listWorkspaces()
      .filter((workspace) => workspace.hostMount && pathContains(workspace.hostMount, cwd))
      .sort(
        (a, b) => normalizePath(b.hostMount ?? "").length - normalizePath(a.hostMount ?? "").length,
      );
    const workspace = candidates[0];
    if (!workspace) {
      throw new Error(`No Oppi workspace hostMount contains terminal cwd: ${cwd}`);
    }

    const matchLength = normalizePath(workspace.hostMount ?? "").length;
    if (
      candidates.length > 1 &&
      normalizePath(candidates[1]?.hostMount ?? "").length === matchLength
    ) {
      throw new Error(`Ambiguous Oppi workspace match for terminal cwd: ${cwd}`);
    }

    return workspace;
  }

  private resolveOrCreateSession(workspace: Workspace, state: PiBridgeStateSnapshot): Session {
    const piSessionFile = canonicalSessionFilePath(state.sessionFile);
    const piSessionId = state.piSessionId?.trim();
    const existing = this.storage.listSessions().find((session) => {
      if (piSessionId && session.piSessionId === piSessionId) return true;
      if (!piSessionFile) return false;
      if (canonicalSessionFilePath(session.piSessionFile) === piSessionFile) return true;
      return (session.piSessionFiles ?? []).some(
        (file) => canonicalSessionFilePath(file) === piSessionFile,
      );
    });

    if (
      existing &&
      existing.runtime !== "pi-tui" &&
      this.options.isOppiSessionActive?.(existing.id)
    ) {
      throw new BridgeRegistrationError(
        `Session ${existing.id} is already owned by the oppi runtime; stop it before mirroring this pi-tui session`,
        "oppi_runtime_active",
        { sessionId: existing.id, retryAfterMs: OPPI_RUNTIME_CONFLICT_RETRY_MS },
      );
    }

    const model = normalizeModelId(state.model);
    const sessionName = meaningfulSessionName(state.sessionName);
    const session = existing ?? this.storage.createSession(sessionName, model);
    session.workspaceId = workspace.id;
    session.workspaceName = workspace.name;
    session.runtime = "pi-tui";
    session.status = state.isIdle === false ? "busy" : "ready";
    const nextName = meaningfulSessionName(state.sessionName, session.id);
    if (nextName) session.name = nextName;
    else if (meaningfulSessionName(session.name, session.id) === undefined) delete session.name;
    if (model) session.model = model;
    if (state.thinkingLevel?.trim()) session.thinkingLevel = state.thinkingLevel.trim();
    if (piSessionId) session.piSessionId = piSessionId;
    mergePiSessionFile(session, piSessionFile);
    if (!session.firstMessage) {
      session.firstMessage = firstUserMessageFromSessionFile(
        piSessionFile ?? session.piSessionFile ?? session.piSessionFiles?.[0],
      );
    }
    this.applyContextUsage(session, state.contextUsage);
    session.lastActivity = Date.now();
    this.storage.saveSession(session);
    return session;
  }

  private ensureActiveFromStorage(sessionId: string): MirrorActiveSession | undefined {
    const existing = this.active.get(sessionId);
    if (existing) return existing;
    const session = this.storage.getSession(sessionId);
    if (!session || !this.isMirrorSession(session)) return undefined;
    return this.ensureActive(session);
  }

  private ensureActive(session: Session): MirrorActiveSession {
    const existing = this.active.get(session.id);
    if (existing) {
      existing.session = session;
      return existing;
    }

    const active: MirrorActiveSession = {
      session,
      subscribers: new Set(),
      seq: 0,
      eventRing: new EventRing(EVENT_RING_CAPACITY),
      pendingUIRequests: new Map(),
      partialResults: new Map(),
      streamedAssistantText: "",
      hasStreamedThinking: false,
      streamedThinkingContentIndexes: new Set(),
      toolNames: new Map(),
      shellPreviewLastSent: new Map(),
      streamingArgPreviews: new Set(),
      streamingToolUpdatesSeen: new Map(),
      toolFullOutputPaths: new Map(),
      turnCache: new TurnDedupeCache(),
      pendingTurnStarts: [],
      messageQueue: emptyQueue(),
      sdkBackend: {} as never,
    };
    this.active.set(session.id, active);
    return active;
  }

  private requireActive(sessionId: string): MirrorActiveSession {
    const active = this.ensureActiveFromStorage(sessionId);
    if (!active) {
      throw new Error(`pi-tui session not active: ${sessionId}`);
    }
    return active;
  }

  private markMirrorConnected(
    active: MirrorActiveSession,
    connection: BridgeConnection,
    state: PiBridgeStateSnapshot,
  ): void {
    active.session.runtime = "pi-tui";
    active.session.mirror = {
      status: "connected",
      capabilities: connection.capabilities,
      protocolVersion: connection.protocolVersion,
      terminal: {
        bridgeId: connection.bridgeId,
        cwd: connection.cwd ?? state.cwd,
        connectedAt: connection.connectedAt,
        lastSeenAt: connection.lastSeenAt,
      },
    };
    this.applyBridgeState(active, state, connection);
  }

  private applyBridgeState(
    active: MirrorActiveSession,
    state: PiBridgeStateSnapshot,
    connection?: BridgeConnection,
  ): void {
    const session = active.session;
    const now = Date.now();
    session.runtime = "pi-tui";
    const nextName = meaningfulSessionName(state.sessionName, session.id);
    if (nextName) session.name = nextName;
    else if (meaningfulSessionName(session.name, session.id) === undefined) delete session.name;
    const model = normalizeModelId(state.model);
    if (model) session.model = model;
    if (state.thinkingLevel?.trim()) session.thinkingLevel = state.thinkingLevel.trim();
    if (state.piSessionId?.trim()) session.piSessionId = state.piSessionId.trim();
    mergePiSessionFile(session, state.sessionFile);
    if (!session.firstMessage) {
      session.firstMessage = firstUserMessageFromSessionFile(
        session.piSessionFile ?? state.sessionFile ?? session.piSessionFiles?.[0],
      );
    }
    this.applyContextUsage(session, state.contextUsage);
    if (
      state.isIdle !== undefined &&
      session.status !== "stopping" &&
      session.status !== "stopped"
    ) {
      session.status = state.isIdle ? "ready" : "busy";
      session.currentTurnStartedAt = state.isIdle ? undefined : session.currentTurnStartedAt;
    }
    session.lastActivity = now;

    if (connection) {
      connection.lastSeenAt = now;
      session.mirror = {
        ...(session.mirror ?? { status: "connected" }),
        status: "connected",
        capabilities: connection.capabilities,
        protocolVersion: connection.protocolVersion,
        terminal: {
          ...(session.mirror?.terminal ?? {}),
          bridgeId: connection.bridgeId,
          cwd: state.cwd ?? connection.cwd ?? session.mirror?.terminal?.cwd,
          connectedAt: connection.connectedAt,
          lastSeenAt: now,
        },
      };
    }

    this.storage.saveSession(session);
  }

  private applyContextUsage(session: Session, usage: PiBridgeStateSnapshot["contextUsage"]): void {
    if (!usage) return;
    if (typeof usage.tokens === "number" && Number.isFinite(usage.tokens)) {
      session.contextTokens = Math.max(0, Math.floor(usage.tokens));
    }
    if (typeof usage.contextWindow === "number" && Number.isFinite(usage.contextWindow)) {
      session.contextWindow = Math.max(0, Math.floor(usage.contextWindow));
    }
  }

  private ingestAgentEvent(active: MirrorActiveSession, rawEvent: AgentSessionEvent): void {
    this.agentEventCoordinator.handlePiEvent(active.session.id, rawEvent as SessionBackendEvent);
  }

  private broadcast(sessionId: string, message: ServerMessage): number {
    return this.broadcaster.broadcast(sessionId, message);
  }

  private broadcastSessionSummaryIfChanged(active: MirrorActiveSession, reason: string): void {
    const summary = buildSessionSummary(active.session);
    const fingerprint = sessionSummaryFingerprint(summary);
    if (active.lastSummaryFingerprint === fingerprint) return;
    active.lastSummaryFingerprint = fingerprint;
    log.info("mirror_runtime.summary_update", {
      runtime: MIRROR_RUNTIME_LOG_TAG,
      sessionId: active.session.id,
      status: summary.status,
      reason,
    });
    this.broadcast(active.session.id, { type: "session_summary", summary });
  }

  private logBridgeCommandEvent(event: MirrorBridgeCommandDriverEvent): void {
    const base = {
      runtime: MIRROR_RUNTIME_LOG_TAG,
      bridgeId: event.bridgeId,
      sessionId: event.sessionId,
      commandId: event.commandId,
      command: event.commandType,
      requestId: event.requestId,
      clientTurnId: event.clientTurnId,
    };

    switch (event.phase) {
      case "sent":
        log.info("mirror_bridge.command_sent", {
          ...base,
          sendDurationMs: event.sendDurationMs,
        });
        return;

      case "result": {
        const payload = {
          ...base,
          outcome: event.success ? "success" : "error",
          durationMs: event.durationMs,
          ...(event.error ? { error: event.error } : {}),
        };
        if (event.success) log.info("mirror_bridge.command_result", payload);
        else log.warn("mirror_bridge.command_result", payload);
        return;
      }

      case "timeout":
      case "send_failed":
      case "rejected":
        log.warn("mirror_bridge.command_result", {
          ...base,
          outcome: event.phase,
          durationMs: event.durationMs,
          error: event.error,
        });
        return;
    }
  }

  private dispatchBridgeCommand(
    sessionId: string,
    command: Record<string, unknown>,
  ): Promise<unknown> {
    const bridgeId = this.bridgeBySession.get(sessionId);
    const connection = bridgeId ? this.bridges.get(bridgeId) : undefined;
    return this.bridgeCommandDriver.dispatch(connection, command);
  }

  private applyCommandResult(
    sessionId: string,
    commandType: string,
    request: Record<string, unknown>,
    data: unknown,
  ): void {
    const active = this.active.get(sessionId);
    if (!active) return;
    const session = active.session;

    if (commandType === "get_state") {
      this.applyBridgeState(active, data as PiBridgeStateSnapshot);
      this.broadcast(sessionId, { type: "state", session });
      return;
    }

    const resultApplication = applyForwardedCommandResultToSession({
      session,
      commandType,
      request,
      data,
    });
    if (resultApplication.changed) {
      this.storage.saveSession(session);
    }
    if (resultApplication.shouldBroadcastState) {
      this.broadcast(sessionId, { type: "state", session });
    }
  }
}

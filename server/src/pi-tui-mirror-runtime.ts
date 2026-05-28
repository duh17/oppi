import { EventEmitter } from "node:events";
import { existsSync, realpathSync } from "node:fs";
import { hostname } from "node:os";
import { resolve } from "node:path";

import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";
import { WebSocket, type RawData } from "ws";

import { EventRing } from "./event-ring.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import {
  normalizeCommandError,
  translatePiEvent,
  applyMessageEndToSession,
  updateSessionChangeStats,
} from "./session-protocol.js";
import { buildSessionSummary, sessionSummaryFingerprint } from "./session-summary.js";
import { composeModelId } from "./session-state.js";
import { SessionBroadcaster, type SessionCatchUpResponse } from "./session-broadcast.js";
import { cloneQueueItem, cloneQueueState, extractQueuedUserText } from "./session-queue-utils.js";
import { SessionTurnCoordinator, type TurnSessionState } from "./session-turns.js";
import type { Storage } from "./storage.js";
import { TurnDedupeCache } from "./turn-cache.js";
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
const COMMAND_TIMEOUT_MS = 30_000;
const EVENT_RING_CAPACITY = 500;

const SUPPORTED_REMOTE_COMMANDS = new Set([
  "get_state",
  "get_messages",
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
  "abort",
  "get_queue",
  "set_queue",
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

type PiBridgeInboundMessage =
  | PiBridgeHelloMessage
  | PiBridgeStateMessage
  | PiBridgeAgentEventMessage
  | PiBridgeCommandResultMessage
  | PiBridgeHeartbeatMessage
  | PiBridgeQueueStateMessage
  | PiBridgeQueueItemStartedMessage
  | PiBridgeGoodbyeMessage;

interface PiBridgeOutboundCommand {
  type: "command";
  id: string;
  command: Record<string, unknown>;
}

interface MirrorActiveSession extends TurnSessionState {
  session: Session;
  subscribers: Set<(msg: ServerMessage) => void>;
  seq: number;
  eventRing: EventRing;
  partialResults: Map<string, string>;
  streamedAssistantText: string;
  hasStreamedThinking: boolean;
  toolNames: Map<string, string>;
  shellPreviewLastSent: Map<string, number>;
  streamingArgPreviews: Set<string>;
  streamingToolUpdatesSeen: Map<string, string>;
  messageQueue: MessageQueueState;
  lastSummaryFingerprint?: string;
}

interface BridgeConnection {
  bridgeId: string;
  sessionId: string;
  ws: WebSocket;
  cwd?: string;
  capabilities: string[];
  protocolVersion: number;
  connectedAt: number;
  lastSeenAt: number;
  pendingCommands: Map<
    string,
    {
      commandType: string;
      resolve: (data: unknown) => void;
      reject: (err: Error) => void;
      timeout: ReturnType<typeof setTimeout>;
    }
  >;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function rawDataToText(data: RawData): string {
  if (typeof data === "string") return data;
  if (Buffer.isBuffer(data)) return data.toString("utf8");
  if (Array.isArray(data)) return Buffer.concat(data).toString("utf8");
  return Buffer.from(data).toString("utf8");
}

function parseBridgeMessage(data: RawData): PiBridgeInboundMessage {
  const parsed = JSON.parse(rawDataToText(data)) as unknown;
  const record = asRecord(parsed);
  if (!record || typeof record.type !== "string") {
    throw new Error("Bridge message must be an object with a string type");
  }
  return record as unknown as PiBridgeInboundMessage;
}

function normalizePath(path: string): string {
  return resolve(path.trim());
}

function canonicalSessionFilePath(path: string | undefined): string | undefined {
  const trimmed = path?.trim();
  if (!trimmed) return undefined;
  const resolved = resolve(trimmed);
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

function formatCommandId(): string {
  return `mirror_cmd_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`;
}

function emptyQueue(): MessageQueueState {
  return { version: 0, steering: [], followUp: [] };
}

function parseQueueState(value: unknown): MessageQueueState | undefined {
  const record = asRecord(value);
  const queue = asRecord(record?.queue) ?? record;
  if (!queue) return undefined;
  const version = typeof queue.version === "number" ? queue.version : undefined;
  const steering = Array.isArray(queue.steering) ? queue.steering : undefined;
  const followUp = Array.isArray(queue.followUp) ? queue.followUp : undefined;
  if (version === undefined || !steering || !followUp) return undefined;
  return queue as unknown as MessageQueueState;
}

export interface PiTuiMirrorRuntimeOptions {
  isManagedSessionActive?: (sessionId: string) => boolean;
}

export class PiTuiMirrorRuntime extends EventEmitter {
  private readonly active = new Map<string, MirrorActiveSession>();
  private readonly bridges = new Map<string, BridgeConnection>();
  private readonly bridgeBySession = new Map<string, string>();
  private readonly broadcaster: SessionBroadcaster;
  private readonly turnCoordinator: SessionTurnCoordinator;

  constructor(
    private readonly storage: Storage,
    private readonly options: PiTuiMirrorRuntimeOptions = {},
  ) {
    super();
    this.broadcaster = new SessionBroadcaster({
      getActiveSession: (sessionId) => this.active.get(sessionId),
      emitSessionEvent: (payload) => this.emit("session_event", payload),
      saveSession: (session) => this.storage.saveSession(session),
    });
    this.turnCoordinator = new SessionTurnCoordinator({
      broadcast: (sessionId, message) => this.broadcast(sessionId, message),
    });
  }

  isMirrorSession(session: Session | undefined | null): boolean {
    return session?.runtime === "pi-tui-mirror";
  }

  handleBridgeWebSocket(ws: WebSocket): void {
    let connection: BridgeConnection | undefined;

    ws.on("message", (data, isBinary) => {
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
        log.warn("mirror_bridge.message_rejected", { error: message });
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: "error", error: message }));
        }
      }
    });

    ws.on("close", () => {
      if (connection) {
        this.detachBridge(connection, "closed");
      }
    });

    ws.on("error", (error) => {
      log.warn("mirror_bridge.ws_error", { error: safeErrorMessage(error) });
    });
  }

  getActiveSession(sessionId: string): Session | undefined {
    return this.active.get(sessionId)?.session ?? this.storage.getSession(sessionId);
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

  getPendingAskMessage(_sessionId: string): ServerMessage | undefined {
    return undefined;
  }

  getPendingUIRequestMessages(_sessionId: string): ServerMessage[] {
    return [];
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
    if (opts.attachments?.length) {
      throw new Error("Terminal mirror does not support file attachments yet");
    }
    if (active.session.status === "busy" && !opts.streamingBehavior) {
      const duplicate = this.turnCoordinator.isDuplicateTurnIntent(
        active,
        "prompt",
        opts.clientTurnId,
        {
          message,
          images: opts.images ?? [],
          attachments: opts.attachments ?? [],
          streamingBehavior: opts.streamingBehavior,
        },
      );
      if (!duplicate) {
        throw new Error(
          "Prompt requires an idle terminal session; use steer or follow_up while a turn is streaming",
        );
      }
    }

    const turn = this.turnCoordinator.beginTurnIntent(
      active.session.id,
      active,
      "prompt",
      {
        message,
        images: opts.images ?? [],
        attachments: opts.attachments ?? [],
        streamingBehavior: opts.streamingBehavior,
      },
      opts.clientTurnId,
      opts.requestId,
    );
    if (turn.duplicate) return;

    const data = await this.dispatchBridgeCommand(sessionId, {
      type: "prompt",
      message,
      images: opts.images,
      streamingBehavior: opts.streamingBehavior,
    });
    this.applyQueueFromCommandData(sessionId, data);

    this.turnCoordinator.markTurnDispatched(
      active.session.id,
      active,
      "prompt",
      turn,
      opts.requestId,
    );
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
    await this.sendStreamingInput(sessionId, "steer", message, opts);
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
    await this.sendStreamingInput(sessionId, "follow_up", message, opts);
  }

  async getMessageQueue(sessionId: string): Promise<MessageQueueState> {
    const active = this.requireActive(sessionId);
    try {
      const data = await this.dispatchBridgeCommand(sessionId, { type: "get_queue" });
      const queue = parseQueueState(data);
      if (queue) {
        active.messageQueue = cloneQueueState(queue);
        this.broadcast(sessionId, { type: "queue_state", queue: active.messageQueue });
      }
    } catch (error) {
      log.warn("mirror_runtime.get_queue.failed", {
        sessionId,
        error: safeErrorMessage(error),
      });
    }
    return cloneQueueState(active.messageQueue);
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
    if (payload.baseVersion !== active.messageQueue.version) {
      throw new Error(
        `Queue version mismatch: expected ${active.messageQueue.version}, got ${payload.baseVersion}`,
      );
    }

    const data = await this.dispatchBridgeCommand(sessionId, {
      type: "set_queue",
      baseVersion: payload.baseVersion,
      steering: payload.steering,
      followUp: payload.followUp,
    });
    const queue = parseQueueState(data);
    if (!queue) {
      throw new Error("Terminal mirror did not return queue state");
    }
    active.messageQueue = cloneQueueState(queue);
    this.broadcast(sessionId, { type: "queue_state", queue: active.messageQueue });
    return cloneQueueState(active.messageQueue);
  }

  async sendAbort(sessionId: string): Promise<void> {
    await this.dispatchBridgeCommand(sessionId, { type: "abort" });
  }

  async stopSession(_sessionId: string): Promise<void> {
    throw new Error(
      "Terminal-owned sessions can only be stopped from the terminal; use abort to stop the current turn",
    );
  }

  respondToUIRequest(_sessionId: string): boolean {
    return false;
  }

  async forwardClientCommand(
    sessionId: string,
    message: Record<string, unknown>,
    requestId: string | undefined,
  ): Promise<void> {
    const commandType = typeof message.type === "string" ? message.type : "unknown";
    if (!SUPPORTED_REMOTE_COMMANDS.has(commandType)) {
      throw new Error(`Terminal mirror does not support command: ${commandType}`);
    }

    try {
      const data = await this.dispatchBridgeCommand(sessionId, message);
      this.applyQueueFromCommandData(sessionId, data);
      this.applyCommandResult(sessionId, commandType, message, data);
      this.broadcast(sessionId, {
        type: "command_result",
        command: commandType,
        requestId,
        success: true,
        data,
      });
    } catch (error) {
      const raw = safeErrorMessage(error);
      this.broadcast(sessionId, {
        type: "command_result",
        command: commandType,
        requestId,
        success: false,
        error: normalizeCommandError(commandType, raw),
      });
    }
  }

  private async sendStreamingInput(
    sessionId: string,
    kind: "steer" | "follow_up",
    message: string,
    opts: {
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      attachments?: ChatAttachmentRef[];
      clientTurnId?: string;
      requestId?: string;
    },
  ): Promise<void> {
    const active = this.requireActive(sessionId);
    if (opts.attachments?.length) {
      throw new Error("Terminal mirror does not support file attachments yet");
    }
    if (active.session.status !== "busy") {
      const label = kind === "steer" ? "Steer" : "Follow-up";
      throw new Error(`${label} requires an active streaming terminal turn`);
    }

    const turn = this.turnCoordinator.beginTurnIntent(
      active.session.id,
      active,
      kind,
      { message, images: opts.images ?? [], attachments: opts.attachments ?? [] },
      opts.clientTurnId,
      opts.requestId,
    );
    if (turn.duplicate) return;

    const data = await this.dispatchBridgeCommand(sessionId, {
      type: kind,
      message,
      images: opts.images,
    });
    this.applyQueueFromCommandData(sessionId, data);
    this.turnCoordinator.markTurnDispatched(active.session.id, active, kind, turn, opts.requestId);
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
      bridgeId,
      sessionId: session.id,
      workspaceId: workspace.id,
      cwd: hello.cwd,
      protocolVersion,
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
          this.applyBridgeQueueState(active, message.queue);
        }
        this.broadcast(connection.sessionId, { type: "state", session: active.session });
        return;

      case "queue_state":
        this.applyBridgeQueueState(active, message.queue);
        return;

      case "queue_item_started":
        this.applyBridgeQueueItemStarted(active, message);
        return;

      case "event":
        this.ingestAgentEvent(active, message.event);
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

  private applyQueueFromCommandData(
    sessionId: string,
    data: unknown,
  ): MessageQueueState | undefined {
    const queue = parseQueueState(data);
    if (!queue) return undefined;
    const active = this.requireActive(sessionId);
    this.applyBridgeQueueState(active, queue);
    return cloneQueueState(active.messageQueue);
  }

  private markQueuedMessageStarted(active: MirrorActiveSession, text: string | undefined): void {
    const normalized = text?.trim();
    if (!normalized) return;

    const dequeue = (kind: MessageQueueKind, list: MessageQueueItem[]): MessageQueueItem | null => {
      const index = list.findIndex((item) => item.message.trim() === normalized);
      if (index === -1) return null;
      const [item] = list.splice(index, 1);
      if (!item) return null;
      active.messageQueue.version += 1;
      this.broadcast(active.session.id, {
        type: "queue_item_started",
        kind,
        item: cloneQueueItem(item),
        queueVersion: active.messageQueue.version,
      });
      this.broadcast(active.session.id, { type: "queue_state", queue: active.messageQueue });
      return item;
    };

    if (dequeue("steer", active.messageQueue.steering)) return;
    dequeue("follow_up", active.messageQueue.followUp);
  }

  private applyBridgeQueueState(active: MirrorActiveSession, queue: MessageQueueState): void {
    active.messageQueue = cloneQueueState(queue);
    this.broadcast(active.session.id, { type: "queue_state", queue: active.messageQueue });
  }

  private applyBridgeQueueItemStarted(
    active: MirrorActiveSession,
    message: PiBridgeQueueItemStartedMessage,
  ): void {
    if (message.queue) {
      active.messageQueue = cloneQueueState(message.queue);
    } else {
      active.messageQueue.version = message.queueVersion;
      const target =
        message.kind === "steer" ? active.messageQueue.steering : active.messageQueue.followUp;
      const index = target.findIndex(
        (item) => item.id === message.item.id || item.message === message.item.message,
      );
      if (index !== -1) target.splice(index, 1);
    }
    this.broadcast(active.session.id, {
      type: "queue_item_started",
      kind: message.kind,
      item: cloneQueueItem(message.item),
      queueVersion: active.messageQueue.version,
    });
    this.broadcast(active.session.id, { type: "queue_state", queue: active.messageQueue });
  }

  private resolveCommandResult(
    connection: BridgeConnection,
    message: PiBridgeCommandResultMessage,
  ): void {
    const pending = connection.pendingCommands.get(message.id);
    if (!pending) {
      log.warn("mirror_bridge.command_result_unmatched", {
        bridgeId: connection.bridgeId,
        sessionId: connection.sessionId,
        commandId: message.id,
      });
      return;
    }

    connection.pendingCommands.delete(message.id);
    clearTimeout(pending.timeout);

    const active = this.requireActive(connection.sessionId);
    if (message.state) {
      this.applyBridgeState(active, message.state, connection);
    }

    if (message.success) {
      pending.resolve(message.data);
      return;
    }

    pending.reject(new Error(message.error || `${pending.commandType} failed`));
  }

  private detachBridge(connection: BridgeConnection, reason: string): void {
    if (this.bridges.get(connection.bridgeId) !== connection) return;

    this.bridges.delete(connection.bridgeId);
    this.bridgeBySession.delete(connection.sessionId);

    for (const pending of connection.pendingCommands.values()) {
      clearTimeout(pending.timeout);
      pending.reject(new Error("Terminal mirror disconnected"));
    }
    connection.pendingCommands.clear();

    const active = this.active.get(connection.sessionId);
    if (active) {
      active.session.mirror = {
        ...(active.session.mirror ?? { status: "disconnected" }),
        status: "disconnected",
        terminal: {
          ...(active.session.mirror?.terminal ?? {}),
          bridgeId: connection.bridgeId,
          cwd: connection.cwd ?? active.session.mirror?.terminal?.cwd,
          disconnectedAt: Date.now(),
          lastSeenAt: connection.lastSeenAt,
        },
      };
      this.storage.saveSession(active.session);
      this.broadcast(connection.sessionId, { type: "state", session: active.session });
    }

    log.info("mirror_bridge.disconnected", {
      bridgeId: connection.bridgeId,
      sessionId: connection.sessionId,
      reason,
    });
  }

  private resolveWorkspace(hello: PiBridgeHelloMessage): Workspace {
    if (hello.workspaceId) {
      const workspace = this.storage.getWorkspace(hello.workspaceId);
      if (workspace) return workspace;
    }

    const cwd = hello.cwd ?? hello.state?.cwd;
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
      existing.runtime !== "pi-tui-mirror" &&
      this.options.isManagedSessionActive?.(existing.id)
    ) {
      throw new Error(
        `Session ${existing.id} is already owned by the managed Oppi runtime; stop it before mirroring this terminal session`,
      );
    }

    const model = normalizeModelId(state.model);
    const session = existing ?? this.storage.createSession(state.sessionName, model);
    session.workspaceId = workspace.id;
    session.workspaceName = workspace.name;
    session.runtime = "pi-tui-mirror";
    session.status = state.isIdle === false ? "busy" : "ready";
    if (state.sessionName?.trim()) session.name = state.sessionName.trim();
    if (model) session.model = model;
    if (state.thinkingLevel?.trim()) session.thinkingLevel = state.thinkingLevel.trim();
    if (piSessionId) session.piSessionId = piSessionId;
    mergePiSessionFile(session, piSessionFile);
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
      partialResults: new Map(),
      streamedAssistantText: "",
      hasStreamedThinking: false,
      toolNames: new Map(),
      shellPreviewLastSent: new Map(),
      streamingArgPreviews: new Set(),
      streamingToolUpdatesSeen: new Map(),
      turnCache: new TurnDedupeCache(),
      pendingTurnStarts: [],
      messageQueue: emptyQueue(),
    };
    this.active.set(session.id, active);
    return active;
  }

  private requireActive(sessionId: string): MirrorActiveSession {
    const active = this.ensureActiveFromStorage(sessionId);
    if (!active) {
      throw new Error(`Terminal mirror session not active: ${sessionId}`);
    }
    return active;
  }

  private markMirrorConnected(
    active: MirrorActiveSession,
    connection: BridgeConnection,
    state: PiBridgeStateSnapshot,
  ): void {
    active.session.runtime = "pi-tui-mirror";
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
    session.runtime = "pi-tui-mirror";
    if (state.sessionName?.trim()) session.name = state.sessionName.trim();
    const model = normalizeModelId(state.model);
    if (model) session.model = model;
    if (state.thinkingLevel?.trim()) session.thinkingLevel = state.thinkingLevel.trim();
    if (state.piSessionId?.trim()) session.piSessionId = state.piSessionId.trim();
    mergePiSessionFile(session, state.sessionFile);
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

  private ingestAgentEvent(active: MirrorActiveSession, event: AgentSessionEvent): void {
    const sessionId = active.session.id;
    const ctx = {
      sessionId,
      partialResults: active.partialResults,
      streamedAssistantText: active.streamedAssistantText,
      hasStreamedThinking: active.hasStreamedThinking,
      toolNames: active.toolNames,
      shellPreviewLastSent: active.shellPreviewLastSent,
      streamingArgPreviews: active.streamingArgPreviews,
      streamingToolUpdatesSeen: active.streamingToolUpdatesSeen,
    };

    const messages = translatePiEvent(event, ctx);
    active.streamedAssistantText = ctx.streamedAssistantText;
    active.hasStreamedThinking = ctx.hasStreamedThinking;

    for (const message of messages) {
      this.broadcast(sessionId, message);
    }

    if (event.type === "message_start" && event.message.role === "user") {
      this.markQueuedMessageStarted(active, extractQueuedUserText(event.message));
    }

    this.updateSessionFromEvent(active, event);

    if (event.type === "agent_start" || event.type === "agent_end") {
      this.broadcastSessionSummaryIfChanged(active, event.type);
      this.broadcast(sessionId, { type: "state", session: active.session });
    }
  }

  private updateSessionFromEvent(active: MirrorActiveSession, event: AgentSessionEvent): void {
    const session = active.session;
    switch (event.type) {
      case "agent_start":
        session.status = "busy";
        session.currentTurnStartedAt = Date.now();
        break;
      case "agent_end":
        session.status = "ready";
        session.currentTurnStartedAt = undefined;
        break;
      case "message_end":
        applyMessageEndToSession(session, event.message);
        break;
      case "tool_execution_start":
        updateSessionChangeStats(session, event.toolName, event.args);
        break;
    }
    session.lastActivity = Date.now();
    this.storage.saveSession(session);
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
      sessionId: active.session.id,
      status: summary.status,
      reason,
    });
    this.broadcast(active.session.id, { type: "session_summary", summary });
  }

  private dispatchBridgeCommand(
    sessionId: string,
    command: Record<string, unknown>,
  ): Promise<unknown> {
    const bridgeId = this.bridgeBySession.get(sessionId);
    const connection = bridgeId ? this.bridges.get(bridgeId) : undefined;
    if (!connection || connection.ws.readyState !== WebSocket.OPEN) {
      throw new Error("Terminal mirror is not connected");
    }

    const id = formatCommandId();
    const commandType = typeof command.type === "string" ? command.type : "unknown";
    const outbound: PiBridgeOutboundCommand = { type: "command", id, command };

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        connection.pendingCommands.delete(id);
        reject(new Error(`Terminal mirror command timed out: ${commandType}`));
      }, COMMAND_TIMEOUT_MS);

      connection.pendingCommands.set(id, { commandType, resolve, reject, timeout });
      connection.ws.send(JSON.stringify(outbound), (error) => {
        if (!error) return;
        clearTimeout(timeout);
        connection.pendingCommands.delete(id);
        reject(error);
      });
    });
  }

  private applyCommandResult(
    sessionId: string,
    commandType: string,
    request: Record<string, unknown>,
    data: unknown,
  ): void {
    const active = this.active.get(sessionId);
    if (!active) return;
    const response = asRecord(data) ?? {};
    const session = active.session;

    if (commandType === "get_state") {
      this.applyBridgeState(active, data as PiBridgeStateSnapshot);
      this.broadcast(sessionId, { type: "state", session });
      return;
    }

    if (commandType === "set_session_name") {
      const requestedName = typeof request.name === "string" ? request.name.trim() : "";
      const responseName = typeof response.name === "string" ? response.name.trim() : "";
      const nextName = responseName || requestedName;
      if (nextName) session.name = nextName;
    }

    if (commandType === "set_thinking_level" || commandType === "cycle_thinking_level") {
      const requested = typeof request.level === "string" ? request.level.trim() : "";
      const responseLevel = typeof response.level === "string" ? response.level.trim() : "";
      const nextLevel = responseLevel || requested;
      if (nextLevel) session.thinkingLevel = nextLevel;
    }

    if (commandType === "set_model" || commandType === "cycle_model") {
      const modelData = commandType === "cycle_model" ? asRecord(response.model) : response;
      if (modelData) {
        const provider = typeof modelData.provider === "string" ? modelData.provider : undefined;
        const modelId =
          typeof modelData.id === "string"
            ? modelData.id
            : typeof modelData.modelId === "string"
              ? modelData.modelId
              : undefined;
        if (provider && modelId) session.model = composeModelId(provider, modelId);
      }
      if (typeof response.thinkingLevel === "string" && response.thinkingLevel.trim()) {
        session.thinkingLevel = response.thinkingLevel.trim();
      }
    }

    this.storage.saveSession(session);
    if (
      commandType === "set_model" ||
      commandType === "cycle_model" ||
      commandType === "set_thinking_level" ||
      commandType === "cycle_thinking_level" ||
      commandType === "set_session_name"
    ) {
      this.broadcast(sessionId, { type: "state", session });
    }
  }
}

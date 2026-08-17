import { EventEmitter } from "node:events";
import { existsSync, realpathSync, statSync } from "node:fs";
import { homedir, hostname } from "node:os";
import { basename, dirname, join, resolve } from "node:path";

import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";
import { WebSocket, type RawData } from "ws";

import { trustedSessionAttachmentSourceRoots } from "./chat-attachments.js";
import { navigationCreatedBranchSummary, resetCacheMissTracker } from "./cache-miss.js";
import {
  RuntimeDisconnectedError,
  applyForwardedCommandResultToSession,
  type AgentRuntimeTransport,
  type RuntimeClientCommand,
} from "./agent-runtime-transport.js";
import {
  buildPendingExtensionUIRequestMessages,
  cancelPendingAskRequest,
  drainExtensionUITeardownMessages,
  handleExtensionUIRequest as handleExtensionUIRequestState,
  respondToExtensionUIRequest as respondToExtensionUIRequestState,
  settleExtensionUIRequest as settleExtensionUIRequestState,
  type ExtensionUIRequest,
  type ExtensionUIResponse,
} from "./extension-ui-state.js";
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
import { resolveSdkSessionCwd } from "./sdk-backend.js";
import {
  isPiTuiMirrorRemoteCommand,
  PI_TUI_MIRROR_BRIDGE_PROTOCOL_VERSION,
  PI_TUI_MIRROR_INPUT_PREFLIGHT_CAPABILITY,
  PI_TUI_MIRROR_QUEUE_VERSION_EXHAUSTED_CODE,
  PI_TUI_MIRROR_QUEUE_VERSION_MISMATCH_CODE,
  PI_TUI_MIRROR_SUPPORTED_BRIDGE_PROTOCOL_VERSIONS,
  piTuiMirrorUnsupportedRemoteCommandReason,
} from "./pi-tui-mirror-contract.js";
import { SessionAgentEventCoordinator } from "./session-agent-events.js";
import { normalizeCommandError } from "./session-protocol.js";
import { isPiTuiTaskRecordBridgeState } from "./pi-tui-session-classification.js";
import { buildSessionSummary, sessionSummaryFingerprint } from "./session-summary.js";
import { composeModelId } from "./session-state.js";
import { SessionBroadcaster, type SessionCatchUpResponse } from "./session-broadcast.js";
import { SessionEventProcessor } from "./session-events.js";
import { SessionInputCoordinator } from "./session-input.js";
import { readSessionJsonlMeta } from "./session-jsonl-meta.js";
import {
  assertQueueBaseVersion,
  cloneQueueState,
  dequeueQueueItemByText,
  extractQueuedUserText,
  parseQueueState,
  queueItemStartedMessage,
  queueStateMessage,
  requireQueueState,
} from "./session-queue-utils.js";
import { SessionTurnCoordinator } from "./session-turns.js";
import { readSessionTreeFilterMode, serializeRawSessionTreePayload } from "./session-tree.js";
import type { SearchIndex } from "./search-index.js";
import { updateSearchIndexForSessionEvent } from "./session-search-indexing.js";
import {
  createEmptyRuntimeMessageQueue,
  createRuntimeSessionStateScaffold,
  type RuntimeSessionStateScaffold,
} from "./session-runtime-state.js";
import type { Storage } from "./storage.js";
import { resolveWorkspaceWorktreeForPath } from "./worktrees.js";
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

const EVENT_RING_CAPACITY = 500;
const OPPI_RUNTIME_CONFLICT_RETRY_MS = 10_000;
const OPPI_RUNTIME_TAKEOVER_STOP_TIMEOUT_MS = 15_000;
const OPPI_RUNTIME_TAKEOVER_STOP_POLL_MS = 50;
const PI_TUI_STOP_TIMEOUT_MS = 15_000;
const MIRROR_RUNTIME_LOG_TAG = "pi-tui";
const TASK_RECORD_REJECTION_LOG_INTERVAL_MS = 60_000;

class BridgeRegistrationError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly details: Record<string, unknown> = {},
  ) {
    super(message);
  }
}

export interface PiBridgeStateSnapshot {
  sessionFile?: string;
  piSessionId?: string;
  sessionName?: string;
  leafId?: string | null;
  model?: string | { provider?: unknown; id?: unknown; modelId?: unknown } | null;
  thinkingLevel?: string;
  isIdle?: boolean;
  contextUsage?: { tokens?: unknown; contextWindow?: unknown } | null;
  showCacheMissNotices?: boolean;
  cacheReadCostPerMillion?: number;
  cwd?: string;
}

interface PiBridgeHelloMessage {
  type: "hello";
  protocolVersion: number;
  bridgeId?: string;
  pid?: number;
  hostname?: string;
  cwd?: string;
  workspaceId?: string;
  createWorkspace?: boolean;
  takeoverConfirmation?: { sessionId?: string };
  capabilities: string[];
  state?: PiBridgeStateSnapshot;
}

interface PiBridgeStateMessage {
  type: "state";
  state: PiBridgeStateSnapshot;
}

interface PiBridgeAgentEventMessage {
  type: "event";
  event:
    | AgentSessionEvent
    | {
        type: "session_tree";
        summaryEntry?: unknown;
      };
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
  queue: MessageQueueState;
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

interface MirrorActiveSession extends RuntimeSessionStateScaffold<MessageQueueState> {
  messageQueue: MessageQueueState;
  leafId?: string;
  lastSummaryFingerprint?: string;
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

function rawDataToText(data: RawData): string {
  if (typeof data === "string") return data;
  if (Buffer.isBuffer(data)) return data.toString("utf8");
  if (Array.isArray(data)) return Buffer.concat(data).toString("utf8");
  return Buffer.from(data).toString("utf8");
}

function isMirrorReloadPrompt(
  message: string,
  opts: {
    attachments?: unknown[];
    streamingBehavior?: "steer" | "followUp";
  },
): boolean {
  return message.trim() === "/reload" && !opts.streamingBehavior && !opts.attachments?.length;
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

  // Mirror keeps path canonicalization and a 1MB budget so a late first
  // user line still backfills titles. The 200-char cap matches Session.firstMessage.
  return readSessionJsonlMeta(file, {
    maxBytes: 1024 * 1024,
    firstMessageMaxChars: 200,
    stopWhen: ["firstMessage"],
  }).firstMessage;
}

function bridgeProtocolVersionDiagnostic(value: unknown): {
  receivedProtocolVersion: string | number | boolean | null;
  receivedProtocolVersionType: string;
  display: string;
} {
  if (value === undefined) {
    return {
      receivedProtocolVersion: "<missing>",
      receivedProtocolVersionType: "missing",
      display: "<missing>",
    };
  }
  if (value === null) {
    return {
      receivedProtocolVersion: null,
      receivedProtocolVersionType: "null",
      display: "null",
    };
  }
  if (typeof value === "number" || typeof value === "boolean") {
    return {
      receivedProtocolVersion: value,
      receivedProtocolVersionType: typeof value,
      display: String(value),
    };
  }
  if (typeof value === "string") {
    const receivedProtocolVersion = value.slice(0, 128);
    return {
      receivedProtocolVersion,
      receivedProtocolVersionType: "string",
      display: JSON.stringify(receivedProtocolVersion),
    };
  }

  const receivedProtocolVersion = Array.isArray(value) ? "<array>" : "<object>";
  return {
    receivedProtocolVersion,
    receivedProtocolVersionType: Array.isArray(value) ? "array" : typeof value,
    display: receivedProtocolVersion,
  };
}

function parseBridgeMessage(data: RawData): PiBridgeInboundMessage {
  const parsed = JSON.parse(rawDataToText(data)) as unknown;
  const record = asRecord(parsed);
  if (!record || typeof record.type !== "string") {
    throw new Error("Bridge message must be an object with a string type");
  }
  if (record.type !== "hello") {
    return record as unknown as PiBridgeInboundMessage;
  }

  const protocolVersion = record.protocolVersion;
  if (protocolVersion !== PI_TUI_MIRROR_BRIDGE_PROTOCOL_VERSION) {
    const diagnostic = bridgeProtocolVersionDiagnostic(protocolVersion);
    throw new BridgeRegistrationError(
      `Bridge hello protocolVersion must be an explicit supported safe integer; received ${diagnostic.display}; supported: ${PI_TUI_MIRROR_SUPPORTED_BRIDGE_PROTOCOL_VERSIONS.join(", ")}`,
      "invalid_bridge_hello",
      {
        receivedProtocolVersion: diagnostic.receivedProtocolVersion,
        receivedProtocolVersionType: diagnostic.receivedProtocolVersionType,
        supportedProtocolVersions: [...PI_TUI_MIRROR_SUPPORTED_BRIDGE_PROTOCOL_VERSIONS],
      },
    );
  }

  const capabilities = record.capabilities;
  if (
    !Array.isArray(capabilities) ||
    capabilities.some(
      (capability) =>
        typeof capability !== "string" ||
        capability.length === 0 ||
        capability.trim() !== capability,
    ) ||
    new Set(capabilities).size !== capabilities.length
  ) {
    throw new BridgeRegistrationError(
      "Bridge hello capabilities must be a unique array of non-empty strings",
      "invalid_bridge_hello",
    );
  }

  if (!capabilities.includes(PI_TUI_MIRROR_INPUT_PREFLIGHT_CAPABILITY)) {
    throw new BridgeRegistrationError(
      `Bridge hello capabilities must include ${PI_TUI_MIRROR_INPUT_PREFLIGHT_CAPABILITY}`,
      "invalid_bridge_hello",
    );
  }

  return record as unknown as PiBridgeHelloMessage;
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

function requireExistingDirectory(path: string): string {
  const resolved = normalizePath(path);
  try {
    if (statSync(resolved).isDirectory()) return resolved;
  } catch {
    // Fall through to a deterministic bridge registration error.
  }
  throw new Error(`Terminal cwd is not an existing directory: ${path}`);
}

function nearestGitRoot(startDir: string): string | undefined {
  let current = requireExistingDirectory(startDir);
  while (true) {
    if (existsSync(join(current, ".git"))) return current;
    const parent = dirname(current);
    if (parent === current) return undefined;
    current = parent;
  }
}

function mirrorWorkspaceRootForCwd(cwd: string): string {
  const resolvedCwd = requireExistingDirectory(cwd);
  return nearestGitRoot(resolvedCwd) ?? resolvedCwd;
}

interface MirrorWorkspaceSuggestion {
  hostMount: string;
  name: string;
}

function workspaceNameFromHostMount(hostMount: string): string {
  return basename(normalizePath(hostMount)) || "Terminal Workspace";
}

function mirrorWorkspaceSuggestionForCwd(cwd: string): MirrorWorkspaceSuggestion {
  const hostMount = mirrorWorkspaceRootForCwd(cwd);
  return { hostMount, name: workspaceNameFromHostMount(hostMount) };
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

function normalizeLeafId(leafId: PiBridgeStateSnapshot["leafId"]): string | undefined {
  return typeof leafId === "string" && leafId.trim().length > 0 ? leafId.trim() : undefined;
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

function syncSessionWorktreeFromCwd(
  session: Session,
  workspace: Workspace,
  cwd: string | undefined,
  dataDir: string,
): void {
  const worktree = resolveWorkspaceWorktreeForPath(workspace, cwd, { dataDir });
  if (worktree) session.worktreeId = worktree.id;
}

function sessionActivityProjectionFingerprint(session: Session): string {
  const summary = buildSessionSummary(session);
  return sessionSummaryFingerprint({
    ...summary,
    lastActivity: 0,
    mirror: summary.mirror ? { status: summary.mirror.status } : undefined,
  });
}

function sessionStorageFingerprint(session: Session): string {
  return JSON.stringify(session);
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

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export interface PiTuiMirrorRuntimeOptions {
  isOppiSessionActive?: (sessionId: string) => boolean;
  stopOppiSession?: (sessionId: string) => Promise<void>;
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
  private taskRecordRejectionLogState:
    | { key: string; lastLoggedAt: number; suppressedCount: number }
    | undefined;
  searchIndex: SearchIndex | null = null;

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
      },
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

    this.inputCoordinator = new SessionInputCoordinator({
      config: this.storage.getConfig(),
      getActiveSession: (sessionId) => this.active.get(sessionId),
      turnCoordinator: this.turnCoordinator,
      sendCommand: (sessionId, command) => this.dispatchBridgeCommand(sessionId, command),
      onCommandResult: (sessionId, command, data) => {
        const commandType = typeof command.type === "string" ? command.type : "unknown";
        this.applyQueueFromCommandData(sessionId, data, `command_result:${commandType}`);
      },
      resolveWorkspaceRoot: (session) => this.resolveWorkspaceRoot(session),
    });

    this.runtimeCommandCoordinator = new RuntimeCommandCoordinator({
      runtimeName: "pi-tui runtime",
      isCommandSupported: isPiTuiMirrorRemoteCommand,
      unsupportedReason: piTuiMirrorUnsupportedRemoteCommandReason,
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

  private logTaskRecordRejection(logContext: Record<string, unknown>): void {
    const key = typeof logContext.error === "string" ? logContext.error : "pi_tui_task_record";
    const now = Date.now();
    const previous = this.taskRecordRejectionLogState;

    if (
      previous?.key === key &&
      now - previous.lastLoggedAt < TASK_RECORD_REJECTION_LOG_INTERVAL_MS
    ) {
      previous.suppressedCount += 1;
      return;
    }

    const suppressedCount = previous?.key === key ? previous.suppressedCount : 0;
    this.taskRecordRejectionLogState = { key, lastLoggedAt: now, suppressedCount: 0 };
    log.debug("mirror_bridge.message_rejected", {
      ...logContext,
      ...(suppressedCount > 0 ? { suppressedCount } : {}),
    });
  }

  handleBridgeWebSocket(ws: WebSocket): void {
    let connection: BridgeConnection | undefined;
    let registration: Promise<void> | null = null;
    let rejectedBeforeHello = false;
    const pendingMessages: PiBridgeInboundMessage[] = [];

    const rejectMessage = (error: unknown): void => {
      const message = safeErrorMessage(error);
      const details = error instanceof BridgeRegistrationError ? error.details : {};
      const logContext = {
        runtime: MIRROR_RUNTIME_LOG_TAG,
        error: message,
        ...(error instanceof BridgeRegistrationError ? { code: error.code, ...details } : {}),
      };
      if (
        error instanceof BridgeRegistrationError &&
        error.code === "pi_tui_task_record_not_openable"
      ) {
        this.logTaskRecordRejection(logContext);
      } else {
        log.warn("mirror_bridge.message_rejected", logContext);
      }
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
          pendingMessages.length = 0;
          ws.close(1008, message);
        }
      }
    };

    const flushPendingMessages = (): void => {
      if (!connection) return;
      const messages = pendingMessages.splice(0);
      for (const message of messages) {
        try {
          this.handleBridgeMessage(connection, message);
        } catch (error) {
          rejectMessage(error);
          break;
        }
      }
    };

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
          if (connection || registration) {
            throw new Error("Bridge already registered");
          }
          const registered = this.registerBridge(ws, message);
          if (registered instanceof Promise) {
            registration = registered
              .then((nextConnection) => {
                connection = nextConnection;
                flushPendingMessages();
              })
              .catch((error: unknown) => {
                rejectMessage(error);
              })
              .finally(() => {
                registration = null;
              });
            return;
          }
          connection = registered;
          flushPendingMessages();
          return;
        }

        if (registration) {
          pendingMessages.push(message);
          return;
        }

        if (!connection) {
          throw new Error("Bridge must send hello before other messages");
        }

        this.handleBridgeMessage(connection, message);
      } catch (error) {
        rejectMessage(error);
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
    const ids = new Set<string>();
    for (const sessionId of this.active.keys()) {
      if (this.isSessionConnected(sessionId)) {
        ids.add(sessionId);
      }
    }
    return ids;
  }

  getActiveSession(sessionId: string): Session | undefined {
    return this.active.get(sessionId)?.session ?? this.storage.getSession(sessionId);
  }

  getSessionTraceState(
    sessionId: string,
  ): { sessionFile?: string; sessionId?: string; leafId?: string } | null {
    const active = this.active.get(sessionId);
    const session = active?.session ?? this.storage.getSession(sessionId) ?? undefined;
    if (!session || !this.isMirrorSession(session)) return null;
    return {
      sessionFile: session.piSessionFile,
      sessionId: session.piSessionId,
      ...(active?.leafId ? { leafId: active.leafId } : {}),
    };
  }

  isSessionConnected(sessionId: string): boolean {
    return this.connectedBridgeForSession(sessionId) !== undefined;
  }

  private connectedBridgeForSession(sessionId: string): BridgeConnection | undefined {
    const bridgeId = this.bridgeBySession.get(sessionId);
    const connection = bridgeId ? this.bridges.get(bridgeId) : undefined;
    if (!connection || connection.ws.readyState !== WebSocket.OPEN) return undefined;
    return connection.sessionId === sessionId ? connection : undefined;
  }

  private settleExtensionUIRequest(
    active: MirrorActiveSession,
    requestId: string,
    cancelled: boolean,
  ): boolean {
    return settleExtensionUIRequestState(active, requestId, {
      cancelled,
      broadcastSettled: (message) => this.broadcast(active.session.id, message),
    });
  }

  private deliverExtensionUIResponse(
    connection: BridgeConnection,
    payload: ExtensionUIResponse,
  ): boolean {
    try {
      connection.ws.send(
        JSON.stringify({
          type: "extension_ui_response",
          id: payload.id,
          value: payload.value,
          confirmed: payload.confirmed,
          cancelled: payload.cancelled,
        }),
      );
      return true;
    } catch (error) {
      log.warn("mirror_bridge.extension_ui_response_send_failed", {
        runtime: MIRROR_RUNTIME_LOG_TAG,
        sessionId: connection.sessionId,
        bridgeId: connection.bridgeId,
        requestId: payload.id,
        error: safeErrorMessage(error),
      });
      return false;
    }
  }

  private cancelPendingAsk(active: MirrorActiveSession, connection: BridgeConnection): void {
    cancelPendingAskRequest(active, {
      broadcastSettled: (message) => this.broadcast(active.session.id, message),
      deliver: (payload) => this.deliverExtensionUIResponse(connection, payload),
    });
  }

  subscribe(sessionId: string, callback: (msg: ServerMessage) => void): () => void {
    this.ensureActiveFromStorage(sessionId);
    const unsubscribe = this.broadcaster.subscribe(sessionId, callback);
    return () => {
      unsubscribe();
      this.releaseActiveSessionIfIdle(sessionId);
    };
  }

  getCurrentSeq(sessionId: string): number {
    return this.broadcaster.getCurrentSeq(sessionId);
  }

  getCatchUp(sessionId: string, sinceSeq: number): SessionCatchUpResponse | null {
    return this.broadcaster.getCatchUp(sessionId, sinceSeq);
  }

  getPendingUIRequestMessages(sessionId: string): ServerMessage[] {
    return buildPendingExtensionUIRequestMessages(this.active.get(sessionId));
  }

  getToolFullOutputPath(sessionId: string, toolCallId: string): string | null {
    const normalizedToolCallId = toolCallId.trim();
    if (normalizedToolCallId.length === 0) {
      return null;
    }

    return this.active.get(sessionId)?.toolFullOutputPaths.get(normalizedToolCallId) ?? null;
  }

  getEventRing(sessionId: string): { length: number; capacity: number } | null {
    const active = this.active.get(sessionId);
    if (!active) return null;
    return { length: active.eventRing.length, capacity: active.eventRing.capacity };
  }

  private resolveWorkspaceRoot(session: Session): string | null {
    if (!session.workspaceId) return null;
    const workspace = this.storage.getWorkspace(session.workspaceId);
    if (!workspace?.hostMount) return null;
    return normalizePath(
      resolveSdkSessionCwd(workspace, session, { dataDir: this.storage.getDataDir() }),
    );
  }

  async sendPrompt(
    sessionId: string,
    message: string,
    opts: {
      attachments?: ChatAttachmentRef[];
      clientTurnId?: string;
      requestId?: string;
      streamingBehavior?: "steer" | "followUp";
      timestamp: number;
    },
  ): Promise<void> {
    if (!this.connectedBridgeForSession(sessionId)) {
      throw new Error("pi-tui is not connected");
    }
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
      attachments?: ChatAttachmentRef[];
      clientTurnId?: string;
      requestId?: string;
    },
  ): Promise<void> {
    if (!this.connectedBridgeForSession(sessionId)) {
      throw new Error("pi-tui is not connected");
    }
    await this.inputCoordinator.sendSteer(sessionId, message, opts);
  }

  async sendFollowUp(
    sessionId: string,
    message: string,
    opts: {
      attachments?: ChatAttachmentRef[];
      clientTurnId?: string;
      requestId?: string;
    },
  ): Promise<void> {
    if (!this.connectedBridgeForSession(sessionId)) {
      throw new Error("pi-tui is not connected");
    }
    await this.inputCoordinator.sendFollowUp(sessionId, message, opts);
  }

  async getMessageQueue(sessionId: string): Promise<MessageQueueState> {
    if (!this.connectedBridgeForSession(sessionId)) {
      throw new Error("pi-tui is not connected");
    }
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
    if (!this.connectedBridgeForSession(sessionId)) {
      throw new Error("pi-tui is not connected");
    }
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
    const active = this.active.get(sessionId);
    const connection = this.connectedBridgeForSession(sessionId);
    if (active && connection) {
      this.cancelPendingAsk(active, connection);
    }

    const data = await this.dispatchBridgeCommand(sessionId, { type: "abort" });
    this.applyQueueFromCommandData(sessionId, data, "command_result:abort");
  }

  async stopSession(sessionId: string): Promise<void> {
    const connection = this.connectedBridgeForSession(sessionId);

    if (!connection) {
      throw new RuntimeDisconnectedError(
        "pi-tui",
        "pi-tui is not connected; stop it from the terminal",
      );
    }

    const active = this.active.get(sessionId);
    if (active) {
      this.cancelPendingAsk(active, connection);
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
        waiter.reject(
          new RuntimeDisconnectedError(
            "pi-tui",
            `pi-tui disconnected before stop completed (${reason})`,
          ),
        );
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
    const active = this.active.get(sessionId);
    if (!active) return false;

    const connection = this.connectedBridgeForSession(sessionId);
    if (!connection) return false;

    return respondToExtensionUIRequestState(active, response, {
      broadcastSettled: (message) => this.broadcast(active.session.id, message),
      deliver: (payload) => this.deliverExtensionUIResponse(connection, payload),
    });
  }

  async forwardClientCommand(
    sessionId: string,
    message: RuntimeClientCommand,
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
    context.data = this.normalizeCommandResult(context.commandType, context.request, context.data);
    this.applyQueueFromCommandData(
      sessionId,
      context.data,
      `command_result:${context.commandType}`,
    );
    this.applyCommandResult(sessionId, context.commandType, context.request, context.data);
  }

  private normalizeCommandResult(
    commandType: string,
    request: RuntimeClientCommand,
    data: unknown,
  ): unknown {
    if (commandType !== "get_session_tree") {
      return data;
    }

    const record = data && typeof data === "object" ? (data as Record<string, unknown>) : {};
    if (Array.isArray(record.nodes)) {
      return data;
    }

    const filterMode = request.type === "get_session_tree" ? request.filterMode : undefined;
    return serializeRawSessionTreePayload(data, readSessionTreeFilterMode(filterMode));
  }

  private registerBridge(
    ws: WebSocket,
    hello: PiBridgeHelloMessage,
  ): BridgeConnection | Promise<BridgeConnection> {
    const now = Date.now();
    const protocolVersion = hello.protocolVersion;
    const bridgeId = hello.bridgeId?.trim() || `pi-tui-${process.pid}-${now}`;
    const state = { ...hello.state, cwd: hello.state?.cwd ?? hello.cwd };
    if (isPiTuiTaskRecordBridgeState(state)) {
      throw new BridgeRegistrationError(
        "Pi task records are not openable mirror sessions because no trace file was reported",
        "pi_tui_task_record_not_openable",
        { sessionName: state.sessionName },
      );
    }
    const workspace = this.resolveWorkspace(hello);
    const session = this.resolveOrCreateSession(workspace, state, hello);
    if (session instanceof Promise) {
      return session.then((resolvedSession) =>
        this.finishBridgeRegistration(ws, hello, resolvedSession, workspace, state, {
          now,
          bridgeId,
          protocolVersion,
        }),
      );
    }

    return this.finishBridgeRegistration(ws, hello, session, workspace, state, {
      now,
      bridgeId,
      protocolVersion,
    });
  }

  private finishBridgeRegistration(
    ws: WebSocket,
    hello: PiBridgeHelloMessage,
    session: Session,
    workspace: Workspace,
    state: PiBridgeStateSnapshot,
    registration: { now: number; bridgeId: string; protocolVersion: number },
  ): BridgeConnection {
    const { now, bridgeId, protocolVersion } = registration;

    const existingSameBridge = this.bridges.get(bridgeId);
    if (existingSameBridge && existingSameBridge.sessionId !== session.id) {
      existingSameBridge.ws.close(4000, "Mirror bridge id reused by a newer terminal session");
      this.detachBridge(existingSameBridge, "replaced");
      this.clearBridgeAliases(bridgeId, session.id, "replaced");
    }

    const existingBridgeId = this.bridgeBySession.get(session.id);
    if (existingBridgeId) {
      const existing = this.bridges.get(existingBridgeId);
      existing?.ws.close(4000, "Mirror bridge replaced by a newer terminal connection");
      if (existing) this.detachBridge(existing, "replaced");
    }
    this.clearBridgeAliases(bridgeId, session.id, "replaced");

    // Ensure after detach: replace can idle-evict the previous entry when no stream is attached.
    const active = this.ensureActive(session);

    const connection: BridgeConnection = {
      bridgeId,
      sessionId: session.id,
      ws,
      cwd: hello.cwd,
      capabilities: [...hello.capabilities],
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
        protocolVersion: PI_TUI_MIRROR_BRIDGE_PROTOCOL_VERSION,
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

      case "heartbeat": {
        const stateChanged = this.applyBridgeState(active, message.state ?? {}, connection);
        if (message.queue) {
          this.applyBridgeQueueState(
            active,
            requireQueueState(message.queue, "pi-tui sent invalid heartbeat queue state"),
            "heartbeat",
          );
        }
        if (stateChanged) {
          this.broadcast(connection.sessionId, { type: "state", session: active.session });
        }
        return;
      }

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
        if (message.event.type === "session_tree") {
          if (message.event.summaryEntry) {
            resetCacheMissTracker(active.cacheMissTracker);
          }
          return;
        }
        this.ingestAgentEvent(active, message.event);
        return;

      case "extension_ui_request":
        handleExtensionUIRequestState(active, message, {
          broadcast: (serverMessage) => this.broadcast(connection.sessionId, serverMessage),
        });
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
    active.messageQueue = cloneQueueState(
      requireQueueState(message.queue, "pi-tui sent invalid started-item queue state"),
    );
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
    const pendingCommandType = connection.pendingCommands.get(message.id)?.commandType;
    const matched = this.bridgeCommandDriver.resolveResult(connection, message, () => {
      const resultData = asRecord(message.data);
      if (
        message.success &&
        pendingCommandType === "navigate_tree" &&
        navigationCreatedBranchSummary(message.data)
      ) {
        resetCacheMissTracker(this.requireActive(connection.sessionId).cacheMissTracker);
      }
      const queueErrorCode = resultData?.code;
      if (
        !message.success &&
        pendingCommandType === "set_queue" &&
        (queueErrorCode === PI_TUI_MIRROR_QUEUE_VERSION_MISMATCH_CODE ||
          queueErrorCode === PI_TUI_MIRROR_QUEUE_VERSION_EXHAUSTED_CODE)
      ) {
        this.applyBridgeQueueState(
          this.requireActive(connection.sessionId),
          requireQueueState(
            resultData?.queue,
            queueErrorCode === PI_TUI_MIRROR_QUEUE_VERSION_MISMATCH_CODE
              ? "pi-tui queue version mismatch did not return current queue state"
              : "pi-tui queue version exhaustion did not return current queue state",
          ),
          `command_result:set_queue_version_${queueErrorCode === PI_TUI_MIRROR_QUEUE_VERSION_MISMATCH_CODE ? "mismatch" : "exhausted"}`,
        );
      }
      if (message.state) {
        const active = this.requireActive(connection.sessionId);
        const stateChanged = this.applyBridgeState(active, message.state, connection);
        if (stateChanged) {
          this.broadcast(connection.sessionId, { type: "state", session: active.session });
        }
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

  private teardownMirrorBridgeSession(
    active: MirrorActiveSession,
    options: {
      bridgeId: string;
      reason: string;
      cwd?: string;
      lastSeenAt?: number;
    },
  ): void {
    for (const message of drainExtensionUITeardownMessages(active, { cancelled: true })) {
      this.broadcast(active.session.id, message);
    }

    const disconnectedAt = Date.now();
    const terminal = {
      ...(active.session.mirror?.terminal ?? {}),
      bridgeId: options.bridgeId,
      cwd: options.cwd ?? active.session.mirror?.terminal?.cwd,
      disconnectedAt,
      disconnectReason: options.reason,
      lastSeenAt: options.lastSeenAt ?? disconnectedAt,
    };

    if (options.reason === "reload") {
      active.session.mirror = {
        ...(active.session.mirror ?? { status: "connected" }),
        status: "connected",
        terminal,
      };
      this.storage.saveSession(active.session);
      return;
    }

    active.session.mirror = {
      ...(active.session.mirror ?? { status: "disconnected" }),
      status: "disconnected",
      terminal,
    };
    if (isTerminalStoppedReason(options.reason)) {
      active.session.status = "stopped";
      active.session.currentTurnStartedAt = undefined;
      active.session.lastActivity = disconnectedAt;
    }
    this.storage.saveSession(active.session);
    this.broadcast(active.session.id, { type: "state", session: active.session });
    this.broadcastSessionSummaryIfChanged(active, `mirror_${options.reason}`);
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

    // Entry may already be idle-evicted while the socket was CLOSING; still persist disconnect.
    const active =
      this.active.get(connection.sessionId) ?? this.ensureActiveFromStorage(connection.sessionId);
    if (active) {
      this.teardownMirrorBridgeSession(active, {
        bridgeId: connection.bridgeId,
        cwd: connection.cwd,
        reason: effectiveReason,
        lastSeenAt: connection.lastSeenAt,
      });
      this.releaseActiveSessionIfIdle(connection.sessionId);
    }

    log.info("mirror_bridge.disconnected", {
      runtime: MIRROR_RUNTIME_LOG_TAG,
      bridgeId: connection.bridgeId,
      sessionId: connection.sessionId,
      reason: effectiveReason,
      pendingCommandCount,
    });
  }

  private clearBridgeAliases(bridgeId: string, keepSessionId: string, reason: string): void {
    for (const [sessionId, mappedBridgeId] of [...this.bridgeBySession.entries()]) {
      if (mappedBridgeId !== bridgeId || sessionId === keepSessionId) continue;
      this.bridgeBySession.delete(sessionId);

      const active = this.active.get(sessionId) ?? this.ensureActiveFromStorage(sessionId);
      if (!active) continue;

      this.teardownMirrorBridgeSession(active, { bridgeId, reason });
      this.releaseActiveSessionIfIdle(sessionId);
    }
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
        if (
          !pathContains(workspace.hostMount, cwd) &&
          !resolveWorkspaceWorktreeForPath(workspace, cwd, { dataDir: this.storage.getDataDir() })
        ) {
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
      .flatMap((workspace) => {
        if (!workspace.hostMount) return [];
        const worktree = resolveWorkspaceWorktreeForPath(workspace, cwd, {
          dataDir: this.storage.getDataDir(),
        });
        if (!pathContains(workspace.hostMount, cwd) && !worktree) return [];
        return [{ workspace, matchPath: worktree?.path ?? workspace.hostMount }];
      })
      .sort((a, b) => normalizePath(b.matchPath).length - normalizePath(a.matchPath).length);
    const match = candidates[0];
    const workspace = match?.workspace;
    if (!workspace) {
      const suggestion = mirrorWorkspaceSuggestionForCwd(cwd);
      if (hello.createWorkspace === true) {
        return this.createMirrorWorkspaceForSuggestion(suggestion, cwd);
      }

      throw new BridgeRegistrationError(
        `No Oppi workspace hostMount contains terminal cwd: ${cwd}`,
        "workspace_missing",
        {
          cwd,
          suggestedHostMount: suggestion.hostMount,
          suggestedName: suggestion.name,
        },
      );
    }

    const matchLength = normalizePath(match.matchPath).length;
    if (
      candidates.length > 1 &&
      normalizePath(candidates[1]?.matchPath ?? "").length === matchLength
    ) {
      throw new Error(`Ambiguous Oppi workspace match for terminal cwd: ${cwd}`);
    }

    return workspace;
  }

  private createMirrorWorkspaceForSuggestion(
    suggestion: MirrorWorkspaceSuggestion,
    cwd: string,
  ): Workspace {
    const workspace = this.storage.createWorkspace({
      name: suggestion.name,
      description: "Created from an interactive Pi terminal session.",
      hostMount: suggestion.hostMount,
      gitStatusEnabled: true,
      runtime: "host",
    });

    log.info("mirror_bridge.workspace_created", {
      runtime: MIRROR_RUNTIME_LOG_TAG,
      workspaceId: workspace.id,
      hostMount: workspace.hostMount,
      cwd,
    });
    return workspace;
  }

  private resolveOrCreateSession(
    workspace: Workspace,
    state: PiBridgeStateSnapshot,
    hello: PiBridgeHelloMessage,
  ): Session | Promise<Session> {
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

    if (existing && existing.runtime !== "pi-tui") {
      const requiresStop = this.options.isOppiSessionActive?.(existing.id) === true;
      if (hello.takeoverConfirmation?.sessionId !== existing.id) {
        throw new BridgeRegistrationError(
          `Confirm taking over Oppi session ${existing.id} from this Pi terminal before mirroring it`,
          "oppi_takeover_confirmation_required",
          {
            sessionId: existing.id,
            sessionName: meaningfulSessionName(existing.name, existing.id),
            sessionStatus: existing.status,
            workspaceId: existing.workspaceId,
            requiresStop,
          },
        );
      }

      if (requiresStop) {
        return this.stopOppiSessionForTakeover(existing.id).then(() => {
          this.logOppiSessionTakeoverConfirmed(existing, true);
          return this.promoteBridgeSession(workspace, state, piSessionFile, piSessionId, existing);
        });
      }

      this.logOppiSessionTakeoverConfirmed(existing, false);
    }

    return this.promoteBridgeSession(workspace, state, piSessionFile, piSessionId, existing);
  }

  private async stopOppiSessionForTakeover(sessionId: string): Promise<void> {
    const stopOppiSession = this.options.stopOppiSession;
    if (!stopOppiSession) {
      throw new BridgeRegistrationError(
        `Session ${sessionId} is already owned by the oppi runtime; stop it before mirroring this pi-tui session`,
        "oppi_runtime_active",
        { sessionId, retryAfterMs: OPPI_RUNTIME_CONFLICT_RETRY_MS },
      );
    }

    try {
      await stopOppiSession(sessionId);
    } catch (error) {
      throw new BridgeRegistrationError(
        `Failed to stop Oppi session ${sessionId} before mirror takeover: ${safeErrorMessage(error)}`,
        "oppi_runtime_stop_failed",
        { sessionId },
      );
    }

    const deadline = Date.now() + OPPI_RUNTIME_TAKEOVER_STOP_TIMEOUT_MS;
    while (this.options.isOppiSessionActive?.(sessionId) === true) {
      if (Date.now() >= deadline) {
        throw new BridgeRegistrationError(
          `Timed out stopping Oppi session ${sessionId} before mirror takeover`,
          "oppi_runtime_active",
          { sessionId, retryAfterMs: OPPI_RUNTIME_CONFLICT_RETRY_MS },
        );
      }
      await sleep(OPPI_RUNTIME_TAKEOVER_STOP_POLL_MS);
    }
  }

  private logOppiSessionTakeoverConfirmed(session: Session, stoppedOppiRuntime: boolean): void {
    log.info("mirror_bridge.oppi_session_takeover_confirmed", {
      runtime: MIRROR_RUNTIME_LOG_TAG,
      sessionId: session.id,
      workspaceId: session.workspaceId,
      status: session.status,
      stoppedOppiRuntime,
    });
  }

  private promoteBridgeSession(
    workspace: Workspace,
    state: PiBridgeStateSnapshot,
    piSessionFile: string | undefined,
    piSessionId: string | undefined,
    existing: Session | undefined,
  ): Session {
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
    syncSessionWorktreeFromCwd(session, workspace, state.cwd, this.storage.getDataDir());
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

  /**
   * Drop in-memory projection state when nothing needs it.
   * Connected bridges always keep their entry. Disconnected entries stay only while
   * stream subscribers still need catch-up / tool-output lookup.
   */
  private releaseActiveSessionIfIdle(sessionId: string): void {
    const active = this.active.get(sessionId);
    if (!active) return;
    if (this.isSessionConnected(sessionId)) return;
    if (active.subscribers.size > 0) return;
    this.active.delete(sessionId);
  }

  private ensureActive(session: Session): MirrorActiveSession {
    const existing = this.active.get(session.id);
    if (existing) {
      existing.session = session;
      return existing;
    }

    const active: MirrorActiveSession = {
      ...createRuntimeSessionStateScaffold(
        session,
        EVENT_RING_CAPACITY,
        createEmptyRuntimeMessageQueue(),
      ),
    };
    this.active.set(session.id, active);
    return active;
  }

  private requireActive(sessionId: string): MirrorActiveSession {
    // Never hydrate here: write paths that fail while disconnected must not pin memory.
    const active = this.active.get(sessionId);
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
    const wasConnected = active.session.mirror?.status === "connected";
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
    if (!wasConnected) {
      active.session.lastActivity = connection.connectedAt;
    }
    this.storage.saveSession(active.session);
  }

  private applyBridgeState(
    active: MirrorActiveSession,
    state: PiBridgeStateSnapshot,
    connection?: BridgeConnection,
  ): boolean {
    const session = active.session;
    const now = Date.now();
    const activityBefore = sessionActivityProjectionFingerprint(session);
    const storageBefore = sessionStorageFingerprint(session);

    session.runtime = "pi-tui";
    const nextName = meaningfulSessionName(state.sessionName, session.id);
    if (nextName) session.name = nextName;
    else if (meaningfulSessionName(session.name, session.id) === undefined) delete session.name;
    const model = normalizeModelId(state.model);
    if (model) session.model = model;
    active.leafId = normalizeLeafId(state.leafId);
    if (typeof state.showCacheMissNotices === "boolean") {
      active.showCacheMissNotices = state.showCacheMissNotices;
    }
    if (
      model &&
      typeof state.cacheReadCostPerMillion === "number" &&
      Number.isFinite(state.cacheReadCostPerMillion)
    ) {
      const modelKey = model;
      const cacheRead = Math.max(0, state.cacheReadCostPerMillion);
      active.cacheMissModelPriceSource = {
        find: (provider, modelId) =>
          `${provider}/${modelId}` === modelKey ? { cost: { cacheRead } } : undefined,
      };
    }
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
      session.currentTurnStartedAt = state.isIdle
        ? undefined
        : (session.currentTurnStartedAt ?? now);
    }

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
          lastSeenAt: session.mirror?.terminal?.lastSeenAt ?? connection.connectedAt,
        },
      };
    }

    if (sessionActivityProjectionFingerprint(session) !== activityBefore) {
      session.lastActivity = now;
    }

    const didChangeSession = sessionStorageFingerprint(session) !== storageBefore;
    if (didChangeSession) {
      this.storage.saveSession(session);
    }
    return didChangeSession;
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
    const event = rawEvent as SessionBackendEvent;
    this.agentEventCoordinator.handlePiEvent(active.session.id, event);
    updateSearchIndexForSessionEvent(this.searchIndex, this.storage, active.session.id, event);
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
    if (connection && connection.sessionId !== sessionId) {
      return Promise.reject(
        new Error(
          `pi-tui bridge session mismatch: requested ${sessionId}, bridge owns ${connection.sessionId}`,
        ),
      );
    }

    const commandType = typeof command.type === "string" ? command.type : "unknown";
    if (
      connection &&
      (commandType === "prompt" || commandType === "steer" || commandType === "follow_up") &&
      !connection.capabilities.includes(PI_TUI_MIRROR_INPUT_PREFLIGHT_CAPABILITY)
    ) {
      return Promise.reject(
        new Error(`pi-tui input requires capability ${PI_TUI_MIRROR_INPUT_PREFLIGHT_CAPABILITY}`),
      );
    }

    return this.bridgeCommandDriver.dispatch(connection, command);
  }

  private applyCommandResult(
    sessionId: string,
    commandType: string,
    request: RuntimeClientCommand,
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

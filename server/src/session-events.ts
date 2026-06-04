import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";

import {
  buildExtensionUINotificationMessage,
  buildExtensionUIRequestMessage,
  isExtensionUIFireAndForgetMethod,
} from "./extension-ui-contract.js";
import { getGitStatus } from "./git-status.js";
import type { MobileRendererRegistry } from "./mobile-renderer.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import {
  appendSessionMessage,
  applyMessageEndToSession,
  incrementSessionCompactionCount,
  updateSessionChangeStats,
  type TranslationContext,
} from "./session-protocol.js";
import { extractQueuedUserText } from "./session-queue-utils.js";
import type { PendingStop } from "./session-stop.js";
import type { Storage } from "./storage.js";
import type { AskQuestion, ExtensionUINativeSurface, Session, ServerMessage } from "./types.js";

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
  timeoutAt?: number;
  questions?: AskQuestion[];
  allowCustom?: boolean;
  nativeSurface?: ExtensionUINativeSurface;
}

const TERMINAL_ONLY_STATUS_KEYS = new Set(["oppi-mirror"]);

function terminalOnlyStatusText(req: ExtensionUIRequest): string | undefined {
  if (req.method === "setStatus" && req.statusKey && TERMINAL_ONLY_STATUS_KEYS.has(req.statusKey)) {
    return undefined;
  }
  return req.statusText;
}

function notificationReplayKey(req: ExtensionUIRequest): string | undefined {
  switch (req.method) {
    case "setStatus":
      return req.statusKey && !TERMINAL_ONLY_STATUS_KEYS.has(req.statusKey)
        ? `status:${req.statusKey}`
        : undefined;
    case "setWidget":
      return req.widgetKey ? `widget:${req.widgetKey}` : undefined;
    case "setTitle":
      return "title";
    default:
      return undefined;
  }
}

function widgetLinesHaveContent(lines: string[] | undefined): boolean {
  return lines?.some((line) => line.replace(/[\r\n]/g, "").length > 0) ?? false;
}

function hasPersistentNotificationContent(req: ExtensionUIRequest): boolean {
  switch (req.method) {
    case "setStatus":
      return (req.statusText?.trim().length ?? 0) > 0;
    case "setWidget":
      return req.nativeSurface !== undefined || widgetLinesHaveContent(req.widgetLines);
    case "setTitle":
      return (req.title?.trim().length ?? 0) > 0;
    default:
      return false;
  }
}

function normalizeFireAndForgetNotificationRequest(req: ExtensionUIRequest): ExtensionUIRequest {
  if (req.method === "setStatus") {
    return { ...req, statusText: terminalOnlyStatusText(req) };
  }
  return req;
}

export function updatePersistentExtensionUINotifications(
  active: Pick<EventProcessorSessionState, "persistentExtensionUINotifications">,
  req: ExtensionUIRequest,
): void {
  const key = notificationReplayKey(req);
  if (!key) {
    return;
  }

  const store = (active.persistentExtensionUINotifications ??= new Map());
  if (hasPersistentNotificationContent(req)) {
    store.set(key, req);
    return;
  }

  const clearReq = buildPersistentExtensionUIClearRequest(req);
  if (clearReq) {
    store.set(key, clearReq);
  } else {
    store.delete(key);
  }
}

export function buildPersistentExtensionUINotificationMessages(
  active: Pick<EventProcessorSessionState, "persistentExtensionUINotifications">,
): ServerMessage[] {
  return Array.from(active.persistentExtensionUINotifications?.values() ?? []).map((req) =>
    buildExtensionUINotificationMessage(req),
  );
}

function buildPersistentExtensionUIClearRequest(
  req: ExtensionUIRequest,
): ExtensionUIRequest | undefined {
  switch (req.method) {
    case "setStatus":
      return req.statusKey
        ? {
            type: "extension_ui_request",
            id: req.id,
            method: "setStatus",
            statusKey: req.statusKey,
          }
        : undefined;
    case "setWidget":
      return req.widgetKey
        ? {
            type: "extension_ui_request",
            id: req.id,
            method: "setWidget",
            widgetKey: req.widgetKey,
          }
        : undefined;
    case "setTitle":
      return { type: "extension_ui_request", id: req.id, method: "setTitle" };
    default:
      return undefined;
  }
}

export function drainPersistentExtensionUIClearMessages(
  active: Pick<EventProcessorSessionState, "persistentExtensionUINotifications">,
): ServerMessage[] {
  const store = active.persistentExtensionUINotifications;
  if (!store?.size) {
    return [];
  }

  const messages: ServerMessage[] = [];
  for (const req of store.values()) {
    const clearReq = buildPersistentExtensionUIClearRequest(req);
    if (clearReq) {
      messages.push(buildExtensionUINotificationMessage(clearReq));
    }
  }
  store.clear();
  return messages;
}

function estimateCharsFromContent(content: unknown): number {
  if (typeof content === "string") {
    return content.length;
  }

  if (!Array.isArray(content)) {
    return 0;
  }

  let chars = 0;
  for (const block of content) {
    if (!block || typeof block !== "object") {
      continue;
    }
    const record = block as Record<string, unknown>;
    if (typeof record.text === "string") {
      chars += record.text.length;
    }
    if (typeof record.thinking === "string") {
      chars += record.thinking.length;
    }
    if (record.type === "toolCall") {
      if (typeof record.name === "string") {
        chars += record.name.length;
      }
      if (record.arguments !== undefined) {
        chars += JSON.stringify(record.arguments).length;
      }
    }
  }
  return chars;
}

function estimatePiMessageChars(message: unknown): number {
  if (!message || typeof message !== "object") {
    return 0;
  }
  const record = message as Record<string, unknown>;
  return estimateCharsFromContent(record.content);
}

function estimateToolResultChars(result: unknown): number {
  if (!result || typeof result !== "object") {
    return 0;
  }
  const record = result as Record<string, unknown>;
  return estimateCharsFromContent(record.content);
}

function estimateTokensFromChars(chars: number): number {
  return Math.ceil(Math.max(0, chars) / 4);
}

/** Server-side state for a pending first-class ask request. */
export interface PendingAskState {
  requestId: string;
  questionCount: number;
  /** Full broadcast message — stored for re-sending on client reconnect. */
  broadcastMessage: ServerMessage;
  /** Timestamp when the ask flow was initiated (for round-trip timing). */
  initiatedAt: number;
}

export interface EventProcessorSessionState {
  session: Session;
  pendingUIRequests: Map<string, ExtensionUIRequest>;
  /** Last persistent extension UI surfaces/status/title, replayed to late focused clients. */
  persistentExtensionUINotifications?: Map<string, ExtensionUIRequest>;
  partialResults: Map<string, string>;
  streamedAssistantText: string;
  hasStreamedThinking: boolean;
  streamedThinkingContentIndexes: Set<number>;
  currentThinkingContentIndex?: number;
  pendingStop?: PendingStop;
  /** Tool names per toolCallId — tracked for shell preview decisions. */
  toolNames: Map<string, string>;
  /** Last time a shell preview snapshot was sent per toolCallId (ms). */
  shellPreviewLastSent: Map<string, number>;
  /** toolCallIds with active streaming arg viewport previews. */
  streamingArgPreviews: Set<string>;
  /** Last serialized streaming tool args emitted per toolCallId this turn. */
  streamingToolUpdatesSeen: Map<string, string>;
  /** Pending first-class ask request awaiting a user response. */
  pendingAsk?: PendingAskState;
  /** Timestamp (ms) when the current turn started (agent_start). */
  turnStartedAt?: number;
  /** Whether the first text/thinking token has been recorded for the current turn. */
  turnFirstTokenRecorded?: boolean;
  /** Number of tool_execution_start events in the current turn. */
  turnToolCallCount?: number;
  /** Timestamp (ms) when auto-compaction started (for duration tracking). */
  compactionStartedAt?: number;
  /** Authoritative context usage at the start of the active turn/estimate window. */
  contextUsageBaselineTokens?: number;
  /** Estimated chars added to context after the authoritative baseline. */
  contextUsageTrailingChars?: number;
  /** Last live context usage state broadcast timestamp (ms). */
  contextUsageLastBroadcastAt?: number;
  /** Last live context usage token estimate broadcast. */
  contextUsageLastBroadcastTokens?: number;
}

export interface SessionEventProcessorDeps {
  storage: Storage;
  mobileRenderers?: MobileRendererRegistry;
  broadcast: (key: string, message: ServerMessage) => void;
  persistSessionNow: (key: string, session: Session) => void;
  markSessionDirty: (key: string) => void;
  /** Respond to a pending extension UI request. */
  respondToUIRequest: (
    key: string,
    response: { type: "extension_ui_response"; id: string; value?: string; cancelled?: boolean },
  ) => boolean;
  /** Server operational metric collector (metrics silently skipped when absent). */
  metrics?: ServerMetricCollector;
  /** Mirror mode receives terminal-origin user messages as pi events. */
  recordUserMessagesFromEvents?: boolean;
}

export class SessionEventProcessor {
  private gitStatusTimers: Map<string, NodeJS.Timeout> = new Map();
  private static readonly GIT_STATUS_DEBOUNCE_MS = 2000;
  private static readonly CONTEXT_USAGE_BROADCAST_MIN_INTERVAL_MS = 500;
  private static readonly CONTEXT_USAGE_BROADCAST_MIN_TOKEN_DELTA = 128;

  constructor(private readonly deps: SessionEventProcessorDeps) {}

  /**
   * Build the TranslationContext for an active session.
   * The context holds mutable streaming state that translatePiEvent reads/writes.
   */
  translationContext(active: EventProcessorSessionState): TranslationContext {
    return {
      sessionId: active.session.id,
      partialResults: active.partialResults,
      streamedAssistantText: active.streamedAssistantText,
      hasStreamedThinking: active.hasStreamedThinking,
      streamedThinkingContentIndexes: active.streamedThinkingContentIndexes,
      currentThinkingContentIndex: active.currentThinkingContentIndex,
      mobileRenderers: this.deps.mobileRenderers,
      toolNames: active.toolNames,
      shellPreviewLastSent: active.shellPreviewLastSent,
      streamingArgPreviews: active.streamingArgPreviews,
      streamingToolUpdatesSeen: active.streamingToolUpdatesSeen,
    };
  }

  /**
   * Handle extension_ui_request from pi.
   * Fire-and-forget methods are forwarded as notifications.
   * Dialog methods are forwarded to the phone and held until
   * respondToUIRequest() is called.
   */
  handleExtensionUIRequest(
    key: string,
    active: EventProcessorSessionState,
    req: ExtensionUIRequest,
  ): void {
    if (isExtensionUIFireAndForgetMethod(req.method)) {
      const notificationReq = normalizeFireAndForgetNotificationRequest(req);
      updatePersistentExtensionUINotifications(active, notificationReq);
      this.deps.broadcast(key, buildExtensionUINotificationMessage(notificationReq));
      return;
    }

    active.pendingUIRequests.set(req.id, req);

    if (req.method === "ask") {
      const broadcastMessage = buildExtensionUIRequestMessage(active.session.id, req);
      active.pendingAsk = {
        requestId: req.id,
        questionCount: req.questions?.length ?? 0,
        broadcastMessage,
        initiatedAt: Date.now(),
      };
      this.deps.broadcast(key, broadcastMessage);
      return;
    }

    this.deps.broadcast(key, buildExtensionUIRequestMessage(active.session.id, req));
  }

  /**
   * Update session state from pi events.
   * Delegates extraction to session-protocol functions; handles persistence here.
   */
  updateSessionFromEvent(
    key: string,
    active: EventProcessorSessionState,
    event: AgentSessionEvent,
  ): void {
    const session = active.session;
    let shouldFlushNow = false;
    const pendingStopMode = active.pendingStop?.mode;
    const metrics = this.deps.metrics;
    const sessionId = session.id;

    switch (event.type) {
      case "agent_start": {
        if (session.status !== "stopping") {
          session.status = "busy";
        }
        const now = Date.now();
        session.currentTurnStartedAt = now;
        active.turnStartedAt = now;
        active.turnFirstTokenRecorded = false;
        active.turnToolCallCount = 0;
        active.contextUsageBaselineTokens = session.contextTokens ?? 0;
        active.contextUsageTrailingChars = 0;
        active.contextUsageLastBroadcastAt = 0;
        active.contextUsageLastBroadcastTokens = session.contextTokens;
        break;
      }

      case "agent_end":
        session.status = pendingStopMode === "terminate" ? "stopping" : "ready";
        session.currentTurnStartedAt = undefined;
        shouldFlushNow = true;

        // Turn duration
        if (metrics && active.turnStartedAt) {
          metrics.record("server.turn_duration_ms", Date.now() - active.turnStartedAt, {
            sessionId,
          });
        }

        // Tool call count for this turn
        if (metrics && active.turnToolCallCount !== undefined) {
          metrics.record("server.turn_tool_calls", active.turnToolCallCount, { sessionId });
        }

        // Check for error: last message in agent_end has stopReason "error"
        if (metrics && "messages" in event && Array.isArray(event.messages)) {
          const lastMsg = event.messages[event.messages.length - 1];
          if (lastMsg && "stopReason" in lastMsg && lastMsg.stopReason === "error") {
            const category =
              "errorMessage" in lastMsg && typeof lastMsg.errorMessage === "string"
                ? lastMsg.errorMessage.slice(0, 64)
                : "unknown";
            metrics.record("server.turn_error", 1, { sessionId, category });
          }
        }

        active.turnStartedAt = undefined;
        break;

      case "message_start": {
        if (event.message.role === "user") {
          this.addEstimatedContextChars(key, active, estimatePiMessageChars(event.message));
        }
        break;
      }

      case "message_update": {
        // Track server-side TTFT: first text_delta or thinking_delta in the turn
        const evt = "assistantMessageEvent" in event ? event.assistantMessageEvent : undefined;
        if (
          metrics &&
          active.turnStartedAt &&
          !active.turnFirstTokenRecorded &&
          evt &&
          (evt.type === "text_delta" || evt.type === "thinking_delta")
        ) {
          metrics.record("server.turn_ttft_ms", Date.now() - active.turnStartedAt, { sessionId });
          active.turnFirstTokenRecorded = true;
        }
        if (evt?.type === "text_delta" && typeof evt.delta === "string") {
          this.addEstimatedContextChars(key, active, evt.delta.length);
        } else if (evt?.type === "thinking_delta" && typeof evt.delta === "string") {
          this.addEstimatedContextChars(key, active, evt.delta.length);
        }
        break;
      }

      case "tool_execution_start":
        updateSessionChangeStats(session, event.toolName, event.args);
        this.maybeEmitGitStatus(key, session, event.toolName);
        if (active.turnToolCallCount !== undefined) {
          active.turnToolCallCount++;
        }
        break;

      case "tool_execution_end":
        this.maybeEmitGitStatus(key, session, event.toolName);
        this.addEstimatedContextChars(key, active, estimateToolResultChars(event.result));
        break;

      case "message_end":
        if (event.message.role === "user" && this.deps.recordUserMessagesFromEvents) {
          const content = extractQueuedUserText(event.message).trim();
          if (content) {
            appendSessionMessage(session, {
              role: "user",
              content,
              timestamp: Date.now(),
            });
          }
        } else {
          applyMessageEndToSession(session, event.message);
          if (event.message.role === "assistant") {
            active.contextUsageBaselineTokens =
              session.contextTokens ?? active.contextUsageBaselineTokens;
            active.contextUsageTrailingChars = 0;
            this.broadcastContextUsageState(key, active, { force: true });
          }
        }

        // Record token usage and cost from message_end
        if (metrics && event.message) {
          const msg = event.message as unknown as Record<string, unknown>;
          const usage =
            msg.usage && typeof msg.usage === "object"
              ? (msg.usage as Record<string, unknown>)
              : null;
          if (usage) {
            if (typeof usage.input === "number") {
              metrics.record("server.turn_input_tokens", usage.input, { sessionId });
            }
            if (typeof usage.output === "number") {
              metrics.record("server.turn_output_tokens", usage.output, { sessionId });
            }
            const cost =
              usage.cost && typeof usage.cost === "object"
                ? (usage.cost as Record<string, unknown>)
                : null;
            if (cost && typeof cost.total === "number") {
              metrics.record("server.turn_cost", Math.round(cost.total * 1_000_000), { sessionId });
            }
          }
        }
        break;

      case "auto_retry_start":
        if (metrics) {
          const attempt =
            "attempt" in event && typeof event.attempt === "number" ? event.attempt : 1;
          metrics.record("server.auto_retry", 1, { sessionId, attempt: String(attempt) });
        }
        break;

      case "compaction_start":
        active.compactionStartedAt = Date.now();
        break;

      case "compaction_end": {
        const aborted = event.aborted === true;
        const willRetry = event.willRetry === true;

        if (!aborted) {
          incrementSessionCompactionCount(session);
        }

        if (metrics) {
          // Duration
          if (active.compactionStartedAt) {
            metrics.record("server.compaction_ms", Date.now() - active.compactionStartedAt, {
              sessionId,
            });
          }
          // Result
          const result = aborted ? "aborted" : willRetry ? "will_retry" : "success";
          metrics.record("server.compaction_result", 1, { sessionId, result });
        }
        active.compactionStartedAt = undefined;
        break;
      }
    }

    session.lastActivity = Date.now();

    if (shouldFlushNow) {
      this.deps.persistSessionNow(key, session);
      return;
    }

    this.deps.markSessionDirty(key);
  }

  private addEstimatedContextChars(
    key: string,
    active: EventProcessorSessionState,
    chars: number,
  ): void {
    if (chars <= 0) {
      return;
    }

    active.contextUsageBaselineTokens ??= active.session.contextTokens ?? 0;
    active.contextUsageTrailingChars = (active.contextUsageTrailingChars ?? 0) + chars;
    this.broadcastContextUsageState(key, active);
  }

  private broadcastContextUsageState(
    key: string,
    active: EventProcessorSessionState,
    options: { force?: boolean } = {},
  ): void {
    const baseline = active.contextUsageBaselineTokens ?? active.session.contextTokens;
    if (baseline === undefined) {
      return;
    }

    const estimatedTokens =
      baseline + estimateTokensFromChars(active.contextUsageTrailingChars ?? 0);
    const previousTokens = active.contextUsageLastBroadcastTokens;
    const tokenDelta =
      previousTokens === undefined
        ? Number.POSITIVE_INFINITY
        : Math.abs(estimatedTokens - previousTokens);
    const now = Date.now();
    const elapsedMs = now - (active.contextUsageLastBroadcastAt ?? 0);

    if (
      !options.force &&
      tokenDelta < SessionEventProcessor.CONTEXT_USAGE_BROADCAST_MIN_TOKEN_DELTA &&
      elapsedMs < SessionEventProcessor.CONTEXT_USAGE_BROADCAST_MIN_INTERVAL_MS
    ) {
      return;
    }

    if (active.session.contextTokens !== estimatedTokens) {
      active.session.contextTokens = estimatedTokens;
    }
    active.contextUsageLastBroadcastAt = now;
    active.contextUsageLastBroadcastTokens = estimatedTokens;
    this.deps.broadcast(key, { type: "state", session: active.session });
    this.deps.markSessionDirty(key);
  }

  completeAskRequest(
    active: Pick<EventProcessorSessionState, "pendingAsk" | "session">,
    cancelled: boolean,
  ): void {
    const ask = active.pendingAsk;
    if (!ask) {
      return;
    }

    const metrics = this.deps.metrics;
    if (metrics && ask.initiatedAt) {
      metrics.record("server.ask_round_trip_ms", Date.now() - ask.initiatedAt, {
        sessionId: active.session.id,
        cancelled: cancelled ? "true" : "false",
        questionCount: String(ask.questionCount),
      });
    }

    active.pendingAsk = undefined;
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
      }, SessionEventProcessor.GIT_STATUS_DEBOUNCE_MS),
    );
  }

  private emitGitStatusNow(key: string, wsId: string): void {
    const workspace = this.deps.storage.getWorkspace(wsId);
    if (!workspace?.hostMount) return;
    if (workspace.gitStatusEnabled === false) return;

    void getGitStatus(workspace.hostMount)
      .then((status) => {
        if (!status.isGitRepo) return;
        this.deps.broadcast(key, {
          type: "git_status",
          workspaceId: wsId,
          status,
        });
      })
      .catch(() => {
        // Silently ignore git errors
      });
  }
}

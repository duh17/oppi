import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";

import { getGitStatus } from "./git-status.js";
import type { MobileRendererRegistry } from "./mobile-renderer.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import {
  applyMessageEndToSession,
  incrementSessionCompactionCount,
  updateSessionChangeStats,
  type TranslationContext,
} from "./session-protocol.js";
import type { PendingStop } from "./session-stop.js";
import type { Storage } from "./storage.js";
import type { AskQuestion, Session, ServerMessage } from "./types.js";

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
}

/** Fire-and-forget UI methods (no response needed) */
const FIRE_AND_FORGET_METHODS = new Set([
  "notify",
  "setStatus",
  "setWidget",
  "setTitle",
  "set_editor_text",
]);

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
  partialResults: Map<string, string>;
  streamedAssistantText: string;
  hasStreamedThinking: boolean;
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
}

export interface SessionEventProcessorDeps {
  storage: Storage;
  mobileRenderers: MobileRendererRegistry;
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
}

export class SessionEventProcessor {
  private gitStatusTimers: Map<string, NodeJS.Timeout> = new Map();
  private static readonly GIT_STATUS_DEBOUNCE_MS = 2000;

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
    if (FIRE_AND_FORGET_METHODS.has(req.method)) {
      this.deps.broadcast(key, {
        type: "extension_ui_notification",
        method: req.method,
        message: req.message,
        notifyType: req.notifyType,
        statusKey: req.statusKey,
        statusText: req.statusText,
        title: req.title,
        text: req.text,
        widgetKey: req.widgetKey,
        widgetLines: req.widgetLines,
        widgetPlacement: req.widgetPlacement,
      });
      return;
    }

    active.pendingUIRequests.set(req.id, req);

    if (req.method === "ask") {
      const broadcastMessage = this.buildAskBroadcastMessage(active.session.id, req);
      active.pendingAsk = {
        requestId: req.id,
        questionCount: req.questions?.length ?? 0,
        broadcastMessage,
        initiatedAt: Date.now(),
      };
      this.deps.broadcast(key, broadcastMessage);
      return;
    }

    this.broadcastDialogRequest(key, active.session.id, req);
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
        break;

      case "message_end":
        applyMessageEndToSession(session, event.message);

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

  private buildAskBroadcastMessage(
    sessionId: string,
    req: Pick<
      ExtensionUIRequest,
      "id" | "method" | "questions" | "allowCustom" | "timeout" | "timeoutAt"
    >,
  ): ServerMessage {
    return {
      type: "extension_ui_request",
      id: req.id,
      sessionId,
      method: req.method,
      questions: req.questions,
      allowCustom: req.allowCustom,
      timeout: req.timeout,
      timeoutAt: req.timeoutAt,
    };
  }

  private broadcastDialogRequest(key: string, sessionId: string, req: ExtensionUIRequest): void {
    this.deps.broadcast(key, {
      type: "extension_ui_request",
      id: req.id,
      sessionId,
      method: req.method,
      title: req.title,
      options: req.options,
      message: req.message,
      placeholder: req.placeholder,
      prefill: req.prefill,
      timeout: req.timeout,
      timeoutAt: req.timeoutAt,
    });
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

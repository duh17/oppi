import type { AgentSessionEvent } from "@mariozechner/pi-coding-agent";

import { getGitStatus } from "./git-status.js";
import type { MobileRendererRegistry } from "./mobile-renderer.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import {
  applyMessageEndToSession,
  updateSessionChangeStats,
  type TranslationContext,
} from "./session-protocol.js";
import type { PendingStop } from "./session-stop.js";
import type { Storage } from "./storage.js";
import type { Session, ServerMessage } from "./types.js";

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

/** Fire-and-forget UI methods (no response needed) */
const FIRE_AND_FORGET_METHODS = new Set([
  "notify",
  "setStatus",
  "setWidget",
  "setTitle",
  "set_editor_text",
]);

/** Server-side state for ask tool interception. */
export interface PendingAskState {
  /** ID of the synthetic ask request sent to iOS. */
  requestId: string;
  /** Questions from tool args (ordered). */
  questions: Array<{ id: string; question: string; multiSelect?: boolean }>;
  /** Extension select/input requests deferred until iOS responds. */
  deferred: Array<{ id: string; req: ExtensionUIRequest }>;
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
  /** Active ask tool — defers extension select() calls until iOS responds. */
  pendingAsk?: PendingAskState;
  /** Timestamp (ms) when the current turn started (agent_start). */
  turnStartedAt?: number;
  /** Whether the first text/thinking token has been recorded for the current turn. */
  turnFirstTokenRecorded?: boolean;
  /** Number of tool_execution_start events in the current turn. */
  turnToolCallCount?: number;
}

export interface SessionEventProcessorDeps {
  storage: Storage;
  mobileRenderers: MobileRendererRegistry;
  broadcast: (key: string, message: ServerMessage) => void;
  persistSessionNow: (key: string, session: Session) => void;
  markSessionDirty: (key: string) => void;
  /** Respond to a pending extension UI request (ask deferred resolution). */
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
    };
  }

  /**
   * Handle extension_ui_request from pi.
   * Fire-and-forget methods are forwarded as notifications.
   * Dialog methods (select, confirm, input, editor) are forwarded
   * to the phone and held until respondToUIRequest() is called.
   */
  handleExtensionUIRequest(
    key: string,
    active: EventProcessorSessionState,
    req: ExtensionUIRequest,
  ): void {
    if (FIRE_AND_FORGET_METHODS.has(req.method)) {
      // Forward as notification (pick relevant fields)
      this.deps.broadcast(key, {
        type: "extension_ui_notification",
        method: req.method,
        message: req.message,
        notifyType: req.notifyType,
        statusKey: req.statusKey,
        statusText: req.statusText,
      });
      return;
    }

    // Ask interception: defer extension's select/input calls while the iOS
    // AskCard is active. They'll be resolved when iOS responds to the ask.
    if (active.pendingAsk && (req.method === "select" || req.method === "input")) {
      active.pendingUIRequests.set(req.id, req);
      active.pendingAsk.deferred.push({ id: req.id, req });
      return;
    }

    // Normal dialog — track and forward to phone
    active.pendingUIRequests.set(req.id, req);
    this.deps.broadcast(key, {
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
      case "agent_start":
        if (session.status !== "stopping") {
          session.status = "busy";
        }
        active.turnStartedAt = Date.now();
        active.turnFirstTokenRecorded = false;
        active.turnToolCallCount = 0;
        break;

      case "agent_end":
        session.status = pendingStopMode === "terminate" ? "stopping" : "ready";
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
        if (event.toolName === "ask" && event.args?.questions) {
          this.initiateAskFlow(key, active, event.args);
        }
        if (active.turnToolCallCount !== undefined) {
          active.turnToolCallCount++;
        }
        break;

      case "tool_execution_end":
        if (event.toolName === "ask") {
          active.pendingAsk = undefined;
        }
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
    }

    session.lastActivity = Date.now();

    if (shouldFlushNow) {
      this.deps.persistSessionNow(key, session);
      return;
    }

    this.deps.markSessionDirty(key);
  }

  /** Send structured ask request to iOS. Extension select() calls are deferred. */
  private initiateAskFlow(
    key: string,
    active: EventProcessorSessionState,
    args: Record<string, unknown>,
  ): void {
    const questions = args.questions as Array<{
      id: string;
      question: string;
      options?: Array<{ value: string; label: string; description?: string }>;
      multiSelect?: boolean;
    }>;
    if (!Array.isArray(questions) || questions.length === 0) return;

    const requestId = `ask-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;

    const broadcastMessage: ServerMessage = {
      type: "extension_ui_request",
      id: requestId,
      sessionId: active.session.id,
      method: "ask",
      questions: questions.map((q) => ({
        id: q.id,
        question: q.question,
        options: q.options ?? [],
        multiSelect: q.multiSelect,
      })),
      allowCustom: (args.allowCustom as boolean) ?? true,
      timeout: 120000,
    };

    active.pendingAsk = {
      requestId,
      questions: questions.map((q) => ({
        id: q.id,
        question: q.question,
        multiSelect: q.multiSelect,
      })),
      deferred: [],
      broadcastMessage,
      initiatedAt: Date.now(),
    };

    // Register as pending so the iOS response is accepted
    active.pendingUIRequests.set(requestId, {
      type: "extension_ui_request",
      id: requestId,
      method: "ask",
    });

    this.deps.broadcast(key, broadcastMessage);
  }

  /** Resolve deferred select/input requests using iOS ask answers. */
  resolveAskDeferred(
    key: string,
    active: Pick<EventProcessorSessionState, "pendingAsk" | "session">,
    answers: Record<string, string | string[]>,
    cancelled: boolean,
  ): void {
    const ask = active.pendingAsk;
    if (!ask) return;

    // Record ask extension round-trip time
    const metrics = this.deps.metrics;
    if (metrics && ask.initiatedAt) {
      metrics.record("server.ask_round_trip_ms", Date.now() - ask.initiatedAt, {
        sessionId: active.session.id,
        cancelled: cancelled ? "true" : "false",
        questionCount: String(ask.questions.length),
      });
    }

    for (let i = 0; i < ask.deferred.length; i++) {
      const { id, req } = ask.deferred[i];
      const question = ask.questions[i];

      if (cancelled) {
        this.deps.respondToUIRequest(key, { type: "extension_ui_response", id, cancelled: true });
        continue;
      }

      if (!question) {
        this.deps.respondToUIRequest(key, { type: "extension_ui_response", id, cancelled: true });
        continue;
      }

      const answer = answers[question.id];
      if (answer === undefined) {
        // Ignored — cancel this select so the extension skips it
        this.deps.respondToUIRequest(key, { type: "extension_ui_response", id, cancelled: true });
      } else if (req.method === "select" && req.options) {
        // Match answer value back to option label
        const value = Array.isArray(answer) ? answer[0] : answer;
        const label =
          req.options.find((o) => o.toLowerCase().includes(value?.toLowerCase() ?? "")) ??
          req.options.find((o) => o === value) ??
          value;
        this.deps.respondToUIRequest(key, { type: "extension_ui_response", id, value: label });
      } else {
        const text = Array.isArray(answer) ? answer.join(", ") : answer;
        this.deps.respondToUIRequest(key, { type: "extension_ui_response", id, value: text });
      }
    }

    ask.deferred = [];
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

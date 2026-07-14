import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";

import type { ExtensionUIState } from "./extension-ui-state.js";
import { getGitStatus } from "./git-status.js";
import { resolveWorkspaceWorktree } from "./worktrees.js";
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
import { normalizeMutationToolName } from "./tool-mutations.js";
import type { Session, ServerMessage } from "./types.js";

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

export interface EventProcessorSessionState extends ExtensionUIState {
  session: Session;
  partialResults: Map<string, string>;
  streamedAssistantText: string;
  hasStreamedThinking: boolean;
  streamedThinkingContentIndexes: Set<number>;
  currentThinkingContentIndex?: number;
  pendingStop?: PendingStop;
  /** Tool names per toolCallId — tracked for shell preview decisions. */
  toolNames: Map<string, string>;
  /** Tool call arguments per toolCallId, retained until the final tool result. */
  toolArgs?: Map<string, Record<string, unknown>>;
  /** Last time a shell preview snapshot was sent per toolCallId (ms). */
  shellPreviewLastSent: Map<string, number>;
  /** Last serialized streaming tool args emitted per toolCallId this turn. */
  streamingToolUpdatesSeen: Map<string, string>;
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
      toolArgs: active.toolArgs,
      shellPreviewLastSent: active.shellPreviewLastSent,
      streamingToolUpdatesSeen: active.streamingToolUpdatesSeen,
    };
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
        // Pi may emit agent_end before scheduling an automatic retry. Keep the
        // session busy until the corresponding agent_settled event proves that
        // no more agent work remains.
        session.currentTurnStartedAt = undefined;

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

      case "agent_settled":
        session.status = pendingStopMode === "terminate" ? "stopping" : "ready";
        session.currentTurnStartedAt = undefined;
        shouldFlushNow = true;
        break;

      case "session_info_changed": {
        const nextName = event.name?.trim();
        if (nextName) {
          session.name = nextName;
        } else {
          delete session.name;
        }
        shouldFlushNow = true;
        break;
      }

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
      (tokenDelta < SessionEventProcessor.CONTEXT_USAGE_BROADCAST_MIN_TOKEN_DELTA ||
        elapsedMs < SessionEventProcessor.CONTEXT_USAGE_BROADCAST_MIN_INTERVAL_MS)
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
    const name = normalizeMutationToolName(toolName);
    if (name !== "edit" && name !== "write" && name !== "bash") return;

    const wsId = session.workspaceId;
    if (!wsId) return;
    const worktreeId = session.worktreeId ?? "main";
    const timerKey = `${wsId}:${worktreeId}`;

    // Debounce per workspace/worktree — cancel any pending timer and restart
    const existing = this.gitStatusTimers.get(timerKey);
    if (existing) clearTimeout(existing);

    this.gitStatusTimers.set(
      timerKey,
      setTimeout(() => {
        this.gitStatusTimers.delete(timerKey);
        this.emitGitStatusNow(key, wsId, worktreeId);
      }, SessionEventProcessor.GIT_STATUS_DEBOUNCE_MS),
    );
  }

  private emitGitStatusNow(key: string, wsId: string, worktreeId: string): void {
    const workspace = this.deps.storage.getWorkspace(wsId);
    if (!workspace?.hostMount) return;
    if (workspace.gitStatusEnabled === false) return;

    const worktreePath = resolveWorkspaceWorktree(workspace, worktreeId, {
      dataDir: this.deps.storage.getDataDir(),
    })?.path;
    if (!worktreePath) return;

    void getGitStatus(worktreePath)
      .then((status) => {
        if (!status.isGitRepo) return;
        this.deps.broadcast(key, {
          type: "git_status",
          workspaceId: wsId,
          worktreeId,
          status,
        });
      })
      .catch(() => {
        // Silently ignore git errors
      });
  }
}

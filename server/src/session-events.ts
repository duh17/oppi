import type { ToolOutputSnapshots } from "./tool-output-sidecar.js";
import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";

import type { ExtensionUIState } from "./extension-ui-state.js";
import { gitTrustForWorkspace } from "./git-safe.js";
import { getGitStatus } from "./git-status.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import {
  programRunFor,
  syncProgramStatus,
  trackProgramRunEvent,
  type ProgramRunTracker,
  type ProgramStatusChangeListener,
} from "./program-status.js";
import { resolveWorkspaceWorktree } from "./worktrees.js";
import {
  isWorktreeSession,
  noteWorktreeActivity,
  readWorktreeChanges,
  storedWorktreeChangeStats,
} from "./session-git-changes.js";
import { buildSessionSummary } from "./session-summary.js";
import type { MobileRendererRegistry } from "./mobile-renderer.js";
import type { EventTags } from "./telemetry/catalog.js";
import type { ServerTelemetry } from "./telemetry/server-telemetry.js";
import {
  appendSessionMessage,
  applyMessageEndToSession,
  incrementSessionCompactionCount,
  setSessionWorktreeChangeStats,
  updateSessionChangeStats,
  type TranslationContext,
} from "./session-protocol.js";
import { extractQueuedUserText } from "./session-queue-utils.js";
import type { PendingStop } from "./session-stop.js";
import { sessionMetricRuntime } from "./session-runtime-capabilities.js";
import type { Storage } from "./storage.js";
import { isThinkingLevel } from "./thinking-levels.js";
import { normalizeMutationToolName } from "./tool-mutations.js";
import type { Session, ServerMessage } from "./types.js";

const log = createLogger({ base: { component: "session_events" } });

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

const SAFE_TOOL_NAME = /^[A-Za-z0-9._-]{1,64}$/;

/** Split canonical `provider/modelId` without inventing a provider. */
function splitExactProviderModel(
  model: string | undefined,
): { provider: string; model: string } | undefined {
  if (!model) return undefined;
  const slash = model.indexOf("/");
  if (slash <= 0 || slash === model.length - 1) return undefined;
  return { provider: model.slice(0, slash), model: model.slice(slash + 1) };
}

function sanitizeToolName(toolName: unknown): string | undefined {
  if (typeof toolName !== "string") return undefined;
  const trimmed = toolName.trim();
  if (!SAFE_TOOL_NAME.test(trimmed)) return undefined;
  return trimmed;
}

type TurnErrorKind = NonNullable<EventTags<"server.turn">["error_kind"]>;

function classifyTurnError(errorMessage: unknown): TurnErrorKind {
  if (typeof errorMessage !== "string") return "other";
  const message = errorMessage.toLowerCase();
  if (message.includes("request_too_large") || message.includes("context_length")) {
    return "request_too_large";
  }
  if (
    message.includes("overloaded") ||
    message.includes("service_unavailable") ||
    message.includes("server is busy")
  ) {
    return "overloaded";
  }
  if (message.includes("rate_limit") || message.includes("rate limit") || message.includes("429")) {
    return "rate_limit";
  }
  if (
    message.includes("unauthorized") ||
    message.includes("authentication") ||
    message.includes("invalid api key") ||
    message.includes("401") ||
    message.includes("403")
  ) {
    return "auth";
  }
  if (message.includes("timed out") || message.includes("timeout")) return "timeout";
  if (message.includes("connection") || message.includes("econn") || message.includes("network")) {
    return "network";
  }
  if (message.includes("json") && message.includes("parse")) return "json_parse";
  if (message.includes("terminated") || message.includes("aborted")) return "terminated";
  return "other";
}

/** Session-configured route plus a bounded configured thinking level when known. */
function routingTags(session: Session): EventTags<"server.turn_ttft"> {
  const parsed = splitExactProviderModel(session.model);
  return {
    runtime: sessionMetricRuntime(session),
    ...(parsed ? { provider: parsed.provider, model: parsed.model } : {}),
    ...(session.thinkingLevel && isThinkingLevel(session.thinkingLevel)
      ? { thinking: session.thinkingLevel }
      : {}),
  };
}

function sessionIds(session: Session): { sessionId: string; workspaceId?: string } {
  return { sessionId: session.id, workspaceId: session.workspaceId };
}

export interface EventProcessorSessionState extends ExtensionUIState {
  session: Session;
  /** Event-folded run state behind `session.programStatus`. */
  programRun?: ProgramRunTracker;
  toolOutputSnapshots: ToolOutputSnapshots;
  streamedAssistantText: string;
  currentThinkingContentIndex?: number;
  pendingStop?: PendingStop;
  /** Tool names per toolCallId — tracked for terminal-kind routing. */
  toolNames: Map<string, string>;
  /** Tool call arguments per toolCallId, retained until the final tool result. */
  toolArgs?: Map<string, Record<string, unknown>>;
  /** Last serialized streaming tool args emitted per toolCallId this turn. */
  streamingToolUpdatesSeen: Map<string, string>;
  /** Last tail-preview send time per terminal call. */
  shellPreviewLastSent: Map<string, number>;
  /** Timestamp (ms) when the current turn started (agent_start). */
  turnStartedAt?: number;
  /** Whether the first text/thinking token has been recorded for the current turn. */
  turnFirstTokenRecorded?: boolean;
  /** Number of tool_execution_start events in the current turn. */
  turnToolCallCount?: number;
  /** In-flight tool starts keyed by toolCallId so concurrent calls pair correctly. */
  inflightToolStarts?: Map<string, { startedAt: number; toolName?: string }>;
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
  mobileRenderers: MobileRendererRegistry;
  broadcast: (key: string, message: ServerMessage) => void;
  persistSessionNow: (key: string, session: Session) => void;
  markSessionDirty: (key: string) => void;
  /** Server telemetry (catalog events; skipped when absent). */
  metrics?: ServerTelemetry;
  /** Mirror mode receives terminal-origin user messages as pi events. */
  recordUserMessagesFromEvents?: boolean;
  /** Called when an event changes the session's program status. */
  onProgramStatusChange?: ProgramStatusChangeListener;
}

export class SessionEventProcessor {
  private gitStatusTimers: Map<string, NodeJS.Timeout> = new Map();
  /** Drops a git-status lookup that lost the debounce race. */
  private gitStatusGeneration = new Map<string, number>();
  private static readonly GIT_STATUS_DEBOUNCE_MS = 2000;
  /** In-flight turn-end worktree reads; `again` queues one more after a settle mid-read. */
  private readonly worktreeChangeReads = new Map<string, { again: boolean }>();
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
      toolOutputSnapshots: active.toolOutputSnapshots,
      streamedAssistantText: active.streamedAssistantText,
      currentThinkingContentIndex: active.currentThinkingContentIndex,
      mobileRenderers: this.deps.mobileRenderers,
      toolNames: active.toolNames,
      toolArgs: active.toolArgs,
      streamingToolUpdatesSeen: active.streamingToolUpdatesSeen,
      shellPreviewLastSent: active.shellPreviewLastSent,
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
        active.inflightToolStarts = new Map();
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

        if (metrics) {
          // An agent_end whose last message stopped with "error" is a failed turn.
          const lastMsg =
            "messages" in event && Array.isArray(event.messages)
              ? event.messages[event.messages.length - 1]
              : undefined;
          const failed = Boolean(
            lastMsg && "stopReason" in lastMsg && lastMsg.stopReason === "error",
          );
          metrics.record(
            "server.turn",
            {
              ...(active.turnStartedAt ? { duration_ms: Date.now() - active.turnStartedAt } : {}),
              ...(active.turnToolCallCount !== undefined
                ? { tool_calls: active.turnToolCallCount }
                : {}),
            },
            {
              ...routingTags(session),
              status: failed ? "error" : "ok",
              ...(failed && lastMsg
                ? {
                    error_kind: classifyTurnError(
                      "errorMessage" in lastMsg ? lastMsg.errorMessage : undefined,
                    ),
                  }
                : {}),
            },
            sessionIds(session),
          );
        }

        active.turnStartedAt = undefined;
        active.inflightToolStarts = undefined;
        break;

      case "agent_settled":
        session.status = pendingStopMode === "terminate" ? "stopping" : "ready";
        session.currentTurnStartedAt = undefined;
        shouldFlushNow = true;
        // Settled, not agent_end: Pi emits agent_end before an automatic retry, and
        // the worktree is read once per finished run.
        this.refreshWorktreeChanges(key, session);
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
          metrics.record(
            "server.turn_ttft",
            { duration_ms: Date.now() - active.turnStartedAt },
            routingTags(session),
            sessionIds(session),
          );
          active.turnFirstTokenRecorded = true;
        }
        if (evt?.type === "text_delta" && typeof evt.delta === "string") {
          this.addEstimatedContextChars(key, active, evt.delta.length);
        } else if (evt?.type === "thinking_delta" && typeof evt.delta === "string") {
          this.addEstimatedContextChars(key, active, evt.delta.length);
        }
        break;
      }

      case "tool_execution_start": {
        updateSessionChangeStats(session, event.toolName, event.args);
        this.maybeEmitGitStatus(key, session, event.toolName);
        if (active.turnToolCallCount !== undefined) {
          active.turnToolCallCount++;
        }
        const toolCallId =
          "toolCallId" in event &&
          typeof event.toolCallId === "string" &&
          event.toolCallId.length > 0
            ? event.toolCallId
            : undefined;
        if (toolCallId) {
          active.inflightToolStarts ??= new Map();
          active.inflightToolStarts.set(toolCallId, {
            startedAt: Date.now(),
            toolName: sanitizeToolName(event.toolName),
          });
        }
        break;
      }

      case "tool_execution_end": {
        this.maybeEmitGitStatus(key, session, event.toolName);
        // In-memory generation bump; the cached worktree change set is stale after any tool.
        noteWorktreeActivity(session);
        this.addEstimatedContextChars(key, active, estimateToolResultChars(event.result));
        if (metrics) {
          const toolCallId =
            "toolCallId" in event &&
            typeof event.toolCallId === "string" &&
            event.toolCallId.length > 0
              ? event.toolCallId
              : undefined;
          const started = toolCallId ? active.inflightToolStarts?.get(toolCallId) : undefined;
          if (toolCallId) active.inflightToolStarts?.delete(toolCallId);
          const tool = started?.toolName ?? sanitizeToolName(event.toolName) ?? "unknown";
          metrics.record(
            "server.tool_call",
            started ? { duration_ms: Date.now() - started.startedAt } : {},
            { ...routingTags(session), tool, status: event.isError === true ? "error" : "ok" },
            sessionIds(session),
          );
        }
        break;
      }

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
            const cost =
              usage.cost && typeof usage.cost === "object"
                ? (usage.cost as Record<string, unknown>)
                : null;
            metrics.record(
              "server.turn_usage",
              {
                input_tokens: typeof usage.input === "number" ? usage.input : 0,
                output_tokens: typeof usage.output === "number" ? usage.output : 0,
                cost_usd_micros:
                  cost && typeof cost.total === "number" ? Math.round(cost.total * 1_000_000) : 0,
              },
              routingTags(session),
              sessionIds(session),
            );
          }
        }
        break;

      case "auto_retry_start":
        if (metrics) {
          const attempt =
            "attempt" in event && typeof event.attempt === "number" ? event.attempt : 1;
          metrics.record(
            "server.auto_retry",
            { attempt },
            routingTags(session),
            sessionIds(session),
          );
        }
        break;

      case "compaction_start":
        active.compactionStartedAt = Date.now();
        break;

      case "compaction_end": {
        const aborted = event.aborted === true;
        const willRetry = event.willRetry === true;
        const failed =
          typeof event.errorMessage === "string" && event.errorMessage.trim().length > 0;

        if (!aborted && !failed) {
          incrementSessionCompactionCount(session);
        }

        if (metrics) {
          // Aborted wins, then a real error, then a retry-without-error.
          const status = aborted ? "cancelled" : failed ? "error" : "ok";
          metrics.record(
            "server.compaction",
            active.compactionStartedAt
              ? { duration_ms: Date.now() - active.compactionStartedAt }
              : {},
            {
              ...routingTags(session),
              status,
              ...(status === "ok" && willRetry ? { result: "will_retry" as const } : {}),
            },
            sessionIds(session),
          );
        }
        active.compactionStartedAt = undefined;
        break;
      }
    }

    session.lastActivity = Date.now();

    // Program status follows the same events Pi's own terminal reporter reads; the lifecycle
    // status above is already updated, so one sync sees both.
    trackProgramRunEvent(programRunFor(active), event);
    const programChange = syncProgramStatus(active);
    if (programChange.changed) this.deps.onProgramStatusChange?.(session, programChange);

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

    const generation = (this.gitStatusGeneration.get(timerKey) ?? 0) + 1;
    this.gitStatusGeneration.set(timerKey, generation);
    this.gitStatusTimers.set(
      timerKey,
      setTimeout(() => {
        this.gitStatusTimers.delete(timerKey);
        // A rejected probe from a timer would reach the process handler and stop the server.
        this.emitGitStatusNow(key, wsId, worktreeId, timerKey, generation).catch((err: unknown) => {
          log.warn("session_events.git_status_failed", {
            workspaceId: wsId,
            worktreeId,
            error: safeErrorMessage(err),
          });
        });
      }, SessionEventProcessor.GIT_STATUS_DEBOUNCE_MS),
    );
  }

  private async emitGitStatusNow(
    key: string,
    wsId: string,
    worktreeId: string,
    timerKey: string,
    generation: number,
  ): Promise<void> {
    if (this.gitStatusGeneration.get(timerKey) !== generation) return;
    const workspace = this.deps.storage.getWorkspace(wsId);
    if (!workspace || workspace.gitStatusEnabled === false) return;

    const worktreePath = (
      await resolveWorkspaceWorktree(workspace, worktreeId, {
        dataDir: this.deps.storage.getDataDir(),
      })
    )?.path;
    if (!worktreePath || this.gitStatusGeneration.get(timerKey) !== generation) return;

    void getGitStatus(worktreePath, gitTrustForWorkspace(workspace))
      .then((status) => {
        if (!status.isGitRepo || this.gitStatusGeneration.get(timerKey) !== generation) return;
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

  /**
   * Turn end in a worktree session: read the worktree's changes from git once and
   * store them on `changeStats.worktree`, so session lists show the count without
   * running git. A settle that lands while a read runs queues one more read. A
   * worktree that is gone (landed and removed) keeps the last stored value.
   */
  private refreshWorktreeChanges(key: string, session: Session): void {
    const workspaceId = session.workspaceId;
    if (!workspaceId || !isWorktreeSession(session)) return;
    const inFlight = this.worktreeChangeReads.get(key);
    if (inFlight) {
      inFlight.again = true;
      return;
    }
    const state = { again: false };
    this.worktreeChangeReads.set(key, state);

    const run = async (): Promise<void> => {
      try {
        do {
          state.again = false;
          const workspace = this.deps.storage.getWorkspace(workspaceId);
          if (!workspace) return;
          const result = await readWorktreeChanges(
            { session, workspace, dataDir: this.deps.storage.getDataDir() },
            { fresh: true },
          );
          if (result.kind !== "ok") continue;
          setSessionWorktreeChangeStats(session, storedWorktreeChangeStats(result.snapshot));
          this.deps.markSessionDirty(key);
          this.deps.broadcast(key, {
            type: "session_summary",
            summary: buildSessionSummary(session),
          });
        } while (state.again);
      } finally {
        // Same tick as the last `again` check, so a settle after it starts a new read.
        this.worktreeChangeReads.delete(key);
      }
    };
    run().catch((err: unknown) => {
      log.warn("session_events.worktree_changes_failed", {
        sessionId: session.id,
        error: safeErrorMessage(err),
      });
    });
  }
}

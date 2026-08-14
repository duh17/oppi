import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";

import {
  asCacheMissAssistantMessage,
  formatCacheMissNotice,
  observeCacheMiss,
  resetCacheMissTracker,
  shouldDisplayCacheMissForMessage,
  type CacheMissModelPriceSource,
  type CacheMissNotice,
  type CacheMissTrackerState,
} from "./cache-miss.js";
import {
  handleExtensionUIRequest as handleExtensionUIRequestState,
  settleExtensionUIRequest,
} from "./extension-ui-state.js";
import type { ExtensionAudioStreamEvent, PiMessage, SessionBackendEvent } from "./pi-events.js";
import { createLogger } from "./logger.js";
import {
  extractAssistantText,
  extractToolFullOutputPath,
  projectAssistantMessageContent,
  normalizeUserFacingError,
  translatePiEvent,
} from "./session-protocol.js";
import { hasToolMediaDetails, materializeAgentEventMedia } from "./session-agent-event-media.js";
import type { EventProcessorSessionState, SessionEventProcessor } from "./session-events.js";
import type { SdkBackend } from "./sdk-backend.js";
import {
  createResourceUsageTraceEventId,
  resourceUsageTraceEventId,
  type ResourceUsageService,
  type ResourceUsageSkillInstructionReadEvidence,
  type ResourceUsageToolEvidence,
} from "./resource-usage-service.js";
import type { SessionStopCoordinator } from "./session-stop.js";
import type { SessionTurnCoordinator, TurnSessionState } from "./session-turns.js";
import { materializeToolMediaDetails } from "./session-attachments.js";
import { buildSessionSummary, sessionSummaryFingerprint } from "./session-summary.js";
import {
  mergeToolTuiRenderSnapshot,
  renderToolTuiResultSnapshot,
  shouldAttachToolTuiRenderSnapshot,
} from "./tool-tui-renderer.js";
import { normalizeMutationToolName } from "./tool-mutations.js";
import type { ServerMessage, SessionSummary } from "./types.js";

export interface SessionAgentEventState extends EventProcessorSessionState, TurnSessionState {
  subscribers: Set<(msg: ServerMessage) => void>;
  sdkBackend?: SdkBackend;
  toolFullOutputPaths: Map<string, string>;
  cacheMissTracker: CacheMissTrackerState;
  showCacheMissNotices: boolean;
  cacheMissModelPriceSource?: CacheMissModelPriceSource;
}

const log = createLogger({ base: { component: "session_agent_events" } });

export interface SessionAgentEventCoordinatorDeps {
  getActiveSession: (key: string) => SessionAgentEventState | undefined;
  eventProcessor: SessionEventProcessor;
  stopCoordinator: Pick<SessionStopCoordinator, "finishPendingStopOnAgentEnd">;
  turnCoordinator: SessionTurnCoordinator;
  broadcast: (key: string, message: ServerMessage) => void;
  resetIdleTimer: (key: string) => void;
  markQueuedMessageStarted?: (key: string, message: PiMessage) => void;
  schedulePostCompactionQueueFlush?: (key: string) => void;
  resumeQueuedCompactions?: (key: string) => void;
  dataDir?: string;
  trustedAttachmentSourceRoots?: string[];
  resourceUsage?: Pick<
    ResourceUsageService,
    "captureToolInvocation" | "captureSkillInstructionRead"
  >;
  resourceUsageToolEvidence?: (
    active: SessionAgentEventState,
    toolName: string,
  ) => ResourceUsageToolEvidence | undefined;
  resolveResourceUsageSkillRead?: (
    active: SessionAgentEventState,
    path: string,
  ) =>
    | ResourceUsageSkillInstructionReadEvidence
    | undefined
    | Promise<ResourceUsageSkillInstructionReadEvidence | undefined>;
}

interface PendingResourceUsageRead {
  producerId: string;
  skill: Promise<ResourceUsageSkillInstructionReadEvidence | undefined>;
}

interface ResourceUsageToolCallState {
  pendingReads: Map<string, PendingResourceUsageRead[]>;
  inFlightCaptures: number;
  released: boolean;
}

function resourceUsagePendingToolKey(toolCallId: string, toolName: string): string {
  return JSON.stringify([toolCallId, toolName]);
}

export class SessionAgentEventCoordinator {
  private static readonly INFO_LOGGED_EVENT_TYPES = new Set<AgentSessionEvent["type"]>([
    "agent_start",
    "agent_end",
    "agent_settled",
    "compaction_start",
    "compaction_end",
    "auto_retry_start",
    "auto_retry_end",
  ]);

  private static readonly DEBUG_LOGGED_EVENT_TYPES = new Set<AgentSessionEvent["type"]>([
    "turn_start",
    "turn_end",
    "message_end",
    "tool_execution_start",
    "tool_execution_end",
  ]);

  private static readonly SUMMARY_BROADCAST_TYPES = new Set<AgentSessionEvent["type"]>([
    "agent_start",
    "agent_end",
    "agent_settled",
    "session_info_changed",
  ]);

  private static readonly CHANGE_SUMMARY_TOOL_NAMES = new Set(["edit", "write"]);

  private readonly lastSummaryFingerprintBySession = new Map<string, string>();
  // Only unresolved read correlation is retained. Exact producer identity is
  // journaled per physical trace event, so completed provider IDs never remain.
  private readonly resourceUsageState = new Map<string, ResourceUsageToolCallState>();

  constructor(private readonly deps: SessionAgentEventCoordinatorDeps) {}

  handlePiEvent(key: string, data: SessionBackendEvent): void {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      return;
    }

    if (data.type === "extension_ui_request") {
      handleExtensionUIRequestState(active, data, {
        broadcast: (message) => this.deps.broadcast(key, message),
      });
      return;
    }

    if (data.type === "extension_ui_request_settled") {
      settleExtensionUIRequest(active, data.id, {
        broadcastSettled: (message) => this.deps.broadcast(key, message),
        broadcastIfMissing: true,
      });
      this.deps.resetIdleTimer(key);
      return;
    }

    if (data.type === "extension_error") {
      log.error("session_agent_events.extension.error", {
        sessionId: active.session.id,
        extensionPath: data.extensionPath,
        error: data.error,
      });
      this.deps.resetIdleTimer(key);
      return;
    }

    if (data.type === "prompt_error") {
      const error = normalizeUserFacingError(data.error);
      log.error("session_agent_events.prompt.error", {
        sessionId: active.session.id,
        error,
        rawError: data.error,
      });
      this.deps.broadcast(key, { type: "error", error });
      this.deps.resetIdleTimer(key);
      return;
    }

    if (data.type === "extension_audio_stream") {
      this.handleExtensionAudioStream(key, data);
      this.deps.resetIdleTimer(key);
      return;
    }

    if (data.type === "tool_execution_start") {
      this.captureResourceUsageToolStart(active, data);
    } else if (data.type === "tool_execution_end") {
      this.captureResourceUsageToolEnd(active, data);
    }

    let event = materializeAgentEventMedia({
      event: data,
      dataDir: this.deps.dataDir,
      sessionId: active.session.id,
      trustedSourceRoots: this.deps.trustedAttachmentSourceRoots,
    });
    event = this.withToolTuiRenderSnapshot(active, event);

    active.cacheMissTracker ??= {};
    active.showCacheMissNotices ??= false;
    if (active.sdkBackend) {
      active.showCacheMissNotices = active.sdkBackend.showCacheMissNotices;
      active.cacheMissModelPriceSource = active.sdkBackend.cacheMissModelPriceSource;
    }

    let cacheMissNotice: CacheMissNotice | undefined;
    if (event.type === "compaction_end" && !event.aborted && event.result) {
      resetCacheMissTracker(active.cacheMissTracker);
    } else if (event.type === "message_end") {
      const assistantMessage = asCacheMissAssistantMessage(event.message);
      if (assistantMessage) {
        const detected = observeCacheMiss(
          active.cacheMissTracker,
          assistantMessage,
          active.cacheMissModelPriceSource,
        );
        if (
          active.showCacheMissNotices &&
          detected &&
          shouldDisplayCacheMissForMessage(assistantMessage)
        ) {
          cacheMissNotice = detected;
        }
      }
    }

    if (SessionAgentEventCoordinator.INFO_LOGGED_EVENT_TYPES.has(event.type)) {
      this.logPiEvent("info", active, event);
    } else if (SessionAgentEventCoordinator.DEBUG_LOGGED_EVENT_TYPES.has(event.type)) {
      this.logPiEvent("debug", active, event);
    }

    if (event.type === "message_start" && event.message.role === "user") {
      this.deps.markQueuedMessageStarted?.(key, event.message);
    }

    // pi may not always emit user message_start for queued steer/follow-up.
    // Reconcile from SDK queue on each turn_start so queue chips cannot linger
    // when dequeues happen without a matching message_start payload.
    if (event.type === "turn_start") {
      this.deps.markQueuedMessageStarted?.(key, {});
    }

    const ctx = this.deps.eventProcessor.translationContext(active);
    const messages = translatePiEvent(event, ctx);
    active.streamedAssistantText = ctx.streamedAssistantText;
    active.hasStreamedThinking = ctx.hasStreamedThinking;
    active.currentThinkingContentIndex = ctx.currentThinkingContentIndex;

    if (event.type === "tool_execution_end") {
      const toolCallId =
        typeof event.toolCallId === "string" && event.toolCallId.length > 0
          ? event.toolCallId
          : null;

      if (toolCallId) {
        const fullOutputPath = extractToolFullOutputPath(event.result?.details);
        if (fullOutputPath) {
          active.toolFullOutputPaths.set(toolCallId, fullOutputPath);
        }
      }
    }

    for (const message of messages) {
      if (
        message.type === "tool_end" &&
        message.details !== undefined &&
        this.deps.dataDir &&
        hasToolMediaDetails(message.details)
      ) {
        try {
          this.deps.broadcast(key, {
            ...message,
            details: materializeToolMediaDetails({
              dataDir: this.deps.dataDir,
              sessionId: active.session.id,
              toolCallId: message.toolCallId,
              details: message.details,
              trustedSourceRoots: this.deps.trustedAttachmentSourceRoots,
            }),
          });
        } catch (error) {
          log.error("session_agent_events.tool_media_attachment_materialize.failed", {
            sessionId: active.session.id,
            toolCallId: message.toolCallId,
            tool: message.tool,
            error: error instanceof Error ? error.message : String(error),
          });
          this.deps.broadcast(key, message);
        }
      } else {
        this.deps.broadcast(key, message);
      }
    }

    if (event.type === "agent_start") {
      this.deps.turnCoordinator.markNextTurnStarted(key, active);
    }

    try {
      this.deps.eventProcessor.updateSessionFromEvent(key, active, event);
    } finally {
      // Pi settlement is authoritative even if projection persistence fails.
      // Do not strand a compact that was accepted during the active turn.
      if (event.type === "agent_settled") {
        this.deps.resumeQueuedCompactions?.(key);
      }
    }

    if (event.type === "agent_end") {
      this.deps.stopCoordinator.finishPendingStopOnAgentEnd(key, active);
    }

    if (event.type === "compaction_end" && !event.aborted && !event.willRetry) {
      this.deps.schedulePostCompactionQueueFlush?.(key);
    }

    if (event.type === "message_end") {
      const role = event.message.role;
      if (role === "assistant") {
        // Keep exactly one historical frame per Pi assistant message. Older
        // clients ignore assistantContent and retain their complete aggregate
        // row; newer clients use it to reconcile text/thinking/tool order.
        this.deps.broadcast(key, {
          type: "message_end",
          role,
          content: extractAssistantText(event.message),
          assistantContent: projectAssistantMessageContent(event.message),
        });
      } else if (role === "user") {
        this.deps.broadcast(key, {
          type: "message_end",
          role,
          content: extractAssistantText(event.message),
        });
      }
      if (cacheMissNotice) {
        this.deps.broadcast(key, {
          type: "cache_miss",
          id: cacheMissNotice.id,
          message: formatCacheMissNotice(cacheMissNotice),
        });
      }
    }

    if (this.shouldBroadcastSessionSummaryAfterUpdate(event)) {
      this.broadcastSessionSummaryIfChanged(key, active, event.type);
    }

    this.deps.resetIdleTimer(key);
  }

  private captureResourceUsageToolStart(
    active: SessionAgentEventState,
    event: Extract<AgentSessionEvent, { type: "tool_execution_start" }>,
  ): void {
    if (
      (event as typeof event & { resourceUsageSkipLiveCapture?: unknown })
        .resourceUsageSkipLiveCapture === true
    ) {
      // The lifecycle marker remains authoritative for history. Do not invent a
      // second live identity when managed correlation deliberately sheds load.
      return;
    }
    const toolCallId =
      typeof event.toolCallId === "string" && event.toolCallId.length > 0
        ? event.toolCallId
        : undefined;
    if (!toolCallId) return;
    const producerId = resourceUsageTraceEventId(event) ?? createResourceUsageTraceEventId();

    try {
      const evidence =
        active.sdkBackend?.resourceUsageToolEvidence?.(event.toolName) ??
        this.deps.resourceUsageToolEvidence?.(active, event.toolName);
      this.deps.resourceUsage?.captureToolInvocation({
        session: active.session,
        runtime: active.sdkBackend ? "oppi" : "pi-tui",
        toolName: event.toolName,
        toolCallId: producerId,
        evidence,
      });

      if (event.toolName === "read") {
        const state = this.resourceUsageToolCallState(active);
        const path =
          event.args && typeof event.args === "object" && "path" in event.args
            ? (event.args as { path?: unknown }).path
            : undefined;
        const resolved =
          typeof path === "string"
            ? (active.sdkBackend?.resourceUsageSkillReadEvidence?.(path) ??
              this.deps.resolveResourceUsageSkillRead?.(active, path))
            : undefined;
        const pendingKey = resourceUsagePendingToolKey(toolCallId, event.toolName);
        const queue = state.pendingReads.get(pendingKey) ?? [];
        queue.push({ producerId, skill: Promise.resolve(resolved) });
        state.pendingReads.set(pendingKey, queue);
      }
    } catch (error) {
      const state = this.resourceUsageState.get(this.resourceUsageTraceKey(active));
      if (state) this.cleanupResourceUsageState(active, state);
      this.logResourceUsageCaptureFailure(active, error);
    }
  }

  private captureResourceUsageToolEnd(
    active: SessionAgentEventState,
    event: Extract<AgentSessionEvent, { type: "tool_execution_end" }>,
  ): void {
    const toolCallId =
      typeof event.toolCallId === "string" && event.toolCallId.length > 0
        ? event.toolCallId
        : undefined;
    if (!toolCallId || event.toolName !== "read") return;
    const state = this.resourceUsageState.get(this.resourceUsageTraceKey(active));
    const pendingKey = resourceUsagePendingToolKey(toolCallId, event.toolName);
    const queue = state?.pendingReads.get(pendingKey);
    const pending = queue?.shift();
    if (queue?.length === 0) state?.pendingReads.delete(pendingKey);
    if (!state || !pending || event.isError !== false) {
      if (state) this.cleanupResourceUsageState(active, state);
      return;
    }

    state.inFlightCaptures += 1;
    void pending.skill
      .then((skill) => {
        if (!skill || state.released) return;
        active.sdkBackend?.appendResourceUsageSkillReadMarker?.({
          producerId: pending.producerId,
          bindingToken: skill.bindingToken,
        });
        this.deps.resourceUsage?.captureSkillInstructionRead({
          session: active.session,
          runtime: active.sdkBackend ? "oppi" : "pi-tui",
          toolCallId: pending.producerId,
          skill,
        });
      })
      .catch((error: unknown) => this.logResourceUsageCaptureFailure(active, error))
      .finally(() => {
        state.inFlightCaptures -= 1;
        this.cleanupResourceUsageState(active, state);
      });
  }

  private resourceUsageToolCallState(active: SessionAgentEventState): ResourceUsageToolCallState {
    const traceKey = this.resourceUsageTraceKey(active);
    let state = this.resourceUsageState.get(traceKey);
    if (!state) {
      state = { pendingReads: new Map(), inFlightCaptures: 0, released: false };
      this.resourceUsageState.set(traceKey, state);
    }
    return state;
  }

  releaseResourceUsageSession(
    session: Pick<SessionAgentEventState["session"], "id" | "piSessionId">,
  ): void {
    const traceKey = this.resourceUsageTraceKeyForSession(session);
    const state = this.resourceUsageState.get(traceKey);
    if (state) state.released = true;
    this.resourceUsageState.delete(traceKey);
  }

  private cleanupResourceUsageState(
    active: SessionAgentEventState,
    state: ResourceUsageToolCallState,
  ): void {
    if (state.pendingReads.size > 0 || state.inFlightCaptures > 0) return;
    const traceKey = this.resourceUsageTraceKey(active);
    if (this.resourceUsageState.get(traceKey) === state) this.resourceUsageState.delete(traceKey);
  }

  private resourceUsageTraceKey(active: SessionAgentEventState): string {
    return this.resourceUsageTraceKeyForSession(active.session);
  }

  private resourceUsageTraceKeyForSession(
    session: Pick<SessionAgentEventState["session"], "id" | "piSessionId">,
  ): string {
    return session.piSessionId ?? session.id;
  }

  private logResourceUsageCaptureFailure(active: SessionAgentEventState, error: unknown): void {
    // Measurement is strictly best-effort and must never interrupt tool projection.
    log.warn("session_agent_events.resource_usage_capture_failed", {
      sessionId: active.session.id,
      error: error instanceof Error ? error.message : String(error),
    });
  }

  private shouldBroadcastSessionSummaryAfterUpdate(event: AgentSessionEvent): boolean {
    if (SessionAgentEventCoordinator.SUMMARY_BROADCAST_TYPES.has(event.type)) {
      return true;
    }

    if (event.type !== "tool_execution_start") {
      return false;
    }

    const toolName = normalizeMutationToolName(event.toolName);
    return SessionAgentEventCoordinator.CHANGE_SUMMARY_TOOL_NAMES.has(toolName);
  }

  private withToolTuiRenderSnapshot(
    active: SessionAgentEventState,
    event: AgentSessionEvent,
  ): AgentSessionEvent {
    if (event.type !== "tool_execution_end") {
      return event;
    }

    const toolName = typeof event.toolName === "string" ? event.toolName : undefined;
    if (!toolName || !shouldAttachToolTuiRenderSnapshot(toolName)) {
      return event;
    }

    const piSession = active.sdkBackend?.session;
    const toolDefinition = piSession?.getToolDefinition(toolName);
    if (!toolDefinition?.renderResult) {
      return event;
    }

    const result = event.result;
    const content = Array.isArray(result?.content) ? result.content : [];
    const toolCallId =
      typeof event.toolCallId === "string" && event.toolCallId.length > 0
        ? event.toolCallId
        : undefined;

    try {
      const snapshot = renderToolTuiResultSnapshot({
        toolDefinition,
        toolCallId,
        content,
        details: result?.details,
        isError: event.isError ?? false,
        args: toolCallId ? active.toolArgs?.get(toolCallId) : undefined,
        cwd:
          piSession?.sessionManager.getHeader()?.cwd ??
          active.session.mirror?.terminal?.cwd ??
          process.cwd(),
      });
      if (!snapshot) {
        return event;
      }
      const details = mergeToolTuiRenderSnapshot(result?.details, snapshot);
      if (!details) {
        return event;
      }
      return {
        ...event,
        result: {
          ...result,
          details,
        },
      };
    } catch (error) {
      log.warn("session_agent_events.tool_tui_render.failed", {
        sessionId: active.session.id,
        tool: toolName,
        toolCallId,
        error: error instanceof Error ? error.message : String(error),
      });
      return event;
    }
  }

  private logPiEvent(
    level: "debug" | "info",
    active: SessionAgentEventState,
    event: AgentSessionEvent,
  ): void {
    const toolName =
      "toolName" in event && typeof event.toolName === "string" ? event.toolName : undefined;
    log[level]("session_agent_events.pi_event", {
      sessionId: active.session.id,
      eventType: event.type,
      toolName,
      subscriberCount: active.subscribers.size,
    });
  }

  private broadcastSessionSummaryIfChanged(
    key: string,
    active: SessionAgentEventState,
    reason: AgentSessionEvent["type"],
  ): void {
    const summary = buildSessionSummary(active.session);
    const fingerprint = sessionSummaryFingerprint(summary);
    if (this.lastSummaryFingerprintBySession.get(active.session.id) === fingerprint) {
      log.debug("session_agent_events.summary_skipped", {
        sessionId: active.session.id,
        reason,
      });
      return;
    }

    this.lastSummaryFingerprintBySession.set(active.session.id, fingerprint);
    this.broadcastSessionSummary(key, active, summary, reason);
  }

  private broadcastSessionSummary(
    key: string,
    active: SessionAgentEventState,
    summary: SessionSummary,
    reason: AgentSessionEvent["type"],
  ): void {
    log.info("session_agent_events.summary_update", {
      sessionId: active.session.id,
      status: summary.status,
      reason,
    });

    const message: ServerMessage = { type: "session_summary", summary };
    this.deps.broadcast(key, message);
  }

  private handleExtensionAudioStream(key: string, event: ExtensionAudioStreamEvent): void {
    this.deps.broadcast(key, {
      type: "audio_stream",
      kind: event.kind,
      id: event.id,
      event: event.event,
      mimeType: event.mimeType,
      sampleRate: event.sampleRate,
      channels: event.channels,
      chunkIndex: event.chunkIndex,
      audioBase64: event.audioBase64,
      text: event.text,
      durationSeconds: event.durationSeconds,
      metrics: event.metrics,
      playbackBehavior: event.playbackBehavior,
    });
  }
}

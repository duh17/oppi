import type { AgentSessionEvent } from "@mariozechner/pi-coding-agent";

import type { ExtensionAudioStreamEvent, PiMessage, SessionBackendEvent } from "./pi-events.js";
import { createLogger } from "./logger.js";
import {
  extractAssistantText,
  extractToolFullOutputPath,
  translatePiEvent,
} from "./session-protocol.js";
import type {
  EventProcessorSessionState,
  ExtensionUIRequest,
  SessionEventProcessor,
} from "./session-events.js";
import type { SessionStopCoordinator, StopSessionState } from "./session-stop.js";
import type { SessionTurnCoordinator, TurnSessionState } from "./session-turns.js";
import { materializeVoiceSpeakAudioDetails } from "./session-attachments.js";
import type { ServerMessage } from "./types.js";

export interface SessionAgentEventState
  extends EventProcessorSessionState, TurnSessionState, StopSessionState {
  subscribers: Set<(msg: ServerMessage) => void>;
  toolFullOutputPaths: Map<string, string>;
}

const log = createLogger({ base: { component: "session_agent_events" } });

export interface SessionAgentEventCoordinatorDeps {
  getActiveSession: (key: string) => SessionAgentEventState | undefined;
  eventProcessor: SessionEventProcessor;
  stopCoordinator: SessionStopCoordinator;
  turnCoordinator: SessionTurnCoordinator;
  broadcast: (key: string, message: ServerMessage) => void;
  resetIdleTimer: (key: string) => void;
  markQueuedMessageStarted?: (key: string, message: PiMessage) => void;
  dataDir?: string;
}

export class SessionAgentEventCoordinator {
  private static readonly LOGGED_EVENT_TYPES = new Set<AgentSessionEvent["type"]>([
    "agent_start",
    "agent_end",
    "turn_start",
    "turn_end",
    "message_end",
    "tool_execution_start",
    "tool_execution_end",
    "compaction_start",
    "compaction_end",
    "auto_retry_start",
    "auto_retry_end",
  ]);

  private static readonly STATUS_BROADCAST_TYPES = new Set<AgentSessionEvent["type"]>([
    "agent_start",
    "agent_end",
    "message_end",
    "tool_execution_start",
  ]);

  constructor(private readonly deps: SessionAgentEventCoordinatorDeps) {}

  handlePiEvent(key: string, data: SessionBackendEvent): void {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      return;
    }

    if (data.type === "extension_ui_request") {
      this.handleExtensionUIRequest(key, data);
      return;
    }

    if (data.type === "extension_ui_request_settled") {
      active.pendingUIRequests.delete(data.id);
      if (active.pendingAsk?.requestId === data.id) {
        active.pendingAsk = undefined;
      }
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
      log.error("session_agent_events.prompt.error", {
        sessionId: active.session.id,
        error: data.error,
      });
      this.deps.broadcast(key, { type: "error", error: data.error });
      this.deps.resetIdleTimer(key);
      return;
    }

    if (data.type === "extension_audio_stream") {
      this.handleExtensionAudioStream(key, data);
      this.deps.resetIdleTimer(key);
      return;
    }

    const event = data;

    if (SessionAgentEventCoordinator.LOGGED_EVENT_TYPES.has(event.type)) {
      const toolName =
        "toolName" in event && typeof event.toolName === "string" ? event.toolName : undefined;
      log.info("session_agent_events.pi_event", {
        sessionId: active.session.id,
        eventType: event.type,
        toolName,
        subscriberCount: active.subscribers.size,
      });
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
        (message.tool === "voice_speak" || message.tool === "voice_create") &&
        message.details !== undefined &&
        this.deps.dataDir
      ) {
        try {
          this.deps.broadcast(key, {
            ...message,
            details: materializeVoiceSpeakAudioDetails({
              dataDir: this.deps.dataDir,
              sessionId: active.session.id,
              toolCallId: message.toolCallId,
              details: message.details,
            }),
          });
        } catch (error) {
          log.error("session_agent_events.voice_attachment_materialize.failed", {
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

    this.deps.eventProcessor.updateSessionFromEvent(key, active, event);

    if (event.type === "agent_end") {
      this.deps.stopCoordinator.finishPendingStopOnAgentEnd(key, active);
    }

    if (event.type === "message_end") {
      const role = event.message.role;
      if (role === "assistant" || role === "user") {
        this.deps.broadcast(key, {
          type: "message_end",
          role,
          content: extractAssistantText(event.message),
        });
      }
    }

    if (SessionAgentEventCoordinator.STATUS_BROADCAST_TYPES.has(event.type)) {
      log.info("session_agent_events.status_update", {
        sessionId: active.session.id,
        status: active.session.status,
      });
      this.deps.broadcast(key, { type: "state", session: active.session });

      if (active.session.parentSessionId) {
        this.deps.broadcast(active.session.parentSessionId, {
          type: "state",
          session: active.session,
        });
      }
    }

    this.deps.resetIdleTimer(key);
  }

  handleExtensionUIRequest(key: string, req: ExtensionUIRequest): void {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      return;
    }

    this.deps.eventProcessor.handleExtensionUIRequest(key, active, req);
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
    });
  }
}

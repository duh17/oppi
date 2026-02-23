import type { AgentSessionEvent } from "@mariozechner/pi-coding-agent";

import { ts } from "./log-utils.js";
import type { SessionBackendEvent } from "./pi-events.js";
import { extractAssistantText, translatePiEvent } from "./session-protocol.js";
import type {
  EventProcessorSessionState,
  ExtensionUIRequest,
  SessionEventProcessor,
} from "./session-events.js";
import type { SessionStopCoordinator, StopSessionState } from "./session-stop.js";
import type { SessionTurnCoordinator, TurnSessionState } from "./session-turns.js";
import type { ServerMessage } from "./types.js";

export interface SessionAgentEventState
  extends EventProcessorSessionState, TurnSessionState, StopSessionState {
  subscribers: Set<(msg: ServerMessage) => void>;
}

export interface SessionAgentEventCoordinatorDeps {
  getActiveSession: (key: string) => SessionAgentEventState | undefined;
  eventProcessor: SessionEventProcessor;
  stopCoordinator: SessionStopCoordinator;
  turnCoordinator: SessionTurnCoordinator;
  broadcast: (key: string, message: ServerMessage) => void;
  resetIdleTimer: (key: string) => void;
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
    "auto_compaction_start",
    "auto_compaction_end",
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

    if (data.type === "extension_error") {
      console.error(
        `${ts()} [pi:${active.session.id}] extension error: ${data.extensionPath}: ${data.error}`,
      );
      this.deps.resetIdleTimer(key);
      return;
    }

    const event = data;

    if (SessionAgentEventCoordinator.LOGGED_EVENT_TYPES.has(event.type)) {
      const tool =
        "toolName" in event && typeof event.toolName === "string" ? ` tool=${event.toolName}` : "";
      console.log(
        `${ts()} [pi:${active.session.id}] EVENT ${event.type}${tool} (subs=${active.subscribers.size})`,
      );
    }

    const ctx = this.deps.eventProcessor.translationContext(active);
    const messages = translatePiEvent(event, ctx);
    active.streamedAssistantText = ctx.streamedAssistantText;
    active.hasStreamedThinking = ctx.hasStreamedThinking;

    for (const message of messages) {
      this.deps.broadcast(key, message);
    }

    if (event.type === "agent_start") {
      this.deps.turnCoordinator.markNextTurnStarted(key, active);
    }

    this.deps.eventProcessor.updateSessionFromEvent(key, active, event);

    if (event.type === "agent_end") {
      this.deps.stopCoordinator.finishPendingAbortWithSuccess(key, active);
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
      console.log(`${ts()} [pi:${active.session.id}] STATUS → ${active.session.status}`);
      this.deps.broadcast(key, { type: "state", session: active.session });
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
}

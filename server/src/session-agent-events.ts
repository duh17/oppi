import { ts } from "./log-utils.js";
import type { PiEvent } from "./pi-events.js";
import { extractAssistantText, translatePiEvent } from "./session-protocol.js";
import type {
  EventProcessorSessionState,
  ExtensionUIRequest,
  SessionEventProcessor,
} from "./session-events.js";
import type { SessionStopCoordinator, StopSessionState } from "./session-stop.js";
import type { SessionTurnCoordinator, TurnSessionState } from "./session-turns.js";
import type { ServerMessage } from "./types.js";

export interface SessionAgentEventState extends EventProcessorSessionState, TurnSessionState {
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
  private static readonly LOGGED_EVENT_TYPES = new Set<PiEvent["type"]>([
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

  private static readonly STATUS_BROADCAST_TYPES = new Set<PiEvent["type"]>([
    "agent_start",
    "agent_end",
    "message_end",
    "tool_execution_start",
  ]);

  constructor(private readonly deps: SessionAgentEventCoordinatorDeps) {}

  handlePiEvent(key: string, data: PiEvent): void {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      return;
    }

    if (data.type === "extension_ui_request") {
      this.handleExtensionUIRequest(key, data);
      return;
    }

    if (SessionAgentEventCoordinator.LOGGED_EVENT_TYPES.has(data.type)) {
      const tool =
        "toolName" in data && typeof data.toolName === "string" ? ` tool=${data.toolName}` : "";
      console.log(
        `${ts()} [pi:${active.session.id}] EVENT ${data.type}${tool} (subs=${active.subscribers.size})`,
      );
    }

    const ctx = this.deps.eventProcessor.translationContext(active);
    const messages = translatePiEvent(data, ctx);
    active.streamedAssistantText = ctx.streamedAssistantText;
    active.hasStreamedThinking = ctx.hasStreamedThinking;

    for (const message of messages) {
      this.deps.broadcast(key, message);
    }

    if (data.type === "agent_start") {
      this.deps.turnCoordinator.markNextTurnStarted(key, active);
    }

    this.deps.eventProcessor.updateSessionFromEvent(key, active, data);

    if (data.type === "agent_end") {
      this.deps.stopCoordinator.finishPendingAbortWithSuccess(
        key,
        active as unknown as StopSessionState,
      );
    }

    if (data.type === "message_end") {
      const role = data.message?.role;
      if (role === "assistant" || role === "user") {
        this.deps.broadcast(key, {
          type: "message_end",
          role,
          content: extractAssistantText(data.message),
        });
      }
    }

    if (SessionAgentEventCoordinator.STATUS_BROADCAST_TYPES.has(data.type)) {
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

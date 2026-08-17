import type { SessionCatchUpResponse } from "./session-broadcast.js";
import { composeModelId } from "./session-state.js";
import type { ExtensionUIResponse } from "./extension-ui-state.js";
import type {
  ChatAttachmentRef,
  ClientMessage,
  MessageQueueDraftItem,
  MessageQueueState,
  ServerMessage,
  Session,
} from "./types.js";

/**
 * RPC passthrough commands forwarded through AgentRuntimeTransport.
 * Prompt/queue/stop/UI messages stay on dedicated transport methods.
 */
export type RuntimeClientCommand = Extract<
  ClientMessage,
  {
    type:
      | "get_messages"
      | "get_fork_messages"
      | "get_session_tree"
      | "navigate_tree"
      | "get_session_stats"
      | "get_commands"
      | "share_session"
      | "set_model"
      | "cycle_model"
      | "set_thinking_level"
      | "cycle_thinking_level"
      | "reload"
      | "new_session"
      | "set_session_name"
      | "compact"
      | "set_auto_compaction"
      | "fork"
      | "set_steering_mode"
      | "set_follow_up_mode"
      | "set_auto_retry"
      | "abort_retry"
      | "abort_bash";
  }
>;

/** Convert a typed runtime command to the bag Pi SDK execute still requires. */
export function toSdkCommandBag(command: RuntimeClientCommand): Record<string, unknown> {
  return { ...command };
}

export interface RuntimePromptOptions {
  attachments?: ChatAttachmentRef[];
  clientTurnId?: string;
  requestId?: string;
  streamingBehavior?: "steer" | "followUp";
  timestamp: number;
}

export interface RuntimeQueuedInputOptions {
  attachments?: ChatAttachmentRef[];
  clientTurnId?: string;
  requestId?: string;
}

export interface RuntimeSetQueuePayload {
  baseVersion: number;
  steering: MessageQueueDraftItem[];
  followUp: MessageQueueDraftItem[];
}

export type RuntimeCommandResultMessage = Extract<ServerMessage, { type: "command_result" }>;

export function runtimeCommandSuccess(
  command: string,
  requestId: string | undefined,
  data?: unknown,
): RuntimeCommandResultMessage {
  return {
    type: "command_result",
    command,
    requestId,
    success: true,
    ...(data === undefined ? {} : { data }),
  };
}

export function runtimeCommandFailure(
  command: string,
  requestId: string | undefined,
  error: string,
): RuntimeCommandResultMessage {
  return {
    type: "command_result",
    command,
    requestId,
    success: false,
    error,
  };
}

export function unsupportedRuntimeCommandMessage(
  runtime: string,
  command: string,
  reason?: string,
): string {
  const base = `${runtime} does not support command: ${command}`;
  return reason ? `${base} (${reason})` : base;
}

export function unsupportedRuntimeCommandError(
  runtime: string,
  command: string,
  reason?: string,
): Error {
  return new Error(unsupportedRuntimeCommandMessage(runtime, command, reason));
}

export class RuntimeDisconnectedError extends Error {
  constructor(
    readonly runtime: string,
    message = `${runtime} is not connected`,
  ) {
    super(message);
    this.name = "RuntimeDisconnectedError";
  }
}

export interface ForwardedCommandResultApplication {
  changed: boolean;
  shouldBroadcastState: boolean;
}

const STATE_BROADCAST_COMMANDS = new Set([
  "set_model",
  "cycle_model",
  "set_thinking_level",
  "cycle_thinking_level",
  "set_session_name",
]);

export function applyForwardedCommandResultToSession(options: {
  session: Session;
  commandType: string;
  request: RuntimeClientCommand;
  data: unknown;
  contextWindowResolver?: ((modelId: string) => number | undefined) | null;
}): ForwardedCommandResultApplication {
  const { session, commandType, request, data, contextWindowResolver } = options;
  const response = asRecord(data) ?? {};
  let changed = false;

  const setSessionField = <K extends keyof Session>(key: K, value: Session[K]): void => {
    if (session[key] === value) return;
    session[key] = value;
    changed = true;
  };

  if (commandType === "set_session_name") {
    const requestedName =
      request.type === "set_session_name" ? asNonEmptyString(request.name) : undefined;
    const responseName = asNonEmptyString(response.name);
    const nextName = responseName ?? requestedName;
    if (nextName) setSessionField("name", nextName);
  }

  if (commandType === "set_thinking_level" || commandType === "cycle_thinking_level") {
    const responseLevel = asNonEmptyString(response.level);
    const requestedLevel =
      request.type === "set_thinking_level" ? asNonEmptyString(request.level) : undefined;
    const nextLevel = responseLevel ?? requestedLevel;
    if (nextLevel) setSessionField("thinkingLevel", nextLevel);
  }

  if (commandType === "set_model" || commandType === "cycle_model") {
    const modelData = commandType === "cycle_model" ? asRecord(response.model) : response;
    const provider = asNonEmptyString(modelData?.provider);
    const modelId = asNonEmptyString(modelData?.id) ?? asNonEmptyString(modelData?.modelId);
    if (provider && modelId) {
      const fullId = composeModelId(provider, modelId);
      setSessionField("model", fullId);
      const contextWindow = contextWindowResolver?.(fullId);
      if (typeof contextWindow === "number") {
        setSessionField("contextWindow", contextWindow);
      }
    }

    const thinkingLevel = asNonEmptyString(response.thinkingLevel);
    if (thinkingLevel) setSessionField("thinkingLevel", thinkingLevel);
  }

  return {
    changed,
    shouldBroadcastState: STATE_BROADCAST_COMMANDS.has(commandType),
  };
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null
    ? (value as Record<string, unknown>)
    : undefined;
}

function asNonEmptyString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
}

/**
 * Canonical command surface for a session runtime.
 *
 * Managed SDK sessions and terminal mirror sessions must both satisfy this
 * contract. The caller should not need to know which process owns the real
 * AgentSession object.
 */
export interface AgentRuntimeCommandTransport {
  sendPrompt(sessionId: string, message: string, opts: RuntimePromptOptions): Promise<void>;
  sendSteer(sessionId: string, message: string, opts: RuntimeQueuedInputOptions): Promise<void>;
  sendFollowUp(sessionId: string, message: string, opts: RuntimeQueuedInputOptions): Promise<void>;
  getMessageQueue(sessionId: string): MessageQueueState | Promise<MessageQueueState>;
  setMessageQueue(sessionId: string, payload: RuntimeSetQueuePayload): Promise<MessageQueueState>;
  sendAbort(sessionId: string): Promise<void>;
  stopSession(sessionId: string): Promise<void>;
  /** True when this runtime currently owns a live process/bridge for the session. */
  isSessionConnected(sessionId: string): boolean;
  getActiveSession(sessionId: string): Session | undefined;
  respondToUIRequest(sessionId: string, response: ExtensionUIResponse): boolean;
  forwardClientCommand(
    sessionId: string,
    message: RuntimeClientCommand,
    requestId: string | undefined,
  ): Promise<void>;
  getToolFullOutputPath(sessionId: string, toolCallId: string): string | null;
  getEventRing(sessionId: string): { length: number; capacity: number } | null;
}

/** Live event stream surface for a runtime-owned session. */
export interface AgentRuntimeEventTransport {
  subscribe(sessionId: string, callback: (msg: ServerMessage) => void): () => void;
  getCurrentSeq(sessionId: string): number;
  getCatchUp(sessionId: string, sinceSeq: number): SessionCatchUpResponse | null;
  /** Replayable extension UI messages: persistent notifications plus pending dialogs and asks. */
  getPendingUIRequestMessages(sessionId: string): ServerMessage[];
}

/** Full runtime adapter contract. */
export interface AgentRuntimeTransport
  extends AgentRuntimeCommandTransport, AgentRuntimeEventTransport {}

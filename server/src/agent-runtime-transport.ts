import type { SessionCatchUpResponse } from "./session-broadcast.js";
import { composeModelId } from "./session-state.js";
import type { ExtensionUIResponse } from "./session-ui.js";
import type {
  ChatAttachmentRef,
  MessageQueueDraftItem,
  MessageQueueState,
  ServerMessage,
  Session,
} from "./types.js";

export interface RuntimeImageAttachment {
  type: "image";
  data: string;
  mimeType: string;
}

export interface RuntimePromptOptions {
  images?: RuntimeImageAttachment[];
  attachments?: ChatAttachmentRef[];
  clientTurnId?: string;
  requestId?: string;
  streamingBehavior?: "steer" | "followUp";
  timestamp: number;
}

export interface RuntimeQueuedInputOptions {
  images?: RuntimeImageAttachment[];
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
  request: Record<string, unknown>;
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
    const requestedName = asNonEmptyString(request.name);
    const responseName = asNonEmptyString(response.name);
    const nextName = responseName ?? requestedName;
    if (nextName) setSessionField("name", nextName);
  }

  if (commandType === "set_thinking_level" || commandType === "cycle_thinking_level") {
    const responseLevel = asNonEmptyString(response.level);
    const requestedLevel =
      commandType === "set_thinking_level" ? asNonEmptyString(request.level) : undefined;
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
  getActiveSession(sessionId: string): Session | undefined;
  respondToUIRequest(sessionId: string, response: ExtensionUIResponse): boolean;
  forwardClientCommand(
    sessionId: string,
    message: Record<string, unknown>,
    requestId: string | undefined,
  ): Promise<void>;
}

/** Live event stream surface for a runtime-owned session. */
export interface AgentRuntimeEventTransport {
  subscribe(sessionId: string, callback: (msg: ServerMessage) => void): () => void;
  getCurrentSeq(sessionId: string): number;
  getCatchUp(sessionId: string, sinceSeq: number): SessionCatchUpResponse | null;
  getPendingAskMessage(sessionId: string): ServerMessage | undefined;
  getPendingUIRequestMessages(sessionId: string): ServerMessage[];
}

/** Full runtime adapter contract. */
export interface AgentRuntimeTransport
  extends AgentRuntimeCommandTransport, AgentRuntimeEventTransport {}

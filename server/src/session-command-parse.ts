import type { ShareSessionAction, ShareSessionRedactionPolicyInput } from "./session-share.js";
import { isThinkingLevel, type ThinkingLevel } from "./thinking-levels.js";
import type {
  ClientMessage,
  ConversationStreamAttach,
  ConversationStreamDetach,
  ConversationStreamOlder,
} from "./types.js";

export function toRecord(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : {};
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, unknown>;
}

export function readOptionalString(value: unknown): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

export function readRequiredString(value: unknown, fieldName: string): string {
  const parsed = readOptionalString(value);
  if (!parsed) {
    throw new Error(`Invalid payload: expected ${fieldName}`);
  }
  return parsed;
}

export function readOptionalBoolean(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

/** A toggle must be a real boolean: `!!"false"` would turn it on. */
export function readRequiredBoolean(value: unknown, fieldName: string): boolean {
  if (typeof value !== "boolean") {
    throw new Error(`Invalid payload: expected ${fieldName}`);
  }
  return value;
}

export function readQueueMode(value: unknown): "all" | "one-at-a-time" {
  if (value !== "all" && value !== "one-at-a-time") {
    throw new Error("Invalid payload: expected mode");
  }
  return value;
}

export function readThinkingLevel(value: unknown): ThinkingLevel {
  const level = readRequiredString(value, "level");
  if (!isThinkingLevel(level)) {
    throw new Error("Invalid payload: expected level");
  }
  return level;
}

export function readShareSessionAction(command: Record<string, unknown>): ShareSessionAction {
  return command.action === "prepare" ? "prepare" : "publish";
}

export function readShareSessionRedactionPolicy(
  command: Record<string, unknown>,
): ShareSessionRedactionPolicyInput | undefined {
  const raw = toRecord(command.redactionPolicy);
  if (Object.keys(raw).length === 0) {
    return undefined;
  }

  return {
    secrets: readOptionalBoolean(raw.secrets),
    emails: readOptionalBoolean(raw.emails),
    phones: readOptionalBoolean(raw.phones),
    userPaths: readOptionalBoolean(raw.userPaths),
    ipAddresses: readOptionalBoolean(raw.ipAddresses),
    jwtAndBearer: readOptionalBoolean(raw.jwtAndBearer),
    namesHeuristic: readOptionalBoolean(raw.namesHeuristic),
    skills: readOptionalBoolean(raw.skills),
  };
}

export type ClientCommandParseErrorCode =
  "not_object" | "missing_type" | "unknown_type" | "invalid_field";

export type ClientCommandParseResult =
  | { ok: true; message: ClientMessage }
  | {
      ok: false;
      code: ClientCommandParseErrorCode;
      error: string;
      requestId?: string;
      command?: string;
    };

function readOptionalRequestId(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function validateRequiredMessage(command: Record<string, unknown>): void {
  // Empty prompt text is still a valid turn; only the field presence/type is required.
  if (typeof command.message !== "string") {
    throw new Error("Invalid payload: expected message");
  }
}

function readRequiredNumber(value: unknown, fieldName: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new Error(`Invalid payload: expected ${fieldName}`);
  }
  return value;
}

function validateKnownCommand(type: string, command: Record<string, unknown>): void {
  switch (type) {
    case "prompt":
    case "steer":
    case "follow_up":
      validateRequiredMessage(command);
      return;
    case "remove_queued_message":
      readRequiredString(command.itemId, "itemId");
      return;
    case "set_model":
      readRequiredString(command.provider, "provider");
      readRequiredString(command.modelId, "modelId");
      return;
    case "set_thinking_level":
      readThinkingLevel(command.level);
      return;
    case "set_auto_compaction":
    case "set_auto_retry":
      readRequiredBoolean(command.enabled, "enabled");
      return;
    case "set_steering_mode":
    case "set_follow_up_mode":
      readQueueMode(command.mode);
      return;
    case "set_session_name":
      readRequiredString(command.name, "name");
      return;
    case "fork":
      readRequiredString(command.entryId, "entryId");
      return;
    case "navigate_tree":
      readRequiredString(command.targetId, "targetId");
      return;
    case "extension_ui_response":
      readRequiredString(command.id, "id");
      return;
    case "voice_call_start":
      readRequiredString(command.clientCallId, "clientCallId");
      return;
    case "voice_call_attach":
      readRequiredString(command.callId, "callId");
      return;
    case "voice_call_detach":
    case "voice_call_keepalive":
    case "voice_call_end":
      readRequiredString(command.callId, "callId");
      readRequiredNumber(command.controllerLeaseEpoch, "controllerLeaseEpoch");
      return;
    case "abort":
    case "stop":
    case "stop_session":
    case "get_state":
    case "get_messages":
    case "get_session_stats":
    case "get_queue":
    case "take_queue":
    case "cycle_model":
    case "cycle_thinking_level":
    case "reload":
    case "new_session":
    case "compact":
    case "get_fork_messages":
    case "get_session_tree":
    case "abort_retry":
    case "abort_bash":
    case "get_commands":
    case "share_session":
    case "dictation_start":
    case "dictation_stop":
    case "dictation_cancel":
      return;
    default:
      throw new UnknownCommandTypeError(type);
  }
}

class UnknownCommandTypeError extends Error {
  readonly commandType: string;

  constructor(commandType: string) {
    super(`Unsupported command type: ${commandType}`);
    this.name = "UnknownCommandTypeError";
    this.commandType = commandType;
  }
}

function readOptionalEntryId(value: unknown, fieldName: string): number | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new Error(`Invalid attach payload: ${fieldName} must be a non-negative integer`);
  }
  return value;
}

/** Conversation stream `attach`; socket-only, so it is not a `ClientMessage` command. */
export function parseConversationStreamAttach(
  record: Record<string, unknown>,
):
  | { ok: true; message: ConversationStreamAttach }
  | { ok: false; error: string; requestId?: string } {
  const requestId = readOptionalRequestId(record.requestId);
  try {
    const conversationId = readOptionalEntryId(record.conversationId, "conversationId");
    const afterEntryId = readOptionalEntryId(record.afterEntryId, "afterEntryId");
    if (record.sessionId !== undefined && typeof record.sessionId !== "string") {
      throw new Error("Invalid attach payload: sessionId must be a string");
    }
    const mode = record.mode;
    if (mode !== undefined && mode !== "full" && mode !== "live") {
      throw new Error('Invalid attach payload: mode must be "full" or "live"');
    }
    if (mode === "live" && afterEntryId !== undefined) {
      throw new Error("Invalid attach payload: the live mode has no cursor");
    }
    return {
      ok: true,
      message: {
        type: "attach",
        ...(conversationId !== undefined ? { conversationId } : {}),
        ...(typeof record.sessionId === "string" ? { sessionId: record.sessionId } : {}),
        ...(mode !== undefined ? { mode } : {}),
        ...(afterEntryId !== undefined ? { afterEntryId } : {}),
        ...(requestId !== undefined ? { requestId } : {}),
      },
    };
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : String(error),
      ...(requestId !== undefined ? { requestId } : {}),
    };
  }
}

/** Conversation stream `detach`; socket-only, like `attach`. */
export function parseConversationStreamDetach(
  record: Record<string, unknown>,
):
  | { ok: true; message: ConversationStreamDetach }
  | { ok: false; error: string; requestId?: string } {
  const requestId = readOptionalRequestId(record.requestId);
  const id = record.conversationId;
  if (typeof id !== "number" || !Number.isSafeInteger(id) || id < 0)
    return {
      ok: false,
      error: "Invalid detach payload: conversationId must be a non-negative integer",
      ...(requestId !== undefined ? { requestId } : {}),
    };
  return {
    ok: true,
    message: {
      type: "detach",
      conversationId: id,
      ...(requestId !== undefined ? { requestId } : {}),
    },
  };
}

/** Conversation stream `older`; socket-only, like `attach`. */
export function parseConversationStreamOlder(
  record: Record<string, unknown>,
):
  | { ok: true; message: ConversationStreamOlder }
  | { ok: false; error: string; requestId?: string } {
  const requestId = readOptionalRequestId(record.requestId);
  const before = record.beforeEntryId;
  const limit = record.limit;
  const error =
    typeof before !== "number" || !Number.isSafeInteger(before) || before < 1
      ? "Invalid older payload: beforeEntryId must be a positive integer"
      : limit !== undefined &&
          (typeof limit !== "number" || !Number.isSafeInteger(limit) || limit < 1)
        ? "Invalid older payload: limit must be a positive integer"
        : undefined;
  if (error) return { ok: false, error, ...(requestId !== undefined ? { requestId } : {}) };
  return {
    ok: true,
    message: {
      type: "older",
      beforeEntryId: before as number,
      ...(limit !== undefined ? { limit: limit as number } : {}),
      ...(requestId !== undefined ? { requestId } : {}),
    },
  };
}

export function parseClientCommand(body: unknown): ClientCommandParseResult {
  const record = asRecord(body);
  if (!record) {
    return {
      ok: false,
      code: "not_object",
      error: "Message payload must be a JSON object",
    };
  }

  const requestId = readOptionalRequestId(record.requestId);
  const type = record.type;
  if (typeof type !== "string" || type.trim().length === 0) {
    return {
      ok: false,
      code: "missing_type",
      error: "Message type is required",
      ...(requestId !== undefined ? { requestId } : {}),
    };
  }

  try {
    validateKnownCommand(type, record);
  } catch (error) {
    if (error instanceof UnknownCommandTypeError) {
      return {
        ok: false,
        code: "unknown_type",
        error: error.message,
        command: error.commandType,
        ...(requestId !== undefined ? { requestId } : {}),
      };
    }
    return {
      ok: false,
      code: "invalid_field",
      error: error instanceof Error ? error.message : String(error),
      command: type,
      ...(requestId !== undefined ? { requestId } : {}),
    };
  }

  return { ok: true, message: record as ClientMessage };
}

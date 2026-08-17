import type { ShareSessionAction, ShareSessionRedactionPolicyInput } from "./session-share.js";
import type { ClientMessage } from "./types.js";

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
  | "not_object"
  | "missing_type"
  | "unknown_type"
  | "invalid_field";

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

function validateSetModel(command: Record<string, unknown>): void {
  const model = readOptionalString(command.model);
  const provider = readOptionalString(command.provider);
  const modelId = readOptionalString(command.modelId);
  if (!model && !(provider && modelId)) {
    throw new Error("Invalid set_model payload: expected model or provider+modelId");
  }
}

function validateRequiredMessage(command: Record<string, unknown>): void {
  // Empty prompt text is still a valid turn; only the field presence/type is required.
  if (typeof command.message !== "string") {
    throw new Error("Invalid payload: expected message");
  }
}

function validateKnownCommand(type: string, command: Record<string, unknown>): void {
  switch (type) {
    case "prompt":
    case "steer":
    case "follow_up":
      validateRequiredMessage(command);
      return;
    case "set_model":
      validateSetModel(command);
      return;
    case "set_thinking_level":
      readRequiredString(command.level, "level");
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
    case "abort":
    case "stop":
    case "stop_session":
    case "get_state":
    case "get_messages":
    case "get_session_stats":
    case "get_queue":
    case "set_queue":
    case "cycle_model":
    case "cycle_thinking_level":
    case "reload":
    case "new_session":
    case "compact":
    case "set_auto_compaction":
    case "get_fork_messages":
    case "get_session_tree":
    case "set_steering_mode":
    case "set_follow_up_mode":
    case "set_auto_retry":
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

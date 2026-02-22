import type { AgentSessionEvent, SessionStats } from "@mariozechner/pi-coding-agent";
import type { AssistantMessageEvent } from "@mariozechner/pi-ai";

export interface PiMessageUsage {
  input?: number;
  output?: number;
  cacheRead?: number;
  cacheWrite?: number;
  cost?: {
    total?: number;
  };
}

export interface PiMessage {
  role?: string;
  content?: unknown;
  usage?: PiMessageUsage;
}

export type PiSessionMessage = Extract<AgentSessionEvent, { type: "message_end" }>["message"];
export type PiSessionStats = SessionStats;

export interface PiToolResultPayload {
  content?: unknown[];
  details?: unknown;
  summary?: string;
  tokensBefore?: number;
}

export interface PiAgentStartEvent {
  type: "agent_start";
}

export interface PiAgentEndEvent {
  type: "agent_end";
  messages?: unknown[];
}

export interface PiTurnStartEvent {
  type: "turn_start";
}

export interface PiTurnEndEvent {
  type: "turn_end";
  message?: PiMessage;
  toolResults?: unknown[];
}

export interface PiMessageStartEvent {
  type: "message_start";
  message?: PiMessage;
}

export interface PiMessageUpdateEvent {
  type: "message_update";
  message?: PiMessage;
  assistantMessageEvent: AssistantMessageEvent;
}

export interface PiMessageEndEvent {
  type: "message_end";
  message: PiMessage;
}

export interface PiToolExecutionStartEvent {
  type: "tool_execution_start";
  toolCallId?: string;
  id?: string;
  toolName: string;
  args: Record<string, unknown>;
}

export interface PiToolExecutionUpdateEvent {
  type: "tool_execution_update";
  toolCallId?: string;
  id?: string;
  toolName: string;
  args: Record<string, unknown>;
  partialResult?: PiToolResultPayload;
}

export interface PiToolExecutionEndEvent {
  type: "tool_execution_end";
  toolCallId?: string;
  id?: string;
  toolName: string;
  result?: PiToolResultPayload;
  isError: boolean;
}

export interface PiAutoCompactionStartEvent {
  type: "auto_compaction_start";
  reason: "threshold" | "overflow";
}

export interface PiAutoCompactionEndEvent {
  type: "auto_compaction_end";
  result?: PiToolResultPayload;
  aborted: boolean;
  willRetry: boolean;
  errorMessage?: string;
}

export interface PiAutoRetryStartEvent {
  type: "auto_retry_start";
  attempt: number;
  maxAttempts: number;
  delayMs: number;
  errorMessage?: string;
}

export interface PiAutoRetryEndEvent {
  type: "auto_retry_end";
  success: boolean;
  attempt: number;
  finalError?: string;
}

export interface PiExtensionUIRequestEvent {
  type: "extension_ui_request";
  id: string;
  method: string;
  title?: string;
  options?: string[];
  message?: string;
  placeholder?: string;
  prefill?: string;
  notifyType?: "info" | "warning" | "error";
  statusKey?: string;
  statusText?: string;
  widgetKey?: string;
  widgetLines?: string[];
  widgetPlacement?: string;
  text?: string;
  timeout?: number;
}

export interface PiExtensionErrorEvent {
  type: "extension_error";
  extensionPath?: string;
  event?: string;
  error?: string;
}

export interface PiResponseEvent {
  type: "response";
  id?: string | number;
  command: string;
  success: boolean;
  data?: unknown;
  error?: string;
}

export interface PiUnknownEvent {
  type: "unknown";
  raw: unknown;
  originalType?: string;
  reason: string;
}

export type PiEvent =
  | PiAgentStartEvent
  | PiAgentEndEvent
  | PiTurnStartEvent
  | PiTurnEndEvent
  | PiMessageStartEvent
  | PiMessageUpdateEvent
  | PiMessageEndEvent
  | PiToolExecutionStartEvent
  | PiToolExecutionUpdateEvent
  | PiToolExecutionEndEvent
  | PiAutoCompactionStartEvent
  | PiAutoCompactionEndEvent
  | PiAutoRetryStartEvent
  | PiAutoRetryEndEvent
  | PiExtensionUIRequestEvent
  | PiExtensionErrorEvent
  | PiResponseEvent
  | PiUnknownEvent;

export interface PiStateSnapshot {
  sessionFile?: string;
  sessionId?: string;
  sessionName?: string;
  model?: {
    provider?: string;
    id?: string;
    name?: string;
  };
  thinkingLevel?: string;
  isStreaming?: boolean;
  autoCompaction?: boolean;
}

const ASSISTANT_MESSAGE_EVENT_TYPES = new Set<AssistantMessageEvent["type"]>([
  "start",
  "text_start",
  "text_delta",
  "text_end",
  "thinking_start",
  "thinking_delta",
  "thinking_end",
  "toolcall_start",
  "toolcall_delta",
  "toolcall_end",
  "done",
  "error",
]);

export function parsePiEvent(raw: unknown): PiEvent {
  const record = asRecord(raw);
  if (!record) {
    return { type: "unknown", raw, reason: "event is not an object" };
  }

  const type = asString(record.type);
  if (!type) {
    return { type: "unknown", raw, reason: "event is missing string type" };
  }

  switch (type) {
    case "agent_start":
      return { type };

    case "agent_end":
      return {
        type,
        messages: asArray(record.messages),
      };

    case "turn_start":
      return { type };

    case "turn_end":
      return {
        type,
        message: parsePiMessage(record.message),
        toolResults: asArray(record.toolResults),
      };

    case "message_start":
      return {
        type,
        message: parsePiMessage(record.message),
      };

    case "message_update": {
      const assistantMessageEvent = parseAssistantMessageEvent(record.assistantMessageEvent);
      if (!assistantMessageEvent) {
        return {
          type: "unknown",
          raw,
          originalType: type,
          reason: "invalid assistantMessageEvent payload",
        };
      }

      return {
        type,
        message: parsePiMessage(record.message),
        assistantMessageEvent,
      };
    }

    case "message_end": {
      const message = parsePiMessage(record.message);
      if (!message) {
        return {
          type: "unknown",
          raw,
          originalType: type,
          reason: "message_end missing message payload",
        };
      }

      return {
        type,
        message,
      };
    }

    case "tool_execution_start": {
      const toolName = asString(record.toolName);
      if (!toolName) {
        return {
          type: "unknown",
          raw,
          originalType: type,
          reason: "tool_execution_start missing toolName",
        };
      }

      return {
        type,
        id: asString(record.id),
        toolCallId: asString(record.toolCallId),
        toolName,
        args: asRecord(record.args) ?? {},
      };
    }

    case "tool_execution_update": {
      const toolName = asString(record.toolName);
      if (!toolName) {
        return {
          type: "unknown",
          raw,
          originalType: type,
          reason: "tool_execution_update missing toolName",
        };
      }

      return {
        type,
        id: asString(record.id),
        toolCallId: asString(record.toolCallId),
        toolName,
        args: asRecord(record.args) ?? {},
        partialResult: parseToolResultPayload(record.partialResult),
      };
    }

    case "tool_execution_end": {
      const toolName = asString(record.toolName);
      if (!toolName) {
        return {
          type: "unknown",
          raw,
          originalType: type,
          reason: "tool_execution_end missing toolName",
        };
      }

      return {
        type,
        id: asString(record.id),
        toolCallId: asString(record.toolCallId),
        toolName,
        result: parseToolResultPayload(record.result),
        isError: asBoolean(record.isError) ?? false,
      };
    }

    case "auto_compaction_start":
      return {
        type,
        reason: asString(record.reason) === "overflow" ? "overflow" : "threshold",
      };

    case "auto_compaction_end":
      return {
        type,
        result: parseToolResultPayload(record.result),
        aborted: asBoolean(record.aborted) ?? false,
        willRetry: asBoolean(record.willRetry) ?? false,
        errorMessage: asString(record.errorMessage),
      };

    case "auto_retry_start":
      return {
        type,
        attempt: asNumber(record.attempt) ?? 0,
        maxAttempts: asNumber(record.maxAttempts) ?? 0,
        delayMs: asNumber(record.delayMs) ?? 0,
        errorMessage: asString(record.errorMessage),
      };

    case "auto_retry_end":
      return {
        type,
        success: asBoolean(record.success) ?? false,
        attempt: asNumber(record.attempt) ?? 0,
        finalError: asString(record.finalError),
      };

    case "extension_ui_request": {
      const id = asString(record.id);
      const method = asString(record.method);
      if (!id || !method) {
        return {
          type: "unknown",
          raw,
          originalType: type,
          reason: "extension_ui_request missing id or method",
        };
      }

      return {
        type,
        id,
        method,
        title: asString(record.title),
        options: asStringArray(record.options),
        message: asString(record.message),
        placeholder: asString(record.placeholder),
        prefill: asString(record.prefill),
        notifyType: parseNotifyType(record.notifyType),
        statusKey: asString(record.statusKey),
        statusText: asString(record.statusText),
        widgetKey: asString(record.widgetKey),
        widgetLines: asStringArray(record.widgetLines),
        widgetPlacement: asString(record.widgetPlacement),
        text: asString(record.text),
        timeout: asNumber(record.timeout),
      };
    }

    case "extension_error":
      return {
        type,
        extensionPath: asString(record.extensionPath),
        event: asString(record.event),
        error: asString(record.error),
      };

    case "response": {
      const command = asString(record.command);
      if (!command) {
        return {
          type: "unknown",
          raw,
          originalType: type,
          reason: "response missing command",
        };
      }

      return {
        type,
        id: parseResponseId(record.id),
        command,
        success: asBoolean(record.success) ?? false,
        data: record.data,
        error: asString(record.error),
      };
    }

    default:
      return {
        type: "unknown",
        raw,
        originalType: type,
        reason: "unrecognized event type",
      };
  }
}

export function parsePiStateSnapshot(raw: unknown): PiStateSnapshot | null {
  const record = asRecord(raw);
  if (!record) {
    return null;
  }

  const modelRecord = asRecord(record.model);

  return {
    sessionFile: asString(record.sessionFile),
    sessionId: asString(record.sessionId),
    sessionName: asString(record.sessionName),
    model: modelRecord
      ? {
          provider: asString(modelRecord.provider),
          id: asString(modelRecord.id),
          name: asString(modelRecord.name),
        }
      : undefined,
    thinkingLevel: asString(record.thinkingLevel),
    isStreaming: asBoolean(record.isStreaming),
    autoCompaction: asBoolean(record.autoCompaction),
  };
}

function parsePiMessage(raw: unknown): PiMessage | undefined {
  const record = asRecord(raw);
  if (!record) {
    return undefined;
  }

  return {
    role: asString(record.role),
    content: record.content,
    usage: parsePiMessageUsage(record.usage),
  };
}

function parsePiMessageUsage(raw: unknown): PiMessageUsage | undefined {
  const usage = asRecord(raw);
  if (!usage) {
    return undefined;
  }

  const cost = asRecord(usage.cost);

  return {
    input: asNumber(usage.input),
    output: asNumber(usage.output),
    cacheRead: asNumber(usage.cacheRead),
    cacheWrite: asNumber(usage.cacheWrite),
    cost: cost
      ? {
          total: asNumber(cost.total),
        }
      : undefined,
  };
}

function parseToolResultPayload(raw: unknown): PiToolResultPayload | undefined {
  const record = asRecord(raw);
  if (!record) {
    return undefined;
  }

  return {
    content: asArray(record.content),
    details: record.details,
    summary: asString(record.summary),
    tokensBefore: asNumber(record.tokensBefore),
  };
}

function parseAssistantMessageEvent(raw: unknown): AssistantMessageEvent | null {
  const record = asRecord(raw);
  if (!record) {
    return null;
  }

  const type = asString(record.type);
  if (!type || !ASSISTANT_MESSAGE_EVENT_TYPES.has(type as AssistantMessageEvent["type"])) {
    return null;
  }

  return raw as AssistantMessageEvent;
}

function parseNotifyType(value: unknown): "info" | "warning" | "error" | undefined {
  if (value === "info" || value === "warning" || value === "error") {
    return value;
  }
  return undefined;
}

function parseResponseId(value: unknown): string | number | undefined {
  if (typeof value === "string" || typeof value === "number") {
    return value;
  }
  return undefined;
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null
    ? (value as Record<string, unknown>)
    : undefined;
}

function asArray(value: unknown): unknown[] | undefined {
  return Array.isArray(value) ? value : undefined;
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function asNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function asBoolean(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

function asStringArray(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) {
    return undefined;
  }

  return value.filter((entry): entry is string => typeof entry === "string");
}

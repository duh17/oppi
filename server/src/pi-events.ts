import type { AgentSessionEvent, SessionStats } from "@mariozechner/pi-coding-agent";

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

export interface ExtensionUIRequestEvent {
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

export interface ExtensionErrorEvent {
  type: "extension_error";
  extensionPath?: string;
  event?: string;
  error?: string;
}

export type SessionBackendEvent = AgentSessionEvent | ExtensionUIRequestEvent | ExtensionErrorEvent;

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

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null
    ? (value as Record<string, unknown>)
    : undefined;
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function asBoolean(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

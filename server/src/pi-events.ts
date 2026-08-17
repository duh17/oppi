import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";

import type { ExtensionUIProtocolRequest } from "./extension-ui-contract.js";
import type { AudioStreamEvent } from "./tts-provider.js";
import type { ExtensionUINotifyType, ExtensionUIWidgetPlacement } from "./types.js";

export interface PiMessageUsage {
  input?: number;
  output?: number;
  cacheRead?: number;
  cacheWrite?: number;
  /**
   * Whole prompt+completion size for the request, when the provider reports it.
   *
   * Providers disagree on what the four counters above cover. For Anthropic, xAI, and
   * openai-codex they partition the whole prompt, so their sum equals context size.
   * The Cursor provider reports only the new tokens for that request and carries
   * context size here, so this field is the only way to recover it.
   */
  totalTokens?: number;
  cost?: {
    total?: number;
  };
}

export interface PiMessage {
  role?: string;
  content?: unknown;
  usage?: PiMessageUsage;
  provider?: string;
  model?: string;
}

export interface ExtensionUIRequestEvent extends Omit<
  ExtensionUIProtocolRequest,
  "notifyType" | "widgetPlacement"
> {
  type: "extension_ui_request";
  notifyType?: ExtensionUINotifyType;
  widgetPlacement?: ExtensionUIWidgetPlacement;
}

export interface ExtensionUIRequestSettledEvent {
  type: "extension_ui_request_settled";
  id: string;
}

export interface ExtensionErrorEvent {
  type: "extension_error";
  extensionPath?: string;
  event?: string;
  error?: string;
}

/** Emitted when SdkBackend.prompt() rejects (e.g. expired OAuth, network). */
export interface PromptErrorEvent {
  type: "prompt_error";
  error: string;
}

export interface ExtensionAudioStreamEvent extends AudioStreamEvent {
  type: "extension_audio_stream";
}

export type SessionBackendEvent =
  | AgentSessionEvent
  | ExtensionUIRequestEvent
  | ExtensionUIRequestSettledEvent
  | ExtensionErrorEvent
  | PromptErrorEvent
  | ExtensionAudioStreamEvent;

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
  isCompacting?: boolean;
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
    isCompacting: asBoolean(record.isCompacting),
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

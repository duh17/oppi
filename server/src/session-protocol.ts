/**
 * Pi event translation and session state helpers.
 *
 * Pure/stateless functions that convert pi agent events into the
 * simplified ServerMessage format consumed by the iOS app.
 * Also handles session state mutation (stats, usage, messages).
 *
 * Extracted from sessions.ts to keep the SessionManager focused on
 * lifecycle orchestration and wiring.
 */

import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";

import type { ServerMessage, Session, SessionMessage } from "./types.js";
import type { MobileRendererRegistry } from "./mobile-renderer.js";
import type { PiMessage } from "./pi-events.js";
import { sanitizeToolResultDetails } from "./visual-schema.js";
import { stripAnsiEscapes } from "./ansi.js";
import { normalizePiUsage } from "./token-usage.js";
import { createLogger } from "./logger.js";
import { stripImageMediaFromDetails } from "./session-media-sanitization.js";

// ─── Shell Preview Constants ───

/** Tools that produce shell-like streaming output eligible for tail preview. */
const SHELL_LIKE_TOOLS = new Set(["bash"]);

/** Accumulated output threshold (bytes) before switching to replace mode. */
const SHELL_PREVIEW_THRESHOLD = 8 * 1024; // 8KB

/** Maximum lines in a tail preview snapshot. */
const SHELL_PREVIEW_MAX_LINES = 80;

/** Maximum bytes in a tail preview snapshot. */
const SHELL_PREVIEW_MAX_BYTES = 16 * 1024; // 16KB

/** Minimum interval between replace snapshots for the same tool call. */
const SHELL_PREVIEW_MIN_INTERVAL_MS = 150;

const log = createLogger({ base: { component: "session_protocol" } });

function isShellLikeTool(toolName: string): boolean {
  return SHELL_LIKE_TOOLS.has(toolName.toLowerCase());
}

/**
 * Extract a bounded tail preview from text.
 *
 * Takes the last N lines (up to maxLines) and caps total size at maxBytes.
 * Returns the original text if it fits within both limits.
 */
function utf8ByteCount(text: string): number {
  return Buffer.byteLength(text, "utf8");
}

function tailByUtf8Bytes(text: string, maxBytes: number): string {
  if (utf8ByteCount(text) <= maxBytes) {
    return text;
  }

  const chars = Array.from(text);
  const kept: string[] = [];
  let bytes = 0;

  for (let index = chars.length - 1; index >= 0; index -= 1) {
    const char = chars[index];
    if (char === undefined) {
      continue;
    }
    const charBytes = utf8ByteCount(char);
    if (bytes + charBytes > maxBytes) {
      break;
    }
    kept.push(char);
    bytes += charBytes;
  }

  return kept.reverse().join("");
}

function extractTailPreview(
  text: string,
  maxLines = SHELL_PREVIEW_MAX_LINES,
  maxBytes = SHELL_PREVIEW_MAX_BYTES,
): string {
  if (utf8ByteCount(text) <= maxBytes) {
    const lineCount = countNewlines(text) + 1;
    if (lineCount <= maxLines) return text;
  }

  // Split and take last N lines
  const lines = text.split("\n");
  const tailLines = lines.length <= maxLines ? lines : lines.slice(-maxLines);
  let preview = tailLines.join("\n");

  // Cap by bytes (take tail substring)
  if (utf8ByteCount(preview) > maxBytes) {
    preview = tailByUtf8Bytes(preview, maxBytes);
    // Clean break at first newline to avoid partial lines
    const firstNewline = preview.indexOf("\n");
    if (firstNewline > 0 && firstNewline < preview.length - 1) {
      preview = preview.slice(firstNewline + 1);
    }
  }

  return preview;
}

function countNewlines(text: string): number {
  let count = 0;
  for (let i = 0; i < text.length; i++) {
    if (text.charCodeAt(i) === 10) count++;
  }
  return count;
}

// ─── Text Helpers ───

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : null;
}

interface NormalizedErrorDetails {
  message?: string;
  code?: string;
  type?: string;
}

function cleanErrorText(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

function tryParseJSON(value: string): unknown | null {
  try {
    return JSON.parse(value) as unknown;
  } catch {
    return null;
  }
}

function parseStructuredErrorCandidate(input: string): unknown | null {
  const direct = tryParseJSON(input);
  if (direct !== null) {
    return direct;
  }

  const start = input.indexOf("{");
  const end = input.lastIndexOf("}");
  if (start >= 0 && end > start) {
    return tryParseJSON(input.slice(start, end + 1));
  }

  return null;
}

function extractNormalizedErrorDetails(value: unknown): NormalizedErrorDetails {
  if (typeof value === "string") {
    const trimmed = cleanErrorText(value);
    if (!trimmed) {
      return {};
    }

    const parsed = parseStructuredErrorCandidate(trimmed);
    if (parsed !== null) {
      const nested = extractNormalizedErrorDetails(parsed);
      if (nested.message || nested.code || nested.type) {
        return nested;
      }
    }

    return { message: trimmed };
  }

  const record = asRecord(value);
  if (!record) {
    return {};
  }

  const nestedError = record.error !== undefined ? extractNormalizedErrorDetails(record.error) : {};
  const nestedDetails =
    record.details !== undefined ? extractNormalizedErrorDetails(record.details) : {};
  const nestedCause = record.cause !== undefined ? extractNormalizedErrorDetails(record.cause) : {};

  const messageCandidates = [
    typeof record.message === "string" ? cleanErrorText(record.message) : "",
    typeof record.errorMessage === "string" ? cleanErrorText(record.errorMessage) : "",
    nestedError.message ?? "",
    nestedDetails.message ?? "",
    nestedCause.message ?? "",
  ];
  const codeCandidates = [
    typeof record.code === "string" ? cleanErrorText(record.code) : "",
    nestedError.code ?? "",
    nestedDetails.code ?? "",
    nestedCause.code ?? "",
  ];
  const typeCandidates = [
    typeof record.type === "string" ? cleanErrorText(record.type) : "",
    nestedError.type ?? "",
    nestedDetails.type ?? "",
    nestedCause.type ?? "",
  ];

  return {
    message: messageCandidates.find((candidate) => candidate.length > 0) || undefined,
    code: codeCandidates.find((candidate) => candidate.length > 0) || undefined,
    type: typeCandidates.find((candidate) => candidate.length > 0) || undefined,
  };
}

function normalizedKnownPlainErrorMessage(message: string): string | null {
  const lower = message.toLowerCase();

  if (
    lower.includes("request_too_large") ||
    lower.includes("context_length_exceeded") ||
    lower.includes("maximum context length") ||
    lower.includes("maximum request size") ||
    lower.includes("prompt is too long")
  ) {
    return "Request too large. Start a new session or reduce the message size and try again.";
  }

  return null;
}

function knownCodeOnlyErrorMessage(details: NormalizedErrorDetails): string | null {
  const combined = [details.code, details.type]
    .filter((value): value is string => typeof value === "string" && value.length > 0)
    .join(" ")
    .toLowerCase();

  if (!combined) {
    return null;
  }

  if (combined.includes("request_too_large") || combined.includes("context_length_exceeded")) {
    return "Request too large. Start a new session or reduce the message size and try again.";
  }

  if (combined.includes("server_is_overloaded") || combined.includes("service_unavailable_error")) {
    return "Servers are currently overloaded. Please try again later.";
  }

  if (combined.includes("rate_limit")) {
    return "Rate limit reached. Please try again in a moment.";
  }

  if (combined.includes("insufficient_quota")) {
    return "Quota exceeded. Check your provider billing or plan and try again.";
  }

  if (combined.includes("invalid_api_key") || combined.includes("authentication_error")) {
    return "Authentication failed. Check the provider login or API key and try again.";
  }

  return null;
}

function looksLikeStructuredErrorText(value: string): boolean {
  const trimmed = value.trim();
  return (
    trimmed.startsWith("{") ||
    trimmed.startsWith("[") ||
    /"(?:error|message|code|type)"\s*:/.test(trimmed)
  );
}

export function normalizeUserFacingError(
  error: string,
  fallback = "Something went wrong. Please try again.",
): string {
  const trimmed = cleanErrorText(error);
  if (!trimmed) {
    return fallback;
  }

  const details = extractNormalizedErrorDetails(trimmed);

  if (details.message && !looksLikeStructuredErrorText(details.message)) {
    return normalizedKnownPlainErrorMessage(details.message) ?? details.message;
  }

  const known = knownCodeOnlyErrorMessage(details);
  if (known) {
    return known;
  }

  if (looksLikeStructuredErrorText(trimmed)) {
    return fallback;
  }

  return trimmed;
}

export function extractToolFullOutputPath(details: unknown): string | null {
  const record = asRecord(details);
  const path = record?.fullOutputPath;
  if (typeof path !== "string") {
    return null;
  }

  const normalized = path.trim();
  return normalized.length > 0 ? normalized : null;
}

export function extractAssistantText(message: PiMessage): string {
  const content = message.content;

  if (typeof content === "string") {
    return content;
  }

  if (!Array.isArray(content)) {
    return "";
  }

  const textParts: string[] = [];
  for (const part of content as unknown[]) {
    const block = asRecord(part);
    if (!block) {
      continue;
    }

    const type = block.type;
    if ((type === "text" || type === "output_text") && typeof block.text === "string") {
      textParts.push(block.text);
    }
  }

  return textParts.join("");
}

function fullModelIdFromMessage(message: PiMessage): string | undefined {
  if (typeof message.provider === "string" && typeof message.model === "string") {
    return `${message.provider}/${message.model}`;
  }

  if (typeof message.model === "string" && message.model.includes("/")) {
    return message.model;
  }

  return undefined;
}

function extractUsage(
  message: PiMessage,
  modelId?: string,
): {
  input: number;
  output: number;
  cost: number;
  cacheRead: number;
  cacheWrite: number;
} | null {
  return normalizePiUsage(message.usage, modelId ?? fullModelIdFromMessage(message));
}

/**
 * Normalize SDK errors into user-facing text.
 */
export function normalizeCommandError(command: string, error: string): string {
  const trimmed = error.trim();

  if (command === "compact" && /already compacted/i.test(trimmed)) {
    return "Already compacted";
  }

  if (!trimmed) {
    return trimmed;
  }

  return normalizeUserFacingError(trimmed);
}

// ─── Event Translation ───

/**
 * Mutable context threaded through translatePiEvent.
 *
 * Holds per-turn streaming state that persists across events within a
 * single pi turn. SessionManager owns the actual state and passes it in.
 */
export interface TranslationContext {
  /** Session ID — used for logging only. */
  sessionId: string;
  /** Accumulated partial-result text per toolCallId (replace → delta conversion). */
  partialResults: Map<string, string>;
  /** Assistant text already streamed via text_delta for the current turn. */
  streamedAssistantText: string;
  /** True when thinking_delta events were already forwarded for the current message. */
  hasStreamedThinking: boolean;
  /** Thinking content indexes that have already streamed for the current assistant message. */
  streamedThinkingContentIndexes: Set<number>;
  /** Current thinking block content index from thinking_start, used when deltas omit it. */
  currentThinkingContentIndex?: number;
  /** Mobile renderer registry for pre-rendering tool call/result summaries. */
  mobileRenderers?: MobileRendererRegistry;
  /** Tool names per toolCallId — tracked for shell preview logic. */
  toolNames: Map<string, string>;
  /** Tool call arguments per toolCallId — used by deferred result renderers. */
  toolArgs?: Map<string, Record<string, unknown>>;
  /** Last time a shell preview snapshot was sent per toolCallId (ms). */
  shellPreviewLastSent: Map<string, number>;
  /** toolCallIds with active streaming arg viewport previews (tool_output emitted from args). */
  streamingArgPreviews: Set<string>;
  /** Last serialized streaming tool args emitted per toolCallId this turn. */
  streamingToolUpdatesSeen: Map<string, string>;
}

/**
 * Extract image/audio content blocks as data URI tool_output messages.
 *
 * Pi sends media as { type: "image"|"audio", data: "base64...", mimeType: "..." }.
 * We encode as data URIs so iOS extractors can detect and render them.
 */
function attachmentMediaDetails(
  record: Record<string, unknown>,
  kind: "image" | "audio",
): Record<string, unknown> {
  return {
    kind,
    id: record.id,
    ...(typeof record.mimeType === "string" ? { mimeType: record.mimeType } : {}),
    ...(typeof record.fileName === "string" ? { fileName: record.fileName } : {}),
    ...(typeof record.sizeBytes === "number" ? { sizeBytes: record.sizeBytes } : {}),
    ...(typeof record.storageKey === "string" ? { storageKey: record.storageKey } : {}),
    ...(typeof record.sha256 === "string" ? { sha256: record.sha256 } : {}),
    ...(typeof record.width === "number" ? { width: record.width } : {}),
    ...(typeof record.height === "number" ? { height: record.height } : {}),
    ...(typeof record.durationSeconds === "number"
      ? { durationSeconds: record.durationSeconds }
      : {}),
  };
}

function extractAttachmentMedia(
  contents: unknown[],
  options: { includeImages?: boolean; includeAudio?: boolean } = {},
): Record<string, unknown>[] {
  const includeImages = options.includeImages ?? true;
  const includeAudio = options.includeAudio ?? true;
  const attachmentMedia: Record<string, unknown>[] = [];
  for (const block of contents) {
    const record = asRecord(block);
    if (!record) {
      continue;
    }

    const type = record.type;
    if (type === "image" && !includeImages) {
      continue;
    }
    if (type === "audio" && !includeAudio) {
      continue;
    }
    if ((type === "image" || type === "audio") && typeof record.id === "string") {
      attachmentMedia.push(attachmentMediaDetails(record, type));
    }
  }
  return attachmentMedia;
}

function mergeAttachmentMediaIntoDetails(
  details: unknown,
  attachmentMedia: Record<string, unknown>[],
): unknown {
  if (attachmentMedia.length === 0) {
    return details;
  }

  const root = asRecord(details) ?? {};
  const existingMedia = Array.isArray(root.media)
    ? root.media.filter(
        (item): item is Record<string, unknown> =>
          !!item && typeof item === "object" && !Array.isArray(item),
      )
    : [];
  const merged = new Map<string, Record<string, unknown>>();
  for (const media of [...existingMedia, ...attachmentMedia]) {
    const kind = typeof media.kind === "string" ? media.kind : "unknown";
    const id = typeof media.id === "string" ? media.id : JSON.stringify(media);
    merged.set(`${kind}:${id}`, media);
  }

  return {
    ...root,
    media: Array.from(merged.values()),
  };
}

function extractMediaOutputs(
  contents: unknown[],
  toolCallId?: string,
  details?: unknown,
  options: { includeImages?: boolean; includeAudio?: boolean } = {},
): ServerMessage[] {
  const includeImages = options.includeImages ?? true;
  const includeAudio = options.includeAudio ?? true;
  const out: ServerMessage[] = [];
  const attachmentMedia = extractAttachmentMedia(contents, options);

  for (const block of contents) {
    const record = asRecord(block);
    if (!record) {
      continue;
    }

    const type = record.type;
    if (type === "image" && !includeImages) {
      continue;
    }
    if (type === "audio" && !includeAudio) {
      continue;
    }
    if ((type === "image" || type === "audio") && typeof record.id === "string") {
      continue;
    }

    if ((type === "image" || type === "audio") && typeof record.data === "string") {
      const defaultMime = type === "image" ? "image/png" : "audio/wav";
      const mimeType = typeof record.mimeType === "string" ? record.mimeType : defaultMime;
      const dataUri = `data:${mimeType};base64,${record.data}`;
      out.push({ type: "tool_output", output: dataUri, toolCallId });
    }
  }

  if (attachmentMedia.length > 0) {
    out.push({
      type: "tool_output",
      output: "",
      toolCallId,
      details: mergeAttachmentMediaIntoDetails(details, attachmentMedia),
    });
  }

  return out;
}

// ─── Streaming Arg Preview ───

/**
 * Byte threshold for emitting a streaming arg value as tool_output.
 *
 * When a string arg value exceeds this during toolcall_delta streaming,
 * the server emits a tool_output (replace mode) so the iOS viewport shows
 * the content in real time instead of stuffing it into the title bar.
 */
const STREAMING_ARG_PREVIEW_THRESHOLD = 200;

function audioPresentationText(root: Record<string, unknown>): string | undefined {
  const candidates = [root.text, root.message, root.transcript];
  for (const candidate of candidates) {
    if (typeof candidate !== "string") continue;
    const text = candidate.trim();
    if (text) return text;
  }
  return undefined;
}

function normalizeAudioPresentationDetails(details: unknown): unknown {
  const root = asRecord(details);
  if (!root || Array.isArray(root)) return details;
  if (root.kind === "audio_presentation") return details;

  const audio = asRecord(root.audio);
  if (!audio || Array.isArray(audio) || audio.kind !== "audio") return details;

  const text = audioPresentationText(root);
  return {
    ...root,
    kind: "audio_presentation",
    ...(text ? { text } : {}),
  };
}

function audioPresentationDetails(
  details: unknown,
): { text?: string; playbackBehavior?: string } | null {
  const root = asRecord(normalizeAudioPresentationDetails(details));
  if (root?.kind !== "audio_presentation") {
    return null;
  }
  return {
    ...(typeof root.text === "string" ? { text: root.text } : {}),
    ...(typeof root.playbackBehavior === "string"
      ? { playbackBehavior: root.playbackBehavior }
      : {}),
  };
}

function sanitizedUpdateDetails(details: unknown): unknown | undefined {
  const result = sanitizeToolResultDetails(details);
  return result.details === undefined ? undefined : result.details;
}

function pushToolOutputMessage(
  messages: ServerMessage[],
  payload: {
    output: string;
    toolCallId?: string;
    isError?: boolean;
    mode?: "append" | "replace";
    truncated?: boolean;
    totalBytes?: number;
    details?: unknown;
  },
): void {
  messages.push({
    type: "tool_output",
    output: payload.output,
    ...(payload.isError !== undefined ? { isError: payload.isError } : {}),
    ...(payload.toolCallId !== undefined ? { toolCallId: payload.toolCallId } : {}),
    ...(payload.mode !== undefined ? { mode: payload.mode } : {}),
    ...(payload.truncated !== undefined ? { truncated: payload.truncated } : {}),
    ...(payload.totalBytes !== undefined ? { totalBytes: payload.totalBytes } : {}),
    ...(payload.details !== undefined ? { details: payload.details } : {}),
  });
}

/**
 * Find the largest string arg value suitable for viewport preview.
 *
 * Returns the largest string value from args that exceeds the threshold,
 * or null if all string args are below it. Non-string values (objects,
 * arrays, numbers) are ignored — only plain text content is meaningful
 * for viewport rendering.
 */
function findLargestStringArg(args: Record<string, unknown>): string | null {
  let largest: string | null = null;
  let largestLen = 0;
  for (const value of Object.values(args)) {
    if (typeof value === "string" && value.length > largestLen) {
      largest = value;
      largestLen = value.length;
    }
  }

  return largest !== null && largestLen > STREAMING_ARG_PREVIEW_THRESHOLD ? largest : null;
}

function serializeStreamingToolArgs(args: Record<string, unknown>): string {
  try {
    return JSON.stringify(args);
  } catch {
    return "{}";
  }
}

/**
 * Extract streamed tool-call arguments from `message_update` events.
 *
 * Pi streams tool calls via assistantMessageEvent toolcall_* deltas before
 * `tool_execution_start`. We forward these as ephemeral `tool_update`
 * messages so iOS can create/update the tool row without polluting the
 * durable event ring or fanout telemetry.
 */
function extractStreamingToolCallUpdate(
  event: Extract<AgentSessionEvent, { type: "message_update" }>,
): Extract<ServerMessage, { type: "tool_update" }> | null {
  const evt = event.assistantMessageEvent;
  if (
    evt.type !== "toolcall_start" &&
    evt.type !== "toolcall_delta" &&
    evt.type !== "toolcall_end"
  ) {
    return null;
  }

  let toolCall = evt.type === "toolcall_end" ? asRecord(evt.toolCall) : null;

  const messageRecord = asRecord(event.message);
  const messageContent = Array.isArray(messageRecord?.content)
    ? (messageRecord.content as unknown[])
    : [];

  if (!toolCall) {
    const index = typeof evt.contentIndex === "number" ? evt.contentIndex : -1;
    if (index >= 0 && index < messageContent.length) {
      const block = asRecord(messageContent[index]);
      if (block?.type === "toolCall") {
        toolCall = block;
      }
    }
  }

  if (!toolCall) {
    for (let i = messageContent.length - 1; i >= 0; i -= 1) {
      const block = asRecord(messageContent[i]);
      if (block?.type === "toolCall") {
        toolCall = block;
        break;
      }
    }
  }

  if (!toolCall) {
    return null;
  }

  const toolCallId = typeof toolCall.id === "string" ? toolCall.id : "";
  const toolName = typeof toolCall.name === "string" ? toolCall.name : "";
  if (toolCallId.length === 0 || toolName.length === 0) {
    return null;
  }

  const args = asRecord(toolCall.arguments) ?? {};
  return {
    type: "tool_update",
    tool: toolName,
    args,
    toolCallId,
  };
}

/** Shared empty array — avoids allocating `[]` on every no-op event path. */
const EMPTY_MESSAGES: ServerMessage[] = [];

/**
 * Compute the delta between accumulated (replace-semantics) tool output and
 * the full text delivered so far.  Hoisted out of translatePiEvent to avoid
 * closure allocation on every call.
 */
function computeToolOutputUpdate(
  lastText: string,
  fullText: string,
): { output: string; mode?: "append" | "replace" } | null {
  if (fullText.length === 0) return null;
  if (lastText.length === 0) return { output: fullText };
  if (fullText === lastText) return null;
  if (fullText.startsWith(lastText)) {
    return { output: fullText.slice(lastText.length) };
  }

  // Pi partial tool results generally have replace semantics: each update is
  // the full current view, not necessarily an append-only stream. When a tool
  // changes status text (for example "Generating…" -> "Downloading…" ->
  // "Generated…"), appending the divergent full text duplicates prompt/knobs
  // in the client. Send an explicit replacement so durable clients converge
  // on the latest tool view instead of accumulating status snapshots.
  return { output: fullText, mode: "replace" };
}

/**
 * Extract toolCallId from a pi event.
 * Hoisted to a module-level helper to avoid re-creating a closure per call.
 */
function resolveToolCallId(event: AgentSessionEvent): string | undefined {
  // If toolCallId is explicitly present, trust it. An empty string is treated
  // as intentionally missing and we do not backfill from other fields.
  if ("toolCallId" in event) {
    if (typeof event.toolCallId === "string" && event.toolCallId.length > 0) {
      return event.toolCallId;
    }
  }

  return undefined;
}

/**
 * Translate a single pi agent event into zero or more ServerMessages.
 *
 * Mutates `ctx.streamedAssistantText` and `ctx.partialResults` as a
 * side effect (streaming state for the current turn).
 */
function contentIndexFrom(value: unknown): number | undefined {
  return typeof value === "number" && Number.isInteger(value) && value >= 0 ? value : undefined;
}

export function translatePiEvent(
  event: AgentSessionEvent,
  ctx: TranslationContext,
): ServerMessage[] {
  switch (event.type) {
    case "agent_start":
      ctx.streamedAssistantText = "";
      ctx.currentThinkingContentIndex = undefined;
      ctx.streamedThinkingContentIndexes.clear();
      ctx.streamingToolUpdatesSeen.clear();
      return [{ type: "agent_start" }];

    case "agent_end":
      ctx.streamedAssistantText = "";
      ctx.currentThinkingContentIndex = undefined;
      ctx.streamedThinkingContentIndexes.clear();
      ctx.streamingToolUpdatesSeen.clear();
      return [{ type: "agent_end" }];

    case "turn_start":
      return EMPTY_MESSAGES;

    case "turn_end":
      return EMPTY_MESSAGES;

    case "message_start":
      // Structural lifecycle marker. No payload needed for iOS —
      // the message object arrives via message_end.
      return EMPTY_MESSAGES;

    case "message_update": {
      const evt = event.assistantMessageEvent;
      if (evt?.type === "text_delta" && typeof evt.delta === "string") {
        ctx.streamedAssistantText += evt.delta;
        return [{ type: "text_delta", delta: evt.delta }];
      }
      if (evt?.type === "thinking_start") {
        ctx.currentThinkingContentIndex = contentIndexFrom(evt.contentIndex);
        return EMPTY_MESSAGES;
      }
      if (evt?.type === "thinking_delta") {
        ctx.hasStreamedThinking = true;
        const contentIndex = contentIndexFrom(evt.contentIndex) ?? ctx.currentThinkingContentIndex;
        if (contentIndex !== undefined) {
          ctx.streamedThinkingContentIndexes.add(contentIndex);
        }
        return [
          {
            type: "thinking_delta",
            delta: evt.delta,
            ...(contentIndex !== undefined ? { contentIndex } : {}),
          },
        ];
      }
      if (evt?.type === "thinking_end") {
        const contentIndex = contentIndexFrom(evt.contentIndex);
        if (contentIndex === undefined || contentIndex === ctx.currentThinkingContentIndex) {
          ctx.currentThinkingContentIndex = undefined;
        }
        return EMPTY_MESSAGES;
      }
      if (evt?.type === "error") {
        const reason = evt.reason ?? "error";
        const errorMsg =
          typeof evt.error?.errorMessage === "string" && evt.error.errorMessage.length > 0
            ? normalizeUserFacingError(evt.error.errorMessage)
            : `Stream ${reason}`;
        return [{ type: "error", error: errorMsg }];
      }

      const toolCallUpdate = extractStreamingToolCallUpdate(event);
      if (toolCallUpdate && toolCallUpdate.type === "tool_update") {
        const messages: ServerMessage[] = [];
        const updateKey = toolCallUpdate.toolCallId ?? "";
        const serializedArgs = serializeStreamingToolArgs(toolCallUpdate.args);
        const previousSerializedArgs = ctx.streamingToolUpdatesSeen.get(updateKey);
        const shouldEmitToolUpdate =
          serializedArgs !== "{}" && previousSerializedArgs !== serializedArgs;

        if (shouldEmitToolUpdate) {
          ctx.streamingToolUpdatesSeen.set(updateKey, serializedArgs);

          // Augment streaming tool_update with callSegments so iOS can keep
          // file-tool titles current as streamed args become more complete.
          if (ctx.mobileRenderers) {
            const callSegments = ctx.mobileRenderers.renderCall(
              toolCallUpdate.tool,
              toolCallUpdate.args,
            );
            if (callSegments) {
              toolCallUpdate.callSegments = callSegments;
            }
          }
          messages.push(toolCallUpdate);
        }

        // Stream the largest string arg value as tool_output (replace mode)
        // so the iOS viewport shows streaming content instead of "Waiting for
        // output…". Cleared at tool_execution_start with an empty replace.
        const largestArg = findLargestStringArg(toolCallUpdate.args);
        if (largestArg && toolCallUpdate.toolCallId) {
          pushToolOutputMessage(messages, {
            output: largestArg,
            toolCallId: toolCallUpdate.toolCallId,
            mode: "replace",
          });
          ctx.streamingArgPreviews.add(toolCallUpdate.toolCallId);
        }

        return messages;
      }

      // Other sub-events (start, text_start/end, thinking_start/end, done)
      // are redundant with top-level events or pure bookkeeping.
      return EMPTY_MESSAGES;
    }

    case "tool_execution_start": {
      const toolCallId = resolveToolCallId(event);
      const callSegments = ctx.mobileRenderers?.renderCall(event.toolName, event.args || {});
      // Track tool name for shell preview decisions in subsequent updates.
      if (toolCallId) {
        ctx.toolNames.set(toolCallId, event.toolName);
        ctx.toolArgs?.set(toolCallId, asRecord(event.args) ?? {});
        ctx.streamingToolUpdatesSeen.delete(toolCallId);
      }

      const messages: ServerMessage[] = [];

      // Clear streaming arg viewport preview before real execution begins.
      // The preview was emitted during toolcall_delta streaming; now real
      // tool output will arrive via tool_execution_update/end.
      if (toolCallId && ctx.streamingArgPreviews.has(toolCallId)) {
        ctx.streamingArgPreviews.delete(toolCallId);
        pushToolOutputMessage(messages, {
          output: "",
          toolCallId,
          mode: "replace",
        });
      }

      messages.push({
        type: "tool_start",
        tool: event.toolName,
        args: event.args || {},
        toolCallId,
        ...(callSegments ? { callSegments } : {}),
      });

      return messages;
    }

    case "tool_execution_update": {
      const contents = Array.isArray(event.partialResult?.content)
        ? event.partialResult.content
        : [];
      const updateDetails = normalizeAudioPresentationDetails(
        stripImageMediaFromDetails(sanitizedUpdateDetails(event.partialResult?.details)),
      );

      const toolCallId = resolveToolCallId(event);
      const key = toolCallId ?? "";
      const toolName = ctx.toolNames.get(key) ?? event.toolName ?? "";

      // Ask tool: no streaming output to iOS.
      if (toolName === "ask") return EMPTY_MESSAGES;

      const messages: ServerMessage[] = [];
      const shellTool = isShellLikeTool(toolName);
      const audioDetails = audioPresentationDetails(updateDetails);
      let emittedOutput = false;

      for (const block of contents) {
        const record = asRecord(block);
        if (!record) {
          continue;
        }

        const type = record.type;
        if ((type === "text" || type === "output_text") && typeof record.text === "string") {
          const fullText = stripAnsiEscapes(record.text);

          // Compute delta from last partialResult to avoid duplication.
          // partialResult is accumulated (replace semantics) — we convert
          // to delta so the client can append without duplicating output.
          const lastText = ctx.partialResults.get(key) ?? "";
          ctx.partialResults.set(key, fullText);

          const fullTextBytes = utf8ByteCount(fullText);
          if (shellTool && fullTextBytes > SHELL_PREVIEW_THRESHOLD) {
            // Shell tool above threshold: send bounded tail preview with replace mode.
            // Throttle to avoid spamming the client with large snapshots.
            const now = Date.now();
            const lastSent = ctx.shellPreviewLastSent.get(key) ?? 0;
            if (now - lastSent < SHELL_PREVIEW_MIN_INTERVAL_MS) {
              continue; // Skip this update — next one or tool_end will catch up.
            }
            ctx.shellPreviewLastSent.set(key, now);

            const preview = extractTailPreview(fullText);
            pushToolOutputMessage(messages, {
              output: preview,
              toolCallId,
              mode: "replace",
              truncated: true,
              totalBytes: fullTextBytes,
              details: updateDetails,
            });
            emittedOutput = true;
          } else {
            // Normal append delta behavior, with replace fallback for tools
            // that publish full non-prefix status snapshots.
            const update = computeToolOutputUpdate(lastText, fullText);
            if (update) {
              pushToolOutputMessage(messages, {
                output: update.output,
                toolCallId,
                ...(update.mode ? { mode: update.mode } : {}),
                details: updateDetails,
              });
              emittedOutput = true;
            }
          }
        }
      }

      if (!emittedOutput && audioDetails) {
        const transcript = audioDetails.text ?? "";
        if (transcript) {
          const lastText = ctx.partialResults.get(key) ?? "";
          ctx.partialResults.set(key, transcript);
          const update = computeToolOutputUpdate(lastText, transcript);
          pushToolOutputMessage(messages, {
            output: update?.output ?? transcript,
            toolCallId,
            ...(update?.mode ? { mode: update.mode } : update ? {} : { mode: "replace" as const }),
            details: updateDetails,
          });
          emittedOutput = true;
        }
      }

      if (!emittedOutput && updateDetails !== undefined) {
        pushToolOutputMessage(messages, {
          output: "",
          toolCallId,
          details: updateDetails,
        });
      }

      messages.push(
        ...extractMediaOutputs(contents, toolCallId, updateDetails, { includeImages: false }),
      );
      return messages;
    }

    case "tool_execution_end": {
      const toolCallId = resolveToolCallId(event);
      const key = toolCallId ?? "";
      const lastText = ctx.partialResults.get(key) ?? "";
      const toolName = ctx.toolNames.get(key) ?? event.toolName ?? "";
      const shellTool = isShellLikeTool(toolName);

      // Ask tool output is only for the LLM — suppress it from iOS broadcast.
      // The structured details (answers) are delivered via tool_end, and iOS
      // renders them as a user message. This avoids scattered output suppression
      // checks on the iOS side (processInternal, processBatch, trace replay).
      const isAskTool = toolName === "ask";

      // Extract final text/media from result — some tools only include output
      // at end (no partial updates), so emit missing delta here.
      const resultContents = event.result?.content;
      const messages: ServerMessage[] = [];

      if (!isAskTool && Array.isArray(resultContents) && resultContents.length > 0) {
        const finalText = resultContents
          .map((block) => {
            const record = asRecord(block);
            if (!record) {
              return "";
            }

            const type = record.type;
            const isText = type === "text" || type === "output_text";
            return isText && typeof record.text === "string" ? stripAnsiEscapes(record.text) : "";
          })
          .join("");

        const finalTextBytes = utf8ByteCount(finalText);
        if (shellTool && finalTextBytes > SHELL_PREVIEW_THRESHOLD) {
          // Shell tool final output: always send the tail preview (no throttle).
          const preview = extractTailPreview(finalText);
          pushToolOutputMessage(messages, {
            output: preview,
            toolCallId,
            mode: "replace",
            truncated: true,
            totalBytes: finalTextBytes,
          });
        } else {
          const update = computeToolOutputUpdate(lastText, finalText);
          if (update) {
            pushToolOutputMessage(messages, {
              output: update.output,
              toolCallId,
              ...(update.mode ? { mode: update.mode } : {}),
            });
          }
        }

        messages.push(
          ...extractMediaOutputs(resultContents, toolCallId, event.result?.details, {
            includeImages: false,
          }),
        );
      }

      ctx.partialResults.delete(key);
      ctx.toolNames.delete(key);
      ctx.toolArgs?.delete(key);
      ctx.shellPreviewLastSent.delete(key);
      if (toolCallId) {
        ctx.streamingArgPreviews.delete(toolCallId);
      }

      // Forward structured details and error status from pi tool results.
      // Extensions emit typed details (e.g. remember: {file, redacted}, recall: {matches, topHeader})
      // and built-in tools emit BashToolDetails, ReadToolDetails, etc.
      const detailsResult = sanitizeToolResultDetails(event.result?.details);
      if (detailsResult.warnings.length > 0) {
        log.warn("session.tool_end_details_sanitized", {
          sessionId: ctx.sessionId,
          tool: event.toolName,
          warnings: detailsResult.warnings,
        });
      }

      const details = normalizeAudioPresentationDetails(
        mergeAttachmentMediaIntoDetails(
          detailsResult.details,
          Array.isArray(resultContents) ? extractAttachmentMedia(resultContents) : [],
        ),
      );
      const resultSegments = ctx.mobileRenderers?.renderResult(
        event.toolName,
        details,
        !!event.isError,
      );
      messages.push({
        type: "tool_end",
        tool: event.toolName,
        toolCallId,
        ...(details !== undefined && details !== null ? { details } : {}),
        ...(event.isError ? { isError: true } : {}),
        ...(resultSegments ? { resultSegments } : {}),
      });

      return messages;
    }

    case "compaction_start":
      return [{ type: "compaction_start", reason: event.reason ?? "threshold" }];

    case "compaction_end":
      return [
        {
          type: "compaction_end",
          aborted: event.aborted ?? false,
          willRetry: event.willRetry ?? false,
          summary: event.result?.summary,
          tokensBefore: event.result?.tokensBefore,
        },
      ];

    case "auto_retry_start":
      return [
        {
          type: "retry_start",
          attempt: event.attempt,
          maxAttempts: event.maxAttempts,
          delayMs: event.delayMs,
          errorMessage: normalizeUserFacingError(event.errorMessage ?? "retry requested"),
        },
      ];

    case "auto_retry_end":
      return [
        {
          type: "retry_end",
          success: event.success,
          attempt: event.attempt,
          finalError: event.finalError,
        },
      ];

    // Pi can deliver final assistant text/thinking only in message_end.
    // The authoritative text is in the message_end broadcast (see
    // SessionAgentEventCoordinator). No synthetic text_delta recovery
    // here — that caused duplicate assistant bubbles when the tail
    // arrived after the assistant message was already finalized.
    //
    // Thinking recovery IS still needed: pi RPC doesn't stream
    // thinking_delta, so message_end is the only source.
    case "message_end": {
      const message = event.message;
      if (message.role !== "assistant") {
        ctx.streamedAssistantText = "";
        ctx.currentThinkingContentIndex = undefined;
        ctx.streamedThinkingContentIndexes.clear();
        return EMPTY_MESSAGES;
      }

      // Check for error stop reason (e.g. 413 request_too_large from Anthropic).
      // Pi delivers these as message_end with stopReason: "error" + errorMessage.
      // The PiMessage type doesn't include these fields, so access via asRecord().
      const msgRecord = asRecord(message as unknown);
      if (msgRecord && msgRecord.stopReason === "error") {
        const rawError =
          typeof msgRecord.errorMessage === "string" ? msgRecord.errorMessage : "Unknown error";

        ctx.streamedAssistantText = "";
        ctx.hasStreamedThinking = false;
        ctx.currentThinkingContentIndex = undefined;
        ctx.streamedThinkingContentIndexes.clear();
        return [{ type: "error", error: normalizeUserFacingError(rawError) }];
      }

      const out: ServerMessage[] = [];

      // Recover thinking only when it wasn't already streamed live.
      // Streaming sets ctx.hasStreamedThinking; recovery is for reconnect
      // catch-up scenarios where the client missed the streaming events.
      // When contentIndex is available, recover only the specific thinking
      // blocks that did not stream instead of suppressing the whole message.
      const content = message.content;
      const hasIndexedThinking = ctx.streamedThinkingContentIndexes.size > 0;
      if (Array.isArray(content)) {
        for (const [index, block] of (content as unknown[]).entries()) {
          const record = asRecord(block);
          if (!record) {
            continue;
          }

          if (
            record.type === "thinking" &&
            typeof record.thinking === "string" &&
            record.thinking.length > 0
          ) {
            const shouldRecover =
              !ctx.hasStreamedThinking ||
              (hasIndexedThinking && !ctx.streamedThinkingContentIndexes.has(index));
            if (shouldRecover) {
              out.push({ type: "thinking_delta", delta: record.thinking, contentIndex: index });
            }
          }
        }
      }

      ctx.streamedAssistantText = "";
      ctx.hasStreamedThinking = false;
      ctx.currentThinkingContentIndex = undefined;
      ctx.streamedThinkingContentIndexes.clear();
      return out;
    }

    default:
      return EMPTY_MESSAGES;
  }
}

// ─── Change Stats ───

const MAX_TRACKED_CHANGED_FILES = 100;

function ensureSessionChangeStats(session: Session): NonNullable<Session["changeStats"]> {
  const existing = session.changeStats;
  if (existing) {
    return existing;
  }

  const stats: NonNullable<Session["changeStats"]> = {
    mutatingToolCalls: 0,
    filesChanged: 0,
    changedFiles: [],
    addedLines: 0,
    removedLines: 0,
  };
  session.changeStats = stats;
  return stats;
}

export function incrementSessionCompactionCount(session: Session): void {
  const stats = ensureSessionChangeStats(session);
  stats.compactionCount = (stats.compactionCount ?? 0) + 1;
}

export function updateSessionChangeStats(
  session: Session,
  rawToolName: unknown,
  rawArgs: unknown,
): void {
  const toolName = typeof rawToolName === "string" ? rawToolName.toLowerCase() : "";
  if (toolName !== "edit" && toolName !== "write") {
    return;
  }

  const existing = session.changeStats;
  const dedupedChangedFiles = Array.isArray(existing?.changedFiles)
    ? existing.changedFiles.filter((f) => typeof f === "string" && f.length > 0)
    : [];

  const filesChanged = Math.max(existing?.filesChanged ?? 0, dedupedChangedFiles.length);
  const changedFilesOverflow = Math.max(
    existing?.changedFilesOverflow ?? 0,
    filesChanged - dedupedChangedFiles.length,
  );

  const stats = {
    mutatingToolCalls: existing?.mutatingToolCalls ?? 0,
    compactionCount: existing?.compactionCount,
    filesChanged,
    changedFiles: dedupedChangedFiles,
    changedFilesOverflow,
    addedLines: existing?.addedLines ?? 0,
    removedLines: existing?.removedLines ?? 0,
  };

  stats.mutatingToolCalls += 1;

  const path = extractChangedFilePath(rawArgs);
  const wasAlreadyTracked = path ? stats.changedFiles.includes(path) : false;
  if (path && !wasAlreadyTracked) {
    stats.filesChanged += 1;

    if (stats.changedFiles.length < MAX_TRACKED_CHANGED_FILES) {
      stats.changedFiles.push(path);
    } else {
      stats.changedFilesOverflow += 1;
    }
  }

  const fileLineCounts: Record<string, number> = existing?._fileLineCounts
    ? { ...existing._fileLineCounts }
    : {};
  const sessionCreatedFiles = new Set<string>(existing?._sessionCreatedFiles ?? []);
  const { added, removed, isNewFile } = estimateLineDelta(toolName, rawArgs, path, fileLineCounts);

  // Track files first created in this session.  Only mark as created if
  // this is the first write (previousLines=0) AND the file wasn't already
  // touched by a prior edit (which proves it pre-existed).
  if (isNewFile && path && !wasAlreadyTracked) {
    sessionCreatedFiles.add(path);
  }

  // For files created in this session, "removed" lines should reduce
  // addedLines instead of incrementing removedLines.  From the pre-session
  // baseline the file didn't exist — you can't remove lines that were never
  // there.  Without this, writing a 568-line file then editing it 3 lines
  // shorter shows (+568, -3) instead of the correct (+565, -0).
  if (path && sessionCreatedFiles.has(path) && removed > 0) {
    stats.addedLines = Math.max(0, stats.addedLines - removed);
  } else {
    stats.removedLines += removed;
  }
  stats.addedLines += added;

  session.changeStats = {
    mutatingToolCalls: stats.mutatingToolCalls,
    ...(stats.compactionCount && stats.compactionCount > 0
      ? { compactionCount: stats.compactionCount }
      : {}),
    filesChanged: stats.filesChanged,
    changedFiles: stats.changedFiles,
    ...(stats.changedFilesOverflow > 0 ? { changedFilesOverflow: stats.changedFilesOverflow } : {}),
    addedLines: stats.addedLines,
    removedLines: stats.removedLines,
    _fileLineCounts: fileLineCounts,
    _sessionCreatedFiles: [...sessionCreatedFiles],
  };
}

function extractChangedFilePath(rawArgs: unknown): string | null {
  if (!rawArgs || typeof rawArgs !== "object") {
    return null;
  }

  const args = rawArgs as Record<string, unknown>;
  const candidate = args.path;
  if (typeof candidate !== "string") {
    return null;
  }

  const normalized = candidate.trim();
  return normalized.length > 0 ? normalized : null;
}

/**
 * Estimate line additions/removals for a write or edit tool call.
 *
 * `fileLineCounts` tracks per-file line counts across calls so that repeated
 * writes to the same file compute a delta instead of counting every line as
 * added.  The map is mutated in place (caller persists it on changeStats).
 */
function estimateLineDelta(
  toolName: string,
  rawArgs: unknown,
  filePath: string | null,
  fileLineCounts: Record<string, number>,
): { added: number; removed: number; isNewFile: boolean } {
  if (!rawArgs || typeof rawArgs !== "object") {
    return { added: 0, removed: 0, isNewFile: false };
  }

  const args = rawArgs as Record<string, unknown>;

  if (toolName === "write") {
    const content = typeof args.content === "string" ? args.content : "";
    if (content.length === 0) {
      return { added: 0, removed: 0, isNewFile: false };
    }

    const newLines = countLines(content);
    const previousLines = filePath !== null ? (fileLineCounts[filePath] ?? 0) : 0;
    const isNewFile = previousLines === 0;

    // Update tracked count for this file
    if (filePath !== null) {
      fileLineCounts[filePath] = newLines;
    }

    return {
      added: Math.max(0, newLines - previousLines),
      removed: Math.max(0, previousLines - newLines),
      isNewFile,
    };
  }

  // edit tool. Newer pi edit calls use a batched `edits` array; older
  // calls used top-level `oldText` / `newText`. Count each replacement
  // independently so a single tool call that adds in one block and removes
  // in another streams both numbers through the session summary.
  const editDeltas = extractEditLineDeltas(args);
  if (editDeltas.length === 0) {
    return { added: 0, removed: 0, isNewFile: false };
  }

  let added = 0;
  let removed = 0;
  let netLineDelta = 0;
  for (const delta of editDeltas) {
    netLineDelta += delta;
    if (delta > 0) {
      added += delta;
    } else if (delta < 0) {
      removed += -delta;
    }
  }

  // Update tracked count so subsequent writes to this file are accurate.
  if (filePath !== null && filePath in fileLineCounts) {
    fileLineCounts[filePath] = Math.max(0, fileLineCounts[filePath] + netLineDelta);
  }

  return { added, removed, isNewFile: false };
}

function extractEditLineDeltas(args: Record<string, unknown>): number[] {
  const batched = Array.isArray(args.edits)
    ? args.edits
        .map((entry) => editLineDelta(entry))
        .filter((delta): delta is number => delta !== null)
    : [];
  if (batched.length > 0) {
    return batched;
  }

  const legacy = editLineDelta(args);
  return legacy === null ? [] : [legacy];
}

function editLineDelta(rawEdit: unknown): number | null {
  if (!rawEdit || typeof rawEdit !== "object") {
    return null;
  }

  const edit = rawEdit as Record<string, unknown>;
  const oldText = typeof edit.oldText === "string" ? edit.oldText : "";
  const newText = typeof edit.newText === "string" ? edit.newText : "";
  if (oldText.length === 0 && newText.length === 0) {
    return null;
  }

  return countLines(newText) - countLines(oldText);
}

function countLines(text: string): number {
  if (text.length === 0) {
    return 0;
  }
  return text.split("\n").length;
}

// ─── Session Message Counters ───

/**
 * Update in-memory session counters from a user/assistant message.
 * Returns true if this call captured the session's firstMessage (first user message).
 */
export function appendSessionMessage(
  session: Session,
  message: Omit<SessionMessage, "id" | "sessionId">,
): boolean {
  session.messageCount += 1;
  session.lastMessage = message.content.slice(0, 100);
  session.lastActivity = message.timestamp;

  // Capture first user message (immutable once set)
  let capturedFirstMessage = false;
  if (!session.firstMessage && message.role === "user") {
    session.firstMessage = message.content.slice(0, 200);
    capturedFirstMessage = true;
  }

  if (message.tokens) {
    session.tokens.input += message.tokens.input;
    session.tokens.output += message.tokens.output;
    session.tokens.cacheRead += message.tokens.cacheRead ?? 0;
    session.tokens.cacheWrite += message.tokens.cacheWrite ?? 0;
  }

  if (message.cost) {
    session.cost += message.cost;
  }

  return capturedFirstMessage;
}

/**
 * Apply a pi `message_end` event to session state.
 *
 * Extracts usage/tokens and updates session counters/context token count.
 */
export function applyMessageEndToSession(session: Session, message: PiMessage): void {
  const role = message.role;

  // Only persist assistant messages — user messages are already stored on prompt receipt
  if (role === "user") return;

  const timestamp = Date.now();
  session.lastAgentReplyAt = timestamp;

  const usage = extractUsage(message, session.model);
  const assistantText = extractAssistantText(message);

  if (assistantText) {
    const tokens = usage
      ? {
          input: usage.input,
          output: usage.output,
          cacheRead: usage.cacheRead,
          cacheWrite: usage.cacheWrite,
        }
      : undefined;

    appendSessionMessage(session, {
      role: "assistant",
      content: assistantText,
      timestamp,
      model: session.model,
      tokens,
      cost: usage?.cost,
    });
  } else if (usage) {
    session.tokens.input += usage.input;
    session.tokens.output += usage.output;
    session.tokens.cacheRead += usage.cacheRead;
    session.tokens.cacheWrite += usage.cacheWrite;
    session.cost += usage.cost;
  }

  // Track context usage for status display (matches pi TUI calculation).
  // Preserve the last non-zero snapshot when pi emits a synthetic aborted
  // assistant message with empty/zero usage at the end of a stopped session.
  if (usage) {
    const contextTokens = usage.input + usage.output + usage.cacheRead + usage.cacheWrite;
    if (contextTokens > 0 || session.contextTokens === undefined) {
      session.contextTokens = contextTokens;
    }
  }
}

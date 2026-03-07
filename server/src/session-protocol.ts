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

import type { AgentSessionEvent } from "@mariozechner/pi-coding-agent";

import type { ServerMessage, Session, SessionMessage } from "./types.js";
import type { MobileRendererRegistry } from "./mobile-renderer.js";
import type { PiMessage } from "./pi-events.js";
import { sanitizeToolResultDetails } from "./visual-schema.js";

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

/**
 * Compute the missing assistant text tail from streamed deltas and finalized text.
 *
 * Pi normally streams assistant text via `message_update.text_delta`, but some
 * turns only include text in `message_end`. This helper bridges that gap.
 */
export function computeAssistantTextTailDelta(streamedText: string, finalizedText: string): string {
  if (finalizedText.length === 0) return "";
  if (streamedText.length === 0) return finalizedText;
  if (finalizedText === streamedText) return "";

  if (finalizedText.startsWith(streamedText)) {
    return finalizedText.slice(streamedText.length);
  }

  // Fallback for unexpected divergence: append from common prefix forward.
  // We cannot retract already-streamed text, but this avoids dropping content.
  let commonPrefix = 0;
  const max = Math.min(streamedText.length, finalizedText.length);
  while (commonPrefix < max && streamedText[commonPrefix] === finalizedText[commonPrefix]) {
    commonPrefix += 1;
  }

  return finalizedText.slice(commonPrefix);
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : null;
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

function extractUsage(message: PiMessage): {
  input: number;
  output: number;
  cost: number;
  cacheRead: number;
  cacheWrite: number;
} | null {
  const usage = asRecord(message.usage);
  if (!usage) {
    return null;
  }

  const cost = asRecord(usage.cost);

  return {
    input: typeof usage.input === "number" ? usage.input : 0,
    output: typeof usage.output === "number" ? usage.output : 0,
    cost: typeof cost?.total === "number" ? cost.total : 0,
    cacheRead: typeof usage.cacheRead === "number" ? usage.cacheRead : 0,
    cacheWrite: typeof usage.cacheWrite === "number" ? usage.cacheWrite : 0,
  };
}

/**
 * Normalize SDK errors into user-facing text.
 */
export function normalizeCommandError(command: string, error: string): string {
  const trimmed = error.trim();

  if (command === "compact" && /already compacted/i.test(trimmed)) {
    return "Already compacted";
  }

  return trimmed;
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
  /** Mobile renderer registry for pre-rendering tool call/result summaries. */
  mobileRenderers?: MobileRendererRegistry;
  /** Tool names per toolCallId — tracked for shell preview logic. */
  toolNames: Map<string, string>;
  /** Last time a shell preview snapshot was sent per toolCallId (ms). */
  shellPreviewLastSent: Map<string, number>;
}

/**
 * Extract image/audio content blocks as data URI tool_output messages.
 *
 * Pi sends media as { type: "image"|"audio", data: "base64...", mimeType: "..." }.
 * We encode as data URIs so iOS extractors can detect and render them.
 */
function extractMediaOutputs(contents: unknown[], toolCallId?: string): ServerMessage[] {
  const out: ServerMessage[] = [];
  for (const block of contents) {
    const record = asRecord(block);
    if (!record) {
      continue;
    }

    const type = record.type;
    if ((type === "image" || type === "audio") && typeof record.data === "string") {
      const defaultMime = type === "image" ? "image/png" : "audio/wav";
      const mimeType = typeof record.mimeType === "string" ? record.mimeType : defaultMime;
      const dataUri = `data:${mimeType};base64,${record.data}`;
      out.push({ type: "tool_output", output: dataUri, toolCallId });
    }
  }
  return out;
}

/**
 * Extract streamed tool-call arguments from `message_update` events.
 *
 * Pi streams tool calls via assistantMessageEvent toolcall_* deltas before
 * `tool_execution_start`. We forward these as `tool_start` updates so iOS can
 * render evolving args (notably write.content) in real time.
 */
function extractStreamingToolCallUpdate(
  event: Extract<AgentSessionEvent, { type: "message_update" }>,
): ServerMessage | null {
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
    type: "tool_start",
    tool: toolName,
    args,
    toolCallId,
  };
}

/**
 * Translate a single pi agent event into zero or more ServerMessages.
 *
 * Mutates `ctx.streamedAssistantText` and `ctx.partialResults` as a
 * side effect (streaming state for the current turn).
 */
export function translatePiEvent(
  event: AgentSessionEvent,
  ctx: TranslationContext,
): ServerMessage[] {
  const resolveToolCallId = (): string | undefined => {
    if (
      "toolCallId" in event &&
      typeof event.toolCallId === "string" &&
      event.toolCallId.length > 0
    ) {
      return event.toolCallId;
    }

    // Some pi tool events omit toolCallId but still include a stable event id.
    // Use it so stream-time IDs match trace lookup IDs.
    if ("id" in event && typeof event.id === "string" && event.id.length > 0) {
      return event.id;
    }

    return undefined;
  };

  const computeToolDelta = (lastText: string, fullText: string): string => {
    if (fullText.length === 0) return "";
    if (lastText.length === 0) return fullText;
    if (fullText === lastText) return "";
    if (fullText.startsWith(lastText)) {
      return fullText.slice(lastText.length);
    }
    // Unexpected divergence: prefer emitting full text over dropping output.
    return fullText;
  };

  switch (event.type) {
    case "agent_start":
      ctx.streamedAssistantText = "";
      return [{ type: "agent_start" }];

    case "agent_end":
      ctx.streamedAssistantText = "";
      return [{ type: "agent_end" }];

    case "turn_start":
      return [];

    case "turn_end":
      return [];

    case "message_start":
      // Structural lifecycle marker. No payload needed for iOS —
      // the message object arrives via message_end.
      return [];

    case "message_update": {
      const evt = event.assistantMessageEvent;
      if (evt?.type === "text_delta" && typeof evt.delta === "string") {
        ctx.streamedAssistantText += evt.delta;
        return [{ type: "text_delta", delta: evt.delta }];
      }
      if (evt?.type === "thinking_delta") {
        ctx.hasStreamedThinking = true;
        return [{ type: "thinking_delta", delta: evt.delta }];
      }
      if (evt?.type === "error") {
        const reason = evt.reason ?? "error";
        const errorMsg =
          typeof evt.error?.errorMessage === "string" && evt.error.errorMessage.length > 0
            ? evt.error.errorMessage
            : `Stream ${reason}`;
        return [{ type: "error", error: errorMsg }];
      }

      const toolCallUpdate = extractStreamingToolCallUpdate(event);
      if (toolCallUpdate) {
        return [toolCallUpdate];
      }

      // Other sub-events (start, text_start/end, thinking_start/end, done)
      // are redundant with top-level events or pure bookkeeping.
      return [];
    }

    case "tool_execution_start": {
      const toolCallId = resolveToolCallId();
      const callSegments = ctx.mobileRenderers?.renderCall(event.toolName, event.args || {});
      // Track tool name for shell preview decisions in subsequent updates.
      if (toolCallId) {
        ctx.toolNames.set(toolCallId, event.toolName);
      }
      return [
        {
          type: "tool_start",
          tool: event.toolName,
          args: event.args || {},
          toolCallId,
          ...(callSegments ? { callSegments } : {}),
        },
      ];
    }

    case "tool_execution_update": {
      const contents = event.partialResult?.content;
      if (!Array.isArray(contents) || contents.length === 0) return [];

      const toolCallId = resolveToolCallId();
      const messages: ServerMessage[] = [];
      const key = toolCallId ?? "";
      const toolName = ctx.toolNames.get(key) ?? event.toolName ?? "";
      const shellTool = isShellLikeTool(toolName);

      for (const block of contents) {
        const record = asRecord(block);
        if (!record) {
          continue;
        }

        const type = record.type;
        if ((type === "text" || type === "output_text") && typeof record.text === "string") {
          const fullText = record.text;

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
            messages.push({
              type: "tool_output",
              output: preview,
              toolCallId,
              mode: "replace",
              truncated: true,
              totalBytes: fullTextBytes,
            });
          } else {
            // Normal append delta behavior.
            const delta = computeToolDelta(lastText, fullText);
            if (delta) {
              messages.push({ type: "tool_output", output: delta, toolCallId });
            }
          }
        }
      }

      messages.push(...extractMediaOutputs(contents, toolCallId));
      return messages;
    }

    case "tool_execution_end": {
      const toolCallId = resolveToolCallId();
      const key = toolCallId ?? "";
      const lastText = ctx.partialResults.get(key) ?? "";
      const toolName = ctx.toolNames.get(key) ?? event.toolName ?? "";
      const shellTool = isShellLikeTool(toolName);

      // Extract final text/media from result — some tools only include output
      // at end (no partial updates), so emit missing delta here.
      const resultContents = event.result?.content;
      const messages: ServerMessage[] = [];

      if (Array.isArray(resultContents) && resultContents.length > 0) {
        const finalText = resultContents
          .map((block) => {
            const record = asRecord(block);
            if (!record) {
              return "";
            }

            const type = record.type;
            const isText = type === "text" || type === "output_text";
            return isText && typeof record.text === "string" ? record.text : "";
          })
          .join("");

        const finalTextBytes = utf8ByteCount(finalText);
        if (shellTool && finalTextBytes > SHELL_PREVIEW_THRESHOLD) {
          // Shell tool final output: always send the tail preview (no throttle).
          const preview = extractTailPreview(finalText);
          messages.push({
            type: "tool_output",
            output: preview,
            toolCallId,
            mode: "replace",
            truncated: true,
            totalBytes: finalTextBytes,
          });
        } else {
          const delta = computeToolDelta(lastText, finalText);
          if (delta.length > 0) {
            messages.push({ type: "tool_output", output: delta, toolCallId });
          }
        }

        messages.push(...extractMediaOutputs(resultContents, toolCallId));
      }

      ctx.partialResults.delete(key);
      ctx.toolNames.delete(key);
      ctx.shellPreviewLastSent.delete(key);

      // Forward structured details and error status from pi tool results.
      // Extensions emit typed details (e.g. remember: {file, redacted}, recall: {matches, topHeader})
      // and built-in tools emit BashToolDetails, ReadToolDetails, etc.
      const detailsResult = sanitizeToolResultDetails(event.result?.details);
      if (detailsResult.warnings.length > 0) {
        console.warn(
          `[session:${ctx.sessionId}] tool_end details sanitized for ${event.toolName}: ${detailsResult.warnings.join("; ")}`,
        );
      }

      const details = detailsResult.details;
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

    case "auto_compaction_start":
      return [{ type: "compaction_start", reason: event.reason ?? "threshold" }];

    case "auto_compaction_end":
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
          errorMessage: event.errorMessage ?? "retry requested",
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
        return [];
      }

      const out: ServerMessage[] = [];

      // Recover thinking only when it wasn't already streamed live.
      // Streaming sets ctx.hasStreamedThinking; recovery is for reconnect
      // catch-up scenarios where the client missed the streaming events.
      if (!ctx.hasStreamedThinking) {
        const content = message.content;
        if (Array.isArray(content)) {
          for (const block of content as unknown[]) {
            const record = asRecord(block);
            if (!record) {
              continue;
            }

            if (
              record.type === "thinking" &&
              typeof record.thinking === "string" &&
              record.thinking.length > 0
            ) {
              out.push({ type: "thinking_delta", delta: record.thinking });
            }
          }
        }
      }

      ctx.streamedAssistantText = "";
      ctx.hasStreamedThinking = false;
      return out;
    }

    default:
      return [];
  }
}

// ─── Change Stats ───

const MAX_TRACKED_CHANGED_FILES = 100;

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
    filesChanged,
    changedFiles: dedupedChangedFiles,
    changedFilesOverflow,
    addedLines: existing?.addedLines ?? 0,
    removedLines: existing?.removedLines ?? 0,
  };

  stats.mutatingToolCalls += 1;

  const path = extractChangedFilePath(rawArgs);
  if (path && !stats.changedFiles.includes(path)) {
    stats.filesChanged += 1;

    if (stats.changedFiles.length < MAX_TRACKED_CHANGED_FILES) {
      stats.changedFiles.push(path);
    } else {
      stats.changedFilesOverflow += 1;
    }
  }

  const { added, removed } = estimateLineDelta(toolName, rawArgs);
  stats.addedLines += added;
  stats.removedLines += removed;

  session.changeStats = {
    mutatingToolCalls: stats.mutatingToolCalls,
    filesChanged: stats.filesChanged,
    changedFiles: stats.changedFiles,
    ...(stats.changedFilesOverflow > 0 ? { changedFilesOverflow: stats.changedFilesOverflow } : {}),
    addedLines: stats.addedLines,
    removedLines: stats.removedLines,
  };
}

function extractChangedFilePath(rawArgs: unknown): string | null {
  if (!rawArgs || typeof rawArgs !== "object") {
    return null;
  }

  const args = rawArgs as Record<string, unknown>;
  const candidate = args.path ?? args.file_path;
  if (typeof candidate !== "string") {
    return null;
  }

  const normalized = candidate.trim();
  return normalized.length > 0 ? normalized : null;
}

function estimateLineDelta(toolName: string, rawArgs: unknown): { added: number; removed: number } {
  if (!rawArgs || typeof rawArgs !== "object") {
    return { added: 0, removed: 0 };
  }

  const args = rawArgs as Record<string, unknown>;

  if (toolName === "write") {
    const content = typeof args.content === "string" ? args.content : "";
    if (content.length === 0) {
      return { added: 0, removed: 0 };
    }
    return { added: countLines(content), removed: 0 };
  }

  const oldText = typeof args.oldText === "string" ? args.oldText : "";
  const newText = typeof args.newText === "string" ? args.newText : "";
  if (oldText.length === 0 && newText.length === 0) {
    return { added: 0, removed: 0 };
  }

  const oldLines = countLines(oldText);
  const newLines = countLines(newText);

  return {
    added: Math.max(0, newLines - oldLines),
    removed: Math.max(0, oldLines - newLines),
  };
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
 */
export function appendSessionMessage(
  session: Session,
  message: Omit<SessionMessage, "id" | "sessionId">,
): void {
  session.messageCount += 1;
  session.lastMessage = message.content.slice(0, 100);
  session.lastActivity = message.timestamp;

  // Capture first user message (immutable once set)
  if (!session.firstMessage && message.role === "user") {
    session.firstMessage = message.content.slice(0, 200);
  }

  if (message.tokens) {
    session.tokens.input += message.tokens.input;
    session.tokens.output += message.tokens.output;
  }

  if (message.cost) {
    session.cost += message.cost;
  }
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

  const usage = extractUsage(message);
  const assistantText = extractAssistantText(message);

  if (assistantText) {
    const tokens = usage ? { input: usage.input, output: usage.output } : undefined;

    appendSessionMessage(session, {
      role: "assistant",
      content: assistantText,
      timestamp: Date.now(),
      model: session.model,
      tokens,
      cost: usage?.cost,
    });
  } else if (usage) {
    session.tokens.input += usage.input;
    session.tokens.output += usage.output;
    session.cost += usage.cost;
  }

  // Track context usage for status display (matches pi TUI calculation)
  if (usage) {
    session.contextTokens = usage.input + usage.output + usage.cacheRead + usage.cacheWrite;
  }
}

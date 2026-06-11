/**
 * Read pi's JSONL session files and build session context.
 *
 * Pi saves full conversation history (including tool calls, tool results,
 * thinking, compaction, and branching) in JSONL files under the trace base dir:
 *   <traceBaseDir>/<workspaceId>/sessions/<sessionId>/agent/sessions/--work--/<timestamp>_<uuid>.jsonl
 *
 * This module reads those files and produces a structured session context
 * that iOS can render as a timeline — matching pi TUI's `buildSessionContext()`.
 *
 * Key behaviors matching pi TUI:
 * - Tree walk from leaf to root via parentId chain (not linear scan)
 * - Compaction handling: summary + kept messages + post-compaction messages
 * - Pre-compaction messages are hidden (same as pi TUI)
 * - All entry types handled: message, compaction, model_change,
 *   thinking_level_change, branch_summary, custom_message
 */

import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { createLogger } from "./logger.js";
import {
  sessionAttachmentDetailsForToolCall,
  sessionAttachmentMediaDetailsForToolResult,
} from "./session-attachments.js";

export type TraceViewMode = "context" | "full";

export interface TraceReadOptions {
  view?: TraceViewMode;
  leafId?: string | null;
  attachmentDataDir?: string;
  attachmentSessionId?: string;
}

const log = createLogger({ base: { component: "trace" } });

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

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

// ─── Trace Event Types ───

export interface TraceEvent {
  id: string;
  type: "user" | "assistant" | "toolCall" | "toolResult" | "thinking" | "system" | "compaction";
  timestamp: string;
  /** For user/assistant/system: the text content */
  text?: string;
  /** For toolCall: tool name */
  tool?: string;
  /** For toolCall: arguments object */
  args?: Record<string, unknown>;
  /** For toolResult: the tool's output */
  output?: string;
  /** For toolResult: the tool call ID it responds to */
  toolCallId?: string;
  /** For toolResult: the tool name */
  toolName?: string;
  /** For toolResult: was it an error? */
  isError?: boolean;
  /** For toolResult: structured details (expandedText, presentationFormat, etc.) */
  details?: unknown;
  /** For thinking: thinking content */
  thinking?: string;
  /** Optional semantic presentation for custom/system events. */
  presentation?: TraceEventPresentation;
}

export interface TraceEventPresentationField {
  label: string;
  value: string;
}

export interface TraceEventPresentation {
  kind: "custom";
  title: string;
  subtitle?: string;
  status?: string;
  body?: string;
  fields?: TraceEventPresentationField[];
  accent?: "info" | "success" | "warning" | "error";
}

// ─── Raw JSONL Entry (matches pi's session file format) ───

interface SessionEntry {
  type: string;
  id: string;
  parentId?: string | null;
  timestamp?: string;
  // message entries
  message?: {
    role: string;
    content: unknown;
    provider?: string;
    model?: string;
    toolCallId?: string;
    toolName?: string;
    isError?: boolean;
  };
  // compaction entries
  summary?: string;
  firstKeptEntryId?: string;
  tokensBefore?: number;
  // thinking_level_change entries
  thinkingLevel?: string;
  // model_change entries
  provider?: string;
  modelId?: string;
  // branch_summary entries
  // custom_message entries
  content?: unknown;
  display?: boolean;
  // session_info entries
  name?: string;
}

// ─── Session Context Builder ───

/**
 * Build session context from raw JSONL entries.
 *
 * Mirrors pi TUI's `buildSessionContext()`:
 * 1. Parse all entry types
 * 2. Build id → entry index
 * 3. Walk parentId chain from leaf to root
 * 4. Handle compaction: summary + kept messages + post-compaction only
 *
 * This produces the same view the user sees in pi TUI.
 */
function buildEntryPath(entries: SessionEntry[], leafId?: string | null): SessionEntry[] {
  if (entries.length === 0) return [];
  if (leafId === null) return [];

  const byId = new Map<string, SessionEntry>();
  for (const entry of entries) {
    if (entry.id) {
      byId.set(entry.id, entry);
    }
  }

  let leaf: SessionEntry | undefined;
  if (leafId !== undefined) {
    leaf = byId.get(leafId);
    if (!leaf) {
      return [];
    }
  } else {
    for (let i = entries.length - 1; i >= 0; i--) {
      const entry = entries[i];
      if (entry.type !== "session" && entry.id) {
        leaf = entry;
        break;
      }
    }
  }

  if (!leaf) return [];

  const path: SessionEntry[] = [];
  let current: SessionEntry | undefined = leaf;
  while (current) {
    path.unshift(current);
    current = current.parentId ? byId.get(current.parentId) : undefined;
  }

  return path;
}

export function findLatestForkableUserEntryId(entries: SessionEntry[]): string | undefined {
  const path = buildEntryPath(entries);
  for (let i = path.length - 1; i >= 0; i--) {
    const entry = path[i];
    if (entry.type === "message" && entry.id && entry.message?.role === "user") {
      return entry.id;
    }
  }
  return undefined;
}

export function findLatestForkableUserEntryIdFromContent(content: string): string | undefined {
  return findLatestForkableUserEntryId(parseEntries(content));
}

export function findLatestForkableUserEntryIdFromFile(filePath: string): string | undefined {
  if (!existsSync(filePath)) return undefined;
  try {
    return findLatestForkableUserEntryIdFromContent(readFileSync(filePath, "utf8"));
  } catch {
    return undefined;
  }
}

export function buildSessionContext(
  entries: SessionEntry[],
  options: TraceReadOptions = {},
): TraceEvent[] {
  if (entries.length === 0) return [];

  const view = options.view ?? "context";
  const path = buildEntryPath(entries, options.leafId);

  if (path.length === 0) return [];

  // Find the LAST compaction in the path (most recent takes precedence)
  let compaction: SessionEntry | null = null;
  for (const entry of path) {
    if (entry.type === "compaction") {
      compaction = entry;
    }
  }

  // Build the visible entries list.
  let visibleEntries: SessionEntry[];

  if (view === "full") {
    visibleEntries = path;
  } else if (compaction) {
    const compactionIdx = path.findIndex((e) => e.type === "compaction" && e.id === compaction.id);

    visibleEntries = [];

    // 1. Add compaction summary as a synthetic entry (handled below)
    // 2. Kept messages: from firstKeptEntryId to compaction
    let foundFirstKept = false;
    for (let i = 0; i < compactionIdx; i++) {
      const entry = path[i];
      if (entry.id === compaction.firstKeptEntryId) {
        foundFirstKept = true;
      }
      if (foundFirstKept) {
        visibleEntries.push(entry);
      }
    }

    // 3. Post-compaction entries
    for (let i = compactionIdx + 1; i < path.length; i++) {
      visibleEntries.push(path[i]);
    }
  } else {
    // No compaction — all path entries are visible
    visibleEntries = path;
  }

  const visibleEntryById = new Map(visibleEntries.map((entry) => [entry.id, entry]));

  // Convert visible entries to TraceEvents
  const events: TraceEvent[] = [];

  // Context view preserves existing behavior: synthetic compaction summary first.
  if (view === "context" && compaction) {
    events.push(formatCompactionEvent(compaction));
  }

  for (const entry of visibleEntries) {
    const timestamp = entry.timestamp || new Date().toISOString();

    switch (entry.type) {
      case "message":
        emitMessageEvents(entry, timestamp, events, options);
        break;

      case "compaction":
        events.push(formatCompactionEvent(entry));
        break;

      case "thinking_level_change":
        if (entry.thinkingLevel) {
          events.push({
            id: entry.id,
            type: "system",
            timestamp,
            text: `Thinking level: ${entry.thinkingLevel}`,
          });
        }
        break;

      case "model_change":
        if (entry.modelId) {
          events.push({
            id: entry.id,
            type: "system",
            timestamp,
            text: `Model: ${entry.modelId}`,
          });
        }
        break;

      case "branch_summary":
        if (entry.summary) {
          events.push({
            id: entry.id,
            type: "system",
            timestamp,
            text: `Branch context: ${entry.summary}`,
          });
        }
        break;

      case "custom_message":
        if (entry.content && entry.display !== false) {
          const text = extractText(entry.content);
          if (text) {
            const parent = entry.parentId ? visibleEntryById.get(entry.parentId) : undefined;
            if (parent?.type === "custom") {
              break;
            }
            const presentation = customPresentationFromText(text);
            events.push({
              id: entry.id,
              type: "system",
              timestamp,
              text: textFromPresentation(presentation),
              presentation,
            });
          }
        }
        break;

      case "custom":
        // Pi CustomEntry records are extension persistence state from appendEntry().
        // They do not participate in LLM context and are not timeline presentation.
        break;

      // Skip non-renderable types (session, label, etc.)
      default:
        break;
    }
  }

  return events;
}

function formatCompactionEvent(entry: SessionEntry): TraceEvent {
  const summaryText = entry.summary || "Previous context was compacted";
  const tokenInfo = entry.tokensBefore ? ` (${entry.tokensBefore.toLocaleString()} tokens)` : "";

  return {
    id: entry.id,
    type: "compaction",
    timestamp: entry.timestamp || new Date().toISOString(),
    text: `Context compacted${tokenInfo}: ${summaryText}`,
  };
}

function customPresentationFromText(text: string): TraceEventPresentation {
  const trimmed = text.trim();
  const rootMatch = trimmed.match(/^<([A-Za-z][\w:-]*)[\s>]/);
  if (!rootMatch) {
    const lines = trimmed
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);
    const firstLine = lines[0] ?? "";
    const title = firstLine.length > 120 ? "Custom Message" : firstLine || "Custom Message";
    const body = firstLine.length > 120 ? trimmed : lines.slice(1).join("\n").trim();
    return {
      kind: "custom",
      title: truncateCustomField(title),
      ...(body ? { body } : {}),
      accent: "info",
    };
  }

  const rootName = rootMatch[1] ?? "custom-message";
  const rootBodyMatch = trimmed.match(
    new RegExp(`^<${rootName}[^>]*>([\\s\\S]*)</${rootName}>$`, "i"),
  );
  const body = rootBodyMatch?.[1] ?? trimmed;
  const fields: TraceEventPresentationField[] = [];
  const tagRegex = /<([A-Za-z][\w:-]*)>([\s\S]*?)<\/\1>/g;
  let match: RegExpExecArray | null;
  while ((match = tagRegex.exec(body))) {
    const name = match[1] ?? "";
    const value = (match[2] ?? "").trim();
    if (!name || !value || value.includes("<")) continue;
    fields.push({ label: titleFromIdentifier(name), value: collapseWhitespace(value) });
  }

  if (fields.length === 0) {
    return {
      kind: "custom",
      title: titleFromIdentifier(rootName),
      body: trimmed,
      accent: "info",
    };
  }

  const sortedFields = sortPresentationFields(fields);
  const status = firstFieldValue(sortedFields, "Status");

  return {
    kind: "custom",
    title: titleFromIdentifier(rootName),
    ...(status ? { status } : {}),
    fields: sortedFields.slice(0, 8).map((field) => ({
      label: field.label,
      value: truncateCustomField(field.value),
    })),
    accent: accentForStatus(status),
  };
}

function titleFromIdentifier(value: string): string {
  return value
    .replace(/[_:-]+/g, " ")
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .trim()
    .replace(/\b\w/g, (char) => char.toUpperCase());
}

function collapseWhitespace(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

function truncateCustomField(value: string): string {
  return value.length <= 500 ? value : `${value.slice(0, 497)}…`;
}

function sortPresentationFields(
  fields: TraceEventPresentationField[],
): TraceEventPresentationField[] {
  const priority = new Map([
    ["Status", 0],
    ["Summary", 1],
    ["Description", 2],
    ["Result", 3],
    ["Type", 4],
    ["Id", 5],
  ]);
  return [...fields].sort((a, b) => (priority.get(a.label) ?? 10) - (priority.get(b.label) ?? 10));
}

function firstFieldValue(fields: TraceEventPresentationField[], label: string): string | undefined {
  return fields.find((field) => field.label === label)?.value;
}

function accentForStatus(status: string | undefined): TraceEventPresentation["accent"] {
  switch (status?.toLowerCase()) {
    case "completed":
    case "complete":
    case "success":
    case "succeeded":
      return "success";
    case "warning":
    case "warn":
    case "retrying":
      return "warning";
    case "error":
    case "failed":
    case "failure":
      return "error";
    default:
      return "info";
  }
}

function textFromPresentation(presentation: TraceEventPresentation): string {
  const lines = [presentation.title];
  if (presentation.subtitle) lines.push(presentation.subtitle);
  if (presentation.body) lines.push("", presentation.body);
  for (const field of presentation.fields ?? []) {
    lines.push(`${field.label}: ${field.value}`);
  }
  return lines.join("\n");
}

/**
 * Emit TraceEvents for a single message entry.
 * Handles user, assistant (with text/thinking/toolCall blocks), and toolResult.
 */
function emitMessageEvents(
  entry: SessionEntry,
  timestamp: string,
  events: TraceEvent[],
  options: TraceReadOptions = {},
): void {
  const msg = entry.message;
  if (!msg) return;

  const role = msg.role;
  const content = msg.content;

  if (role === "user") {
    const text = extractText(content);
    if (text) {
      events.push({
        id: entry.id,
        type: "user",
        timestamp,
        text,
      });
    }
  } else if (role === "assistant") {
    if (Array.isArray(content)) {
      let subIdx = 0;
      for (const block of content) {
        const b = block as Record<string, unknown>;
        if (isTextBlock(b)) {
          events.push({
            id: `${entry.id}-text-${subIdx++}`,
            type: "assistant",
            timestamp,
            text: b.text,
          });
        } else if (b.type === "thinking" && b.thinking) {
          events.push({
            id: `${entry.id}-think-${subIdx++}`,
            type: "thinking",
            timestamp,
            thinking: b.thinking as string,
          });
        } else if (b.type === "toolCall") {
          events.push({
            id: (b.id as string) || `${entry.id}-tool-${subIdx++}`,
            type: "toolCall",
            timestamp,
            tool: (b.name as string) || "unknown",
            args: (b.arguments as Record<string, unknown>) || tryParseJson(b.partialJson),
          });
        } else if (b.type && !KNOWN_BLOCK_TYPES.has(b.type as string)) {
          // Unknown content block type — log so new API formats don't
          // silently vanish from the timeline.
          log.warn("trace.unknown_assistant_block_type", {
            entryId: entry.id,
            blockType: b.type as string,
          });
        }
      }
    } else if (typeof content === "string" && content) {
      events.push({
        id: entry.id,
        type: "assistant",
        timestamp,
        text: content,
      });
    }
  } else if (role === "toolResult") {
    // pi's ToolResultMessage carries structured details (expandedText,
    // presentationFormat, etc.) used by extensions for rich rendering.
    // The message object is the raw JSONL entry — details lives on msg
    // as a peer of role/content/toolCallId.
    const rawMsg = msg as Record<string, unknown>;
    const rawDetails =
      rawMsg.details !== undefined && rawMsg.details !== null ? rawMsg.details : undefined;
    const mediaDetails =
      options.attachmentDataDir && options.attachmentSessionId
        ? sessionAttachmentMediaDetailsForToolResult(
            options.attachmentDataDir,
            options.attachmentSessionId,
            msg.toolCallId,
            content,
            rawDetails,
          )
        : [];
    const output = extractText(content, { includeMediaDataURIs: mediaDetails.length === 0 });
    const replayDetails =
      rawDetails !== undefined && options.attachmentDataDir && options.attachmentSessionId
        ? sessionAttachmentDetailsForToolCall(
            options.attachmentDataDir,
            options.attachmentSessionId,
            msg.toolCallId,
            rawDetails,
          )
        : rawDetails;
    const details = normalizeAudioPresentationDetails(
      mediaDetails.length > 0
        ? { ...(asRecord(replayDetails) ?? {}), media: mediaDetails }
        : replayDetails,
    );
    events.push({
      id: `result-${entry.id}`,
      type: "toolResult",
      timestamp,
      toolCallId: msg.toolCallId,
      toolName: msg.toolName,
      output: output || "",
      isError: msg.isError === true,
      ...(details !== undefined ? { details } : {}),
    });
  }
}

// ─── JSONL Parsing ───

/**
 * Parse raw JSONL content into session entries.
 */
function parseEntries(content: string): SessionEntry[] {
  const entries: SessionEntry[] = [];
  for (const line of content.split("\n")) {
    if (!line.trim()) continue;
    try {
      entries.push(JSON.parse(line) as SessionEntry);
    } catch {
      // Skip malformed lines
    }
  }
  return entries;
}

/**
 * Parse JSONL content and build session context.
 *
 * This is the main entry point — equivalent to pi TUI's
 * `loadEntriesFromFile()` + `buildSessionContext()`.
 */
export function parseJsonl(content: string, options: TraceReadOptions = {}): TraceEvent[] {
  const entries = parseEntries(content);
  return buildSessionContext(entries, options);
}

// ─── JSONL File Readers ───

/**
 * Find and read the latest pi JSONL file for a workspace-scoped session trace dir.
 *
 * Layout:
 *   <traceBaseDir>/<workspaceId>/sessions/<sessionId>/agent/sessions/--work--/*.jsonl
 */
export function readSessionTrace(
  traceBaseDir: string,
  sessionId: string,
  workspaceId?: string,
  options: TraceReadOptions = {},
): TraceEvent[] | null {
  if (!workspaceId) return null;

  const sessionsDir = join(
    traceBaseDir,
    workspaceId,
    "sessions",
    sessionId,
    "agent",
    "sessions",
    "--work--",
  );

  const trace = readTraceFromDir(sessionsDir, {
    ...options,
    attachmentDataDir: options.attachmentDataDir ?? traceBaseDir,
    attachmentSessionId: options.attachmentSessionId ?? sessionId,
  });
  return trace && trace.length > 0 ? trace : null;
}

/**
 * Read a specific JSONL file by pi session UUID.
 */
export function readSessionTraceByUuid(
  traceBaseDir: string,
  piSessionUuid: string,
  workspaceId?: string,
  options: TraceReadOptions = {},
): TraceEvent[] | null {
  const candidateDirs = collectWorkspaceTraceDirs(traceBaseDir, workspaceId);

  for (const sessionsDir of candidateDirs) {
    if (!existsSync(sessionsDir)) continue;
    const file = readdirSync(sessionsDir).find((f) => f.includes(piSessionUuid));
    if (file) {
      return readSessionTraceFromFile(join(sessionsDir, file), options);
    }
  }

  return null;
}

function collectWorkspaceTraceDirs(traceBaseDir: string, workspaceId?: string): string[] {
  if (workspaceId) {
    const workspaceSessionsDir = join(traceBaseDir, workspaceId, "sessions");
    if (!existsSync(workspaceSessionsDir)) return [];

    return readdirSync(workspaceSessionsDir).map((sessionDir) =>
      join(workspaceSessionsDir, sessionDir, "agent", "sessions", "--work--"),
    );
  }

  const baseDir = traceBaseDir;
  if (!existsSync(baseDir)) return [];

  const traceDirs: string[] = [];
  for (const workspaceDir of readdirSync(baseDir)) {
    if (workspaceDir.startsWith(".") || workspaceDir.startsWith("_")) continue;

    const workspaceSessionsDir = join(baseDir, workspaceDir, "sessions");
    if (!existsSync(workspaceSessionsDir)) continue;

    for (const sessionDir of readdirSync(workspaceSessionsDir)) {
      traceDirs.push(join(workspaceSessionsDir, sessionDir, "agent", "sessions", "--work--"));
    }
  }

  return traceDirs;
}

/**
 * Read and parse a session context from an absolute JSONL file path.
 */
export function readSessionTraceFromFile(
  jsonlPath: string,
  options: TraceReadOptions = {},
): TraceEvent[] | null {
  if (!existsSync(jsonlPath)) return null;

  try {
    const content = readFileSync(jsonlPath, "utf-8");
    return parseJsonl(content, options);
  } catch {
    return null;
  }
}

/**
 * Read and merge session context from multiple JSONL file paths.
 *
 * For multi-file sessions, we concatenate all entries (sorted by file name
 * which is chronological) then build context once.
 */
export function readSessionTraceFromFiles(
  jsonlPaths: string[],
  options: TraceReadOptions = {},
): TraceEvent[] | null {
  const uniqueSorted = Array.from(new Set(jsonlPaths)).sort();
  const allEntries: SessionEntry[] = [];

  for (const path of uniqueSorted) {
    if (!existsSync(path)) continue;
    try {
      const content = readFileSync(path, "utf-8");
      const entries = parseEntries(content);
      allEntries.push(...entries);
    } catch {
      // Skip unreadable files
    }
  }

  if (allEntries.length === 0) return null;
  const events = buildSessionContext(allEntries, options);
  return events.length > 0 ? events : null;
}

function readTraceFromDir(
  sessionsDir: string,
  options: TraceReadOptions = {},
): TraceEvent[] | null {
  if (!existsSync(sessionsDir)) return null;

  const files = readdirSync(sessionsDir)
    .filter((f) => f.endsWith(".jsonl"))
    .sort(); // timestamp prefix => chronological order

  if (files.length === 0) return null;

  // Collect all entries across files, then build context once
  const allEntries: SessionEntry[] = [];
  for (const file of files) {
    try {
      const content = readFileSync(join(sessionsDir, file), "utf-8");
      const entries = parseEntries(content);
      allEntries.push(...entries);
    } catch {
      // Skip unreadable files
    }
  }

  if (allEntries.length === 0) return null;
  const events = buildSessionContext(allEntries, options);
  return events.length > 0 ? events : null;
}

// ─── Tool Output Lookup ───

/**
 * Find the full tool result for a specific toolCallId in a JSONL file.
 *
 * Scans the JSONL for a `toolResult` message whose `toolCallId` matches.
 * Returns the output text and error flag, or null if not found.
 *
 * This is cheaper than parsing the full context — it stops at the first match
 * and only extracts the content we need.
 */
export function findToolOutput(
  jsonlPath: string,
  toolCallId: string,
): { text: string; isError: boolean } | null {
  if (!existsSync(jsonlPath)) return null;

  let content: string;
  try {
    content = readFileSync(jsonlPath, "utf-8");
  } catch {
    return null;
  }

  for (const line of content.split("\n")) {
    if (!line.trim()) continue;

    let entry: SessionEntry;
    try {
      entry = JSON.parse(line) as SessionEntry;
    } catch {
      continue;
    }

    if (entry.type !== "message") continue;

    const msg = entry.message;
    if (!msg || msg.role !== "toolResult") continue;
    if (msg.toolCallId !== toolCallId) continue;

    return {
      text: extractText(msg.content),
      isError: msg.isError === true,
    };
  }

  return null;
}

// ─── Helpers ───

/** Content block types that carry displayable text. Single source of truth
 *  for both `emitMessageEvents` (assistant blocks) and `extractText`
 *  (user/toolResult). Add new text-carrying types here. */
const TEXT_BLOCK_TYPES: ReadonlySet<string> = new Set(["text", "output_text"]);

function isTextBlock(b: Record<string, unknown>): b is { type: string; text: string } {
  return TEXT_BLOCK_TYPES.has(b.type as string) && typeof b.text === "string" && b.text.length > 0;
}

/** Known non-text block types that are handled elsewhere (thinking, toolCall,
 *  image, audio). Used to detect truly unknown block types. */
const KNOWN_BLOCK_TYPES: ReadonlySet<string> = new Set([
  ...TEXT_BLOCK_TYPES,
  "thinking",
  "toolCall",
  "image",
  "audio",
  "output_audio",
]);

function extractText(content: unknown, options: { includeMediaDataURIs?: boolean } = {}): string {
  const includeMediaDataURIs = options.includeMediaDataURIs ?? true;
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((b: Record<string, unknown>) => {
        if (isTextBlock(b)) {
          return b.text;
        }
        // Image/audio content blocks -> data URI so iOS extractors can render them
        if (includeMediaDataURIs && b.type === "image" && b.data) {
          const mime = (b.mimeType as string) || "image/png";
          return `data:${mime};base64,${b.data}`;
        }
        if (includeMediaDataURIs && (b.type === "audio" || b.type === "output_audio") && b.data) {
          const mime = (b.mimeType as string) || "audio/wav";
          return `data:${mime};base64,${b.data}`;
        }
        return null;
      })
      .filter(Boolean)
      .join("\n");
  }
  return "";
}

function tryParseJson(s: unknown): Record<string, unknown> | undefined {
  if (typeof s !== "string") return undefined;
  try {
    return JSON.parse(s) as Record<string, unknown>;
  } catch {
    return undefined;
  }
}

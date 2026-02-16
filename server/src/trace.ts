/**
 * Read pi's JSONL session files and build session context.
 *
 * Pi saves full conversation history (including tool calls, tool results,
 * thinking, compaction, and branching) in JSONL files inside the sandbox:
 *   <sandboxBaseDir>/<workspaceId>/sessions/<sessionId>/agent/sessions/--work--/<timestamp>_<uuid>.jsonl
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

export type TraceViewMode = "context" | "full";

export interface TraceReadOptions {
  view?: TraceViewMode;
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
  /** For thinking: thinking content */
  thinking?: string;
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
  customType?: string;
  content?: unknown;
  display?: boolean;
  details?: unknown;
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
export function buildSessionContext(
  entries: SessionEntry[],
  options: TraceReadOptions = {},
): TraceEvent[] {
  if (entries.length === 0) return [];

  const view = options.view ?? "context";

  // Build id → entry index
  const byId = new Map<string, SessionEntry>();
  for (const entry of entries) {
    if (entry.id) {
      byId.set(entry.id, entry);
    }
  }

  // Find leaf (last entry with an id, excluding the session header)
  let leaf: SessionEntry | undefined;
  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i];
    if (entry.type !== "session" && entry.id) {
      leaf = entry;
      break;
    }
  }

  if (!leaf) return [];

  // Walk parentId chain from leaf to root, collecting the path
  const path: SessionEntry[] = [];
  let current: SessionEntry | undefined = leaf;
  while (current) {
    path.unshift(current);
    current = current.parentId ? byId.get(current.parentId) : undefined;
  }

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

  // Convert visible entries to TraceEvents
  const events: TraceEvent[] = [];
  let eventCounter = 0;

  // Context view preserves existing behavior: synthetic compaction summary first.
  if (view === "context" && compaction) {
    events.push(formatCompactionEvent(compaction));
  }

  for (const entry of visibleEntries) {
    const timestamp = entry.timestamp || new Date().toISOString();

    switch (entry.type) {
      case "message":
        emitMessageEvents(entry, timestamp, events, eventCounter);
        eventCounter += 10; // Reserve IDs for sub-events
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
            events.push({
              id: entry.id,
              type: "system",
              timestamp,
              text,
            });
          }
        }
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
  const tokenInfo = entry.tokensBefore
    ? ` (${entry.tokensBefore.toLocaleString()} tokens)`
    : "";

  return {
    id: entry.id,
    type: "compaction",
    timestamp: entry.timestamp || new Date().toISOString(),
    text: `Context compacted${tokenInfo}: ${summaryText}`,
  };
}

/**
 * Emit TraceEvents for a single message entry.
 * Handles user, assistant (with text/thinking/toolCall blocks), and toolResult.
 */
function emitMessageEvents(
  entry: SessionEntry,
  timestamp: string,
  events: TraceEvent[],
  _counterBase: number,
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
        if (b.type === "text" && b.text) {
          events.push({
            id: `${entry.id}-text-${subIdx++}`,
            type: "assistant",
            timestamp,
            text: b.text as string,
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
            tool: b.name as string,
            args: (b.arguments as Record<string, unknown>) || tryParseJson(b.partialJson),
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
    const output = extractText(content);
    events.push({
      id: `result-${entry.id}`,
      type: "toolResult",
      timestamp,
      toolCallId: msg.toolCallId,
      toolName: msg.toolName,
      output: output || "",
      isError: msg.isError === true,
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
 * Find and read the latest pi JSONL file for a workspace-scoped session sandbox.
 *
 * Layout:
 *   <sandboxBaseDir>/<workspaceId>/sessions/<sessionId>/agent/sessions/--work--/*.jsonl
 */
export function readSessionTrace(
  sandboxBaseDir: string,
  sessionId: string,
  workspaceId?: string,
  options: TraceReadOptions = {},
): TraceEvent[] | null {
  if (!workspaceId) return null;

  const sessionsDir = join(
    sandboxBaseDir,
    workspaceId,
    "sessions",
    sessionId,
    "agent",
    "sessions",
    "--work--",
  );

  const trace = readTraceFromDir(sessionsDir, options);
  return trace && trace.length > 0 ? trace : null;
}

/**
 * Read a specific JSONL file by pi session UUID.
 */
export function readSessionTraceByUuid(
  sandboxBaseDir: string,
  piSessionUuid: string,
  workspaceId?: string,
  options: TraceReadOptions = {},
): TraceEvent[] | null {
  const candidateDirs = collectWorkspaceTraceDirs(sandboxBaseDir, workspaceId);

  for (const sessionsDir of candidateDirs) {
    if (!existsSync(sessionsDir)) continue;
    const file = readdirSync(sessionsDir).find((f) => f.includes(piSessionUuid));
    if (file) {
      return readSessionTraceFromFile(join(sessionsDir, file), options);
    }
  }

  return null;
}

function collectWorkspaceTraceDirs(
  sandboxBaseDir: string,
  workspaceId?: string,
): string[] {
  if (workspaceId) {
    const workspaceSessionsDir = join(sandboxBaseDir, workspaceId, "sessions");
    if (!existsSync(workspaceSessionsDir)) return [];

    return readdirSync(workspaceSessionsDir).map((sessionDir) =>
      join(workspaceSessionsDir, sessionDir, "agent", "sessions", "--work--"),
    );
  }

  const baseDir = sandboxBaseDir;
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

function extractText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((b: Record<string, unknown>) => {
        if ((b.type === "text" || b.type === "output_text") && b.text) {
          return b.text as string;
        }
        // Image/audio content blocks -> data URI so iOS extractors can render them
        if (b.type === "image" && b.data) {
          const mime = (b.mimeType as string) || "image/png";
          return `data:${mime};base64,${b.data}`;
        }
        if ((b.type === "audio" || b.type === "output_audio") && b.data) {
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

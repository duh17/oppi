/**
 * Read pi's JSONL session files and convert to trace events.
 *
 * Pi saves full conversation history (including tool calls, tool results,
 * and thinking) in JSONL files inside the sandbox:
 *   <sandboxBaseDir>/<userId>/agent/sessions/--work--/<timestamp>_<uuid>.jsonl
 *
 * This module reads those files and produces a structured trace that iOS
 * can render as a full timeline (tool calls, output, thinking, etc).
 */

import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";

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

// ─── JSONL Reader ───

/**
 * Find and read the latest pi JSONL file for a session sandbox.
 *
 * Layout:
 *   <sandboxBaseDir>/<userId>/<sessionId>/agent/sessions/--work--/*.jsonl
 */
export function readSessionTrace(sandboxBaseDir: string, userId: string, sessionId: string): TraceEvent[] | null {
  const sessionsDir = join(sandboxBaseDir, userId, sessionId, "agent", "sessions", "--work--");
  return readTraceFromDir(sessionsDir);
}

/**
 * Read a specific JSONL file by pi session UUID.
 */
export function readSessionTraceByUuid(
  sandboxBaseDir: string,
  userId: string,
  piSessionUuid: string,
): TraceEvent[] | null {
  const sessionsDir = join(sandboxBaseDir, userId, "agent", "sessions", "--work--");
  if (!existsSync(sessionsDir)) return null;

  const file = readdirSync(sessionsDir).find(f => f.includes(piSessionUuid));
  if (!file) return null;

  return readSessionTraceFromFile(join(sessionsDir, file));
}

/**
 * Read and parse a trace from an absolute JSONL file path.
 */
export function readSessionTraceFromFile(jsonlPath: string): TraceEvent[] | null {
  if (!existsSync(jsonlPath)) return null;

  try {
    const content = readFileSync(jsonlPath, "utf-8");
    return parseJsonl(content);
  } catch {
    return null;
  }
}

/**
 * Read and merge traces from multiple explicit JSONL file paths.
 */
export function readSessionTraceFromFiles(jsonlPaths: string[]): TraceEvent[] | null {
  const uniqueSorted = Array.from(new Set(jsonlPaths)).sort();
  const merged: TraceEvent[] = [];

  for (const path of uniqueSorted) {
    const trace = readSessionTraceFromFile(path);
    if (trace?.length) {
      merged.push(...trace);
    }
  }

  return merged.length > 0 ? merged : null;
}

function readTraceFromDir(sessionsDir: string): TraceEvent[] | null {
  if (!existsSync(sessionsDir)) return null;

  const files = readdirSync(sessionsDir)
    .filter(f => f.endsWith(".jsonl"))
    .sort(); // timestamp prefix => chronological order

  if (files.length === 0) return null;

  const merged: TraceEvent[] = [];
  for (const file of files) {
    const trace = readSessionTraceFromFile(join(sessionsDir, file));
    if (trace?.length) {
      merged.push(...trace);
    }
  }

  return merged.length > 0 ? merged : null;
}

// ─── Parser ───

export function parseJsonl(content: string): TraceEvent[] {
  const events: TraceEvent[] = [];
  let eventCounter = 0;

  for (const line of content.split("\n")) {
    if (!line.trim()) continue;

    let entry: any;
    try {
      entry = JSON.parse(line);
    } catch {
      continue;
    }

    if (entry.type !== "message") continue;

    const msg = entry.message;
    if (!msg) continue;

    const timestamp = entry.timestamp || new Date().toISOString();
    const role = msg.role;
    const content = msg.content;

    if (role === "user") {
      const text = extractText(content);
      if (text) {
        events.push({
          id: entry.id || `trace-${eventCounter++}`,
          type: "user",
          timestamp,
          text,
        });
      }
    } else if (role === "assistant") {
      // Assistant messages can contain text, thinking, and toolCall blocks
      if (Array.isArray(content)) {
        for (const block of content) {
          if (block.type === "text" && block.text) {
            events.push({
              id: `${entry.id || "msg"}-text-${eventCounter++}`,
              type: "assistant",
              timestamp,
              text: block.text,
            });
          } else if (block.type === "thinking" && block.thinking) {
            events.push({
              id: `${entry.id || "msg"}-think-${eventCounter++}`,
              type: "thinking",
              timestamp,
              thinking: block.thinking,
            });
          } else if (block.type === "toolCall") {
            events.push({
              id: block.id || `tool-${eventCounter++}`,
              type: "toolCall",
              timestamp,
              tool: block.name,
              args: block.arguments || tryParseJson(block.partialJson),
            });
          }
        }
      } else if (typeof content === "string" && content) {
        events.push({
          id: entry.id || `trace-${eventCounter++}`,
          type: "assistant",
          timestamp,
          text: content,
        });
      }
    } else if (role === "toolResult") {
      const output = extractText(content);
      events.push({
        id: `result-${eventCounter++}`,
        type: "toolResult",
        timestamp,
        toolCallId: msg.toolCallId,
        toolName: msg.toolName,
        output: output || "",
        isError: msg.isError === true,
      });
    }
  }

  return events;
}

// ─── Tool Output Lookup ───

/**
 * Find the full tool result for a specific toolCallId in a JSONL file.
 *
 * Scans the JSONL for a `toolResult` message whose `toolCallId` matches.
 * Returns the output text and error flag, or null if not found.
 *
 * This is cheaper than parsing the full trace — it stops at the first match
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

    let entry: any;
    try {
      entry = JSON.parse(line);
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

function extractText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((b: any) => {
        if ((b.type === "text" || b.type === "output_text") && b.text) {
          return b.text;
        }
        // Image content blocks → data URI so iOS ImageExtractor can render them
        if (b.type === "image" && b.data) {
          const mime = b.mimeType || "image/png";
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
    return JSON.parse(s);
  } catch {
    return undefined;
  }
}

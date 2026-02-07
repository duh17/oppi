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
 * Find and read the pi JSONL file for a given session's sandbox.
 *
 * Layout: <sandboxBaseDir>/<userId>/<sessionId>/agent/sessions/--work--/*.jsonl
 *
 * Returns null if no JSONL found (session never ran, or sandbox cleaned up).
 */
export function readSessionTrace(sandboxBaseDir: string, userId: string, sessionId: string): TraceEvent[] | null {
  const sessionsDir = join(sandboxBaseDir, userId, sessionId, "agent", "sessions", "--work--");

  if (!existsSync(sessionsDir)) return null;

  // Find the most recent JSONL file (each pi run creates one)
  const files = readdirSync(sessionsDir)
    .filter(f => f.endsWith(".jsonl"))
    .sort()  // Timestamp prefix makes alphabetical = chronological
    .reverse();

  if (files.length === 0) return null;

  // Read the most recent session file
  const jsonlPath = join(sessionsDir, files[0]);
  const content = readFileSync(jsonlPath, "utf-8");

  return parseJsonl(content);
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

  const content = readFileSync(join(sessionsDir, file), "utf-8");
  return parseJsonl(content);
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

function extractText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .filter((b: any) => (b.type === "text" || b.type === "output_text") && b.text)
      .map((b: any) => b.text)
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

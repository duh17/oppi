import { createHash } from "node:crypto";
import { createReadStream, statSync } from "node:fs";
import { createInterface } from "node:readline";
import { performance } from "node:perf_hooks";
import type { SessionEntry } from "./trace.js";

export type TraceOutlineEntryKind =
  | "user"
  | "assistant"
  | "thinking"
  | "tool"
  | "system"
  | "compaction"
  | "custom";

export interface TraceOutlineEntry {
  id: string;
  kind: TraceOutlineEntryKind;
  summary: string;
  timestamp: string;
  isMessage: boolean;
  isTool: boolean;
  passesAllFilter: boolean;
  isForkable?: boolean;
  tool?: string;
  isError?: boolean;
}

export interface TraceOutlineSnapshot {
  traceVersion: string;
  entries: TraceOutlineEntry[];
  itemCount: number;
  sourceCount: number;
  jsonlBytes: number;
}

export interface TraceOutlineMetrics {
  rawEntryCount: number;
  outlineEntryCount: number;
  jsonlBytes: number;
  readMs: number;
  parseMs: number;
  projectMs: number;
}

export interface TraceOutlineResult {
  outline: TraceOutlineSnapshot;
  metrics: TraceOutlineMetrics;
}

interface TraceOutlineSource {
  path: string;
  size: number;
  mtimeMs: number;
}

const MAX_SUMMARY_CHARS = 160;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function readSessionTraceOutlineFromFiles(
  jsonlPaths: string[],
): Promise<TraceOutlineResult> {
  const sources = traceOutlineSources(jsonlPaths);
  const jsonlBytes = sources.reduce((sum, source) => sum + source.size, 0);
  const sessionEntries: SessionEntry[] = [];
  const entries: TraceOutlineEntry[] = [];
  const toolRowsByCallId = new Map<string, TraceOutlineEntry>();
  let rawEntryCount = 0;
  let readMs = 0;
  let parseMs = 0;
  let projectMs = 0;

  for (const source of sources) {
    const readStart = performance.now();
    const rl = createInterface({
      input: createReadStream(source.path, { encoding: "utf8" }),
      crlfDelay: Infinity,
    });

    for await (const line of rl) {
      const trimmed = line.trim();
      if (!trimmed) {
        continue;
      }

      const parseStart = performance.now();
      const entry = parseOutlineEntryLine(trimmed);
      parseMs += elapsed(parseStart);
      if (!entry) {
        continue;
      }
      rawEntryCount += 1;
      sessionEntries.push(entry);
    }
    readMs += elapsed(readStart);
  }

  const projectStart = performance.now();
  for (const entry of currentSessionEntryPath(sessionEntries)) {
    projectEntry(entry, entries, toolRowsByCallId);
  }
  projectMs += elapsed(projectStart);

  return {
    outline: {
      traceVersion: traceVersionFor(sources),
      entries,
      itemCount: entries.length,
      sourceCount: sources.length,
      jsonlBytes,
    },
    metrics: {
      rawEntryCount,
      outlineEntryCount: entries.length,
      jsonlBytes,
      readMs,
      parseMs,
      projectMs,
    },
  };
}

function elapsed(startMs: number): number {
  return Math.round((performance.now() - startMs) * 100) / 100;
}

function traceOutlineSources(jsonlPaths: string[]): TraceOutlineSource[] {
  return Array.from(new Set(jsonlPaths))
    .sort()
    .flatMap((path) => {
      try {
        const stats = statSync(path);
        if (!stats.isFile()) return [];
        return [{ path, size: stats.size, mtimeMs: stats.mtimeMs }];
      } catch {
        return [];
      }
    });
}

function traceVersionFor(sources: TraceOutlineSource[]): string {
  if (sources.length === 0) return "";
  const totalBytes = sources.reduce((sum, source) => sum + source.size, 0);
  const latestMtime = Math.max(...sources.map((source) => Math.trunc(source.mtimeMs)));
  const identity = createHash("sha256")
    .update(
      sources
        .map((source) => `${source.path}:${source.size}:${Math.trunc(source.mtimeMs)}`)
        .join("|"),
    )
    .digest("base64url")
    .slice(0, 12);
  return `${sources.length}:${totalBytes}:${latestMtime}:${identity}`;
}

function parseOutlineEntryLine(line: string): SessionEntry | null {
  if (line.includes('"role":"toolResult"')) {
    const toolCallId = readJsonStringField(line, "toolCallId");
    if (!toolCallId) return null;
    return {
      type: "message",
      id: readJsonStringField(line, "id") ?? `result-${toolCallId}`,
      parentId: readJsonNullableStringField(line, "parentId"),
      timestamp: readJsonStringField(line, "timestamp"),
      message: {
        role: "toolResult",
        content: "",
        toolCallId,
        toolName: readJsonStringField(line, "toolName"),
        isError: line.includes('"isError":true'),
      },
    };
  }

  try {
    return JSON.parse(line) as SessionEntry;
  } catch {
    return null;
  }
}

function readJsonStringField(line: string, field: string): string | undefined {
  const match = new RegExp(`"${field}":"((?:\\\\.|[^"\\\\])*)"`).exec(line);
  if (!match?.[1]) return undefined;
  return unescapeJsonString(match[1]);
}

function readJsonNullableStringField(line: string, field: string): string | null | undefined {
  if (line.includes(`"${field}":null`)) return null;
  return readJsonStringField(line, field);
}

function unescapeJsonString(value: string): string {
  if (!value.includes("\\")) return value;
  try {
    return JSON.parse(`"${value}"`) as string;
  } catch {
    return value;
  }
}

function currentSessionEntryPath(entries: SessionEntry[]): SessionEntry[] {
  if (entries.length === 0) return [];

  const byId = new Map<string, SessionEntry>();
  for (const entry of entries) {
    if (entry.id) {
      byId.set(entry.id, entry);
    }
  }

  let leaf: SessionEntry | undefined;
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (entry?.type !== "session" && entry?.id) {
      leaf = entry;
      break;
    }
  }
  if (!leaf) return [];

  const path: SessionEntry[] = [];
  const seen = new Set<string>();
  let current: SessionEntry | undefined = leaf;
  while (current) {
    if (seen.has(current.id)) break;
    seen.add(current.id);
    path.unshift(current);
    current = current.parentId ? byId.get(current.parentId) : undefined;
  }
  return path;
}

function projectEntry(
  entry: SessionEntry,
  entries: TraceOutlineEntry[],
  toolRowsByCallId: Map<string, TraceOutlineEntry>,
): void {
  if (typeof entry.id !== "string" || entry.id.length === 0) return;

  const timestamp = entry.timestamp ?? "";

  switch (entry.type) {
    case "message":
      projectMessageEntry(entry, entries, toolRowsByCallId, timestamp);
      return;

    case "compaction":
      entries.push({
        id: entry.id,
        kind: "compaction",
        summary:
          typeof entry.tokensBefore === "number"
            ? `Context compacted (${entry.tokensBefore.toLocaleString()} tokens)`
            : "Context compacted",
        timestamp,
        isMessage: false,
        isTool: false,
        passesAllFilter: true,
      });
      return;

    case "branch_summary": {
      const summary = previewText(String(entry.summary || ""));
      if (!summary) return;
      entries.push({
        id: entry.id,
        kind: "system",
        summary: `Branch context: ${summary}`,
        timestamp,
        isMessage: false,
        isTool: false,
        passesAllFilter: true,
      });
      return;
    }

    case "custom_message": {
      if (entry.display === false) return;
      const summary = previewText(extractText(entry.content));
      if (!summary) return;
      entries.push({
        id: entry.id,
        kind: "custom",
        summary,
        timestamp,
        isMessage: false,
        isTool: false,
        passesAllFilter: true,
      });
      return;
    }

    default:
      return;
  }
}

function projectMessageEntry(
  entry: SessionEntry,
  entries: TraceOutlineEntry[],
  toolRowsByCallId: Map<string, TraceOutlineEntry>,
  timestamp: string,
): void {
  const message = entry.message;
  if (!message) return;

  switch (message.role) {
    case "user": {
      const summary = previewText(extractText(message.content));
      if (!summary) return;
      entries.push({
        id: entry.id,
        kind: "user",
        summary,
        timestamp,
        isMessage: true,
        isTool: false,
        passesAllFilter: true,
        isForkable: !UUID_RE.test(entry.id),
      });
      return;
    }

    case "assistant":
      projectAssistantEntry(entry, entries, toolRowsByCallId, timestamp);
      return;

    case "toolResult": {
      const toolCallId = message.toolCallId;
      if (!toolCallId) return;
      const row = toolRowsByCallId.get(toolCallId);
      if (row) {
        row.isError = message.isError === true;
      }
      return;
    }

    case "bashExecution": {
      const summary = previewText(String((message as Record<string, unknown>).command || ""));
      if (!summary) return;
      entries.push({
        id: entry.id,
        kind: "tool",
        tool: "bash",
        summary: `$ ${summary}`,
        timestamp,
        isMessage: false,
        isTool: true,
        passesAllFilter: true,
      });
      return;
    }

    default:
      return;
  }
}

function projectAssistantEntry(
  entry: SessionEntry,
  entries: TraceOutlineEntry[],
  toolRowsByCallId: Map<string, TraceOutlineEntry>,
  timestamp: string,
): void {
  const content = entry.message?.content;
  if (typeof content === "string") {
    const summary = previewText(content);
    if (!summary) return;
    entries.push({
      id: entry.id,
      kind: "assistant",
      summary,
      timestamp,
      isMessage: true,
      isTool: false,
      passesAllFilter: true,
    });
    return;
  }

  if (!Array.isArray(content)) return;

  let traceGeneratedIndex = 0;

  for (const block of content) {
    const record = asRecord(block);
    if (!record) continue;

    if (isTextBlock(record)) {
      const id = `${entry.id}-text-${traceGeneratedIndex}`;
      traceGeneratedIndex += 1;
      const summary = previewText(record.text);
      if (!summary) continue;
      entries.push({
        id,
        kind: "assistant",
        summary,
        timestamp,
        isMessage: true,
        isTool: false,
        passesAllFilter: true,
      });
      continue;
    }

    if (
      record.type === "thinking" &&
      typeof record.thinking === "string" &&
      record.thinking.length > 0
    ) {
      const id = `${entry.id}-think-${traceGeneratedIndex}`;
      traceGeneratedIndex += 1;
      const summary = previewText(record.thinking);
      if (!summary) continue;
      entries.push({
        id,
        kind: "thinking",
        summary,
        timestamp,
        isMessage: false,
        isTool: false,
        passesAllFilter: true,
      });
      continue;
    }

    if (record.type === "toolCall") {
      let id: string;
      if (typeof record.id === "string" && record.id.length > 0) {
        id = record.id;
      } else {
        id = `${entry.id}-tool-${traceGeneratedIndex}`;
        traceGeneratedIndex += 1;
      }
      const tool = typeof record.name === "string" ? record.name : "unknown";
      const args = asRecord(record.arguments) ?? tryParseJsonObject(record.partialJson);
      const row: TraceOutlineEntry = {
        id,
        kind: "tool",
        tool,
        summary: formatToolSummary(tool, args ?? {}),
        timestamp,
        isMessage: false,
        isTool: true,
        passesAllFilter: true,
      };
      entries.push(row);
      toolRowsByCallId.set(id, row);
    }
  }
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function isTextBlock(record: Record<string, unknown>): record is { type: string; text: string } {
  return (
    (record.type === "text" || record.type === "output_text") &&
    typeof record.text === "string" &&
    record.text.length > 0
  );
}

function extractText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";

  const parts: string[] = [];
  let chars = 0;
  for (const block of content) {
    const record = asRecord(block);
    if (!record || !isTextBlock(record)) continue;
    parts.push(record.text);
    chars += record.text.length;
    if (chars >= MAX_SUMMARY_CHARS * 2) break;
  }
  return parts.join(" ");
}

function previewText(rawText: string): string | undefined {
  const normalized = rawText.replace(/\s+/g, " ").trim();
  if (!normalized) return undefined;
  if (normalized.length <= MAX_SUMMARY_CHARS) return normalized;
  return `${normalized.slice(0, MAX_SUMMARY_CHARS - 1)}…`;
}

function formatToolSummary(tool: string, args: Record<string, unknown>): string {
  switch (tool) {
    case "bash":
    case "Bash": {
      const command = String(args.command || "")
        .replace(/[\n\t]/g, " ")
        .trim();
      return `$ ${previewText(command) ?? tool}`;
    }

    case "read":
    case "Read":
      return `read ${shortenPath(String(args.path || ""))}`.trim();

    case "write":
    case "Write":
      return `write ${shortenPath(String(args.path || ""))}`.trim();

    case "edit":
    case "Edit":
      return `edit ${shortenPath(String(args.path || ""))}`.trim();

    default: {
      const argsSummary = summarizeArgs(args);
      return argsSummary ? `${tool}: ${argsSummary}` : tool;
    }
  }
}

function summarizeArgs(args: Record<string, unknown>): string {
  const parts: string[] = [];
  for (const [key, value] of Object.entries(args).slice(0, 4)) {
    parts.push(`${key}: ${previewText(String(value)) ?? ""}`.trim());
  }
  return previewText(parts.join(", ")) ?? "";
}

function shortenPath(path: string): string {
  if (!path) return "";
  const home = process.env.HOME || process.env.USERPROFILE || "";
  const display = home && path.startsWith(home) ? `~${path.slice(home.length)}` : path;
  return previewText(display) ?? display;
}

function tryParseJsonObject(value: unknown): Record<string, unknown> | undefined {
  if (typeof value !== "string") return undefined;
  try {
    return asRecord(JSON.parse(value)) ?? undefined;
  } catch {
    return undefined;
  }
}

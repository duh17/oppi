import type { ExtensionAPI, ToolResultEvent } from "@earendil-works/pi-coding-agent";

export const CUSTOM_TYPE = "ops-receipt";

export type OpsReceipt = {
  title: string;
  body: string;
  sessionId?: string;
  reason?: string;
};

type JsonRecord = Record<string, unknown>;

function asRecord(value: unknown): JsonRecord | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as JsonRecord)
    : null;
}

function commandFromArgs(args: unknown): string {
  const record = asRecord(args);
  if (!record) return "";
  for (const key of ["command", "cmd", "script"] as const) {
    const value = record[key];
    if (typeof value === "string") return value;
  }
  return "";
}

export function commandKind(command: string): "wait" | "inspect" | null {
  if (/\boppi\s+session\s+wait\b/.test(command)) return "wait";
  if (/\boppi\s+session\s+inspect\b/.test(command)) return "inspect";
  return null;
}

export function extractToolText(result: unknown): string {
  if (typeof result === "string") return result;
  if (Array.isArray(result)) {
    return result
      .map((block) => {
        const item = asRecord(block);
        return typeof item?.text === "string" ? item.text : "";
      })
      .filter(Boolean)
      .join("\n");
  }
  const record = asRecord(result);
  if (!record) return "";
  if (typeof record.output === "string") return record.output;
  if (typeof record.stdout === "string") return record.stdout;
  if (typeof record.text === "string") return record.text;
  if (Array.isArray(record.content)) {
    return record.content
      .map((block) => {
        const item = asRecord(block);
        return typeof item?.text === "string" ? item.text : "";
      })
      .filter(Boolean)
      .join("\n");
  }
  const details = asRecord(record.details);
  if (typeof details?.output === "string") return details.output;
  if (typeof details?.expandedText === "string") return details.expandedText;
  return "";
}

export function parseOppiJsonData(text: string): JsonRecord | null {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  try {
    const parsed = JSON.parse(text.slice(start, end + 1)) as unknown;
    const envelope = asRecord(parsed);
    if (!envelope || envelope.ok !== true) return null;
    return asRecord(envelope.data);
  } catch {
    return null;
  }
}

function shortSessionId(sessionId: string): string {
  return sessionId.replace(/-/g, "").slice(0, 8);
}

function settledLabel(reason: string | undefined, status: string | undefined): string | null {
  const token = (reason ?? status ?? "").toLowerCase();
  if (token === "idle" || token === "stopped") return "Child done";
  if (token === "attention") return "Child needs you";
  return null;
}

function stringField(record: JsonRecord | null, key: string): string | undefined {
  const value = record?.[key];
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

export function receiptFromWait(data: JsonRecord, command: string): OpsReceipt | null {
  const sessionId = stringField(data, "session_id") ?? stringField(data, "sessionId");
  const reason = stringField(data, "reason");
  const status = stringField(data, "status");
  const title = settledLabel(reason, status);
  if (!title || !sessionId) return null;
  const name = nameFromCommand(command) ?? shortSessionId(sessionId);
  const detail = reason ?? status ?? "idle";
  return {
    title,
    body: `${name} · ${detail}`,
    sessionId,
    reason: reason ?? status,
  };
}

export function receiptFromInspect(data: JsonRecord): OpsReceipt | null {
  const summary = asRecord(data.summary) ?? data;
  const status = stringField(summary, "status");
  const title = settledLabel(undefined, status);
  if (!title) return null;
  const sessionId =
    stringField(data, "session_id") ??
    stringField(data, "sessionId") ??
    stringField(summary, "sessionId");
  const name =
    stringField(summary, "sessionName") ??
    stringField(summary, "session_name") ??
    (sessionId ? shortSessionId(sessionId) : undefined);
  if (!name) return null;
  return {
    title,
    body: `${name} · ${status}`,
    ...(sessionId ? { sessionId } : {}),
    reason: status,
  };
}

function nameFromCommand(command: string): string | undefined {
  const named = command.match(/--name(?:\s+|=)([^\s]+)/);
  const value = named?.[1]?.replace(/^['"]|['"]$/g, "");
  return value || undefined;
}

export function receiptFromToolEvent(event: {
  isError?: boolean;
  toolName?: string;
  args?: unknown;
  input?: unknown;
  result?: unknown;
  content?: unknown;
}): OpsReceipt | null {
  if (event.isError) return null;
  const command = commandFromArgs(event.args ?? event.input);
  const kind = commandKind(command);
  if (!kind) return null;
  const data = parseOppiJsonData(extractToolText(event.result ?? event.content));
  if (!data) return null;
  return kind === "wait" ? receiptFromWait(data, command) : receiptFromInspect(data);
}

export default function opsReceipt(pi: ExtensionAPI): void {
  pi.registerEntryRenderer<OpsReceipt>(CUSTOM_TYPE, (entry) => {
    const data = asRecord(entry.data);
    const title = stringField(data, "title") ?? "Child session";
    const body = stringField(data, "body");
    return {
      render: () => (body ? [title, body] : [title]),
    };
  });

  // tool_execution_end has no args. tool_result carries input.command + content.
  pi.on("tool_result", (event: ToolResultEvent) => {
    const receipt = receiptFromToolEvent(event);
    if (!receipt) return;
    pi.appendEntry(CUSTOM_TYPE, receipt);
  });
}

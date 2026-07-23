import type { Session } from "../../types.js";
import type { LocalApiRequestOptions } from "../local-api-client.js";
import { printList } from "../output.js";
import { clipListCell } from "./session-list.js";

export type SessionTraceEvent = {
  id?: string;
  type?: string;
  text?: string;
  message?: unknown;
  thinking?: string;
  tool?: string;
  args?: Record<string, unknown>;
  output?: string;
  toolName?: string;
  isError?: boolean;
  [key: string]: unknown;
};

type SessionTraceOutlineEntry = {
  id: string;
  kind: string;
  summary: string;
  timestamp?: string;
  tool?: string;
  isError?: boolean;
};

type SessionInspectView = "overview" | "outline" | "response" | "messages" | "summary" | "tools";

type SessionInspectTurn = {
  turn: number;
  userTexts: string[];
  assistantTexts: string[];
  thinkingTexts: string[];
  systemTexts: string[];
  summaryTexts: string[];
  toolCalls: Array<{ id?: string; tool?: string; args?: Record<string, unknown> }>;
  toolResults: Array<{ toolName?: string; output?: string; isError?: boolean }>;
};

const INLINE_DATA_URL_RE = /data:([a-z0-9.+-]+\/[a-z0-9.+-]+);base64,[a-z0-9+/_=-]+/gi;

type SessionListApiCall = <T>(path: string, options?: LocalApiRequestOptions) => Promise<T>;

type SessionInspectResult = {
  selected_turns: number[];
  view: SessionInspectView;
  summary: Record<string, unknown>;
  text: string;
};

export async function inspectSession(
  id: string,
  positional: string[],
  flags: Record<string, string>,
  call: SessionListApiCall,
): Promise<SessionInspectResult> {
  const turnsSpec = flags.turns?.trim() || positional[0]?.trim() || "all";
  const view = inspectView(flags.view);

  if (view === "outline" || view === "overview" || view === "summary") {
    const sessionResult = await call<{ session?: Partial<Session> }>(
      `/sessions/${encodeURIComponent(id)}`,
    );
    const workspaceId = sessionResult.session?.workspaceId?.trim();
    const outlinePath = workspaceId
      ? `/workspaces/${encodeURIComponent(workspaceId)}/sessions/${encodeURIComponent(id)}/trace-outline`
      : `/control-sessions/${encodeURIComponent(id)}/trace-outline`;
    const outlineResult = await call<Record<string, unknown>>(outlinePath);
    return buildInspectResult(
      sessionResult.session,
      traceEventsFromOutline(parseTraceOutlineEntries(outlineResult)),
      turnsSpec,
      view,
    );
  }

  // Response only needs conversational messages. Keep the full trace for views that explicitly
  // request message context or tools so their summary counts remain complete.
  const tracePath =
    view === "response"
      ? `/sessions/${encodeURIComponent(id)}/trace?include=messages`
      : `/sessions/${encodeURIComponent(id)}/trace`;
  const result = await call<{ session?: Partial<Session>; trace?: SessionTraceEvent[] }>(tracePath);
  if (!Array.isArray(result.trace)) throw new Error("Local API did not return a trace array");
  return buildInspectResult(result.session, result.trace, turnsSpec, view);
}

function buildInspectResult(
  session: Partial<Session> | undefined,
  trace: SessionTraceEvent[],
  turnsSpec: string,
  view: SessionInspectView,
): SessionInspectResult {
  const turns = buildInspectTurns(trace);
  const selectedTurns = parseInspectTurnSelector(turnsSpec, turns.length);
  const selectedSet = new Set(selectedTurns);
  const summary = inspectSummary(session, trace, turns);
  const text = renderInspectView(view, turns, selectedSet, summary);

  return {
    selected_turns: selectedTurns,
    view,
    summary,
    text,
  };
}

export function inspectJsonResult(result: SessionInspectResult): Record<string, unknown> {
  if (result.view === "summary" || result.view === "overview") {
    return { view: result.view, summary: result.summary };
  }
  return {
    view: result.view,
    selected_turns: result.selected_turns,
    summary: result.summary,
    text: result.text,
  };
}

function inspectView(raw: string | undefined): SessionInspectView {
  const view = raw?.trim() || "outline";
  if (
    view === "overview" ||
    view === "outline" ||
    view === "response" ||
    view === "messages" ||
    view === "summary" ||
    view === "tools"
  ) {
    return view;
  }
  throw new Error("--view must be one of overview, outline, response, messages, summary, or tools");
}

function buildInspectTurns(trace: SessionTraceEvent[]): SessionInspectTurn[] {
  const turns: SessionInspectTurn[] = [];
  let current: SessionInspectTurn | undefined;
  // Pi TUI treats leading model/thinking/compaction entries as context metadata,
  // not as standalone user/assistant turns.
  const pendingLeadingSummaryTexts: string[] = [];
  const pendingLeadingSystemTexts: string[] = [];

  const attachPendingLeadingText = (turn: SessionInspectTurn): void => {
    if (pendingLeadingSummaryTexts.length > 0) {
      turn.summaryTexts.push(...pendingLeadingSummaryTexts);
      pendingLeadingSummaryTexts.length = 0;
    }
    if (pendingLeadingSystemTexts.length > 0) {
      turn.systemTexts.push(...pendingLeadingSystemTexts);
      pendingLeadingSystemTexts.length = 0;
    }
  };

  const ensureTurn = (): SessionInspectTurn => {
    if (!current) {
      current = emptyInspectTurn(turns.length + 1);
      attachPendingLeadingText(current);
      turns.push(current);
    }
    return current;
  };

  for (const event of trace) {
    const type = event.type ?? "";
    if (type === "user") {
      current = emptyInspectTurn(turns.length + 1);
      attachPendingLeadingText(current);
      const text = eventText(event).trim();
      if (text) current.userTexts.push(text);
      turns.push(current);
      continue;
    }

    if (!current && (type === "system" || type === "compaction")) {
      const text = eventText(event).trim();
      if (text && type === "system") pendingLeadingSystemTexts.push(text);
      if (text && type === "compaction") pendingLeadingSummaryTexts.push(text);
      continue;
    }

    const turn = ensureTurn();
    if (type === "assistant") {
      const text = eventText(event).trim();
      if (text) turn.assistantTexts.push(text);
    } else if (type === "thinking") {
      const text = typeof event.thinking === "string" ? event.thinking.trim() : "";
      if (text) turn.thinkingTexts.push(text);
    } else if (type === "system") {
      const text = eventText(event).trim();
      if (text) turn.systemTexts.push(text);
    } else if (type === "compaction") {
      const text = eventText(event).trim();
      if (text) turn.summaryTexts.push(text);
    } else if (type === "toolCall") {
      turn.toolCalls.push({
        ...(typeof event.id === "string" ? { id: event.id } : {}),
        ...(typeof event.tool === "string" ? { tool: event.tool } : {}),
        ...(event.args ? { args: event.args } : {}),
      });
    } else if (type === "toolResult") {
      turn.toolResults.push({
        ...(typeof event.toolName === "string" ? { toolName: event.toolName } : {}),
        ...(typeof event.output === "string" ? { output: event.output } : {}),
        ...(typeof event.isError === "boolean" ? { isError: event.isError } : {}),
      });
    }
  }

  if (!current && (pendingLeadingSummaryTexts.length > 0 || pendingLeadingSystemTexts.length > 0)) {
    current = emptyInspectTurn(turns.length + 1);
    attachPendingLeadingText(current);
    turns.push(current);
  }

  return turns;
}

function emptyInspectTurn(turn: number): SessionInspectTurn {
  return {
    turn,
    userTexts: [],
    assistantTexts: [],
    thinkingTexts: [],
    systemTexts: [],
    summaryTexts: [],
    toolCalls: [],
    toolResults: [],
  };
}

function parseInspectTurnSelector(spec: string, maxTurn: number): number[] {
  const trimmed = spec.trim().toLowerCase();
  if (!trimmed || trimmed === "all") {
    return Array.from({ length: maxTurn }, (_, index) => index + 1);
  }

  const selected = new Set<number>();
  const invalid = (): never => {
    throw new Error("--turns must be all, a number, a range, or a comma-separated list");
  };
  const requireInRange = (turn: number): void => {
    if (!Number.isSafeInteger(turn) || turn < 1 || turn > maxTurn) invalid();
  };

  for (const part of trimmed.split(",")) {
    const token = part.trim();
    if (!token) invalid();

    const range = token.match(/^(\d+)-(\d+)$/);
    if (range) {
      const start = Number.parseInt(range[1] ?? "", 10);
      const end = Number.parseInt(range[2] ?? "", 10);
      requireInRange(start);
      requireInRange(end);
      if (start > end) invalid();
      for (let turn = start; turn <= end; turn++) selected.add(turn);
      continue;
    }

    if (token.includes("-") || !/^\d+$/.test(token)) invalid();
    const turn = Number.parseInt(token, 10);
    requireInRange(turn);
    selected.add(turn);
  }

  if (selected.size === 0) invalid();
  return [...selected].sort((a, b) => a - b);
}

function inspectSummary(
  session: Partial<Session> | undefined,
  trace: SessionTraceEvent[],
  turns: SessionInspectTurn[],
): Record<string, unknown> {
  const assistantMessages = turns.reduce((sum, turn) => sum + turn.assistantTexts.length, 0);
  const userMessages = turns.reduce((sum, turn) => sum + turn.userTexts.length, 0);
  const thinkingMessages = turns.reduce((sum, turn) => sum + turn.thinkingTexts.length, 0);
  const toolCalls = turns.reduce((sum, turn) => sum + turn.toolCalls.length, 0);
  const toolResults = turns.reduce((sum, turn) => sum + turn.toolResults.length, 0);
  const toolErrors = turns.reduce(
    (sum, turn) => sum + turn.toolResults.filter((result) => result.isError === true).length,
    0,
  );

  return {
    source: "oppi",
    sessionId: session?.id,
    sessionName: session?.name,
    workspaceId: session?.workspaceId,
    worktreeId: session?.worktreeId,
    status: session?.status,
    model: session?.model,
    counts: {
      traceEvents: trace.length,
      turns: turns.length,
      userMessages,
      assistantMessages,
      thinkingMessages,
      toolCalls,
      toolResults,
      toolErrors,
    },
  };
}

function renderInspectView(
  view: SessionInspectView,
  turns: SessionInspectTurn[],
  selectedSet: Set<number>,
  summary: Record<string, unknown>,
): string {
  if (view === "overview") return renderInspectOverview(summary);
  if (view === "outline") return renderInspectOutline(turns, selectedSet);
  if (view === "response") return renderInspectResponse(turns, selectedSet);
  if (view === "summary") return JSON.stringify(summary, null, 2);
  if (view === "tools") return renderInspectTools(turns, selectedSet);
  return renderInspectMessages(turns, selectedSet);
}

function renderInspectOverview(summary: Record<string, unknown>): string {
  const counts = isRecord(summary.counts) ? summary.counts : {};
  return [
    `source: ${summary.source ?? "unknown"}`,
    `session: ${summary.sessionId ?? "unknown"}`,
    `name: ${summary.sessionName ?? "(none)"}`,
    `workspace: ${summary.workspaceId ?? "(unknown)"}`,
    `worktree: ${summary.worktreeId ?? "(unknown)"}`,
    `status: ${summary.status ?? "unknown"}`,
    `model: ${summary.model ?? "(unknown)"}`,
    `turns: ${counts.turns ?? 0}`,
    `trace_events: ${counts.traceEvents ?? 0}`,
    `assistant_messages: ${counts.assistantMessages ?? 0}`,
    `tool_calls: ${counts.toolCalls ?? 0}`,
    `tool_errors: ${counts.toolErrors ?? 0}`,
  ].join("\n");
}

function renderInspectOutline(turns: SessionInspectTurn[], selectedSet: Set<number>): string {
  const lines: string[] = [];
  for (const turn of turns) {
    if (!selectedSet.has(turn.turn)) continue;

    const userText = inspectDisplayText(
      turn.userTexts.find((text) => text.trim()) ?? "(no user message)",
    );
    const assistantText = inspectDisplayText(
      turn.assistantTexts.filter((text) => text.trim()).at(-1) ?? "(no response)",
    );
    const toolErrors = turn.toolResults.filter((result) => result.isError === true).length;
    const activity = [
      countLabel(turn.toolCalls.length, "tool call"),
      countLabel(toolErrors, "error"),
      countLabel(turn.thinkingTexts.length, "thinking block"),
      countLabel(turn.summaryTexts.length, "compaction"),
    ].filter(Boolean);

    lines.push(`Turn ${turn.turn}`);
    lines.push(`  user: ${clipListCell(userText, 180)}`);
    lines.push(`  assistant: ${clipListCell(assistantText, 180)}`);
    if (activity.length > 0) lines.push(`  activity: ${activity.join(" · ")}`);
    lines.push("");
  }

  return lines.length > 0 ? lines.join("\n").trimEnd() : "No turns found.";
}

function countLabel(count: number, singular: string): string {
  if (count === 0) return "";
  return `${count} ${singular}${count === 1 ? "" : "s"}`;
}

function renderInspectResponse(turns: SessionInspectTurn[], selectedSet: Set<number>): string {
  const response = turns
    .filter((turn) => selectedSet.has(turn.turn))
    .flatMap((turn) => turn.assistantTexts)
    .filter((text) => text.trim())
    .at(-1);
  return response ? inspectDisplayText(response) : "(no assistant response)";
}

function renderInspectMessages(turns: SessionInspectTurn[], selectedSet: Set<number>): string {
  const lines: string[] = [];
  for (const turn of turns) {
    if (!selectedSet.has(turn.turn)) continue;
    lines.push(`Turn ${turn.turn}`);
    for (const text of turn.summaryTexts) lines.push(`  summary: ${inspectDisplayText(text)}`);
    for (const text of turn.systemTexts) lines.push(`  system: ${inspectDisplayText(text)}`);
    for (const text of turn.userTexts) lines.push(`  user: ${inspectDisplayText(text)}`);
    for (const text of turn.assistantTexts) lines.push(`  assistant: ${inspectDisplayText(text)}`);
    for (const text of turn.thinkingTexts) lines.push(`  thinking: ${inspectDisplayText(text)}`);
    if (
      turn.summaryTexts.length === 0 &&
      turn.systemTexts.length === 0 &&
      turn.userTexts.length === 0 &&
      turn.assistantTexts.length === 0 &&
      turn.thinkingTexts.length === 0
    ) {
      lines.push("  (no text)");
    }
    lines.push("");
  }
  return lines.join("\n").trimEnd();
}

function inspectDisplayText(text: string): string {
  return text.replace(INLINE_DATA_URL_RE, (_match, contentType: string) => {
    return `[inline ${contentType} data omitted]`;
  });
}

function renderInspectTools(turns: SessionInspectTurn[], selectedSet: Set<number>): string {
  const lines: string[] = [];
  for (const turn of turns) {
    if (!selectedSet.has(turn.turn)) continue;
    lines.push(`Turn ${turn.turn}`);
    if (turn.toolCalls.length === 0 && turn.toolResults.length === 0) {
      lines.push("  (no tool calls)");
      lines.push("");
      continue;
    }
    for (const call of turn.toolCalls) {
      const args = call.args ? ` ${JSON.stringify(call.args)}` : "";
      lines.push(`  call: ${call.tool ?? "unknown"}${args}`);
    }
    for (const result of turn.toolResults) {
      const status = result.isError === true ? "error" : "ok";
      lines.push(
        `  result: ${result.toolName ?? "unknown"} [${status}] ${clipListCell(result.output ?? "", 220)}`,
      );
    }
    lines.push("");
  }
  return lines.join("\n").trimEnd();
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function parseTraceOutlineEntries(result: Record<string, unknown>): SessionTraceOutlineEntry[] {
  const outline = result.outline;
  if (!isRecord(outline) || !Array.isArray(outline.entries)) {
    throw new Error("Local API did not return a trace outline entries array");
  }

  return outline.entries.map((value) => {
    if (
      !isRecord(value) ||
      typeof value.id !== "string" ||
      typeof value.kind !== "string" ||
      typeof value.summary !== "string"
    ) {
      throw new Error("Local API returned an invalid trace outline entry");
    }
    return {
      id: value.id,
      kind: value.kind,
      summary: value.summary,
      ...(typeof value.timestamp === "string" ? { timestamp: value.timestamp } : {}),
      ...(typeof value.tool === "string" ? { tool: value.tool } : {}),
      ...(typeof value.isError === "boolean" ? { isError: value.isError } : {}),
    };
  });
}

function traceEventsFromOutline(entries: SessionTraceOutlineEntry[]): SessionTraceEvent[] {
  return entries.flatMap((entry): SessionTraceEvent[] => {
    switch (entry.kind) {
      case "user":
      case "assistant":
      case "system":
      case "compaction":
        return [{ id: entry.id, type: entry.kind, text: entry.summary }];
      case "thinking":
        return [{ id: entry.id, type: "thinking", thinking: entry.summary }];
      case "tool": {
        const call: SessionTraceEvent = {
          id: entry.id,
          type: "toolCall",
          ...(entry.tool ? { tool: entry.tool } : {}),
        };
        if (entry.isError === undefined) return [call];
        return [
          call,
          {
            type: "toolResult",
            ...(entry.tool ? { toolName: entry.tool } : {}),
            isError: entry.isError,
          },
        ];
      }
      default:
        return [];
    }
  });
}

export function printTraceOutline(id: string, result: Record<string, unknown>): void {
  const entries = parseTraceOutlineEntries(result);

  printList(
    `Trace outline for ${id} (${entries.length})`,
    entries.map((entry) => ({
      id: entry.id,
      status: entry.kind,
      title: entry.summary,
      meta: [entry.tool ? `tool ${entry.tool}` : "", entry.isError === true ? "error" : ""],
    })),
    { empty: "No trace entries found." },
  );
}

export function eventText(event: SessionTraceEvent): string {
  if (typeof event.text === "string") return event.text;
  if (typeof event.message === "string") return event.message;
  return "";
}

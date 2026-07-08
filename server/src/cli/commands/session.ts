/* eslint-disable no-console */
import * as c from "../../ansi.js";
import type { Session } from "../../types.js";
import {
  localApiRequest,
  type LocalApiConnection,
  type LocalApiHostResolvers,
  type LocalApiRequestOptions,
} from "../local-api-client.js";
import {
  codeValue,
  nonEmptyDetails,
  printDetails,
  printList,
  printNextCommands,
  writeJsonEnvelope,
} from "../output.js";
import {
  apiStatus,
  inferWorkspaceIdFromCwdForCli,
  resolveWorkspaceIdForCli,
} from "../resources.js";

type SessionTraceEvent = {
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

type SessionInspectView = "overview" | "messages" | "summary" | "tools";

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

type SessionListRow = Partial<Session> & {
  source?: "tui" | string;
  pendingAskCount?: number;
  lastModified?: number;
  path?: string;
  piSessionId?: string;
};

type WorkspaceSessionCollectionResponse = {
  workspaceId: string;
  sinceMs?: number;
  untilMs?: number;
  serverNow?: number;
  active?: SessionListRow[];
  stopped?: SessionListRow[];
};

type SessionListResponse = {
  sessions?: SessionListRow[];
  serverNow?: number;
};

const DEFAULT_SESSION_LIST_RECENT_DAYS = 3;
const DAY_MS = 86_400_000;

export async function cmdSession(
  storage: LocalApiConnection,
  action: string | undefined,
  positional: string[],
  flags: Record<string, string>,
  hostResolvers: LocalApiHostResolvers = {},
  cwd = process.cwd(),
): Promise<void> {
  const mode = action || "list";
  const jsonOutput = flags.json === "true";

  async function call<T>(path: string, options?: LocalApiRequestOptions): Promise<T> {
    return localApiRequest<T>(storage, path, options, hostResolvers);
  }

  function output(data: Record<string, unknown>, human: () => void): void {
    if (jsonOutput) writeJsonEnvelope({ ok: true, data });
    else human();
  }

  try {
    if (mode === "list") {
      const result = await listSessions(storage, flags, call, hostResolvers);
      output(result as Record<string, unknown>, () => {
        const sessions = Array.isArray(result.sessions) ? result.sessions : [];
        printList(
          `Sessions (${sessions.length})`,
          sessions.map((session) => {
            const path = clipListCell(session.path ?? session.piSessionFile ?? "", 56);
            return {
              id: session.id ?? "?",
              status: session.status ?? "?",
              title: clipListCell(session.name ?? session.firstMessage ?? "(unnamed)", 88),
              meta: [sessionWorkspaceMeta(session), `worktree ${session.worktreeId ?? "main"}`],
              details: path ? [`path ${path}`] : [],
            };
          }),
          { empty: "No sessions found." },
        );
      });
      return;
    }

    if (mode === "get") {
      const id = requirePositional(positional, "session id is required");
      const result = await call<Record<string, unknown>>(`/sessions/${encodeURIComponent(id)}`);
      output(result, () => {
        const session = result.session as Partial<Session> | undefined;
        printDetails(
          "Session",
          nonEmptyDetails([
            ["ID", codeValue(session?.id ?? id)],
            ["Status", session?.status ?? "unknown"],
            ["Name", session?.name ?? ""],
            ["Workspace", session?.workspaceName ?? session?.workspaceId ?? ""],
            ["Worktree", session?.worktreeId ?? ""],
            ["Model", session?.model ?? ""],
          ]),
        );
      });
      return;
    }

    if (mode === "create") {
      await createSession(storage, flags, jsonOutput, hostResolvers);
      return;
    }

    if (mode === "send") {
      const id = requirePositional(positional, "session id is required");
      const text = flags.text;
      if (!text?.trim()) throw new Error("--text is required");
      const result = await call<Record<string, unknown>>(
        `/sessions/${encodeURIComponent(id)}/command`,
        { method: "POST", body: { type: "prompt", message: text } },
      );
      output(result, () => {
        printDetails("✓ Message sent", [["Session", codeValue(id)]]);
      });
      return;
    }

    if (mode === "read" || mode === "trace") {
      const id = requirePositional(positional, "session id is required");
      const params = new URLSearchParams();
      if (mode === "read" && flags.tail) params.set("tail", flags.tail);
      if (mode === "trace" && flags.include) params.set("include", flags.include);
      const result = await call<Record<string, unknown>>(
        `/sessions/${encodeURIComponent(id)}/${mode}${querySuffix(params)}`,
      );
      output(result, () => {
        const trace = Array.isArray(result.trace) ? (result.trace as SessionTraceEvent[]) : [];
        printList(
          `${mode === "read" ? "Messages" : "Trace"} for ${id} (${trace.length})`,
          trace.map((event) => ({
            status: event.type ?? "event",
            title: eventText(event) || "(empty)",
          })),
          { empty: "No trace events returned." },
        );
      });
      return;
    }

    if (mode === "events") {
      const id = requirePositional(positional, "session id is required");
      const params = new URLSearchParams();
      if (flags.since) params.set("since", flags.since);
      const result = await call<Record<string, unknown>>(
        `/sessions/${encodeURIComponent(id)}/events${querySuffix(params)}`,
      );
      output(result, () => {
        const events = Array.isArray(result.events)
          ? (result.events as Array<{ seq?: number; type?: string }>)
          : [];
        printList(
          `Events for ${id} (${events.length})`,
          events.map((event) => ({
            id: event.seq ?? "?",
            title: event.type ?? "event",
          })),
          { empty: "No events returned." },
        );
      });
      return;
    }

    if (mode === "stop") {
      const id = requirePositional(positional, "session id is required");
      const result = await call<Record<string, unknown>>(
        `/sessions/${encodeURIComponent(id)}/stop`,
        {
          method: "POST",
        },
      );
      output(result, () => {
        printDetails("✓ Session stopped", [["Session", codeValue(id)]]);
      });
      return;
    }

    if (mode === "search") {
      const query = flags.query?.trim() || positional.join(" ").trim();
      const hasTimeFilter = !!flags.since || !!flags.until;
      if (!query && !hasTimeFilter)
        throw new Error("--query, search text, or a date filter is required");
      const params = new URLSearchParams();
      if (query) params.set("q", query);
      if (flags.limit) params.set("limit", flags.limit);
      if (flags.since) params.set("since", flags.since);
      if (flags.until) params.set("until", flags.until);
      if (flags.workspace && flags.all === "true") {
        throw new Error("--workspace and --all cannot be used together");
      }
      if (flags.workspace) {
        const workspaceId = await resolveWorkspaceIdForCli(storage, flags.workspace, hostResolvers);
        params.set("workspaceId", workspaceId);
      } else if (flags.all !== "true") {
        const workspaceId = await inferWorkspaceIdFromCwdForCli(storage, cwd, hostResolvers);
        if (!workspaceId)
          throw new Error("Could not infer workspace from cwd; pass --workspace or --all");
        params.set("workspaceId", workspaceId);
      }
      const result = await call<Record<string, unknown>>(`/sessions/search${querySuffix(params)}`);
      output(result, () => {
        const results = Array.isArray(result.results)
          ? (result.results as Array<{
              sessionId?: string;
              snippet?: string;
              text?: string;
              title?: string;
              rank?: number;
              score?: number;
              session?: Partial<Session>;
            }>)
          : [];
        printList(
          `Search results (${results.length})`,
          results.map((searchResult) => ({
            id: searchResult.sessionId ?? "?",
            status: searchResult.score !== undefined ? String(searchResult.score) : "",
            title: clipListCell(
              searchResult.snippet ?? searchResult.text ?? searchResult.title ?? "(match)",
              88,
            ),
            meta: [searchResult.session?.name ?? ""],
          })),
          { empty: "No matching sessions." },
        );
      });
      return;
    }

    if (mode === "inspect") {
      const id = requirePositional(positional, "session id is required");
      const result = await inspectSession(id, positional.slice(1), flags, call);
      output(result as unknown as Record<string, unknown>, () => {
        console.log(result.text || "(empty)");
      });
      return;
    }

    if (mode === "delete") {
      const id = requirePositional(positional, "session id is required");
      const workspaceId = await resolveSessionWorkspaceId(id, call);
      const result = await call<Record<string, unknown>>(
        `/workspaces/${encodeURIComponent(workspaceId)}/sessions/${encodeURIComponent(id)}`,
        { method: "DELETE" },
      );
      output(result, () => {
        printDetails("✓ Session deleted", [["Session", codeValue(id)]]);
      });
      return;
    }

    if (mode === "resume") {
      const id = requirePositional(positional, "session id is required");
      const workspaceId = await resolveSessionWorkspaceId(id, call);
      const result = await call<Record<string, unknown>>(
        `/workspaces/${encodeURIComponent(workspaceId)}/sessions/${encodeURIComponent(id)}/resume`,
        { method: "POST" },
      );
      output(result, () => {
        printDetails("✓ Session resumed", [["Session", codeValue(id)]]);
      });
      return;
    }

    if (mode === "fork") {
      const id = requirePositional(positional, "session id is required");
      const entryId = flags.entry?.trim() || flags["entry-id"]?.trim();
      if (!entryId) throw new Error("--entry is required");
      const workspaceId = await resolveSessionWorkspaceId(id, call);
      const result = await call<Record<string, unknown>>(
        `/workspaces/${encodeURIComponent(workspaceId)}/sessions/${encodeURIComponent(id)}/fork`,
        {
          method: "POST",
          body: { entryId, ...(flags.name ? { name: flags.name } : {}) },
        },
      );
      output(result, () => {
        const session = result.session as Partial<Session> | undefined;
        printDetails("✓ Session forked", [
          ["Source", codeValue(id)],
          ["Fork", codeValue(session?.id ?? "?")],
        ]);
      });
      return;
    }

    if (mode === "changes") {
      const id = requirePositional(positional, "session id is required");
      const workspaceId = await resolveSessionWorkspaceId(id, call);
      const result = await call<Record<string, unknown>>(
        `/workspaces/${encodeURIComponent(workspaceId)}/sessions/${encodeURIComponent(id)}/changes`,
      );
      output(result, () => {
        const files = Array.isArray(result.files)
          ? (result.files as Array<{ path?: string; status?: string }>)
          : [];
        printList(
          `Changed files for ${id} (${files.length})`,
          files.map((file) => ({ status: file.status ?? "", title: file.path ?? "(unknown)" })),
          { empty: "No changed files returned." },
        );
      });
      return;
    }

    if (mode === "diff") {
      const id = requirePositional(positional, "session id is required");
      const path = flags.path?.trim();
      if (!path) throw new Error("--path is required");
      const workspaceId = await resolveSessionWorkspaceId(id, call);
      const params = new URLSearchParams();
      params.set("path", path);
      const result = await call<Record<string, unknown>>(
        `/workspaces/${encodeURIComponent(workspaceId)}/sessions/${encodeURIComponent(id)}/diff${querySuffix(params)}`,
      );
      output(result, () => {
        printDetails("Session diff", [
          ["Session", codeValue(id)],
          ["Path", codeValue(path)],
        ]);
      });
      return;
    }

    if (mode === "tool-output") {
      const id = requirePositional(positional, "session id is required");
      const toolCallId = positional[1]?.trim() || flags.tool?.trim() || flags["tool-call"]?.trim();
      if (!toolCallId) throw new Error("tool call id is required");
      const workspaceId = await resolveSessionWorkspaceId(id, call);
      const result = await call<Record<string, unknown>>(
        `/workspaces/${encodeURIComponent(workspaceId)}/sessions/${encodeURIComponent(id)}/tool-output/${encodeURIComponent(toolCallId)}`,
      );
      output(result, () => {
        printDetails("Tool output", [
          ["Session", codeValue(id)],
          ["Tool", codeValue(toolCallId)],
        ]);
      });
      return;
    }

    if (mode === "trace-page" || mode === "trace-outline") {
      const id = requirePositional(positional, "session id is required");
      const workspaceId = await resolveSessionWorkspaceId(id, call);
      const params = new URLSearchParams();
      if (mode === "trace-page") {
        if (flags.cursor) params.set("cursor", flags.cursor);
        if (flags["around-entry"]) params.set("aroundEntryId", flags["around-entry"]);
        if (flags["target-events"]) params.set("targetEvents", flags["target-events"]);
        if (flags["preview-bytes"]) params.set("previewBytes", flags["preview-bytes"]);
      }
      const result = await call<Record<string, unknown>>(
        `/workspaces/${encodeURIComponent(workspaceId)}/sessions/${encodeURIComponent(id)}/${mode}${querySuffix(params)}`,
      );
      output(result, () => {
        printDetails(mode === "trace-page" ? "Trace page" : "Trace outline", [
          ["Session", codeValue(id)],
        ]);
      });
      return;
    }

    throw new Error(
      "Usage: oppi session list|get|create|send|read|events|trace|search|inspect|stop|resume|fork|delete|changes|diff|tool-output|trace-page|trace-outline",
    );
  } catch (err: unknown) {
    const status = apiStatus(err);
    const message = err instanceof Error ? err.message : String(err);
    if (jsonOutput) {
      writeJsonEnvelope({ ok: false, error: { message, ...(status ? { status } : {}) } });
      process.exitCode = 1;
      return;
    }
    console.log(c.red(`  Error: ${message}`));
    process.exit(1);
  }
}

async function createSession(
  storage: LocalApiConnection,
  flags: Record<string, string>,
  jsonOutput: boolean,
  hostResolvers: LocalApiHostResolvers,
): Promise<void> {
  const workspaceRef = flags.workspace?.trim();
  const promptText = flags.prompt;
  if (!workspaceRef || promptText === undefined || promptText.trim() === "") {
    const message = "--workspace and --prompt are required";
    if (jsonOutput) writeJsonEnvelope({ ok: false, error: { message } });
    else {
      console.log(c.red(`  Error: ${message}`));
      console.log(c.dim("  Usage: oppi session create --workspace <id> --prompt <text> [--json]"));
    }
    process.exitCode = 1;
    return;
  }
  const workspaceId = await resolveWorkspaceIdForCli(storage, workspaceRef, hostResolvers);
  const savedAgent = savedAgentReference(flags.agent);
  const result = savedAgent
    ? await localApiRequest<{ session: Session; receipt?: Record<string, unknown> }>(
        storage,
        `/agents/${encodeURIComponent(savedAgent)}/sessions`,
        {
          method: "POST",
          body: {
            prompt: { text: promptText },
            target: {
              workspaceId,
              ...(flags.worktree ? { worktreeId: flags.worktree } : {}),
            },
            ...(flags.name ? { sessionName: flags.name } : {}),
            ...(flags.model || flags.thinking
              ? {
                  overrides: {
                    ...(flags.model ? { model: flags.model } : {}),
                    ...(flags.thinking ? { thinkingLevel: flags.thinking } : {}),
                  },
                }
              : {}),
            ...(flags["idempotency-key"] ? { idempotencyKey: flags["idempotency-key"] } : {}),
          },
        },
        hostResolvers,
      )
    : await localApiRequest<{ session: Session; prompted?: boolean }>(
        storage,
        `/workspaces/${encodeURIComponent(workspaceId)}/sessions`,
        {
          method: "POST",
          body: {
            prompt: promptText,
            ...(flags.name ? { name: flags.name } : {}),
            ...(flags.model ? { model: flags.model } : {}),
            ...(flags.thinking ? { thinking: flags.thinking } : {}),
            ...(flags.worktree ? { worktreeId: flags.worktree } : {}),
            ...(flags["idempotency-key"] ? { launchIdempotencyKey: flags["idempotency-key"] } : {}),
          },
        },
        hostResolvers,
      );
  if (jsonOutput) {
    writeJsonEnvelope({ ok: true, data: result as unknown as Record<string, unknown> });
    return;
  }

  printDetails("✓ Session created", [
    ["Workspace", codeValue(workspaceId)],
    ["Session", codeValue(result.session.id)],
  ]);
  printNextCommands([
    `oppi session read ${result.session.id}`,
    `oppi session events ${result.session.id}`,
    `oppi session send ${result.session.id} --text "..."`,
  ]);
}

function requirePositional(positional: string[], message: string): string {
  const value = positional[0]?.trim();
  if (!value) throw new Error(message);
  return value;
}

function querySuffix(params: URLSearchParams): string {
  const query = params.toString();
  return query ? `?${query}` : "";
}

function sessionWorkspaceMeta(session: SessionListRow): string {
  const workspace = session.workspaceName ?? session.workspaceId;
  return workspace ? `workspace ${workspace}` : "";
}

function clipListCell(value: unknown, maxLength: number): string {
  const text = typeof value === "string" ? value.trim() : String(value ?? "");
  if (text.length <= maxLength) return text;
  return `${text.slice(0, Math.max(0, maxLength - 1))}…`;
}

type SessionListApiCall = <T>(path: string, options?: LocalApiRequestOptions) => Promise<T>;

async function resolveSessionWorkspaceId(id: string, call: SessionListApiCall): Promise<string> {
  const result = await call<{ session?: Partial<Session> }>(`/sessions/${encodeURIComponent(id)}`);
  const workspaceId = result.session?.workspaceId?.trim();
  if (!workspaceId) throw new Error("Session has no workspaceId");
  return workspaceId;
}

function normalizeStatusFilter(raw: string | undefined): string[] {
  return (raw ?? "")
    .split(",")
    .map((status) => status.trim())
    .filter(Boolean);
}

function isWorkspaceListStatusFilter(statuses: string[]): boolean {
  return statuses.every((status) => status === "active" || status === "stopped");
}

function sessionMatchesStatus(session: SessionListRow, statuses: string[]): boolean {
  if (statuses.length === 0) return true;
  return statuses.some((status) => {
    if (status === "active") return session.status !== "stopped";
    if (status === "stopped") return session.status === "stopped";
    return session.status === status;
  });
}

function parsePositiveLimit(raw: string | undefined): number | undefined {
  if (!raw) return undefined;
  const limit = Number.parseInt(raw, 10);
  if (!Number.isFinite(limit) || limit < 1) {
    throw new Error("--limit must be a positive integer");
  }
  return limit;
}

function activeWorkspaceRows(rows: SessionListRow[]): SessionListRow[] {
  return rows.filter((session) => session.status !== "stopped");
}

function stoppedWorkspaceRows(rows: SessionListRow[]): SessionListRow[] {
  return rows.filter((session) => session.status === "stopped");
}

function applySessionListClientFilters(
  sessions: SessionListRow[],
  flags: Record<string, string>,
): SessionListRow[] {
  const statuses = normalizeStatusFilter(flags.status);
  const limit = parsePositiveLimit(flags.limit);
  let filtered = sessions.filter((session) => sessionMatchesStatus(session, statuses));
  if (flags.worktree) {
    filtered = filtered.filter((session) => (session.worktreeId ?? "main") === flags.worktree);
  }
  if (limit !== undefined) {
    filtered = filtered.slice(0, limit);
  }
  return filtered;
}

async function listWorkspaceSessionsLikeApp(
  workspaceId: string,
  flags: Record<string, string>,
  call: SessionListApiCall,
): Promise<SessionListResponse & WorkspaceSessionCollectionResponse> {
  const statuses = normalizeStatusFilter(flags.status);
  const workspaceStatuses = statuses.length > 0 ? statuses : ["active", "stopped"];
  const nowMs = Date.now();
  const params = new URLSearchParams();
  params.set("status", workspaceStatuses.join(","));
  if (workspaceStatuses.includes("stopped")) {
    params.set("sinceMs", String(nowMs - DEFAULT_SESSION_LIST_RECENT_DAYS * DAY_MS));
    params.set("untilMs", String(nowMs + 1));
  }
  if (flags.worktree) params.set("worktreeId", flags.worktree);

  const response = await call<WorkspaceSessionCollectionResponse>(
    `/workspaces/${encodeURIComponent(workspaceId)}/sessions${querySuffix(params)}`,
  );
  const sessions = applySessionListClientFilters(
    [...(response.active ?? []), ...(response.stopped ?? [])],
    flags,
  );

  return {
    ...response,
    sessions,
    active: activeWorkspaceRows(sessions),
    stopped: stoppedWorkspaceRows(sessions),
  };
}

async function listRecentSessionsLikeApp(
  flags: Record<string, string>,
  call: SessionListApiCall,
): Promise<SessionListResponse> {
  const params = new URLSearchParams();
  params.set("recentDays", String(DEFAULT_SESSION_LIST_RECENT_DAYS));
  const response = await call<SessionListResponse>(`/sessions/recent${querySuffix(params)}`);
  return {
    ...response,
    sessions: applySessionListClientFilters(response.sessions ?? [], flags),
  };
}

async function listGenericSessions(
  flags: Record<string, string>,
  call: SessionListApiCall,
  workspaceId?: string,
): Promise<SessionListResponse> {
  const params = new URLSearchParams();
  if (workspaceId) params.set("workspaceId", workspaceId);
  if (flags.worktree) params.set("worktreeId", flags.worktree);
  if (flags.status) params.set("status", flags.status);
  if (flags.limit) params.set("limit", flags.limit);
  if (flags.agent) params.set("agentId", flags.agent);
  return call<SessionListResponse>(`/sessions${querySuffix(params)}`);
}

async function listSessions(
  storage: LocalApiConnection,
  flags: Record<string, string>,
  call: SessionListApiCall,
  hostResolvers: LocalApiHostResolvers,
): Promise<SessionListResponse> {
  const statuses = normalizeStatusFilter(flags.status);

  if (flags.workspace) {
    const workspaceId = await resolveWorkspaceIdForCli(storage, flags.workspace, hostResolvers);
    if (!flags.agent && isWorkspaceListStatusFilter(statuses)) {
      return listWorkspaceSessionsLikeApp(workspaceId, flags, call);
    }
    return listGenericSessions(flags, call, workspaceId);
  }

  if (!flags.agent) {
    return listRecentSessionsLikeApp(flags, call);
  }

  return listGenericSessions(flags, call);
}

type SessionInspectResult = {
  session?: Partial<Session>;
  turns: string;
  selectedTurns: number[];
  selected_turns: number[];
  view: SessionInspectView;
  summary: Record<string, unknown>;
  text: string;
};

async function inspectSession(
  id: string,
  positional: string[],
  flags: Record<string, string>,
  call: SessionListApiCall,
): Promise<SessionInspectResult> {
  const turnsSpec = flags.turns?.trim() || positional[0]?.trim() || "all";
  const view = inspectView(flags.view);

  const result = await call<{ session?: Partial<Session>; trace?: SessionTraceEvent[] }>(
    `/sessions/${encodeURIComponent(id)}/trace`,
  );
  if (!Array.isArray(result.trace)) throw new Error("Local API did not return a trace array");
  const trace = result.trace;
  const turns = buildInspectTurns(trace);
  const selectedTurns = parseInspectTurnSelector(turnsSpec, turns.length);
  const selectedSet = new Set(selectedTurns);
  const summary = inspectSummary(result.session, trace, turns);
  const text = renderInspectView(view, turns, selectedSet, summary);

  return {
    session: result.session,
    turns: turnsSpec,
    selectedTurns,
    selected_turns: selectedTurns,
    view,
    summary,
    text,
  };
}

function inspectView(raw: string | undefined): SessionInspectView {
  const view = raw?.trim() || "messages";
  if (view === "overview" || view === "messages" || view === "summary" || view === "tools") {
    return view;
  }
  throw new Error("--view must be one of overview, messages, summary, or tools");
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

function renderInspectMessages(turns: SessionInspectTurn[], selectedSet: Set<number>): string {
  const lines: string[] = [];
  for (const turn of turns) {
    if (!selectedSet.has(turn.turn)) continue;
    lines.push(`Turn ${turn.turn}`);
    for (const text of turn.summaryTexts) lines.push(`  summary: ${text}`);
    for (const text of turn.systemTexts) lines.push(`  system: ${text}`);
    for (const text of turn.userTexts) lines.push(`  user: ${text}`);
    for (const text of turn.assistantTexts) lines.push(`  assistant: ${text}`);
    for (const text of turn.thinkingTexts) lines.push(`  thinking: ${text}`);
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

function savedAgentReference(agent: string | undefined): string | undefined {
  const normalized = agent?.trim();
  if (!normalized || normalized === "default" || normalized === "workspace_default")
    return undefined;
  return normalized;
}

function eventText(event: SessionTraceEvent): string {
  if (typeof event.text === "string") return event.text;
  if (typeof event.message === "string") return event.message;
  return "";
}

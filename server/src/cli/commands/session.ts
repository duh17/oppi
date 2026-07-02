/* eslint-disable no-console */
import * as c from "../../ansi.js";
import type { Storage } from "../../storage.js";
import type { Session } from "../../types.js";
import {
  localApiRequest,
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
import { apiStatus, resolveWorkspaceIdForCli } from "../resources.js";

type SessionTraceEvent = {
  type?: string;
  text?: string;
  message?: unknown;
  [key: string]: unknown;
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
  storage: Storage,
  action: string | undefined,
  positional: string[],
  flags: Record<string, string>,
  hostResolvers: LocalApiHostResolvers = {},
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

    throw new Error("Usage: oppi session list|get|create|send|read|events|trace|stop");
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
  storage: Storage,
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
  storage: Storage,
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

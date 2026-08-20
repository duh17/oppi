import { parseSessionTimeRange, type SessionTimeRange } from "../../session-time-range.js";
import type { Session } from "../../types.js";
import type { LocalApiConnection, LocalApiRequestOptions } from "../local-api-client.js";
import { resolveWorkspaceIdForCli } from "../resources.js";

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
export function compactSessionListRow(session: SessionListRow): Record<string, unknown> {
  return {
    id: session.id ?? null,
    status: session.status ?? null,
    name: session.name ?? null,
    workspace_id: session.workspaceId ?? null,
    workspace_name: session.workspaceName ?? null,
    worktree_id: session.worktreeId ?? null,
    model: session.model ?? null,
    runtime: session.runtime ?? null,
    last_activity: session.lastActivity ?? session.lastModified ?? null,
    message_count: session.messageCount ?? null,
    pending_asks: session.pendingAskCount ?? 0,
  };
}

export function sessionWorkspaceMeta(session: SessionListRow): string {
  const workspace = session.workspaceName ?? session.workspaceId;
  return workspace ? `workspace ${workspace}` : "";
}

export function clipListCell(value: unknown, maxLength: number): string {
  const text = typeof value === "string" ? value.trim() : String(value ?? "");
  if (text.length <= maxLength) return text;
  return `${text.slice(0, Math.max(0, maxLength - 1))}…`;
}

export function formatSessionListRelativeTime(activityMs: number, nowMs: number): string {
  if (!Number.isFinite(activityMs) || !Number.isFinite(nowMs)) return "";
  const elapsedMs = Math.max(0, nowMs - activityMs);
  if (elapsedMs < 60_000) return "just now";
  if (elapsedMs < 3_600_000) return `${Math.floor(elapsedMs / 60_000)}m ago`;
  if (elapsedMs < 86_400_000) return `${Math.floor(elapsedMs / 3_600_000)}h ago`;
  return `${Math.floor(elapsedMs / 86_400_000)}d ago`;
}

type SessionListApiCall = <T>(path: string, options?: LocalApiRequestOptions) => Promise<T>;

function querySuffix(params: URLSearchParams): string {
  const query = params.toString();
  return query ? `?${query}` : "";
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

function sessionListActivity(session: SessionListRow): number | undefined {
  const activity = session.lastActivity ?? session.lastModified;
  return typeof activity === "number" && Number.isFinite(activity) ? activity : undefined;
}

function sessionMatchesTimeRange(session: SessionListRow, timeRange: SessionTimeRange): boolean {
  if (timeRange.sinceMs === undefined && timeRange.untilMs === undefined) return true;
  const activity = sessionListActivity(session);
  if (activity === undefined) return false;
  if (timeRange.sinceMs !== undefined && activity < timeRange.sinceMs) return false;
  if (timeRange.untilMs !== undefined && activity > timeRange.untilMs) return false;
  return true;
}

function applySessionListClientFilters(
  sessions: SessionListRow[],
  flags: Record<string, string>,
  timeRange: SessionTimeRange,
): SessionListRow[] {
  const statuses = normalizeStatusFilter(flags.status);
  const limit = parsePositiveLimit(flags.limit);
  let filtered = sessions.filter(
    (session) =>
      sessionMatchesTimeRange(session, timeRange) && sessionMatchesStatus(session, statuses),
  );
  if (flags.worktree) {
    filtered = filtered.filter((session) => (session.worktreeId ?? "main") === flags.worktree);
  }
  if (limit !== undefined) {
    filtered = filtered.slice(0, limit);
  }
  return filtered;
}

function sessionListTimeRange(flags: Record<string, string>): SessionTimeRange {
  const parsed = parseSessionTimeRange(flags.since, flags.until, "session list");
  if (parsed.error) throw new Error(parsed.error);
  return parsed;
}

async function listWorkspaceSessionsLikeApp(
  workspaceId: string,
  flags: Record<string, string>,
  timeRange: SessionTimeRange,
  call: SessionListApiCall,
): Promise<SessionListResponse & WorkspaceSessionCollectionResponse> {
  const statuses = normalizeStatusFilter(flags.status);
  const workspaceStatuses = statuses.length > 0 ? statuses : ["active", "stopped"];
  const nowMs = Date.now();
  const params = new URLSearchParams();
  params.set("status", workspaceStatuses.join(","));
  const hasExplicitTimeRange = timeRange.sinceMs !== undefined || timeRange.untilMs !== undefined;
  if (hasExplicitTimeRange) {
    if (flags.since) params.set("since", flags.since);
    if (flags.until) params.set("until", flags.until);
  } else if (workspaceStatuses.includes("stopped")) {
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
    timeRange,
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
  timeRange: SessionTimeRange,
  call: SessionListApiCall,
): Promise<SessionListResponse> {
  const params = new URLSearchParams();
  if (timeRange.sinceMs !== undefined || timeRange.untilMs !== undefined) {
    if (flags.since) params.set("since", flags.since);
    if (flags.until) params.set("until", flags.until);
  } else {
    params.set("recentDays", String(DEFAULT_SESSION_LIST_RECENT_DAYS));
  }
  const response = await call<SessionListResponse>(`/sessions/recent${querySuffix(params)}`);
  return {
    ...response,
    sessions: applySessionListClientFilters(
      Array.isArray(response.sessions) ? response.sessions : [],
      flags,
      timeRange,
    ),
  };
}

async function listGenericSessions(
  flags: Record<string, string>,
  timeRange: SessionTimeRange,
  call: SessionListApiCall,
  workspaceId?: string,
): Promise<SessionListResponse> {
  const params = new URLSearchParams();
  if (workspaceId) params.set("workspaceId", workspaceId);
  if (flags.worktree) params.set("worktreeId", flags.worktree);
  if (flags.status) params.set("status", flags.status);
  if (flags.limit) params.set("limit", flags.limit);
  if (flags.agent) params.set("agentId", flags.agent);
  if (flags.since) params.set("since", flags.since);
  if (flags.until) params.set("until", flags.until);
  const response = await call<SessionListResponse>(`/sessions${querySuffix(params)}`);
  return {
    ...response,
    sessions: applySessionListClientFilters(
      Array.isArray(response.sessions) ? response.sessions : [],
      flags,
      timeRange,
    ),
  };
}

export async function listSessions(
  storage: LocalApiConnection,
  flags: Record<string, string>,
  call: SessionListApiCall,
): Promise<SessionListResponse> {
  const statuses = normalizeStatusFilter(flags.status);
  const timeRange = sessionListTimeRange(flags);

  if (flags.workspace) {
    const workspaceId = await resolveWorkspaceIdForCli(storage, flags.workspace);
    if (!flags.agent && isWorkspaceListStatusFilter(statuses)) {
      return listWorkspaceSessionsLikeApp(workspaceId, flags, timeRange, call);
    }
    return listGenericSessions(flags, timeRange, call, workspaceId);
  }

  if (!flags.agent) {
    return listRecentSessionsLikeApp(flags, timeRange, call);
  }

  return listGenericSessions(flags, timeRange, call);
}

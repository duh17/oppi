import type { Session } from "../../types.js";
import type {
  LocalApiConnection,
  LocalApiHostResolvers,
  LocalApiRequestOptions,
} from "../local-api-client.js";
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
    sessions: applySessionListClientFilters(
      Array.isArray(response.sessions) ? response.sessions : [],
      flags,
    ),
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

export async function listSessions(
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

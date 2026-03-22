/**
 * Aggregation logic for GET /server/stats.
 *
 * Pure functions — no side effects — so we can unit-test without HTTP.
 */
import type { Session, Workspace } from "../types.js";

// ─── Response types ───

export interface StatsMemory {
  heapUsed: number;
  heapTotal: number;
  rss: number;
  external: number;
}

export interface StatsActiveSession {
  id: string;
  status: string;
  model?: string;
  cost: number;
  name?: string;
  firstMessage?: string;
  workspaceName?: string;
  thinkingLevel?: string;
  parentSessionId?: string;
  contextTokens?: number;
  contextWindow?: number;
  createdAt: number;
}

export interface StatsDailyModelEntry {
  sessions: number;
  cost: number;
  tokens: number;
}

export interface StatsDailyEntry {
  date: string; // "YYYY-MM-DD"
  sessions: number;
  cost: number;
  tokens: number;
  byModel: Record<string, StatsDailyModelEntry>;
}

export interface StatsModelBreakdown {
  model: string;
  sessions: number;
  cost: number;
  tokens: number;
  share: number; // 0–1 fraction of total cost
}

export interface StatsWorkspaceBreakdown {
  id: string;
  name: string;
  sessions: number;
  cost: number;
}

export interface StatsTotals {
  sessions: number;
  cost: number;
  tokens: number;
}

// ─── Daily detail types ───

export interface StatsDailyHourlyEntry {
  hour: number; // 0-23
  sessions: number;
  cost: number;
  tokens: number;
  byModel: Record<string, StatsDailyModelEntry>;
}

export interface StatsDailySession {
  id: string;
  name?: string;
  model?: string;
  cost: number;
  tokens: number;
  createdAt: number;
  workspaceName?: string;
  status: string;
}

export interface DailyDetailResult {
  date: string;
  totals: StatsTotals;
  hourly: StatsDailyHourlyEntry[];
  sessions: StatsDailySession[];
}

// ─── Helpers ───

const VALID_RANGES = new Set([7, 30, 90]);

export function parseRange(raw: string | null): number {
  if (!raw) return 7;
  const n = Number(raw);
  return VALID_RANGES.has(n) ? n : 7;
}

function toDateString(ts: number): string {
  const d = new Date(ts);
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, "0");
  const day = String(d.getUTCDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function sessionTokens(s: Session): number {
  return (
    (s.tokens?.input ?? 0) +
    (s.tokens?.output ?? 0) +
    (s.tokens?.cacheRead ?? 0) +
    (s.tokens?.cacheWrite ?? 0)
  );
}

function round2(n: number): number {
  return Math.round(n * 100) / 100;
}

// ─── Memory ───

export function getMemoryStats(): StatsMemory {
  const mem = process.memoryUsage();
  return {
    heapUsed: round2(mem.heapUsed / 1024 / 1024),
    heapTotal: round2(mem.heapTotal / 1024 / 1024),
    rss: round2(mem.rss / 1024 / 1024),
    external: round2(mem.external / 1024 / 1024),
  };
}

// ─── Active sessions ───

/**
 * Return sessions that are genuinely active.
 *
 * A session is active only if it has a non-terminal disk status AND is
 * present in the in-memory `activeSessionIds` set. Sessions that crashed
 * mid-startup (status "starting" on disk but not in memory) are zombies
 * and excluded.
 */
export function getActiveSessions(
  sessions: Session[],
  activeSessionIds?: Set<string>,
): StatsActiveSession[] {
  return sessions
    .filter((s) => {
      if (s.status === "stopped" || s.status === "error") return false;
      // If we have in-memory state, cross-reference — disk-only zombies are excluded
      if (activeSessionIds && !activeSessionIds.has(s.id)) return false;
      return true;
    })
    .map((s) => ({
      id: s.id,
      status: s.status,
      model: s.model,
      cost: round2(s.cost),
      name: s.name,
      firstMessage: s.firstMessage,
      workspaceName: s.workspaceName,
      thinkingLevel: s.thinkingLevel,
      parentSessionId: s.parentSessionId,
      contextTokens: s.contextTokens,
      contextWindow: s.contextWindow,
      createdAt: s.createdAt,
    }));
}

// ─── Aggregation (pure) ───

export interface AggregateInput {
  sessions: Session[];
  workspaces: Workspace[];
  rangeDays: number;
  now?: number; // injectable for testing
}

export interface AggregateResult {
  daily: StatsDailyEntry[];
  modelBreakdown: StatsModelBreakdown[];
  workspaceBreakdown: StatsWorkspaceBreakdown[];
  totals: StatsTotals;
}

export function aggregateStats(input: AggregateInput): AggregateResult {
  const now = input.now ?? Date.now();
  const cutoff = now - input.rangeDays * 24 * 60 * 60 * 1000;

  const inRange = input.sessions.filter((s) => s.createdAt >= cutoff);

  // Build workspace name map
  const wsNames = new Map<string, string>();
  for (const w of input.workspaces) {
    wsNames.set(w.id, w.name);
  }

  // ─── Daily ───
  const dailyMap = new Map<
    string,
    { sessions: number; cost: number; tokens: number; byModel: Map<string, StatsDailyModelEntry> }
  >();

  // ─── Model ───
  const modelMap = new Map<string, { sessions: number; cost: number; tokens: number }>();

  // ─── Workspace ───
  const wsMap = new Map<string, { sessions: number; cost: number }>();

  // ─── Totals ───
  let totalSessions = 0;
  let totalCost = 0;
  let totalTokens = 0;

  for (const s of inRange) {
    const date = toDateString(s.createdAt);
    const model = s.model ?? "unknown";
    const cost = s.cost ?? 0;
    const tokens = sessionTokens(s);

    totalSessions++;
    totalCost += cost;
    totalTokens += tokens;

    // Daily
    let day = dailyMap.get(date);
    if (!day) {
      day = { sessions: 0, cost: 0, tokens: 0, byModel: new Map() };
      dailyMap.set(date, day);
    }
    day.sessions++;
    day.cost += cost;
    day.tokens += tokens;

    let dayModel = day.byModel.get(model);
    if (!dayModel) {
      dayModel = { sessions: 0, cost: 0, tokens: 0 };
      day.byModel.set(model, dayModel);
    }
    dayModel.sessions++;
    dayModel.cost += cost;
    dayModel.tokens += tokens;

    // Model
    let m = modelMap.get(model);
    if (!m) {
      m = { sessions: 0, cost: 0, tokens: 0 };
      modelMap.set(model, m);
    }
    m.sessions++;
    m.cost += cost;
    m.tokens += tokens;

    // Workspace
    const wsId = s.workspaceId ?? "unknown";
    let ws = wsMap.get(wsId);
    if (!ws) {
      ws = { sessions: 0, cost: 0 };
      wsMap.set(wsId, ws);
    }
    ws.sessions++;
    ws.cost += cost;
  }

  // ─── Format daily (sorted ascending) ───
  const daily: StatsDailyEntry[] = [...dailyMap.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([date, d]) => ({
      date,
      sessions: d.sessions,
      cost: round2(d.cost),
      tokens: d.tokens,
      byModel: Object.fromEntries(
        [...d.byModel.entries()].map(([model, entry]) => [
          model,
          { sessions: entry.sessions, cost: round2(entry.cost), tokens: entry.tokens },
        ]),
      ),
    }));

  // ─── Format model breakdown (sorted by cost desc) ───
  const modelBreakdown: StatsModelBreakdown[] = [...modelMap.entries()]
    .sort(([, a], [, b]) => b.cost - a.cost)
    .map(([model, m]) => ({
      model,
      sessions: m.sessions,
      cost: round2(m.cost),
      tokens: m.tokens,
      share: totalCost > 0 ? round2(m.cost / totalCost) : 0,
    }));

  // ─── Format workspace breakdown (sorted by cost desc) ───
  const workspaceBreakdown: StatsWorkspaceBreakdown[] = [...wsMap.entries()]
    .sort(([, a], [, b]) => b.cost - a.cost)
    .map(([id, w]) => ({
      id,
      name: wsNames.get(id) ?? id,
      sessions: w.sessions,
      cost: round2(w.cost),
    }));

  return {
    daily,
    modelBreakdown,
    workspaceBreakdown,
    totals: {
      sessions: totalSessions,
      cost: round2(totalCost),
      tokens: totalTokens,
    },
  };
}

// ─── Daily detail aggregation ───

export function aggregateDailyDetail(sessions: Session[], date: string): DailyDetailResult {
  const dayStart = new Date(date + "T00:00:00.000Z").getTime();
  const dayEnd = new Date(date + "T23:59:59.999Z").getTime();

  const inDay = sessions.filter((s) => s.createdAt >= dayStart && s.createdAt <= dayEnd);

  // Hourly buckets
  const hourlyMap = new Map<
    number,
    { sessions: number; cost: number; tokens: number; byModel: Map<string, StatsDailyModelEntry> }
  >();

  let totalSessions = 0;
  let totalCost = 0;
  let totalTokens = 0;

  for (const s of inDay) {
    const hour = new Date(s.createdAt).getUTCHours();
    const model = s.model ?? "unknown";
    const cost = s.cost ?? 0;
    const tokens = sessionTokens(s);

    totalSessions++;
    totalCost += cost;
    totalTokens += tokens;

    let bucket = hourlyMap.get(hour);
    if (!bucket) {
      bucket = { sessions: 0, cost: 0, tokens: 0, byModel: new Map() };
      hourlyMap.set(hour, bucket);
    }
    bucket.sessions++;
    bucket.cost += cost;
    bucket.tokens += tokens;

    let modelEntry = bucket.byModel.get(model);
    if (!modelEntry) {
      modelEntry = { sessions: 0, cost: 0, tokens: 0 };
      bucket.byModel.set(model, modelEntry);
    }
    modelEntry.sessions++;
    modelEntry.cost += cost;
    modelEntry.tokens += tokens;
  }

  // Sparse hourly array sorted by hour
  const hourly: StatsDailyHourlyEntry[] = [...hourlyMap.entries()]
    .sort(([a], [b]) => a - b)
    .map(([hour, h]) => ({
      hour,
      sessions: h.sessions,
      cost: round2(h.cost),
      tokens: h.tokens,
      byModel: Object.fromEntries(
        [...h.byModel.entries()].map(([model, entry]) => [
          model,
          { sessions: entry.sessions, cost: round2(entry.cost), tokens: entry.tokens },
        ]),
      ),
    }));

  // Session list sorted by createdAt
  const sessionList: StatsDailySession[] = inDay
    .slice()
    .sort((a, b) => a.createdAt - b.createdAt)
    .map((s) => ({
      id: s.id,
      name: s.name,
      model: s.model,
      cost: round2(s.cost ?? 0),
      tokens: sessionTokens(s),
      createdAt: s.createdAt,
      workspaceName: s.workspaceName,
      status: s.status,
    }));

  return {
    date,
    totals: {
      sessions: totalSessions,
      cost: round2(totalCost),
      tokens: totalTokens,
    },
    hourly,
    sessions: sessionList,
  };
}

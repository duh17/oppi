import { chmodSync, existsSync, mkdirSync } from "node:fs";
import { join, resolve } from "node:path";

import { openDatabase, type SqliteDatabase, type SqliteStatement } from "../sqlite-compat.js";

export const RESOURCE_USAGE_RETENTION_DAYS = 120;
const RETENTION_MS = RESOURCE_USAGE_RETENTION_DAYS * 86_400_000;

export type ResourceUsageSignal =
  | "agent_load"
  | "explicit_activation"
  | "tool_invocation"
  | "command_invocation";
export type ResourceUsageOwnerKind = "skill" | "extension" | "builtin";
export type ResourceUsageRuntime = "oppi" | "pi-tui";

export interface ResourceUsageEvent {
  actionId: string;
  occurredAt: number;
  signal: ResourceUsageSignal;
  sessionId: string;
  workspaceId?: string;
  runtime: ResourceUsageRuntime;
  ownerKind: ResourceUsageOwnerKind;
  ownerId: string;
  itemName?: string;
  provider?: string;
  model?: string;
  manifestRevision?: string;
}

export type ResourceUsageSubject =
  | { kind: "skill"; id: string }
  | { kind: "extension"; id: string }
  | { kind: "tools" };

export interface ResourceUsageBounds {
  oldestRecordedAt?: number;
  lastRecordedAt?: number;
}

export interface ResourceUsageAggregateBreakdown {
  signal: ResourceUsageSignal;
  name: string;
  ownerKind: ResourceUsageOwnerKind;
  ownerId: string;
  actions: number;
  sessions: number;
}

export interface ResourceUsageAggregate {
  actions: number;
  sessions: number;
  lastRecordedAt?: number;
  breakdown: ResourceUsageAggregateBreakdown[];
}

interface EventRow {
  action_id: string;
  occurred_at: number;
  signal: ResourceUsageSignal;
  session_id: string;
  workspace_id: string | null;
  runtime: ResourceUsageRuntime;
  owner_kind: ResourceUsageOwnerKind;
  owner_id: string;
  item_name: string | null;
  provider: string | null;
  model: string | null;
  manifest_revision: string | null;
}

interface BoundsRow {
  oldest_recorded_at: number | null;
  last_recorded_at: number | null;
}

interface AggregateSummaryRow {
  actions: number;
  sessions: number;
  last_recorded_at: number | null;
}

interface AggregateBreakdownRow {
  signal: ResourceUsageSignal;
  name: string;
  owner_kind: ResourceUsageOwnerKind;
  owner_id: string;
  actions: number;
  sessions: number;
}

interface AggregateDailyRow {
  day_index: number;
  actions: number;
  sessions: number;
  last_recorded_at: number | null;
}

export interface ResourceUsagePendingPurge {
  kind: "session" | "workspace";
  targetId: string;
  requestedAt: number;
}

export interface ResourceUsagePurgeAttempt {
  completed: boolean;
  records: number;
}

export interface ResourceUsageStoreOptions {
  dbPath?: string;
  now?: () => number;
}

/** Indexed, privacy-minimized source of truth for exact live resource actions. */
export class ResourceUsageStore {
  private readonly db: SqliteDatabase;
  private readonly now: () => number;
  private readonly insertStatement: SqliteStatement;

  constructor(dataDir: string, options: ResourceUsageStoreOptions = {}) {
    if (!existsSync(dataDir)) mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    const dbPath = resolve(options.dbPath ?? join(dataDir, "resource-usage.db"));
    this.db = openDatabase(dbPath);
    this.now = options.now ?? Date.now;
    chmodSync(dbPath, 0o600);
    this.db.exec("PRAGMA journal_mode = WAL");
    this.db.exec("PRAGMA synchronous = NORMAL");
    this.db.exec("PRAGMA busy_timeout = 100");
    this.ensureSchema();
    this.retryPendingPurges();
    this.insertStatement = this.db.prepare(`
      INSERT OR IGNORE INTO resource_usage_events (
        action_id, occurred_at, signal, session_id, workspace_id, runtime,
        owner_kind, owner_id, item_name, provider, model, manifest_revision
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);
    this.deleteExpired(this.now());
  }

  close(): void {
    this.db.close();
  }

  recordBatch(events: readonly ResourceUsageEvent[], nowMs = this.now()): void {
    this.retryPendingPurges();
    const transaction = this.db.transaction(() => {
      const cutoff = nowMs - RETENTION_MS;
      for (const event of events) {
        if (event.occurredAt < cutoff) continue;
        this.insertStatement.run(
          event.actionId,
          event.occurredAt,
          event.signal,
          event.sessionId,
          event.workspaceId ?? null,
          event.runtime,
          event.ownerKind,
          event.ownerId,
          event.itemName ?? null,
          event.provider ?? null,
          event.model ?? null,
          event.manifestRevision ?? null,
        );
      }
      this.db.prepare("DELETE FROM resource_usage_events WHERE occurred_at < ?").run(cutoff);
    });
    transaction();
  }

  deleteExpired(nowMs = this.now()): number {
    return changesFrom(
      this.db
        .prepare("DELETE FROM resource_usage_events WHERE occurred_at < ?")
        .run(nowMs - RETENTION_MS),
    );
  }

  deleteSession(sessionId: string): number {
    return changesFrom(
      this.db.prepare("DELETE FROM resource_usage_events WHERE session_id = ?").run(sessionId),
    );
  }

  deleteResource(ownerKind: ResourceUsageOwnerKind, ownerId: string): number {
    return changesFrom(
      this.db
        .prepare("DELETE FROM resource_usage_events WHERE owner_kind = ? AND owner_id = ?")
        .run(ownerKind, ownerId),
    );
  }

  deleteWorkspace(workspaceId: string): number {
    return changesFrom(
      this.db.prepare("DELETE FROM resource_usage_events WHERE workspace_id = ?").run(workspaceId),
    );
  }

  requestSessionPurge(sessionId: string): ResourceUsagePurgeAttempt {
    return this.requestPurge("session", sessionId);
  }

  requestWorkspacePurge(workspaceId: string): ResourceUsagePurgeAttempt {
    return this.requestPurge("workspace", workspaceId);
  }

  listPendingPurges(): ResourceUsagePendingPurge[] {
    const rows = this.db
      .prepare(
        `SELECT kind, target_id, requested_at
         FROM resource_usage_pending_purges
         ORDER BY requested_at ASC, kind ASC, target_id ASC`,
      )
      .all() as Array<{ kind: "session" | "workspace"; target_id: string; requested_at: number }>;
    return rows.map((row) => ({
      kind: row.kind,
      targetId: row.target_id,
      requestedAt: row.requested_at,
    }));
  }

  nextRuntimeInstanceId(): string {
    const transaction = this.db.transaction(() => {
      const key = "runtime_instance_generation";
      const current = Number(this.getMetadata(key));
      const next = Number.isSafeInteger(current) && current >= 0 ? current + 1 : 1;
      this.setMetadata(key, String(next));
      return `runtime-${next}`;
    });
    return transaction();
  }

  aggregate(input: {
    subject: ResourceUsageSubject;
    sinceMs: number;
    untilMs: number;
  }): ResourceUsageAggregate {
    const { clause, params } = subjectClause(input.subject);
    const untilMs = Number.isFinite(input.untilMs) ? input.untilMs : Number.MAX_SAFE_INTEGER;
    const rangeParams = [input.sinceMs, untilMs, ...params];
    const summary = this.db
      .prepare(
        `SELECT COUNT(*) AS actions,
                COUNT(DISTINCT session_id) AS sessions,
                MAX(occurred_at) AS last_recorded_at
         FROM resource_usage_events
         WHERE occurred_at >= ? AND occurred_at <= ? AND ${clause}`,
      )
      .get(...rangeParams) as AggregateSummaryRow | undefined;
    const rows = this.db
      .prepare(
        `SELECT signal,
                COALESCE(item_name, signal) AS name,
                owner_kind,
                owner_id,
                COUNT(*) AS actions,
                COUNT(DISTINCT session_id) AS sessions
         FROM resource_usage_events
         WHERE occurred_at >= ? AND occurred_at <= ? AND ${clause}
         GROUP BY signal, name, owner_kind, owner_id
         ORDER BY actions DESC, name ASC`,
      )
      .all(...rangeParams) as AggregateBreakdownRow[];

    return {
      actions: numberValue(summary?.actions),
      sessions: numberValue(summary?.sessions),
      ...(summary?.last_recorded_at !== null && summary?.last_recorded_at !== undefined
        ? { lastRecordedAt: summary.last_recorded_at }
        : {}),
      breakdown: rows.map((row) => ({
        signal: row.signal,
        name: row.name,
        ownerKind: row.owner_kind,
        ownerId: row.owner_id,
        actions: numberValue(row.actions),
        sessions: numberValue(row.sessions),
      })),
    };
  }

  aggregateDaily(input: {
    subject: ResourceUsageSubject;
    ranges: readonly { startMs: number; endMs: number }[];
  }): Map<number, ResourceUsageAggregate> {
    if (input.ranges.length === 0) return new Map();
    const { clause, params } = subjectClause(input.subject);
    const first = input.ranges[0];
    const last = input.ranges[input.ranges.length - 1];
    if (!first || !last) return new Map();
    const cases = input.ranges
      .map((_, index) => `WHEN occurred_at >= ? AND occurred_at < ? THEN ${index}`)
      .join(" ");
    const rangeParams = input.ranges.flatMap((range) => [range.startMs, range.endMs]);
    const rows = this.db
      .prepare(
        `SELECT CASE ${cases} ELSE NULL END AS day_index,
                COUNT(*) AS actions,
                COUNT(DISTINCT session_id) AS sessions,
                MAX(occurred_at) AS last_recorded_at
         FROM resource_usage_events
         WHERE occurred_at >= ? AND occurred_at < ? AND ${clause}
         GROUP BY day_index
         ORDER BY day_index ASC`,
      )
      .all(...rangeParams, first.startMs, last.endMs, ...params) as AggregateDailyRow[];
    return new Map(
      rows.flatMap((row) => {
        if (!Number.isInteger(row.day_index) || row.day_index < 0) return [];
        return [
          [
            row.day_index,
            {
              actions: numberValue(row.actions),
              sessions: numberValue(row.sessions),
              ...(row.last_recorded_at !== null && row.last_recorded_at !== undefined
                ? { lastRecordedAt: row.last_recorded_at }
                : {}),
              breakdown: [],
            },
          ] as const,
        ];
      }),
    );
  }

  queryEvents(input: {
    subject: ResourceUsageSubject;
    sinceMs: number;
    untilMs: number;
  }): ResourceUsageEvent[] {
    const { clause, params } = subjectClause(input.subject);
    const untilMs = Number.isFinite(input.untilMs) ? input.untilMs : Number.MAX_SAFE_INTEGER;
    const rows = this.db
      .prepare(
        `SELECT action_id, occurred_at, signal, session_id, workspace_id, runtime,
                owner_kind, owner_id, item_name, provider, model, manifest_revision
         FROM resource_usage_events
         WHERE occurred_at >= ? AND occurred_at <= ? AND ${clause}
         ORDER BY occurred_at ASC, action_id ASC`,
      )
      .all(input.sinceMs, untilMs, ...params) as EventRow[];
    return rows.map(eventFromRow);
  }

  retainedBounds(subject: ResourceUsageSubject, nowMs = this.now()): ResourceUsageBounds {
    const { clause, params } = subjectClause(subject);
    const row = this.db
      .prepare(
        `SELECT MIN(occurred_at) AS oldest_recorded_at, MAX(occurred_at) AS last_recorded_at
         FROM resource_usage_events
         WHERE occurred_at >= ? AND ${clause}`,
      )
      .get(nowMs - RETENTION_MS, ...params) as BoundsRow | undefined;
    return {
      ...(row?.oldest_recorded_at !== null && row?.oldest_recorded_at !== undefined
        ? { oldestRecordedAt: row.oldest_recorded_at }
        : {}),
      ...(row?.last_recorded_at !== null && row?.last_recorded_at !== undefined
        ? { lastRecordedAt: row.last_recorded_at }
        : {}),
    };
  }

  getMetadata(key: string): string | undefined {
    const row = this.db
      .prepare("SELECT value FROM resource_usage_metadata WHERE key = ?")
      .get(key) as { value?: string } | undefined;
    return row?.value;
  }

  setMetadata(key: string, value: string): void {
    this.db
      .prepare(
        `INSERT INTO resource_usage_metadata (key, value) VALUES (?, ?)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
      )
      .run(key, value);
  }

  private requestPurge(
    kind: ResourceUsagePendingPurge["kind"],
    targetId: string,
  ): ResourceUsagePurgeAttempt {
    this.db
      .prepare(
        `INSERT OR IGNORE INTO resource_usage_pending_purges (kind, target_id, requested_at)
         VALUES (?, ?, ?)`,
      )
      .run(kind, targetId, this.now());
    try {
      const records =
        kind === "session" ? this.deleteSession(targetId) : this.deleteWorkspace(targetId);
      this.db
        .prepare("DELETE FROM resource_usage_pending_purges WHERE kind = ? AND target_id = ?")
        .run(kind, targetId);
      return { completed: true, records };
    } catch {
      return { completed: false, records: 0 };
    }
  }

  private retryPendingPurges(): void {
    for (const purge of this.listPendingPurges()) {
      try {
        if (purge.kind === "session") this.deleteSession(purge.targetId);
        else this.deleteWorkspace(purge.targetId);
        this.db
          .prepare("DELETE FROM resource_usage_pending_purges WHERE kind = ? AND target_id = ?")
          .run(purge.kind, purge.targetId);
      } catch {
        // Keep the durable row for the next startup or write.
      }
    }
  }

  private ensureSchema(): void {
    const existingColumns = tableColumns(this.db, "resource_usage_events");
    const exactLiveSchema =
      existingColumns.length > 0 && metadataValue(this.db, "exact_live_schema") === "1";
    if (existingColumns.length > 0 && !exactLiveSchema) {
      this.db.exec(`
        DROP TABLE IF EXISTS resource_usage_events;
        DROP TABLE IF EXISTS resource_usage_metadata;
      `);
    }

    this.db.exec(`
      DROP TABLE IF EXISTS resource_usage_backfill_checkpoints;
      DROP TABLE IF EXISTS resource_usage_backfill_sources;
      DROP TABLE IF EXISTS resource_usage_purges;
      CREATE TABLE IF NOT EXISTS resource_usage_events (
        action_id TEXT PRIMARY KEY,
        occurred_at INTEGER NOT NULL,
        signal TEXT NOT NULL CHECK(signal IN (
          'agent_load', 'explicit_activation', 'tool_invocation', 'command_invocation'
        )),
        session_id TEXT NOT NULL,
        workspace_id TEXT,
        runtime TEXT NOT NULL CHECK(runtime IN ('oppi', 'pi-tui')),
        owner_kind TEXT NOT NULL CHECK(owner_kind IN ('skill', 'extension', 'builtin')),
        owner_id TEXT NOT NULL,
        item_name TEXT,
        provider TEXT,
        model TEXT,
        manifest_revision TEXT
      );
      CREATE TABLE IF NOT EXISTS resource_usage_metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS resource_usage_pending_purges (
        kind TEXT NOT NULL CHECK(kind IN ('session', 'workspace')),
        target_id TEXT NOT NULL,
        requested_at INTEGER NOT NULL,
        PRIMARY KEY(kind, target_id)
      );
      CREATE INDEX IF NOT EXISTS resource_usage_events_time_idx
        ON resource_usage_events(occurred_at);
      CREATE INDEX IF NOT EXISTS resource_usage_events_owner_time_idx
        ON resource_usage_events(owner_kind, owner_id, occurred_at);
      CREATE INDEX IF NOT EXISTS resource_usage_events_signal_time_idx
        ON resource_usage_events(signal, occurred_at);
      CREATE INDEX IF NOT EXISTS resource_usage_events_session_idx
        ON resource_usage_events(session_id);
      CREATE INDEX IF NOT EXISTS resource_usage_events_workspace_idx
        ON resource_usage_events(workspace_id);
      INSERT OR IGNORE INTO resource_usage_metadata (key, value)
        VALUES ('exact_live_schema', '1');
    `);
  }
}

function metadataValue(db: SqliteDatabase, key: string): string | undefined {
  const tables = db
    .prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'resource_usage_metadata'",
    )
    .all() as Array<{ name: string }>;
  if (tables.length === 0) return undefined;
  const row = db.prepare("SELECT value FROM resource_usage_metadata WHERE key = ?").get(key) as
    | { value?: string }
    | undefined;
  return row?.value;
}

function tableColumns(db: SqliteDatabase, table: string): string[] {
  return (db.prepare(`PRAGMA table_info(${table})`).all() as Array<{ name: string }>).map(
    (row) => row.name,
  );
}

function subjectClause(subject: ResourceUsageSubject): { clause: string; params: string[] } {
  switch (subject.kind) {
    case "skill":
      return { clause: "owner_kind = 'skill' AND owner_id = ?", params: [subject.id] };
    case "extension":
      return { clause: "owner_kind = 'extension' AND owner_id = ?", params: [subject.id] };
    case "tools":
      return { clause: "signal = 'tool_invocation'", params: [] };
  }
}

function eventFromRow(row: EventRow): ResourceUsageEvent {
  return {
    actionId: row.action_id,
    occurredAt: row.occurred_at,
    signal: row.signal,
    sessionId: row.session_id,
    ...(row.workspace_id ? { workspaceId: row.workspace_id } : {}),
    runtime: row.runtime,
    ownerKind: row.owner_kind,
    ownerId: row.owner_id,
    ...(row.item_name ? { itemName: row.item_name } : {}),
    ...(row.provider ? { provider: row.provider } : {}),
    ...(row.model ? { model: row.model } : {}),
    ...(row.manifest_revision ? { manifestRevision: row.manifest_revision } : {}),
  };
}

function numberValue(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : Number(value ?? 0) || 0;
}

function changesFrom(result: unknown): number {
  if (!result || typeof result !== "object") return 0;
  const changes = (result as { changes?: unknown }).changes;
  return typeof changes === "number" ? changes : 0;
}

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
export type ResourceUsageAttribution = "exact" | "inferred";
export type ResourceUsageOrigin = "live" | "history";

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
  attribution?: ResourceUsageAttribution;
  origin?: ResourceUsageOrigin;
  /** Opaque SHA-256 identity. Filesystem paths must never enter this store. */
  sourceKey?: string;
  /** Transient replay identity removed when an exact persisted marker reconciles inference. */
  reconcilesActionId?: string;
  /** Exact marker arrived before Pi's message; persist a source-scoped FIFO reconciliation. */
  reconcilesFutureInference?: boolean;
  /** Matching Pi message consumed this exact marker's durable reconciliation. */
  consumesFutureInferenceReconciliation?: boolean;
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
  exactActions: number;
  inferredActions: number;
  historicalActions: number;
  liveActions: number;
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
  attribution: ResourceUsageAttribution;
  origin: ResourceUsageOrigin;
  source_key: string | null;
}

interface BoundsRow {
  oldest_recorded_at: number | null;
  last_recorded_at: number | null;
}

interface AggregateSummaryRow {
  actions: number;
  sessions: number;
  exact_actions: number;
  inferred_actions: number;
  historical_actions: number;
  live_actions: number;
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

export interface ResourceUsageBackfillCheckpoint {
  sourceKey: string;
  offset: number;
  size: number;
  fingerprint: string;
  completedAt?: number;
  corruptLines: number;
  oversizedLines: number;
  lines: number;
}

export interface ResourceUsageBackfillSourceRecord {
  sourceKey: string;
  sessionId: string;
  workspaceId?: string;
  runtime: ResourceUsageRuntime;
  traceIdHash?: string;
}

export interface ResourceUsageBackfillEnrollment {
  sourceKey: string;
  generation: number;
}

export interface ResourceUsageBackfillFlush {
  enrollment: ResourceUsageBackfillEnrollment;
  events: readonly ResourceUsageEvent[];
  checkpoint: ResourceUsageBackfillCheckpoint;
  nowMs?: number;
}

export interface ResourceUsageBackfillFlushResult {
  accepted: boolean;
  retainedHistoricalEvents: number;
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

export interface ResourceUsageBackfillState {
  status: "available" | "running" | "complete" | "partial";
  totalSources: number;
  processedSources: number;
  completedSources: number;
  failedSources: number;
  processedBytes: number;
  processedLines: number;
  historicalEvents: number;
  corruptLines: number;
  oversizedLines: number;
  startedAt?: number;
  updatedAt: number;
  lastCompletedAt?: number;
  lastError?: string;
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
        owner_kind, owner_id, item_name, provider, model, manifest_revision,
        attribution, origin, source_key
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(action_id) DO UPDATE SET
        occurred_at = CASE WHEN excluded.origin = 'live' AND resource_usage_events.origin = 'history' THEN excluded.occurred_at ELSE resource_usage_events.occurred_at END,
        session_id = CASE WHEN excluded.origin = 'live' AND resource_usage_events.origin = 'history' THEN excluded.session_id ELSE resource_usage_events.session_id END,
        workspace_id = CASE WHEN excluded.origin = 'live' AND resource_usage_events.origin = 'history' THEN excluded.workspace_id ELSE resource_usage_events.workspace_id END,
        runtime = CASE WHEN excluded.origin = 'live' AND resource_usage_events.origin = 'history' THEN excluded.runtime ELSE resource_usage_events.runtime END,
        owner_kind = CASE WHEN excluded.attribution = 'exact' AND resource_usage_events.attribution = 'inferred' THEN excluded.owner_kind ELSE resource_usage_events.owner_kind END,
        owner_id = CASE WHEN excluded.attribution = 'exact' AND resource_usage_events.attribution = 'inferred' THEN excluded.owner_id ELSE resource_usage_events.owner_id END,
        item_name = CASE WHEN excluded.attribution = 'exact' AND resource_usage_events.attribution = 'inferred' THEN excluded.item_name ELSE resource_usage_events.item_name END,
        provider = COALESCE(resource_usage_events.provider, excluded.provider),
        model = COALESCE(resource_usage_events.model, excluded.model),
        manifest_revision = COALESCE(resource_usage_events.manifest_revision, excluded.manifest_revision),
        attribution = CASE WHEN resource_usage_events.attribution = 'exact' OR excluded.attribution = 'exact' THEN 'exact' ELSE 'inferred' END,
        origin = CASE WHEN resource_usage_events.origin = 'live' OR excluded.origin = 'live' THEN 'live' ELSE 'history' END,
        source_key = CASE WHEN resource_usage_events.origin = 'live' OR excluded.origin = 'live' THEN NULL ELSE COALESCE(resource_usage_events.source_key, excluded.source_key) END
    `);
    this.deleteExpired(this.now());
  }

  close(): void {
    this.db.close();
  }

  recordBatch(events: readonly ResourceUsageEvent[], nowMs = this.now()): void {
    this.retryPendingPurges();
    const transaction = this.db.transaction(() => {
      this.insertEvents(events, nowMs, { honorPurges: true });
    });
    transaction();
  }

  /** Atomically verifies scan ownership, writes history, and advances its checkpoint. */
  recordBackfillBatch(input: ResourceUsageBackfillFlush): ResourceUsageBackfillFlushResult {
    const transaction = this.db.transaction((): ResourceUsageBackfillFlushResult => {
      const enrolled = this.db
        .prepare(
          `SELECT session_id, workspace_id FROM resource_usage_backfill_sources
           WHERE source_key = ? AND generation = ?`,
        )
        .get(input.enrollment.sourceKey, input.enrollment.generation) as
        | { session_id: string; workspace_id: string | null }
        | undefined;
      if (!enrolled || this.isPurged(enrolled.session_id, enrolled.workspace_id ?? undefined)) {
        return { accepted: false, retainedHistoricalEvents: this.countHistoricalEvents() };
      }
      this.insertEvents(input.events, input.nowMs ?? this.now(), { honorPurges: true });
      this.saveBackfillCheckpointUnchecked(input.checkpoint);
      return { accepted: true, retainedHistoricalEvents: this.countHistoricalEvents() };
    });
    return transaction();
  }

  deleteExpired(nowMs = this.now()): number {
    return changesFrom(
      this.db
        .prepare("DELETE FROM resource_usage_events WHERE occurred_at < ?")
        .run(nowMs - RETENTION_MS),
    );
  }

  deleteSession(sessionId: string): number {
    const transaction = this.db.transaction(() => {
      const records = changesFrom(
        this.db.prepare("DELETE FROM resource_usage_events WHERE session_id = ?").run(sessionId),
      );
      const keys = this.db
        .prepare("SELECT source_key FROM resource_usage_backfill_sources WHERE session_id = ?")
        .all(sessionId) as Array<{ source_key: string }>;
      for (const row of keys) {
        this.db
          .prepare("DELETE FROM resource_usage_backfill_checkpoints WHERE source_key = ?")
          .run(row.source_key);
      }
      this.db
        .prepare(
          `DELETE FROM resource_usage_backfill_reconciliations
           WHERE source_key IN (
             SELECT source_key FROM resource_usage_backfill_sources WHERE session_id = ?
           )`,
        )
        .run(sessionId);
      this.db
        .prepare("DELETE FROM resource_usage_backfill_sources WHERE session_id = ?")
        .run(sessionId);
      return records;
    });
    return transaction();
  }

  deleteResource(ownerKind: ResourceUsageOwnerKind, ownerId: string): number {
    return changesFrom(
      this.db
        .prepare("DELETE FROM resource_usage_events WHERE owner_kind = ? AND owner_id = ?")
        .run(ownerKind, ownerId),
    );
  }

  deleteWorkspace(workspaceId: string): number {
    const transaction = this.db.transaction(() => {
      const records = changesFrom(
        this.db
          .prepare("DELETE FROM resource_usage_events WHERE workspace_id = ?")
          .run(workspaceId),
      );
      const keys = this.db
        .prepare("SELECT source_key FROM resource_usage_backfill_sources WHERE workspace_id = ?")
        .all(workspaceId) as Array<{ source_key: string }>;
      for (const row of keys) {
        this.db
          .prepare("DELETE FROM resource_usage_backfill_checkpoints WHERE source_key = ?")
          .run(row.source_key);
      }
      this.db
        .prepare(
          `DELETE FROM resource_usage_backfill_reconciliations
           WHERE source_key IN (
             SELECT source_key FROM resource_usage_backfill_sources WHERE workspace_id = ?
           )`,
        )
        .run(workspaceId);
      this.db
        .prepare("DELETE FROM resource_usage_backfill_sources WHERE workspace_id = ?")
        .run(workspaceId);
      return records;
    });
    return transaction();
  }

  enrollBackfillSource(
    source: ResourceUsageBackfillSourceRecord,
  ): ResourceUsageBackfillEnrollment | undefined {
    const transaction = this.db.transaction(() => {
      if (this.isPurged(source.sessionId, source.workspaceId)) return undefined;
      this.db
        .prepare(
          `INSERT INTO resource_usage_backfill_sources (
             source_key, session_id, workspace_id, runtime, trace_id_hash, enrolled_at, generation
           ) VALUES (?, ?, ?, ?, ?, ?, 1)
           ON CONFLICT(source_key) DO UPDATE SET
             session_id = excluded.session_id,
             workspace_id = excluded.workspace_id,
             runtime = excluded.runtime,
             trace_id_hash = COALESCE(excluded.trace_id_hash, resource_usage_backfill_sources.trace_id_hash),
             generation = resource_usage_backfill_sources.generation + 1`,
        )
        .run(
          source.sourceKey,
          source.sessionId,
          source.workspaceId ?? null,
          source.runtime,
          source.traceIdHash ?? null,
          this.now(),
        );
      const row = this.db
        .prepare("SELECT generation FROM resource_usage_backfill_sources WHERE source_key = ?")
        .get(source.sourceKey) as { generation: number };
      return { sourceKey: source.sourceKey, generation: row.generation };
    });
    return transaction();
  }

  getBackfillCheckpoint(sourceKey: string): ResourceUsageBackfillCheckpoint | undefined {
    const row = this.db
      .prepare(
        `SELECT source_key, offset_bytes, size_bytes, fingerprint, completed_at,
                corrupt_lines, oversized_lines, line_count
         FROM resource_usage_backfill_checkpoints WHERE source_key = ?`,
      )
      .get(sourceKey) as
      | {
          source_key: string;
          offset_bytes: number;
          size_bytes: number;
          fingerprint: string;
          completed_at: number | null;
          corrupt_lines: number;
          oversized_lines: number;
          line_count: number;
        }
      | undefined;
    if (!row) return undefined;
    return {
      sourceKey: row.source_key,
      offset: row.offset_bytes,
      size: row.size_bytes,
      fingerprint: row.fingerprint,
      ...(row.completed_at !== null ? { completedAt: row.completed_at } : {}),
      corruptLines: row.corrupt_lines,
      oversizedLines: row.oversized_lines,
      lines: row.line_count,
    };
  }

  saveBackfillCheckpoint(checkpoint: ResourceUsageBackfillCheckpoint): void {
    this.saveBackfillCheckpointUnchecked(checkpoint);
  }

  countHistoricalEvents(): number {
    const row = this.db
      .prepare("SELECT COUNT(*) AS count FROM resource_usage_events WHERE origin = 'history'")
      .get() as { count: number };
    return numberValue(row.count);
  }

  resetBackfillSource(sourceKey: string): void {
    const transaction = this.db.transaction(() => {
      this.db
        .prepare("DELETE FROM resource_usage_events WHERE source_key = ? AND origin = 'history'")
        .run(sourceKey);
      this.db
        .prepare("DELETE FROM resource_usage_backfill_checkpoints WHERE source_key = ?")
        .run(sourceKey);
      this.db
        .prepare("DELETE FROM resource_usage_backfill_reconciliations WHERE source_key = ?")
        .run(sourceKey);
    });
    transaction();
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
                SUM(CASE WHEN attribution = 'exact' THEN 1 ELSE 0 END) AS exact_actions,
                SUM(CASE WHEN attribution = 'inferred' THEN 1 ELSE 0 END) AS inferred_actions,
                SUM(CASE WHEN origin = 'history' THEN 1 ELSE 0 END) AS historical_actions,
                SUM(CASE WHEN origin = 'live' THEN 1 ELSE 0 END) AS live_actions,
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
      exactActions: numberValue(summary?.exact_actions),
      inferredActions: numberValue(summary?.inferred_actions),
      historicalActions: numberValue(summary?.historical_actions),
      liveActions: numberValue(summary?.live_actions),
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
              exactActions: 0,
              inferredActions: 0,
              historicalActions: 0,
              liveActions: 0,
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
                owner_kind, owner_id, item_name, provider, model, manifest_revision,
                attribution, origin, source_key
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

  getBackfillState(): ResourceUsageBackfillState {
    const raw = this.getMetadata("manual_backfill_state_v1");
    if (!raw) return emptyBackfillState(this.now());
    try {
      const value = JSON.parse(raw) as Partial<ResourceUsageBackfillState>;
      const status = value.status === "running" ? "partial" : value.status;
      if (status !== "available" && status !== "complete" && status !== "partial") {
        return emptyBackfillState(this.now());
      }
      return {
        status,
        totalSources: nonNegative(value.totalSources),
        processedSources: nonNegative(value.processedSources),
        completedSources: nonNegative(value.completedSources),
        failedSources: nonNegative(value.failedSources),
        processedBytes: nonNegative(value.processedBytes),
        processedLines: nonNegative(value.processedLines),
        historicalEvents: this.countHistoricalEvents(),
        corruptLines: nonNegative(value.corruptLines),
        oversizedLines: nonNegative(value.oversizedLines),
        ...(positive(value.startedAt) ? { startedAt: value.startedAt } : {}),
        updatedAt: positive(value.updatedAt) ? value.updatedAt : this.now(),
        ...(positive(value.lastCompletedAt) ? { lastCompletedAt: value.lastCompletedAt } : {}),
        ...(typeof value.lastError === "string" && value.lastError
          ? { lastError: value.lastError }
          : status === "partial" && value.status === "running"
            ? { lastError: "Server restarted before the backfill finished" }
            : {}),
      };
    } catch {
      return {
        ...emptyBackfillState(this.now()),
        status: "partial",
        lastError: "Backfill state was unreadable",
      };
    }
  }

  setBackfillState(state: ResourceUsageBackfillState): void {
    this.setMetadata("manual_backfill_state_v1", JSON.stringify(state));
  }

  private insertEvents(
    events: readonly ResourceUsageEvent[],
    nowMs: number,
    options: { honorPurges: boolean },
  ): void {
    const cutoff = nowMs - RETENTION_MS;
    for (const event of events) {
      if (event.occurredAt < cutoff) continue;
      if (options.honorPurges && this.isPurged(event.sessionId, event.workspaceId)) continue;
      if (event.attribution === "inferred" && event.sourceKey) {
        const pending = this.db
          .prepare(
            `SELECT action_id FROM resource_usage_backfill_reconciliations
             WHERE source_key = ? AND signal = ? AND owner_kind = ? AND owner_id = ?
               AND item_name = ?
             ORDER BY sequence ASC LIMIT 1`,
          )
          .get(
            event.sourceKey,
            event.signal,
            event.ownerKind,
            event.ownerId,
            event.itemName ?? "",
          ) as { action_id: string } | undefined;
        if (pending) {
          this.db
            .prepare("DELETE FROM resource_usage_backfill_reconciliations WHERE action_id = ?")
            .run(pending.action_id);
          continue;
        }
      }
      if (event.consumesFutureInferenceReconciliation && event.sourceKey) {
        this.db
          .prepare(
            `DELETE FROM resource_usage_backfill_reconciliations
             WHERE action_id = ? AND source_key = ?`,
          )
          .run(event.actionId, event.sourceKey);
      }
      if (event.reconcilesFutureInference && event.sourceKey) {
        this.db
          .prepare(
            `INSERT OR IGNORE INTO resource_usage_backfill_reconciliations (
               action_id, source_key, signal, owner_kind, owner_id, item_name, sequence
             ) VALUES (?, ?, ?, ?, ?, ?, ?)`,
          )
          .run(
            event.actionId,
            event.sourceKey,
            event.signal,
            event.ownerKind,
            event.ownerId,
            event.itemName ?? "",
            event.occurredAt,
          );
      }
      if (event.reconcilesActionId && event.reconcilesActionId !== event.actionId) {
        this.db
          .prepare(
            `DELETE FROM resource_usage_events
             WHERE action_id = ? AND attribution = 'inferred'`,
          )
          .run(event.reconcilesActionId);
      }
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
        event.attribution ?? "exact",
        event.origin ?? "live",
        event.sourceKey ?? null,
      );
    }
    this.db.prepare("DELETE FROM resource_usage_events WHERE occurred_at < ?").run(cutoff);
  }

  private saveBackfillCheckpointUnchecked(checkpoint: ResourceUsageBackfillCheckpoint): void {
    this.db
      .prepare(
        `INSERT INTO resource_usage_backfill_checkpoints (
           source_key, offset_bytes, size_bytes, fingerprint, completed_at,
           corrupt_lines, oversized_lines, line_count, updated_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(source_key) DO UPDATE SET
           offset_bytes = excluded.offset_bytes,
           size_bytes = excluded.size_bytes,
           fingerprint = excluded.fingerprint,
           completed_at = excluded.completed_at,
           corrupt_lines = excluded.corrupt_lines,
           oversized_lines = excluded.oversized_lines,
           line_count = excluded.line_count,
           updated_at = excluded.updated_at`,
      )
      .run(
        checkpoint.sourceKey,
        checkpoint.offset,
        checkpoint.size,
        checkpoint.fingerprint,
        checkpoint.completedAt ?? null,
        checkpoint.corruptLines,
        checkpoint.oversizedLines,
        checkpoint.lines,
        this.now(),
      );
  }

  private isPurged(sessionId: string, workspaceId?: string): boolean {
    const blocked = this.db
      .prepare(
        `SELECT 1 AS blocked FROM resource_usage_purges
         WHERE (kind = 'session' AND target_id = ?)
            OR (kind = 'workspace' AND target_id = ?)
         LIMIT 1`,
      )
      .get(sessionId, workspaceId ?? "") as { blocked: number } | undefined;
    return blocked !== undefined;
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
    this.db
      .prepare(
        `INSERT OR IGNORE INTO resource_usage_purges (kind, target_id, requested_at)
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
    scrubPathBearingUsageSchema(this.db);
    const existingColumns = tableColumns(this.db, "resource_usage_events");
    const exactLiveSchema =
      existingColumns.length > 0 && metadataValue(this.db, "exact_live_schema") === "1";
    if (existingColumns.length > 0 && !exactLiveSchema) {
      // Pre-release history drafts could contain raw source paths. Drop only their
      // path-bearing enrollment state; keep privacy-minimized event rows.
      this.db.exec(`
        DROP TABLE IF EXISTS resource_usage_backfill_checkpoints;
        DROP TABLE IF EXISTS resource_usage_backfill_sources;
        DROP TABLE IF EXISTS resource_usage_purges;
      `);
    }

    this.db.exec(`
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
        manifest_revision TEXT,
        attribution TEXT NOT NULL DEFAULT 'exact' CHECK(attribution IN ('exact', 'inferred')),
        origin TEXT NOT NULL DEFAULT 'live' CHECK(origin IN ('live', 'history')),
        source_key TEXT
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
      CREATE TABLE IF NOT EXISTS resource_usage_backfill_sources (
        source_key TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        workspace_id TEXT,
        runtime TEXT NOT NULL CHECK(runtime IN ('oppi', 'pi-tui')),
        trace_id_hash TEXT,
        enrolled_at INTEGER NOT NULL,
        generation INTEGER NOT NULL DEFAULT 1
      );
      CREATE TABLE IF NOT EXISTS resource_usage_backfill_checkpoints (
        source_key TEXT PRIMARY KEY REFERENCES resource_usage_backfill_sources(source_key) ON DELETE CASCADE,
        offset_bytes INTEGER NOT NULL,
        size_bytes INTEGER NOT NULL,
        fingerprint TEXT NOT NULL,
        completed_at INTEGER,
        corrupt_lines INTEGER NOT NULL DEFAULT 0,
        oversized_lines INTEGER NOT NULL DEFAULT 0,
        line_count INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS resource_usage_purges (
        kind TEXT NOT NULL CHECK(kind IN ('session', 'workspace')),
        target_id TEXT NOT NULL,
        requested_at INTEGER NOT NULL,
        PRIMARY KEY(kind, target_id)
      );
      CREATE TABLE IF NOT EXISTS resource_usage_backfill_reconciliations (
        action_id TEXT PRIMARY KEY,
        source_key TEXT NOT NULL,
        signal TEXT NOT NULL,
        owner_kind TEXT NOT NULL,
        owner_id TEXT NOT NULL,
        item_name TEXT NOT NULL,
        sequence INTEGER NOT NULL
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
      CREATE INDEX IF NOT EXISTS resource_usage_backfill_sources_session_idx
        ON resource_usage_backfill_sources(session_id);
      CREATE INDEX IF NOT EXISTS resource_usage_backfill_sources_workspace_idx
        ON resource_usage_backfill_sources(workspace_id);
      CREATE INDEX IF NOT EXISTS resource_usage_backfill_reconciliations_match_idx
        ON resource_usage_backfill_reconciliations(
          source_key, signal, owner_kind, owner_id, item_name, sequence
        );
      INSERT OR IGNORE INTO resource_usage_metadata (key, value)
        VALUES ('exact_live_schema', '1');
    `);

    const sourceColumns = tableColumns(this.db, "resource_usage_backfill_sources");
    if (!sourceColumns.includes("generation")) {
      this.db.exec(
        "ALTER TABLE resource_usage_backfill_sources ADD COLUMN generation INTEGER NOT NULL DEFAULT 1",
      );
    }

    const migratedColumns = tableColumns(this.db, "resource_usage_events");
    if (!migratedColumns.includes("attribution")) {
      this.db.exec(
        "ALTER TABLE resource_usage_events ADD COLUMN attribution TEXT NOT NULL DEFAULT 'exact'",
      );
    }
    if (!migratedColumns.includes("origin")) {
      this.db.exec(
        "ALTER TABLE resource_usage_events ADD COLUMN origin TEXT NOT NULL DEFAULT 'live'",
      );
    }
    if (!migratedColumns.includes("source_key")) {
      this.db.exec("ALTER TABLE resource_usage_events ADD COLUMN source_key TEXT");
    }
    this.db.exec(`
      CREATE INDEX IF NOT EXISTS resource_usage_events_source_idx
        ON resource_usage_events(source_key);
    `);
  }
}

function scrubPathBearingUsageSchema(db: SqliteDatabase): void {
  const expectedColumns = new Map<string, Set<string>>([
    [
      "resource_usage_events",
      new Set([
        "action_id",
        "occurred_at",
        "signal",
        "session_id",
        "workspace_id",
        "runtime",
        "owner_kind",
        "owner_id",
        "item_name",
        "provider",
        "model",
        "manifest_revision",
        "attribution",
        "origin",
        "source_key",
      ]),
    ],
    ["resource_usage_metadata", new Set(["key", "value"])],
    ["resource_usage_pending_purges", new Set(["kind", "target_id", "requested_at"])],
    [
      "resource_usage_backfill_sources",
      new Set([
        "source_key",
        "session_id",
        "workspace_id",
        "runtime",
        "trace_id_hash",
        "enrolled_at",
        "generation",
      ]),
    ],
    [
      "resource_usage_backfill_checkpoints",
      new Set([
        "source_key",
        "offset_bytes",
        "size_bytes",
        "fingerprint",
        "completed_at",
        "corrupt_lines",
        "oversized_lines",
        "line_count",
        "updated_at",
      ]),
    ],
    ["resource_usage_purges", new Set(["kind", "target_id", "requested_at"])],
    [
      "resource_usage_backfill_reconciliations",
      new Set([
        "action_id",
        "source_key",
        "signal",
        "owner_kind",
        "owner_id",
        "item_name",
        "sequence",
      ]),
    ],
  ]);
  const tables = db
    .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'resource_usage_%'")
    .all() as Array<{ name: string }>;
  for (const { name } of tables) {
    const expected = expectedColumns.get(name);
    const columns = tableColumns(db, name);
    const suspicious = columns.some((column) =>
      /(^|_)(path|file|cwd|directory|dir)($|_)/i.test(column),
    );
    if (!expected || suspicious) {
      if (name === "resource_usage_events" && expected) {
        const preserved = columns.filter((column) => expected.has(column));
        if (preserved.length === 0) {
          db.exec(`DROP TABLE IF EXISTS ${name}`);
          continue;
        }
        db.exec(`ALTER TABLE ${name} RENAME TO resource_usage_events_path_scrub`);
        db.exec(`
          CREATE TABLE resource_usage_events (
            action_id TEXT PRIMARY KEY,
            occurred_at INTEGER NOT NULL,
            signal TEXT NOT NULL,
            session_id TEXT NOT NULL,
            workspace_id TEXT,
            runtime TEXT NOT NULL,
            owner_kind TEXT NOT NULL,
            owner_id TEXT NOT NULL,
            item_name TEXT,
            provider TEXT,
            model TEXT,
            manifest_revision TEXT,
            attribution TEXT NOT NULL DEFAULT 'exact',
            origin TEXT NOT NULL DEFAULT 'live',
            source_key TEXT
          );
          INSERT INTO resource_usage_events (${preserved.join(", ")})
            SELECT ${preserved.join(", ")} FROM resource_usage_events_path_scrub;
          DROP TABLE resource_usage_events_path_scrub;
        `);
      } else {
        db.exec(`DROP TABLE IF EXISTS ${name}`);
      }
    }
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
    attribution: row.attribution,
    origin: row.origin,
    ...(row.source_key ? { sourceKey: row.source_key } : {}),
  };
}

function emptyBackfillState(nowMs: number): ResourceUsageBackfillState {
  return {
    status: "available",
    totalSources: 0,
    processedSources: 0,
    completedSources: 0,
    failedSources: 0,
    processedBytes: 0,
    processedLines: 0,
    historicalEvents: 0,
    corruptLines: 0,
    oversizedLines: 0,
    updatedAt: nowMs,
  };
}

function nonNegative(value: unknown): number {
  const number = numberValue(value);
  return number >= 0 ? number : 0;
}

function positive(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value > 0;
}

function numberValue(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : Number(value ?? 0) || 0;
}

function changesFrom(result: unknown): number {
  if (!result || typeof result !== "object") return 0;
  const changes = (result as { changes?: unknown }).changes;
  return typeof changes === "number" ? changes : 0;
}

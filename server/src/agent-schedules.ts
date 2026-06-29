import { chmodSync, existsSync, mkdirSync } from "node:fs";
import { join, resolve } from "node:path";

import { generateId } from "./id.js";
import { decideScheduledMutation, liveAcceptedApprovalRefAuditIds } from "./schedule-approval.js";
import { openDatabase, type SqliteDatabase } from "./sqlite-compat.js";
import type { ScheduleApprovalRef } from "./types/schedules.js";

export type AgentScheduleStatus = "active" | "paused" | "archived";
export type AgentScheduleRunStatus = "pending" | "claimed" | "running" | "completed" | "failed";
export type AgentScheduleRunKind = "due" | "manual";

export type AgentScheduleTrigger =
  | { type: "at"; at: number; timeZone: string }
  | { type: "every"; intervalMs: number; timeZone: string }
  | { type: "cron"; expression: string; timeZone: string };

export type ApprovalRefs = readonly ScheduleApprovalRef[];

export type AgentScheduleAction =
  | {
      type: "new_session";
      workspaceId: string;
      prompt: string;
      model?: string;
      worktreeId?: string;
      name?: string;
      approvalRefs?: ApprovalRefs;
    }
  | {
      type: "existing_session";
      workspaceId: string;
      sessionId: string;
      prompt: string;
      streamingBehavior?: "steer" | "followUp";
      approvalRefs?: ApprovalRefs;
    };

export interface AgentSchedule {
  id: string;
  name: string;
  status: AgentScheduleStatus;
  trigger: AgentScheduleTrigger;
  action: AgentScheduleAction;
  createdAt: number;
  updatedAt: number;
  archivedAt?: number;
}

export interface AgentScheduleRun {
  id: string;
  scheduleId: string;
  kind: AgentScheduleRunKind;
  slotKey: string;
  idempotencyKey: string;
  status: AgentScheduleRunStatus;
  actionSnapshot: AgentScheduleAction;
  approvalRefs: ApprovalRefs;
  createdAt: number;
  updatedAt: number;
  claimedAt?: number;
  leaseOwner?: string;
  leaseExpiresAt?: number;
  startedAt?: number;
  completedAt?: number;
  error?: string;
  result?: unknown;
}

export interface AgentScheduleActionSummary {
  type: AgentScheduleAction["type"];
  workspaceId: string;
  sessionId?: string;
  promptChars: number;
}

export interface AgentScheduleSummary {
  id: string;
  name: string;
  status: AgentScheduleStatus;
  trigger: AgentScheduleTrigger;
  action: AgentScheduleActionSummary;
  approvalRefCount: number;
  createdAt: number;
  updatedAt: number;
  archivedAt?: number;
}

export interface AgentScheduleRunSummary {
  id: string;
  scheduleId: string;
  kind: AgentScheduleRunKind;
  slotKey: string;
  idempotencyKey: string;
  status: AgentScheduleRunStatus;
  action: AgentScheduleActionSummary;
  approvalRefCount: number;
  createdAt: number;
  updatedAt: number;
  claimedAt?: number;
  leaseOwner?: string;
  leaseExpiresAt?: number;
  startedAt?: number;
  completedAt?: number;
  sessionId?: string;
  promptDispatch?: "delivered" | "not_sent";
  error?: string;
}

export interface CreateAgentScheduleRequest {
  name: string;
  trigger: AgentScheduleTrigger;
  action: AgentScheduleAction;
}

export interface AgentScheduleClaimOptions {
  now: number;
  ownerId: string;
  leaseMs: number;
  limit: number;
  runIds?: readonly string[];
}

export interface AgentScheduleListRunOptions {
  limit?: number;
}

export interface NewSessionDispatchInput {
  run: AgentScheduleRun;
  schedule: AgentSchedule;
  action: Extract<AgentScheduleAction, { type: "new_session" }>;
}

export interface ExistingSessionDispatchInput {
  run: AgentScheduleRun;
  schedule: AgentSchedule;
  action: Extract<AgentScheduleAction, { type: "existing_session" }>;
}

export interface AgentScheduleDispatchHooks {
  /** This hook is the integration point for AgentLaunchService without importing launch flow code here. */
  launchNewSession(input: NewSessionDispatchInput): Promise<unknown>;
  /** Existing-session input must use run.idempotencyKey as the request/client idempotency key. */
  sendExistingSessionInput(input: ExistingSessionDispatchInput): Promise<unknown>;
}

export interface AgentScheduleDispatchOptions {
  leaseOwner: string;
  now?: number;
}

interface ScheduleRow {
  id: string;
  name: string;
  status: AgentScheduleStatus;
  trigger_json: string;
  action_json: string;
  created_at: number;
  updated_at: number;
  archived_at: number | null;
}

interface RunRow {
  id: string;
  schedule_id: string;
  kind: AgentScheduleRunKind;
  slot_key: string;
  idempotency_key: string;
  status: AgentScheduleRunStatus;
  action_snapshot_json: string;
  approval_refs_json: string;
  created_at: number;
  updated_at: number;
  claimed_at: number | null;
  lease_owner: string | null;
  lease_expires_at: number | null;
  started_at: number | null;
  completed_at: number | null;
  error: string | null;
  result_json: string | null;
}

export class AgentScheduleStore {
  private readonly db: SqliteDatabase;

  constructor(dataDir: string, dbPath?: string) {
    if (!existsSync(dataDir)) {
      mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    }
    const resolvedDbPath = resolve(dbPath ?? join(dataDir, "session-state.db"));
    this.db = openDatabase(resolvedDbPath);
    chmodSync(resolvedDbPath, 0o600);
    this.db.exec("PRAGMA journal_mode = WAL");
    this.db.exec("PRAGMA synchronous = NORMAL");
    this.ensureSchema();
  }

  close(): void {
    this.db.close();
  }

  createSchedule(request: CreateAgentScheduleRequest, now = Date.now()): AgentSchedule {
    const schedule: AgentSchedule = {
      id: generateId(8),
      name: validateName(request.name),
      status: "active",
      trigger: validateTrigger(request.trigger),
      action: validateAction(request.action),
      createdAt: now,
      updatedAt: now,
    };
    this.db
      .prepare(
        `INSERT INTO agent_schedules (id, name, status, trigger_json, action_json, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        schedule.id,
        schedule.name,
        schedule.status,
        JSON.stringify(schedule.trigger),
        JSON.stringify(schedule.action),
        schedule.createdAt,
        schedule.updatedAt,
      );
    return schedule;
  }

  updateSchedule(
    scheduleId: string,
    updates: Partial<Pick<CreateAgentScheduleRequest, "name" | "trigger" | "action">>,
    now = Date.now(),
  ): AgentSchedule | undefined {
    const current = this.getSchedule(scheduleId);
    if (!current || current.status === "archived") return undefined;

    const next: AgentSchedule = {
      ...current,
      ...(updates.name !== undefined ? { name: validateName(updates.name) } : {}),
      ...(updates.trigger !== undefined ? { trigger: validateTrigger(updates.trigger) } : {}),
      ...(updates.action !== undefined ? { action: validateAction(updates.action) } : {}),
      updatedAt: now,
    };
    this.db
      .prepare(
        `UPDATE agent_schedules
         SET name = ?, trigger_json = ?, action_json = ?, updated_at = ?
         WHERE id = ? AND status <> 'archived'`,
      )
      .run(next.name, JSON.stringify(next.trigger), JSON.stringify(next.action), now, scheduleId);
    return this.getSchedule(scheduleId);
  }

  pauseSchedule(scheduleId: string, now = Date.now()): AgentSchedule | undefined {
    return this.setScheduleStatus(scheduleId, "paused", now);
  }

  resumeSchedule(scheduleId: string, now = Date.now()): AgentSchedule | undefined {
    return this.setScheduleStatus(scheduleId, "active", now);
  }

  archiveSchedule(scheduleId: string, now = Date.now()): AgentSchedule | undefined {
    const current = this.getSchedule(scheduleId);
    if (!current) return undefined;
    this.db
      .prepare(
        `UPDATE agent_schedules
         SET status = 'archived', updated_at = ?, archived_at = ?
         WHERE id = ?`,
      )
      .run(now, now, scheduleId);
    return this.getSchedule(scheduleId);
  }

  getSchedule(scheduleId: string): AgentSchedule | undefined {
    const row = this.db.prepare("SELECT * FROM agent_schedules WHERE id = ?").get(scheduleId) as
      | ScheduleRow
      | undefined;
    return row ? scheduleFromRow(row) : undefined;
  }

  listSchedules(): AgentSchedule[] {
    return (
      this.db
        .prepare("SELECT * FROM agent_schedules ORDER BY created_at, id")
        .all() as ScheduleRow[]
    ).map(scheduleFromRow);
  }

  listScheduleSummaries(): AgentScheduleSummary[] {
    return this.listSchedules().map(scheduleSummary);
  }

  getScheduleSummary(scheduleId: string): AgentScheduleSummary | undefined {
    const schedule = this.getSchedule(scheduleId);
    return schedule ? scheduleSummary(schedule) : undefined;
  }

  createManualRun(scheduleId: string, requestId: string, now = Date.now()): AgentScheduleRun {
    const cleanRequestId = validateKeyPart(requestId, "requestId");
    return this.createRun({
      scheduleId,
      kind: "manual",
      slotKey: `manual:${cleanRequestId}`,
      idempotencyKey: `schedule:${scheduleId}:manual:${cleanRequestId}`,
      now,
    });
  }

  createDueRun(scheduleId: string, slotKey: string, now = Date.now()): AgentScheduleRun {
    const cleanSlotKey = validateKeyPart(slotKey, "slotKey");
    return this.createRun({
      scheduleId,
      kind: "due",
      slotKey: cleanSlotKey,
      idempotencyKey: `schedule:${scheduleId}:slot:${cleanSlotKey}`,
      now,
    });
  }

  getRun(runId: string): AgentScheduleRun | undefined {
    const row = this.db.prepare("SELECT * FROM agent_schedule_runs WHERE id = ?").get(runId) as
      | RunRow
      | undefined;
    return row ? runFromRow(row) : undefined;
  }

  listRuns(scheduleId: string, options: AgentScheduleListRunOptions = {}): AgentScheduleRun[] {
    const limit = validateListLimit(options.limit);
    const sql = "SELECT * FROM agent_schedule_runs WHERE schedule_id = ? ORDER BY created_at, id";
    const rows = (
      limit === undefined
        ? this.db.prepare(sql).all(scheduleId)
        : this.db.prepare(`${sql} LIMIT ?`).all(scheduleId, limit)
    ) as RunRow[];
    return rows.map(runFromRow);
  }

  listRunSummaries(
    scheduleId: string,
    options: AgentScheduleListRunOptions = {},
  ): AgentScheduleRunSummary[] {
    return this.listRuns(scheduleId, options).map(runSummary);
  }

  claimReadyRuns(options: AgentScheduleClaimOptions): AgentScheduleRun[] {
    if (options.leaseMs <= 0 || options.limit <= 0) return [];
    const runIds = options.runIds?.filter((id) => id.trim().length > 0);
    const idClause = runIds?.length ? ` AND id IN (${runIds.map(() => "?").join(",")})` : "";
    const candidates = this.db
      .prepare(
        `SELECT * FROM agent_schedule_runs
         WHERE status IN ('pending', 'claimed', 'running')
           AND (lease_expires_at IS NULL OR lease_expires_at <= ?)
           ${idClause}
         ORDER BY created_at, id
         LIMIT ?`,
      )
      .all(options.now, ...(runIds ?? []), options.limit) as RunRow[];

    const claimed: AgentScheduleRun[] = [];
    for (const row of candidates) {
      this.db
        .prepare(
          `UPDATE agent_schedule_runs
           SET status = 'claimed', claimed_at = ?, lease_owner = ?, lease_expires_at = ?, updated_at = ?
           WHERE id = ?
             AND status IN ('pending', 'claimed', 'running')
             AND (lease_expires_at IS NULL OR lease_expires_at <= ?)`,
        )
        .run(
          options.now,
          options.ownerId,
          options.now + options.leaseMs,
          options.now,
          row.id,
          options.now,
        );
      const run = this.getRun(row.id);
      if (
        run?.leaseOwner === options.ownerId &&
        run.leaseExpiresAt === options.now + options.leaseMs
      ) {
        claimed.push(run);
      }
    }
    return claimed;
  }

  async dispatchClaimedRun(
    runId: string,
    hooks: AgentScheduleDispatchHooks,
    options: AgentScheduleDispatchOptions,
  ): Promise<AgentScheduleRun> {
    const now = options.now ?? Date.now();
    const run = this.getRun(runId);
    if (!run) throw new Error(`Schedule run not found: ${runId}`);
    if (run.status !== "claimed") throw new Error(`Schedule run is not claimed: ${runId}`);
    if (run.leaseOwner !== options.leaseOwner) {
      throw new Error(`Schedule run lease is not held by ${options.leaseOwner}: ${runId}`);
    }
    if (run.leaseExpiresAt !== undefined && run.leaseExpiresAt <= now) {
      throw new Error(`Schedule run lease expired: ${runId}`);
    }
    const schedule = this.getSchedule(run.scheduleId);
    if (!schedule) throw new Error(`Schedule not found: ${run.scheduleId}`);

    const approvalDecision = decideScheduledMutation({
      origin: run.kind === "manual" ? "interactive" : "scheduled",
      approvalRefs: run.approvalRefs,
      nowMs: now,
    });
    if (!approvalDecision.allowed) {
      const error =
        approvalDecision.reason === "expired_approval_ref"
          ? `approval_required_noninteractive:${approvalDecision.reason}:${approvalDecision.approvalRefId}`
          : `approval_required_noninteractive:${approvalDecision.reason}`;
      this.failClaimedRunBeforeStart(run, options.leaseOwner, now, error, { approvalDecision });
      throw new Error(error);
    }
    if (run.kind !== "manual") {
      const approvalRefIds = liveAcceptedApprovalRefAuditIds(run.approvalRefs, now);
      const hasAcceptedProvenance = this.hasAcceptedApprovalProvenance(
        run,
        schedule,
        approvalRefIds,
      );
      if (!hasAcceptedProvenance) {
        const error = "approval_required_noninteractive:missing_accepted_approval_provenance";
        this.failClaimedRunBeforeStart(run, options.leaseOwner, now, error, {
          approvalDecision,
          approvalProvenance: {
            allowed: false,
            reason: "missing_accepted_audit_event",
            approvalRefIds,
          },
        });
        throw new Error(error);
      }
    }

    const started = this.db
      .prepare(
        `UPDATE agent_schedule_runs
         SET status = 'running', started_at = ?, updated_at = ?
         WHERE id = ? AND status = 'claimed' AND lease_owner = ?
           AND (lease_expires_at IS NULL OR lease_expires_at > ?)`,
      )
      .run(now, now, run.id, options.leaseOwner, now) as { changes?: number };
    if (started.changes !== undefined && started.changes !== 1) {
      throw new Error(`Schedule run lease is not held: ${runId}`);
    }

    try {
      const action = run.actionSnapshot;
      const result =
        action.type === "new_session"
          ? await hooks.launchNewSession({ run, schedule, action })
          : await hooks.sendExistingSessionInput({ run, schedule, action });
      const completed = this.db
        .prepare(
          `UPDATE agent_schedule_runs
           SET status = 'completed', completed_at = ?, updated_at = ?, result_json = ?
           WHERE id = ? AND status = 'running' AND lease_owner = ?
             AND (lease_expires_at IS NULL OR lease_expires_at > ?)`,
        )
        .run(now, now, JSON.stringify(result ?? null), run.id, options.leaseOwner, now) as {
        changes?: number;
      };
      if (completed.changes !== undefined && completed.changes !== 1) {
        throw new Error(`Schedule run lease was lost: ${run.id}`);
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const failed = this.db
        .prepare(
          `UPDATE agent_schedule_runs
           SET status = 'failed', completed_at = ?, updated_at = ?, error = ?
           WHERE id = ? AND status = 'running' AND lease_owner = ?
             AND (lease_expires_at IS NULL OR lease_expires_at > ?)`,
        )
        .run(now, now, message, run.id, options.leaseOwner, now) as { changes?: number };
      if (
        failed.changes !== undefined &&
        failed.changes !== 1 &&
        !message.startsWith("Schedule run lease was lost:")
      ) {
        throw new Error(`Schedule run lease was lost: ${run.id}`);
      }
      throw error;
    }

    const completed = this.getRun(run.id);
    if (!completed) throw new Error(`Schedule run disappeared: ${run.id}`);
    return completed;
  }

  private createRun(input: {
    scheduleId: string;
    kind: AgentScheduleRunKind;
    slotKey: string;
    idempotencyKey: string;
    now: number;
  }): AgentScheduleRun {
    const schedule = this.getSchedule(input.scheduleId);
    if (!schedule) throw new Error(`Schedule not found: ${input.scheduleId}`);
    if (schedule.status === "archived") throw new Error(`Schedule archived: ${input.scheduleId}`);
    const approvalRefs = schedule.action.approvalRefs ?? [];
    this.db
      .prepare(
        `INSERT OR IGNORE INTO agent_schedule_runs (
           id, schedule_id, kind, slot_key, idempotency_key, status,
           action_snapshot_json, approval_refs_json, created_at, updated_at
         ) VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?)`,
      )
      .run(
        generateId(8),
        schedule.id,
        input.kind,
        input.slotKey,
        input.idempotencyKey,
        JSON.stringify(schedule.action),
        JSON.stringify(approvalRefs),
        input.now,
        input.now,
      );

    const row = this.db
      .prepare("SELECT * FROM agent_schedule_runs WHERE idempotency_key = ?")
      .get(input.idempotencyKey) as RunRow | undefined;
    if (!row) throw new Error(`Schedule run was not created: ${input.idempotencyKey}`);
    return runFromRow(row);
  }

  private setScheduleStatus(
    scheduleId: string,
    status: Exclude<AgentScheduleStatus, "archived">,
    now: number,
  ): AgentSchedule | undefined {
    this.db
      .prepare(
        `UPDATE agent_schedules
         SET status = ?, updated_at = ?
         WHERE id = ? AND status <> 'archived'`,
      )
      .run(status, now, scheduleId);
    return this.getSchedule(scheduleId);
  }

  private failClaimedRunBeforeStart(
    run: AgentScheduleRun,
    leaseOwner: string,
    now: number,
    error: string,
    result: unknown,
  ): void {
    this.db
      .prepare(
        `UPDATE agent_schedule_runs
         SET status = 'failed', completed_at = ?, updated_at = ?, error = ?, result_json = ?
         WHERE id = ? AND status = 'claimed' AND lease_owner = ?`,
      )
      .run(now, now, error, JSON.stringify(result), run.id, leaseOwner);
  }

  private hasAcceptedApprovalProvenance(
    run: AgentScheduleRun,
    schedule: AgentSchedule,
    approvalRefIds: readonly string[],
  ): boolean {
    if (approvalRefIds.length === 0) return false;
    const placeholders = approvalRefIds.map(() => "?").join(",");
    const row = this.db
      .prepare(
        `SELECT id
         FROM server_agent_extension_audit_events
         WHERE event_type = 'approval_ref.accepted'
           AND approval_ref_id IN (${placeholders})
           AND workspace_id = ?
           AND (schedule_id = ? OR run_id = ?)
         LIMIT 1`,
      )
      .get(...approvalRefIds, run.actionSnapshot.workspaceId, schedule.id, run.id) as
      | { id: string }
      | undefined;
    return row !== undefined;
  }

  private ensureSchema(): void {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS agent_schedules (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        status TEXT NOT NULL,
        trigger_json TEXT NOT NULL,
        action_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        archived_at INTEGER
      );

      CREATE TABLE IF NOT EXISTS agent_schedule_runs (
        id TEXT PRIMARY KEY,
        schedule_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        slot_key TEXT NOT NULL,
        idempotency_key TEXT NOT NULL,
        status TEXT NOT NULL,
        action_snapshot_json TEXT NOT NULL,
        approval_refs_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        claimed_at INTEGER,
        lease_owner TEXT,
        lease_expires_at INTEGER,
        started_at INTEGER,
        completed_at INTEGER,
        error TEXT,
        result_json TEXT,
        FOREIGN KEY (schedule_id) REFERENCES agent_schedules(id) ON DELETE CASCADE,
        UNIQUE(schedule_id, slot_key),
        UNIQUE(idempotency_key)
      );

      CREATE INDEX IF NOT EXISTS agent_schedules_status_idx ON agent_schedules(status, created_at);
      CREATE INDEX IF NOT EXISTS agent_schedule_runs_claim_idx
        ON agent_schedule_runs(status, lease_expires_at, created_at);
      CREATE INDEX IF NOT EXISTS agent_schedule_runs_schedule_idx
        ON agent_schedule_runs(schedule_id, created_at);

      CREATE TABLE IF NOT EXISTS server_agent_extension_audit_events (
        id TEXT PRIMARY KEY,
        created_at INTEGER NOT NULL,
        workspace_id TEXT,
        schedule_id TEXT,
        run_id TEXT,
        session_id TEXT,
        event_type TEXT NOT NULL,
        approval_ref_id TEXT,
        extension_scope_id TEXT,
        extension_display_name TEXT,
        display_json TEXT,
        provenance_json TEXT,
        envelope_json TEXT NOT NULL
      );

      CREATE INDEX IF NOT EXISTS server_agent_extension_audit_events_schedule_idx
        ON server_agent_extension_audit_events (schedule_id, created_at ASC, id ASC);

      CREATE INDEX IF NOT EXISTS server_agent_extension_audit_events_run_idx
        ON server_agent_extension_audit_events (run_id, created_at ASC, id ASC);

      CREATE INDEX IF NOT EXISTS server_agent_extension_audit_events_approval_ref_idx
        ON server_agent_extension_audit_events (
          approval_ref_id,
          event_type,
          workspace_id,
          schedule_id,
          run_id
        );
    `);
  }
}

function scheduleFromRow(row: ScheduleRow): AgentSchedule {
  return {
    id: row.id,
    name: row.name,
    status: row.status,
    trigger: parseJson<AgentScheduleTrigger>(row.trigger_json),
    action: parseJson<AgentScheduleAction>(row.action_json),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    ...(row.archived_at === null ? {} : { archivedAt: row.archived_at }),
  };
}

function runFromRow(row: RunRow): AgentScheduleRun {
  return {
    id: row.id,
    scheduleId: row.schedule_id,
    kind: row.kind,
    slotKey: row.slot_key,
    idempotencyKey: row.idempotency_key,
    status: row.status,
    actionSnapshot: parseJson<AgentScheduleAction>(row.action_snapshot_json),
    approvalRefs: parseJson<ApprovalRefs>(row.approval_refs_json),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    ...(row.claimed_at === null ? {} : { claimedAt: row.claimed_at }),
    ...(row.lease_owner === null ? {} : { leaseOwner: row.lease_owner }),
    ...(row.lease_expires_at === null ? {} : { leaseExpiresAt: row.lease_expires_at }),
    ...(row.started_at === null ? {} : { startedAt: row.started_at }),
    ...(row.completed_at === null ? {} : { completedAt: row.completed_at }),
    ...(row.error === null ? {} : { error: row.error }),
    ...(row.result_json === null ? {} : { result: parseJson<unknown>(row.result_json) }),
  };
}

function scheduleSummary(schedule: AgentSchedule): AgentScheduleSummary {
  return {
    id: schedule.id,
    name: schedule.name,
    status: schedule.status,
    trigger: schedule.trigger,
    action: actionSummary(schedule.action),
    approvalRefCount: schedule.action.approvalRefs?.length ?? 0,
    createdAt: schedule.createdAt,
    updatedAt: schedule.updatedAt,
    ...(schedule.archivedAt === undefined ? {} : { archivedAt: schedule.archivedAt }),
  };
}

function runSummary(run: AgentScheduleRun): AgentScheduleRunSummary {
  return {
    id: run.id,
    scheduleId: run.scheduleId,
    kind: run.kind,
    slotKey: run.slotKey,
    idempotencyKey: run.idempotencyKey,
    status: run.status,
    action: actionSummary(run.actionSnapshot),
    approvalRefCount: run.approvalRefs.length,
    createdAt: run.createdAt,
    updatedAt: run.updatedAt,
    ...(run.claimedAt === undefined ? {} : { claimedAt: run.claimedAt }),
    ...(run.leaseOwner === undefined ? {} : { leaseOwner: run.leaseOwner }),
    ...(run.leaseExpiresAt === undefined ? {} : { leaseExpiresAt: run.leaseExpiresAt }),
    ...(run.startedAt === undefined ? {} : { startedAt: run.startedAt }),
    ...(run.completedAt === undefined ? {} : { completedAt: run.completedAt }),
    ...runResultSummary(run.result),
    ...(run.error === undefined ? {} : { error: run.error }),
  };
}

function runResultSummary(result: unknown): {
  sessionId?: string;
  promptDispatch?: "delivered" | "not_sent";
} {
  if (!result || typeof result !== "object") return {};
  const record = result as { sessionId?: unknown; promptDispatch?: unknown };
  return {
    ...(typeof record.sessionId === "string" ? { sessionId: record.sessionId } : {}),
    ...(record.promptDispatch === "delivered" || record.promptDispatch === "not_sent"
      ? { promptDispatch: record.promptDispatch }
      : {}),
  };
}

function actionSummary(action: AgentScheduleAction): AgentScheduleActionSummary {
  return {
    type: action.type,
    workspaceId: action.workspaceId,
    ...(action.type === "existing_session" ? { sessionId: action.sessionId } : {}),
    promptChars: action.prompt.length,
  };
}

function validateName(name: string): string {
  const value = name.trim();
  if (value.length === 0) throw new Error("Schedule name is required");
  return value;
}

function validateTrigger(trigger: AgentScheduleTrigger): AgentScheduleTrigger {
  if (!trigger.timeZone.trim()) throw new Error("Schedule timeZone is required");
  if (trigger.type === "at") {
    if (!Number.isFinite(trigger.at)) throw new Error("Schedule at trigger requires a timestamp");
    return { type: "at", at: trigger.at, timeZone: trigger.timeZone };
  }
  if (trigger.type === "every") {
    if (!Number.isFinite(trigger.intervalMs) || trigger.intervalMs <= 0) {
      throw new Error("Schedule every trigger requires a positive intervalMs");
    }
    return { type: "every", intervalMs: trigger.intervalMs, timeZone: trigger.timeZone };
  }
  if (!trigger.expression.trim()) throw new Error("Schedule cron trigger requires an expression");
  return { type: "cron", expression: trigger.expression, timeZone: trigger.timeZone };
}

function validateAction(action: AgentScheduleAction): AgentScheduleAction {
  if (!action.workspaceId.trim()) throw new Error("Schedule action workspaceId is required");
  if (!action.prompt.trim()) throw new Error("Schedule action prompt is required");
  if (action.approvalRefs !== undefined && !Array.isArray(action.approvalRefs)) {
    throw new Error("Schedule approvalRefs must be an array");
  }
  if (action.type === "existing_session" && !action.sessionId.trim()) {
    throw new Error("Existing-session schedule action sessionId is required");
  }
  return action;
}

function validateKeyPart(value: string, label: string): string {
  const clean = value.trim();
  if (!clean) throw new Error(`${label} is required`);
  return clean;
}

function validateListLimit(limit: number | undefined): number | undefined {
  if (limit === undefined) return undefined;
  if (!Number.isSafeInteger(limit) || limit < 1) {
    throw new Error("Run history limit must be a positive integer");
  }
  return limit;
}

function parseJson<T>(raw: string): T {
  return JSON.parse(raw) as T;
}

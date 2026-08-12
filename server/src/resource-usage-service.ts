import { createHash } from "node:crypto";

import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import {
  RESOURCE_USAGE_RETENTION_DAYS,
  type ResourceUsageAggregate,
  type ResourceUsageBounds,
  type ResourceUsageEvent,
  type ResourceUsageOwnerKind,
  type ResourceUsageRuntime,
  type ResourceUsageSignal,
  type ResourceUsageStore,
  type ResourceUsageSubject,
} from "./storage/resource-usage-store.js";
import type { Session } from "./types.js";

const log = createLogger({ base: { component: "resource_usage" } });
const VALID_RANGES = new Set([7, 30, 90]);
const MAX_PENDING_EVENTS = 2_000;
const MAX_BATCH_EVENTS = 200;
const RECORDING_STARTED_AT_KEY = "recording_started_at_v1";

export interface ResourceUsageOwnerEvidence {
  ownerKind: ResourceUsageOwnerKind;
  ownerId: string;
}

export interface ResourceUsageModelEvidence {
  provider?: string;
  model?: string;
  manifestRevision?: string;
}

export interface ResourceUsageToolEvidence
  extends ResourceUsageOwnerEvidence, ResourceUsageModelEvidence {}

export interface ResourceUsagePromptEvidence
  extends ResourceUsageOwnerEvidence, ResourceUsageModelEvidence {
  signal: "explicit_activation" | "command_invocation";
  itemName: string;
}

export interface ResourceUsageSkillLoadEvidence extends ResourceUsageModelEvidence {
  id: string;
  name: string;
}

export interface ResourceUsageCaptureStatus {
  status: "active" | "degraded";
  failedWrites: number;
  droppedEvents: number;
  lastCapturedAt?: number;
}

export interface ResourceUsageDailyRow {
  date: string;
  actions: number;
  sessions: number;
}

export interface ResourceUsageBreakdownRow {
  signal: ResourceUsageSignal;
  name: string;
  ownerKind: ResourceUsageOwnerKind;
  ownerId: string;
  actions: number;
  sessions: number;
}

export interface ResourceUsageResponse {
  subject: ResourceUsageSubject;
  rangeDays: 7 | 30 | 90;
  timezone: string;
  recordingStartedAt: number;
  recordedActions: number;
  distinctSessions: number;
  activeDays: number;
  lastRecordedAt?: number;
  retainedHistory: {
    retentionDays: number;
    oldestRecordedAt?: number;
    lastRecordedAt?: number;
  };
  daily: ResourceUsageDailyRow[];
  breakdown: ResourceUsageBreakdownRow[];
  capture: ResourceUsageCaptureStatus;
}

export interface ResourceUsageServiceOptions {
  now?: () => number;
  maxPendingEvents?: number;
  batchSize?: number;
}

export interface ResourceUsagePurgeResult {
  status: "purged" | "pending";
  records: number;
}

export interface AggregateResourceUsageInput {
  events: ResourceUsageEvent[];
  retainedBounds: ResourceUsageBounds;
  subject: ResourceUsageSubject;
  rangeDays: 7 | 30 | 90;
  timezone: string;
  nowMs: number;
  recordingStartedAt: number;
  capture: ResourceUsageCaptureStatus;
}

/** Application service for best-effort exact live capture and indexed reads. */
export class ResourceUsageService {
  private readonly now: () => number;
  private readonly maxPendingEvents: number;
  private readonly batchSize: number;
  private readonly recordingStartedAt: number;
  private pending: ResourceUsageEvent[] = [];
  private flushScheduled = false;
  private flushTail: Promise<void> = Promise.resolve();
  private captureStatus: ResourceUsageCaptureStatus = {
    status: "active",
    failedWrites: 0,
    droppedEvents: 0,
  };

  constructor(
    private readonly store: ResourceUsageStore,
    options: ResourceUsageServiceOptions = {},
  ) {
    this.now = options.now ?? Date.now;
    this.maxPendingEvents = options.maxPendingEvents ?? MAX_PENDING_EVENTS;
    this.batchSize = options.batchSize ?? MAX_BATCH_EVENTS;
    this.recordingStartedAt = recordingStartedAt(store, this.now());
  }

  capture(event: ResourceUsageEvent): void {
    try {
      if (this.pending.length >= this.maxPendingEvents) {
        this.captureStatus = {
          ...this.captureStatus,
          status: "degraded",
          droppedEvents: this.captureStatus.droppedEvents + 1,
        };
        return;
      }
      this.pending.push(event);
      this.captureStatus = { ...this.captureStatus, lastCapturedAt: event.occurredAt };
      this.scheduleFlush();
    } catch (error) {
      this.noteWriteFailure(error);
    }
  }

  captureToolInvocation(input: {
    session: Pick<Session, "id" | "piSessionId" | "workspaceId" | "model">;
    runtime: ResourceUsageRuntime;
    toolName: string;
    toolCallId?: string;
    occurredAt?: number;
    evidence?: ResourceUsageToolEvidence;
  }): void {
    const producerId = input.toolCallId?.trim();
    if (!producerId || !input.evidence) return;
    const occurredAt = input.occurredAt ?? this.now();
    const sessionModel = splitModel(input.session.model);
    this.capture({
      actionId: resourceUsageActionId(
        input.runtime,
        input.session.piSessionId ?? input.session.id,
        "tool_invocation",
        producerId,
      ),
      occurredAt,
      signal: "tool_invocation",
      sessionId: input.session.id,
      ...(input.session.workspaceId ? { workspaceId: input.session.workspaceId } : {}),
      runtime: input.runtime,
      ownerKind: input.evidence.ownerKind,
      ownerId: input.evidence.ownerId,
      itemName: input.toolName,
      provider: input.evidence.provider ?? sessionModel.provider,
      model: input.evidence.model ?? sessionModel.model,
      manifestRevision: input.evidence.manifestRevision,
    });
  }

  captureAcceptedPrompt(input: {
    session: Pick<Session, "id" | "piSessionId" | "workspaceId" | "model">;
    runtime: ResourceUsageRuntime;
    evidence?: ResourceUsagePromptEvidence;
    producerId?: string;
    occurredAt?: number;
  }): void {
    const producerId = input.producerId?.trim();
    if (!input.evidence || !producerId) return;
    const sessionModel = splitModel(input.session.model);
    this.capture({
      actionId: resourceUsageActionId(
        input.runtime,
        input.session.piSessionId ?? input.session.id,
        input.evidence.signal,
        producerId,
      ),
      occurredAt: input.occurredAt ?? this.now(),
      signal: input.evidence.signal,
      sessionId: input.session.id,
      ...(input.session.workspaceId ? { workspaceId: input.session.workspaceId } : {}),
      runtime: input.runtime,
      ownerKind: input.evidence.ownerKind,
      ownerId: input.evidence.ownerId,
      itemName: input.evidence.itemName,
      provider: input.evidence.provider ?? sessionModel.provider,
      model: input.evidence.model ?? sessionModel.model,
      manifestRevision: input.evidence.manifestRevision,
    });
  }

  createRuntimeInstanceId(): string {
    return this.store.nextRuntimeInstanceId();
  }

  captureSkillLoads(input: {
    session: Pick<Session, "id" | "piSessionId" | "workspaceId" | "model">;
    runtime: ResourceUsageRuntime;
    skills: readonly ResourceUsageSkillLoadEvidence[];
    runtimeInstanceId: string;
    generation: number;
    occurredAt?: number;
  }): void {
    const occurredAt = input.occurredAt ?? this.now();
    const sessionModel = splitModel(input.session.model);
    for (const skill of input.skills) {
      this.capture({
        actionId: resourceUsageActionId(
          input.runtime,
          input.session.piSessionId ?? input.session.id,
          "agent_load",
          `${input.runtimeInstanceId}:${input.generation}:${skill.id}`,
        ),
        occurredAt,
        signal: "agent_load",
        sessionId: input.session.id,
        ...(input.session.workspaceId ? { workspaceId: input.session.workspaceId } : {}),
        runtime: input.runtime,
        ownerKind: "skill",
        ownerId: skill.id,
        itemName: skill.name,
        provider: skill.provider ?? sessionModel.provider,
        model: skill.model ?? sessionModel.model,
        manifestRevision: skill.manifestRevision,
      });
    }
  }

  async flush(): Promise<void> {
    this.flushScheduled = false;
    const run = async (): Promise<void> => {
      while (this.pending.length > 0) {
        const batch = this.pending.splice(0, this.batchSize);
        try {
          this.store.recordBatch(batch, this.now());
        } catch (error) {
          this.noteWriteFailure(error);
        }
        await yieldToEventLoop();
      }
    };
    this.flushTail = this.flushTail.then(run, run);
    await this.flushTail;
  }

  async getUsage(
    subject: ResourceUsageSubject,
    rangeDays: 7 | 30 | 90,
    timezone: string,
  ): Promise<ResourceUsageResponse> {
    assertRange(rangeDays);
    assertIanaTimezone(timezone);
    const nowMs = this.now();
    try {
      const dates = localDateRange(rangeDays, timezone, nowMs);
      const sinceMs = localDateStartMs(dates[0], timezone);
      const retainedBounds = this.store.retainedBounds(subject, nowMs);
      const overall = this.store.aggregate({ subject, sinceMs, untilMs: nowMs });
      const dailyRanges = dates.map((date, index) => {
        const startMs = localDateStartMs(date, timezone);
        const nextStartMs =
          index + 1 < dates.length ? localDateStartMs(dates[index + 1], timezone) : nowMs + 1;
        return { startMs, endMs: Math.min(nowMs + 1, nextStartMs) };
      });
      const dailyAggregates = this.store.aggregateDaily({ subject, ranges: dailyRanges });
      const daily = dates.map((date, index) => ({
        date,
        aggregate: dailyAggregates.get(index) ?? emptyUsageAggregate(),
      }));
      return responseFromAggregates({
        subject,
        rangeDays,
        timezone,
        recordingStartedAt: this.recordingStartedAt,
        retainedBounds,
        overall,
        daily,
        capture: { ...this.captureStatus },
      });
    } catch (error) {
      this.noteWriteFailure(error);
      throw new Error("Resource usage statistics are unavailable", { cause: error });
    }
  }

  async deleteSession(sessionId: string): Promise<ResourceUsagePurgeResult> {
    this.pending = this.pending.filter((event) => event.sessionId !== sessionId);
    await this.flush();
    try {
      const result = this.store.requestSessionPurge(sessionId);
      if (!result.completed) this.noteWriteFailure(new Error("session usage purge pending"));
      return { status: result.completed ? "purged" : "pending", records: result.records };
    } catch (error) {
      this.noteWriteFailure(error);
      return { status: "pending", records: 0 };
    }
  }

  async deleteWorkspace(workspaceId: string): Promise<ResourceUsagePurgeResult> {
    this.pending = this.pending.filter((event) => event.workspaceId !== workspaceId);
    await this.flush();
    try {
      const result = this.store.requestWorkspacePurge(workspaceId);
      if (!result.completed) this.noteWriteFailure(new Error("workspace usage purge pending"));
      return { status: result.completed ? "purged" : "pending", records: result.records };
    } catch (error) {
      this.noteWriteFailure(error);
      return { status: "pending", records: 0 };
    }
  }

  async close(): Promise<void> {
    await this.flush();
    this.store.close();
  }

  private scheduleFlush(): void {
    if (this.flushScheduled) return;
    this.flushScheduled = true;
    setImmediate(() => void this.flush());
  }

  private noteWriteFailure(error: unknown): void {
    this.captureStatus = {
      ...this.captureStatus,
      status: "degraded",
      failedWrites: this.captureStatus.failedWrites + 1,
    };
    log.warn("resource_usage.write_failed", { error: safeErrorMessage(error) });
  }
}

export function aggregateResourceUsage(input: AggregateResourceUsageInput): ResourceUsageResponse {
  assertIanaTimezone(input.timezone);
  const dates = localDateRange(input.rangeDays, input.timezone, input.nowMs);
  const dailyState = new Map(
    dates.map((date) => [date, { actions: 0, sessions: new Set<string>() }]),
  );
  const sessions = new Set<string>();
  const activeDates = new Set<string>();
  const breakdown = new Map<
    string,
    {
      signal: ResourceUsageSignal;
      name: string;
      ownerKind: ResourceUsageOwnerKind;
      ownerId: string;
      actions: number;
      sessions: Set<string>;
    }
  >();
  let recordedActions = 0;

  for (const event of input.events) {
    const date = localDate(event.occurredAt, input.timezone);
    const daily = dailyState.get(date);
    if (!daily) continue;
    recordedActions += 1;
    daily.actions += 1;
    daily.sessions.add(event.sessionId);
    sessions.add(event.sessionId);
    activeDates.add(date);

    const name = event.itemName ?? event.signal;
    const key = `${event.signal}\0${event.ownerKind}\0${event.ownerId}\0${name}`;
    let row = breakdown.get(key);
    if (!row) {
      row = {
        signal: event.signal,
        name,
        ownerKind: event.ownerKind,
        ownerId: event.ownerId,
        actions: 0,
        sessions: new Set(),
      };
      breakdown.set(key, row);
    }
    row.actions += 1;
    row.sessions.add(event.sessionId);
  }

  return {
    subject: input.subject,
    rangeDays: input.rangeDays,
    timezone: input.timezone,
    recordingStartedAt: input.recordingStartedAt,
    recordedActions,
    distinctSessions: sessions.size,
    activeDays: activeDates.size,
    ...(input.retainedBounds.lastRecordedAt !== undefined
      ? { lastRecordedAt: input.retainedBounds.lastRecordedAt }
      : {}),
    retainedHistory: {
      retentionDays: RESOURCE_USAGE_RETENTION_DAYS,
      ...input.retainedBounds,
    },
    daily: dates.map((date) => {
      const row = dailyState.get(date);
      return { date, actions: row?.actions ?? 0, sessions: row?.sessions.size ?? 0 };
    }),
    breakdown: [...breakdown.values()]
      .map((row) => ({ ...row, sessions: row.sessions.size }))
      .sort((left, right) => right.actions - left.actions || left.name.localeCompare(right.name)),
    capture: input.capture,
  };
}

export function parseResourceUsageRange(raw: string | null): 7 | 30 | 90 | undefined {
  const value = Number(raw);
  return VALID_RANGES.has(value) ? (value as 7 | 30 | 90) : undefined;
}

export function isIanaTimezone(value: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: value }).format(0);
    return value.trim().length > 0;
  } catch {
    return false;
  }
}

function assertRange(rangeDays: number): asserts rangeDays is 7 | 30 | 90 {
  if (!VALID_RANGES.has(rangeDays)) throw new Error("range must be one of 7, 30, or 90");
}

function assertIanaTimezone(timezone: string): void {
  if (!isIanaTimezone(timezone)) throw new Error("timezone must be a valid IANA timezone");
}

function localDateRange(rangeDays: number, timezone: string, nowMs: number): string[] {
  const current = localDate(nowMs, timezone);
  const [year, month, day] = current.split("-").map(Number);
  const anchor = Date.UTC(year, month - 1, day);
  return Array.from({ length: rangeDays }, (_, index) => {
    const date = new Date(anchor - (rangeDays - index - 1) * 86_400_000);
    return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}-${String(date.getUTCDate()).padStart(2, "0")}`;
  });
}

function localDate(timestamp: number, timezone: string): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(timestamp);
  const value = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${value.year}-${value.month}-${value.day}`;
}

function localDateStartMs(date: string, timezone: string): number {
  const [year, month, day] = date.split("-").map(Number);
  const desired = Date.UTC(year, month - 1, day);
  const targetDate = `${String(year).padStart(4, "0")}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
  let low = desired - 3 * 86_400_000;
  let high = desired + 3 * 86_400_000;
  while (high - low > 1) {
    const middle = low + Math.floor((high - low) / 2);
    if (localDate(middle, timezone) >= targetDate) high = middle;
    else low = middle;
  }
  return high;
}

function responseFromAggregates(input: {
  subject: ResourceUsageSubject;
  rangeDays: 7 | 30 | 90;
  timezone: string;
  recordingStartedAt: number;
  retainedBounds: ResourceUsageBounds;
  overall: ResourceUsageAggregate;
  daily: Array<{ date: string; aggregate: ResourceUsageAggregate }>;
  capture: ResourceUsageCaptureStatus;
}): ResourceUsageResponse {
  return {
    subject: input.subject,
    rangeDays: input.rangeDays,
    timezone: input.timezone,
    recordingStartedAt: input.recordingStartedAt,
    recordedActions: input.overall.actions,
    distinctSessions: input.overall.sessions,
    activeDays: input.daily.filter((row) => row.aggregate.actions > 0).length,
    ...(input.retainedBounds.lastRecordedAt !== undefined
      ? { lastRecordedAt: input.retainedBounds.lastRecordedAt }
      : {}),
    retainedHistory: {
      retentionDays: RESOURCE_USAGE_RETENTION_DAYS,
      ...input.retainedBounds,
    },
    daily: input.daily.map(({ date, aggregate }) => ({
      date,
      actions: aggregate.actions,
      sessions: aggregate.sessions,
    })),
    breakdown: input.overall.breakdown,
    capture: input.capture,
  };
}

function emptyUsageAggregate(): ResourceUsageAggregate {
  return { actions: 0, sessions: 0, breakdown: [] };
}

function splitModel(value: string | undefined): { provider?: string; model?: string } {
  const normalized = value?.trim();
  if (!normalized) return {};
  const separator = normalized.indexOf("/");
  return separator > 0
    ? { provider: normalized.slice(0, separator), model: normalized.slice(separator + 1) }
    : { model: normalized };
}

export function resourceUsageActionId(
  runtime: ResourceUsageRuntime,
  sessionId: string,
  signal: ResourceUsageSignal,
  producerId: string,
): string {
  return createHash("sha256")
    .update(`${runtime}\0${sessionId}\0${signal}\0${producerId}`)
    .digest("hex");
}

function recordingStartedAt(store: ResourceUsageStore, nowMs: number): number {
  const stored = Number(store.getMetadata(RECORDING_STARTED_AT_KEY));
  if (Number.isFinite(stored) && stored > 0) return stored;
  store.setMetadata(RECORDING_STARTED_AT_KEY, String(nowMs));
  return nowMs;
}

function yieldToEventLoop(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}

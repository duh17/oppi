import { cronOccurrences } from "./agent-schedule-cron.js";
import type { ThinkingLevel } from "./agent-launch-service.js";
import {
  actionSummary,
  atSlotKey,
  runSummary,
  type AgentSchedule,
  type AgentScheduleActionSummary,
  type AgentScheduleRun,
  type AgentScheduleRunKind,
  type AgentScheduleRunStatus,
  type AgentScheduleStatus,
  type AgentScheduleTrigger,
} from "./agent-schedules.js";
import type { ProgramStatus, Session } from "./types.js";

/** The longest range one calendar request may ask for: two months and change. */
export const SCHEDULE_CALENDAR_MAX_RANGE_MS = 62 * 86_400_000;
/** Upcoming occurrences listed per schedule per request; more sets `upcomingTruncated`. */
export const SCHEDULE_CALENDAR_UPCOMING_LIMIT = 200;

/**
 * `GET /schedules/calendar`: what ran and what will run in `[from, to)`.
 *
 * Read-only. Past entries are runs created in the range, each joined to its session on the
 * server, so a stopped session the device never loaded still shows its outcome. Upcoming
 * entries are expanded from active schedules' triggers here, with the runner's own cron and
 * daylight-saving rules (`cronOccurrences`), so no client keeps a second cron parser.
 */
export interface ScheduleCalendarResponse {
  from: number;
  to: number;
  now: number;
  /** Every schedule an entry names, paused and archived ones included: their runs happened. */
  schedules: ScheduleCalendarSchedule[];
  /** Oldest first. */
  entries: ScheduleCalendarEntry[];
}

export interface ScheduleCalendarSchedule {
  id: string;
  name: string;
  status: AgentScheduleStatus;
  trigger: AgentScheduleTrigger;
  action: AgentScheduleActionSummary;
  /**
   * The model a run asks for, as dispatch picks it: a new session's own model, else its saved
   * Agent's default; an existing session's model. Absent leaves the server's default.
   */
  model?: string;
  thinkingLevel?: ThinkingLevel;
  /** The range held more upcoming occurrences than the calendar lists. */
  upcomingTruncated?: true;
}

export interface ScheduleCalendarEntry {
  scheduleId: string;
  slotKey: string;
  /** The slot's time (a manual run's creation); epoch ms. */
  at: number;
  /** Absent for an upcoming occurrence. */
  run?: ScheduleCalendarRun;
}

export interface ScheduleCalendarRun {
  id: string;
  kind: AgentScheduleRunKind;
  /** Dispatch status only: `completed` means the session launched or the prompt was sent. */
  status: AgentScheduleRunStatus;
  createdAt: number;
  startedAt?: number;
  completedAt?: number;
  error?: string;
  promptDispatch?: "delivered" | "not_sent";
  session?: ScheduleCalendarSession;
}

/**
 * The run's session as it is now. `cost` and `programStatus` cover the whole session, so they
 * include any later human follow-up in it.
 */
export interface ScheduleCalendarSession {
  id: string;
  workspaceId?: string;
  status: Session["status"];
  programStatus?: ProgramStatus;
  cost: number;
  model?: string;
  /** When the session last settled (its done, error, or idle program status began). */
  settledAt?: number;
}

export interface ScheduleCalendarSources {
  listSchedules(): AgentSchedule[];
  listRunsCreatedBetween(from: number, to: number): AgentScheduleRun[];
  getSession(sessionId: string): Session | undefined;
  agentDefaultModel(agentId: string): string | undefined;
}

/** A range the route refuses, with the reason it answers 400 with. */
export class ScheduleCalendarRangeError extends Error {}

export function parseScheduleCalendarRange(url: URL): { from: number; to: number } {
  const from = parseEpochMs(url.searchParams.get("from"), "from");
  const to = parseEpochMs(url.searchParams.get("to"), "to");
  if (to <= from) throw new ScheduleCalendarRangeError("to must be after from");
  if (to - from > SCHEDULE_CALENDAR_MAX_RANGE_MS) {
    throw new ScheduleCalendarRangeError("The range may span at most 62 days");
  }
  return { from, to };
}

function parseEpochMs(raw: string | null, name: string): number {
  const value = raw?.trim() ?? "";
  if (!/^\d+$/.test(value) || !Number.isSafeInteger(Number(value))) {
    throw new ScheduleCalendarRangeError(`${name} must be epoch milliseconds`);
  }
  return Number(value);
}

export function buildScheduleCalendar(
  sources: ScheduleCalendarSources,
  range: { from: number; to: number; now: number },
): ScheduleCalendarResponse {
  const { from, to, now } = range;
  const schedules = new Map(sources.listSchedules().map((schedule) => [schedule.id, schedule]));
  const named = new Map<string, ScheduleCalendarSchedule>();
  const entries: ScheduleCalendarEntry[] = [];
  const takenSlots = new Set<string>();

  for (const run of sources.listRunsCreatedBetween(from, to)) {
    const schedule = schedules.get(run.scheduleId);
    if (!schedule) continue;
    named.set(schedule.id, named.get(schedule.id) ?? calendarSchedule(schedule, sources));
    takenSlots.add(`${run.scheduleId}\n${run.slotKey}`);
    entries.push({
      scheduleId: run.scheduleId,
      slotKey: run.slotKey,
      at: slotTime(run),
      run: calendarRun(run, sources),
    });
  }

  // Only what is still to come: a past slot with no run is not shown (the server keeps no
  // pause history, so it cannot tell a missed run from a paused one).
  const upcomingFrom = Math.max(from, now + 1);
  for (const schedule of schedules.values()) {
    if (schedule.status !== "active" || upcomingFrom >= to) continue;
    const { at, truncated } = upcomingOccurrences(schedule, upcomingFrom, to);
    let listed = false;
    for (const time of at) {
      const slotKey = slotKeyFor(schedule.trigger, time);
      if (takenSlots.has(`${schedule.id}\n${slotKey}`)) continue;
      entries.push({ scheduleId: schedule.id, slotKey, at: time });
      listed = true;
    }
    if (!listed && !truncated) continue;
    const entry = named.get(schedule.id) ?? calendarSchedule(schedule, sources);
    named.set(schedule.id, truncated ? { ...entry, upcomingTruncated: true } : entry);
  }

  entries.sort(
    (a, b) =>
      a.at - b.at || a.scheduleId.localeCompare(b.scheduleId) || a.slotKey.localeCompare(b.slotKey),
  );
  return { from, to, now, schedules: [...named.values()], entries };
}

/**
 * The trigger's due times in `[from, to)`, by the runner's rules (`dueSlotKeys`): `at` once, if
 * the schedule existed by then; `every` at `createdAt + k·interval` from k = 1; cron through
 * `cronOccurrences`.
 */
function upcomingOccurrences(
  schedule: AgentSchedule,
  from: number,
  to: number,
): { at: number[]; truncated: boolean } {
  const { trigger, createdAt } = schedule;
  const limit = SCHEDULE_CALENDAR_UPCOMING_LIMIT;
  switch (trigger.type) {
    case "at":
      return {
        at: trigger.at >= from && trigger.at < to && createdAt <= trigger.at ? [trigger.at] : [],
        truncated: false,
      };
    case "every": {
      const first = createdAt + trigger.intervalMs;
      const step = Math.max(0, Math.ceil((from - first) / trigger.intervalMs));
      const at: number[] = [];
      for (let time = first + step * trigger.intervalMs; time < to; time += trigger.intervalMs) {
        if (at.length === limit) return { at, truncated: true };
        at.push(time);
      }
      return { at, truncated: false };
    }
    case "cron":
      return cronOccurrences(trigger.expression, trigger.timeZone, { from, to, createdAt, limit });
  }
}

function slotKeyFor(trigger: AgentScheduleTrigger, time: number): string {
  switch (trigger.type) {
    case "at":
      return atSlotKey(time);
    case "every":
      return `every:${time}`;
    case "cron":
      return `cron:${time}`;
  }
}

/** A due run's slot names its time; a manual run's time is when it was asked for. */
function slotTime(run: AgentScheduleRun): number {
  if (run.kind === "due") {
    const time = Number(run.slotKey.slice(run.slotKey.indexOf(":") + 1));
    if (Number.isSafeInteger(time)) return time;
  }
  return run.createdAt;
}

function calendarSchedule(
  schedule: AgentSchedule,
  sources: ScheduleCalendarSources,
): ScheduleCalendarSchedule {
  const action = schedule.action;
  const model =
    action.type === "new_session"
      ? (action.model ?? (action.agentId ? sources.agentDefaultModel(action.agentId) : undefined))
      : sources.getSession(action.sessionId)?.model;
  const thinkingLevel = action.type === "new_session" ? action.thinkingLevel : undefined;
  return {
    id: schedule.id,
    name: schedule.name,
    status: schedule.status,
    trigger: schedule.trigger,
    action: actionSummary(action),
    ...(model ? { model } : {}),
    ...(thinkingLevel ? { thinkingLevel } : {}),
  };
}

function calendarRun(run: AgentScheduleRun, sources: ScheduleCalendarSources): ScheduleCalendarRun {
  const summary = runSummary(run);
  const session = summary.sessionId ? sources.getSession(summary.sessionId) : undefined;
  return {
    id: run.id,
    kind: run.kind,
    status: run.status,
    createdAt: run.createdAt,
    ...(run.startedAt === undefined ? {} : { startedAt: run.startedAt }),
    ...(run.completedAt === undefined ? {} : { completedAt: run.completedAt }),
    ...(run.error === undefined ? {} : { error: run.error }),
    ...(summary.promptDispatch ? { promptDispatch: summary.promptDispatch } : {}),
    ...(session ? { session: calendarSession(session) } : {}),
  };
}

function calendarSession(session: Session): ScheduleCalendarSession {
  const program = session.programStatus;
  const settled =
    program && (program.state === "done" || program.state === "error" || program.state === "idle");
  return {
    id: session.id,
    ...(session.workspaceId ? { workspaceId: session.workspaceId } : {}),
    status: session.status,
    ...(program ? { programStatus: program } : {}),
    cost: session.cost,
    ...(session.model ? { model: session.model } : {}),
    ...(settled ? { settledAt: program.since } : {}),
  };
}

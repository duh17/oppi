import { cronMatchesNow } from "./agent-schedule-cron.js";
import type { AgentSchedule, AgentScheduleTrigger } from "./agent-schedules.js";
import {
  createAgentScheduleDispatchHooks,
  type AgentScheduleDispatchDeps,
} from "./agent-schedule-dispatch.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";

const DEFAULT_INTERVAL_MS = 60_000;
const DEFAULT_LEASE_MS = 10 * 60_000;
const DEFAULT_LIMIT = 3;
const DEFAULT_OWNER_ID = "agent-schedule-runner";
const MS_PER_MINUTE = 60_000;
const log = createLogger({ base: { component: "agent_schedule_runner" } });

export interface AgentScheduleRunnerDeps extends AgentScheduleDispatchDeps {
  nowMs?: () => number;
  intervalMs?: number;
  leaseMs?: number;
  limit?: number;
  ownerId?: string;
}

export class AgentScheduleRunner {
  private timer: ReturnType<typeof setInterval> | null = null;
  private running = false;
  private readonly nowMs: () => number;
  private readonly intervalMs: number;
  private readonly leaseMs: number;
  private readonly limit: number;
  private readonly ownerId: string;

  constructor(private readonly deps: AgentScheduleRunnerDeps) {
    this.nowMs = deps.nowMs ?? Date.now;
    this.intervalMs = Math.max(5_000, deps.intervalMs ?? DEFAULT_INTERVAL_MS);
    this.leaseMs = Math.max(1_000, deps.leaseMs ?? DEFAULT_LEASE_MS);
    this.limit = Math.max(1, deps.limit ?? DEFAULT_LIMIT);
    this.ownerId = deps.ownerId?.trim() || DEFAULT_OWNER_ID;
  }

  start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => {
      void this.runOnce();
    }, this.intervalMs);
    this.timer.unref?.();
    log.info("agent_schedule_runner.started", { intervalMs: this.intervalMs });
    void this.runOnce();
  }

  stop(): void {
    if (!this.timer) return;
    clearInterval(this.timer);
    this.timer = null;
  }

  async runOnce(): Promise<void> {
    if (this.running) return;
    this.running = true;
    try {
      const now = this.nowMs();
      this.materializeDueRuns(now);
      await this.dispatchReadyRuns(now);
    } catch (error) {
      log.error("agent_schedule_runner.tick.failed", { error: safeErrorMessage(error) });
    } finally {
      this.running = false;
    }
  }

  private materializeDueRuns(now: number): void {
    const store = this.deps.storage.getAgentScheduleStore();
    for (const schedule of store.listSchedules()) {
      if (schedule.status !== "active") continue;
      let slotKeys: string[];
      try {
        slotKeys = dueSlotKeysForSchedule(schedule, now);
      } catch (error) {
        log.warn("agent_schedule_runner.schedule_due_check.failed", {
          scheduleId: schedule.id,
          error: safeErrorMessage(error),
        });
        continue;
      }
      for (const slotKey of slotKeys) {
        try {
          store.createDueRun(schedule.id, slotKey, now);
        } catch (error) {
          log.warn("agent_schedule_runner.create_due_run.failed", {
            scheduleId: schedule.id,
            slotKey,
            error: safeErrorMessage(error),
          });
        }
      }
    }
  }

  private async dispatchReadyRuns(now: number): Promise<void> {
    const store = this.deps.storage.getAgentScheduleStore();
    const claimed = store.claimReadyRuns({
      now,
      ownerId: this.ownerId,
      leaseMs: this.leaseMs,
      limit: this.limit,
      kinds: ["due"],
    });
    if (claimed.length === 0) return;

    const hooks = createAgentScheduleDispatchHooks(this.deps, this.ownerId);
    for (const run of claimed) {
      try {
        await store.dispatchClaimedRun(run.id, hooks, {
          leaseOwner: this.ownerId,
          now: this.nowMs(),
        });
      } catch (error) {
        log.warn("agent_schedule_runner.dispatch.failed", {
          scheduleId: run.scheduleId,
          runId: run.id,
          error: safeErrorMessage(error),
        });
      }
    }
  }
}

export function dueSlotKeysForSchedule(schedule: AgentSchedule, now: number): string[] {
  if (schedule.status !== "active") return [];
  return dueSlotKeys(schedule.trigger, schedule.createdAt, now);
}

function dueSlotKeys(trigger: AgentScheduleTrigger, createdAt: number, now: number): string[] {
  if (trigger.type === "at") {
    return now >= trigger.at && createdAt <= trigger.at ? [`at:${trigger.at}`] : [];
  }

  if (trigger.type === "every") {
    const firstRun = createdAt + trigger.intervalMs;
    if (now < firstRun) return [];
    const elapsed = now - firstRun;
    const slotTime = firstRun + Math.floor(elapsed / trigger.intervalMs) * trigger.intervalMs;
    return [`every:${slotTime}`];
  }

  const minuteStart = Math.floor(now / MS_PER_MINUTE) * MS_PER_MINUTE;
  if (createdAt > minuteStart) return [];
  if (!cronMatchesNow(trigger.expression, trigger.timeZone, minuteStart)) return [];
  return [`cron:${minuteStart}`];
}

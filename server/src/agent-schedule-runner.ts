import { cronMatchesNow, earlierRepeatedWallClockMinute } from "./agent-schedule-cron.js";
import { atSlotKey, type AgentSchedule, type AgentScheduleTrigger } from "./agent-schedules.js";
import { recordScheduleRun } from "./schedule-run-metrics.js";
import type { ServerTelemetry } from "./telemetry/server-telemetry.js";
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
/**
 * How many minutes before the current one a cron evaluation may still run. Covers a dispatch
 * that holds the runner past a few ticks and setInterval drift; a longer gap (laptop sleep)
 * is not replayed.
 */
export const CRON_CATCH_UP_MINUTES = 5;
const log = createLogger({ base: { component: "agent_schedule_runner" } });

export interface AgentScheduleRunnerDeps extends AgentScheduleDispatchDeps {
  nowMs?: () => number;
  intervalMs?: number;
  leaseMs?: number;
  limit?: number;
  ownerId?: string;
  metrics?: ServerTelemetry;
  /**
   * True while the server drains for a restart: due runs are still recorded, and the first
   * tick after the restart dispatches them.
   */
  dispatchPaused?: () => boolean;
  /**
   * The server's Schedules switch (`features.schedules`). Off, a tick records and runs nothing;
   * the first tick back on starts the schedules from that moment, so a slot that came due while
   * off is never run. Absent means on.
   */
  schedulesOn?: () => boolean;
}

export class AgentScheduleRunner {
  private timer: ReturnType<typeof setInterval> | null = null;
  private runInFlight: Promise<void> | null = null;
  private stopped = false;
  // Last minute whose cron slots were evaluated. In memory only: a restart begins at its
  // first tick's minute and does not backfill earlier ones.
  private lastCronMinute: number | null = null;
  // While the Schedules switch is off: the tick that first found it off. The first tick back
  // on turns it into `notBefore`, the earliest slot time that may still run. In memory only.
  private offSince: number | null = null;
  private notBefore = 0;
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
    if (this.timer || this.stopped) return;
    this.timer = setInterval(() => {
      void this.runOnce();
    }, this.intervalMs);
    this.timer.unref?.();
    log.info("agent_schedule_runner.started", { intervalMs: this.intervalMs });
    void this.runOnce();
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    await this.runInFlight;
  }

  runOnce(): Promise<void> {
    if (this.stopped) return Promise.resolve();
    if (this.runInFlight) return this.runInFlight;
    const run = (async () => {
      try {
        const now = this.nowMs();
        if (this.deps.schedulesOn?.() === false) {
          this.offSince ??= now;
          return;
        }
        if (this.offSince !== null) {
          this.offSince = null;
          this.notBefore = now;
          this.lastCronMinute = null;
        }
        this.materializeDueRuns(now);
        if (this.deps.dispatchPaused?.()) return;
        await this.dispatchReadyRuns();
      } catch (error) {
        log.error("agent_schedule_runner.tick.failed", { error: safeErrorMessage(error) });
      }
    })();
    this.runInFlight = run;
    void run.finally(() => {
      if (this.runInFlight === run) this.runInFlight = null;
    });
    return run;
  }

  private materializeDueRuns(now: number): void {
    const store = this.deps.storage.getAgentScheduleStore();
    // A tick that finds a dispatch in flight evaluates nothing, so its minutes stay between
    // lastCronMinute and the current one and are picked up here by the next evaluation. If
    // the clock stepped back, the window collapses to the current minute.
    const currentMinute = minuteStartOf(now);
    const cronFromMinute =
      this.lastCronMinute === null
        ? currentMinute
        : Math.min(
            currentMinute,
            Math.max(
              this.lastCronMinute + MS_PER_MINUTE,
              currentMinute - CRON_CATCH_UP_MINUTES * MS_PER_MINUTE,
            ),
          );
    const schedules = store.listSchedules();
    for (const schedule of schedules) {
      if (schedule.status !== "active") continue;
      let slotKeys: string[];
      try {
        slotKeys = dueSlotKeysForSchedule(schedule, now, cronFromMinute, this.notBefore);
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
          if (slotKey.startsWith("cron:")) {
            const lateMs = now - Number(slotKey.slice("cron:".length));
            if (lateMs >= MS_PER_MINUTE) {
              log.info("agent_schedule_runner.cron_slot.late", {
                scheduleId: schedule.id,
                slotKey,
                lateMs,
              });
            }
          }
        } catch (error) {
          log.warn("agent_schedule_runner.create_due_run.failed", {
            scheduleId: schedule.id,
            slotKey,
            error: safeErrorMessage(error),
          });
        }
      }
    }
    // Only after the schedules were read and walked, so a failed read keeps these minutes.
    this.lastCronMinute = currentMinute;
  }

  private async dispatchReadyRuns(): Promise<void> {
    const store = this.deps.storage.getAgentScheduleStore();
    const hooks = createAgentScheduleDispatchHooks(this.deps, this.ownerId);
    for (let i = 0; i < this.limit && !this.stopped; i++) {
      // Claim only when ready to dispatch; stop must not strand a batch of leases.
      // Stamp each lease from the current time: earlier dispatches in this tick
      // may have awaited long enough that a tick-start lease is already expired.
      const run = store.claimReadyRuns({
        now: this.nowMs(),
        ownerId: this.ownerId,
        leaseMs: this.leaseMs,
        limit: 1,
        kinds: ["due"],
      })[0];
      if (!run) break;
      const startedAt = this.nowMs();
      try {
        await store.dispatchClaimedRun(run.id, hooks, {
          leaseOwner: this.ownerId,
          now: this.nowMs(),
        });
        recordScheduleRun(this.deps.metrics, {
          startedAt,
          now: this.nowMs(),
          kind: "due",
          status: "ok",
        });
      } catch (error) {
        recordScheduleRun(this.deps.metrics, {
          startedAt,
          now: this.nowMs(),
          kind: "due",
          status: "error",
          error,
        });
        log.warn("agent_schedule_runner.dispatch.failed", {
          scheduleId: run.scheduleId,
          runId: run.id,
          error: safeErrorMessage(error),
        });
      }
    }
  }
}

/**
 * Slot keys due at `now`. A cron trigger yields at most one slot: the latest matching minute
 * from `cronFromMinute` (a minute start; default the minute of `now`) through the minute of
 * `now`, so a catch-up never queues a burst of runs. A slot before `notBefore` (when the
 * Schedules switch came back on) is never due.
 */
export function dueSlotKeysForSchedule(
  schedule: AgentSchedule,
  now: number,
  cronFromMinute?: number,
  notBefore = 0,
): string[] {
  if (schedule.status !== "active") return [];
  return dueSlotKeys(schedule.trigger, schedule.createdAt, now, cronFromMinute).filter(
    (slotKey) => slotTime(slotKey) >= notBefore,
  );
}

/** The time a slot key names: `at:`, `every:` and `cron:` all end in epoch milliseconds. */
function slotTime(slotKey: string): number {
  return Number(slotKey.slice(slotKey.indexOf(":") + 1));
}

function minuteStartOf(ms: number): number {
  return Math.floor(ms / MS_PER_MINUTE) * MS_PER_MINUTE;
}

function dueSlotKeys(
  trigger: AgentScheduleTrigger,
  createdAt: number,
  now: number,
  cronFromMinute?: number,
): string[] {
  if (trigger.type === "at") {
    return now >= trigger.at && createdAt <= trigger.at ? [atSlotKey(trigger.at)] : [];
  }

  if (trigger.type === "every") {
    const firstRun = createdAt + trigger.intervalMs;
    if (now < firstRun) return [];
    const elapsed = now - firstRun;
    const slotTime = firstRun + Math.floor(elapsed / trigger.intervalMs) * trigger.intervalMs;
    return [`every:${slotTime}`];
  }

  // One slot per evaluation, like "every": the latest matching minute in the window.
  const currentMinute = minuteStartOf(now);
  for (
    let minuteStart = currentMinute;
    minuteStart >= (cronFromMinute ?? currentMinute);
    minuteStart -= MS_PER_MINUTE
  ) {
    if (createdAt > minuteStart) continue;
    if (!cronMatchesNow(trigger.expression, trigger.timeZone, minuteStart)) continue;
    // Fall-back repeats a wall-clock hour; run it only on the first occurrence. A schedule
    // created after the first occurrence never ran that minute, so the repeat still fires.
    if (earlierRepeatedWallClockMinute(trigger.timeZone, minuteStart, createdAt) !== undefined) {
      continue;
    }
    return [`cron:${minuteStart}`];
  }
  return [];
}

import type { ServerMetricCollector } from "./server-metric-collector.js";

export type ScheduleRunMetricKind = "due" | "manual";
export type ScheduleRunMetricStatus = "completed" | "failed";

/** Bounded failure class. Never the raw error text. */
export function scheduleRunFailureReason(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  const lower = message.toLowerCase();
  if (lower.includes("lease")) return "lease_lost";
  if (lower.includes("not found")) return "not_found";
  if (message === "launch_in_progress") return "launch_in_progress";
  return "other";
}

/** Dispatch outcome for a schedule run. Duration is wall time around dispatch. */
export function recordScheduleRun(
  metrics: ServerMetricCollector | undefined,
  input: {
    startedAt: number;
    now: number;
    kind: ScheduleRunMetricKind;
    status: ScheduleRunMetricStatus;
    error?: unknown;
  },
): void {
  const tags: Record<string, string> = {
    status: input.status,
    kind: input.kind,
  };
  if (input.status === "failed") tags.reason = scheduleRunFailureReason(input.error);
  metrics?.record(
    "server.schedule_run_ms",
    Math.max(0, Math.round(input.now - input.startedAt)),
    tags,
  );
}

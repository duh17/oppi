import type { ServerMetricCollector } from "./server-metric-collector.js";

export type ScheduleRunMetricKind = "due" | "manual";
export type ScheduleRunMetricStatus = "completed" | "failed";

const SCHEDULE_RUN_REASONS = new Set(["lease_lost", "not_found", "launch_in_progress"]);

/** Dispatch failure whose metric reason is a code, not the user-facing message. */
export class ScheduleDispatchError extends Error {
  readonly code: string;

  constructor(code: string, message = code) {
    super(message);
    this.name = "ScheduleDispatchError";
    this.code = code;
  }
}

function failureCode(error: unknown): string | undefined {
  if (!error || typeof error !== "object" || !("code" in error)) return undefined;
  return typeof error.code === "string" ? error.code : undefined;
}

/** Bounded failure class. Never the raw error text. */
export function scheduleRunFailureReason(error: unknown): string {
  const code = failureCode(error);
  if (code && SCHEDULE_RUN_REASONS.has(code)) return code;
  // A typed code that is not a schedule reason, including prompt failures, stays other.
  if (code) return "other";

  const message = error instanceof Error ? error.message : String(error);
  if (message === "launch_in_progress") return "launch_in_progress";
  if (
    message.startsWith("Schedule run lease was lost:") ||
    message.startsWith("Schedule run lease is not held") ||
    message.startsWith("Schedule run lease expired:")
  ) {
    return "lease_lost";
  }
  if (
    message.startsWith("Schedule run not found:") ||
    message.startsWith("Schedule not found:") ||
    message.startsWith("Schedule run disappeared:")
  ) {
    return "not_found";
  }
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

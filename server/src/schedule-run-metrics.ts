import type { EventTags } from "./telemetry/catalog.js";
import type { ServerTelemetry } from "./telemetry/server-telemetry.js";

export type ScheduleRunMetricKind = "due" | "manual";
export type ScheduleRunMetricStatus = "ok" | "error";
type ScheduleRunFailureReason = NonNullable<EventTags<"server.schedule_run">["reason"]>;

const SCHEDULE_RUN_REASONS = new Set<string>(["lease_lost", "not_found", "launch_in_progress"]);

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
export function scheduleRunFailureReason(error: unknown): ScheduleRunFailureReason {
  const code = failureCode(error);
  if (code && SCHEDULE_RUN_REASONS.has(code)) return code as ScheduleRunFailureReason;
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
  metrics: ServerTelemetry | undefined,
  input: {
    startedAt: number;
    now: number;
    kind: ScheduleRunMetricKind;
    status: ScheduleRunMetricStatus;
    error?: unknown;
  },
): void {
  metrics?.record(
    "server.schedule_run",
    { duration_ms: Math.max(0, Math.round(input.now - input.startedAt)) },
    {
      status: input.status,
      run_kind: input.kind,
      ...(input.status === "error" ? { reason: scheduleRunFailureReason(input.error) } : {}),
    },
  );
}

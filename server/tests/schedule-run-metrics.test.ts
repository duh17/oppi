import { describe, expect, it } from "vitest";

import { ScheduleDispatchError, recordScheduleRun } from "../src/schedule-run-metrics.js";
import { ServerTelemetry } from "../src/telemetry/server-telemetry.js";
import type { TelemetryEventRecord } from "../src/types.js";

function telemetry() {
  const records: TelemetryEventRecord[] = [];
  const metrics = new ServerTelemetry({ write: (_origin, batch) => records.push(...batch) });
  return { metrics, stored: () => (metrics.flush(), records) };
}

describe("schedule run metrics", () => {
  it("records a bounded failure reason and drops the raw error text", () => {
    const { metrics, stored } = telemetry();
    recordScheduleRun(metrics, {
      startedAt: 1_000,
      now: 1_250,
      kind: "due",
      status: "error",
      error: new Error(
        'Required model "ds4/deepseek-v4-flash" is not available at /Users/example/secret',
      ),
    });
    expect(stored()).toEqual([
      expect.objectContaining({
        name: "server.schedule_run",
        fields: { duration_ms: 250 },
        tags: { status: "error", run_kind: "due", reason: "other" },
      }),
    ]);
    expect(JSON.stringify(stored())).not.toContain("deepseek");
    expect(JSON.stringify(stored())).not.toContain("/Users/example/secret");
  });

  it("maps a promptError that mentions release or not found to other", () => {
    const { metrics, stored } = telemetry();
    recordScheduleRun(metrics, {
      startedAt: 1,
      now: 2,
      kind: "due",
      status: "error",
      error: new ScheduleDispatchError(
        "other",
        "please release the workspace; model not found at /Users/example/secret",
      ),
    });
    recordScheduleRun(metrics, {
      startedAt: 1,
      now: 2,
      kind: "due",
      status: "error",
      error: new Error("please release the file; model not found"),
    });
    const records = stored();
    expect(records.map((record) => record.tags.reason)).toEqual(["other", "other"]);
    expect(JSON.stringify(records)).not.toContain("release");
    expect(JSON.stringify(records)).not.toContain("not found");
  });

  it("classifies lease loss without keeping the run id, and omits a reason on success", () => {
    const { metrics, stored } = telemetry();
    recordScheduleRun(metrics, {
      startedAt: 10,
      now: 10,
      kind: "manual",
      status: "error",
      error: new Error("Schedule run lease was lost: run-9f3a"),
    });
    recordScheduleRun(metrics, { startedAt: 10, now: 12, kind: "manual", status: "ok" });
    const records = stored();
    expect(records.map((record) => record.tags)).toEqual([
      { status: "error", run_kind: "manual", reason: "lease_lost" },
      { status: "ok", run_kind: "manual" },
    ]);
    expect(JSON.stringify(records)).not.toContain("run-9f3a");
  });
});

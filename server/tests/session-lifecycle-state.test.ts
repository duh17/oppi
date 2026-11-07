import { describe, expect, it, vi } from "vitest";

import {
  applyLifecycle,
  lifecyclePhase,
  nextLifecyclePhase,
  type LifecycleEvent,
  type LifecyclePhase,
} from "../src/session-lifecycle-state.js";
import type { Session } from "../src/types.js";

const PHASES: Record<string, LifecyclePhase> = {
  starting: { name: "starting" },
  idle: { name: "idle" },
  running: { name: "running" },
  "aborting(run)": { name: "aborting", run: true },
  aborting: { name: "aborting", run: false },
  "terminating(run)": { name: "terminating", run: true },
  terminating: { name: "terminating", run: false },
  stopped: { name: "stopped" },
  failed: { name: "failed" },
};

const EVENTS: LifecycleEvent[] = [
  "start_begun",
  "start_registered",
  "start_failed",
  "run_started",
  "run_settled",
  "abort_requested",
  "terminate_requested",
  "stop_failed",
  "runtime_ended",
  "launch_failed",
];

const label = (phase: LifecyclePhase | undefined): string => {
  if (!phase) return "—";
  return Object.entries(PHASES).find(
    ([, candidate]) => JSON.stringify(candidate) === JSON.stringify(phase),
  )![0];
};

// Each row: the phase every event leads to, in EVENTS order. "—" is an event the phase ignores.
const EXPECTED: Record<string, string[]> = {
  starting: ["starting", "idle", "stopped", "—", "—", "—", "terminating", "—", "stopped", "failed"],
  idle: [
    "starting",
    "—",
    "—",
    "running",
    "idle",
    "aborting",
    "terminating",
    "—",
    "stopped",
    "failed",
  ],
  running: [
    "starting",
    "—",
    "—",
    "running",
    "idle",
    "aborting(run)",
    "terminating(run)",
    "—",
    "stopped",
    "failed",
  ],
  "aborting(run)": [
    "starting",
    "—",
    "—",
    "aborting(run)",
    "idle",
    "—",
    "terminating(run)",
    "running",
    "stopped",
    "failed",
  ],
  aborting: [
    "starting",
    "—",
    "—",
    "aborting(run)",
    "idle",
    "—",
    "terminating",
    "idle",
    "stopped",
    "failed",
  ],
  "terminating(run)": [
    "starting",
    "—",
    "—",
    "terminating(run)",
    "terminating",
    "—",
    "terminating(run)",
    "running",
    "stopped",
    "failed",
  ],
  terminating: [
    "starting",
    "—",
    "—",
    "terminating(run)",
    "terminating",
    "—",
    "terminating",
    "idle",
    "stopped",
    "failed",
  ],
  stopped: ["starting", "—", "—", "—", "—", "—", "—", "—", "stopped", "failed"],
  failed: [
    "starting",
    "—",
    "—",
    "running",
    "—",
    "aborting",
    "terminating",
    "—",
    "stopped",
    "failed",
  ],
};

function makeSession(status: Session["status"]): Session {
  return {
    id: "s1",
    status,
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
  };
}

describe("session lifecycle transitions", () => {
  it.each(Object.keys(PHASES))("from %s", (name) => {
    const phase = PHASES[name]!;
    expect(EVENTS.map((event) => label(nextLifecyclePhase(phase, event)))).toEqual(EXPECTED[name]);
  });
});

describe("applyLifecycle", () => {
  const markers = () => ({ markRuntimeLive: vi.fn() });

  it("keeps abort and terminate apart while both show stopping", () => {
    const aborted = makeSession("busy");
    applyLifecycle(aborted, "abort_requested");
    const terminated = makeSession("busy");
    applyLifecycle(terminated, "terminate_requested", markers());

    expect([aborted.status, terminated.status]).toEqual(["stopping", "stopping"]);
    applyLifecycle(aborted, "run_settled");
    applyLifecycle(terminated, "run_settled");
    expect([aborted.status, terminated.status]).toEqual(["ready", "stopping"]);
  });

  it("returns a failed stop to the run it interrupted, or to idle", () => {
    const busy = makeSession("busy");
    applyLifecycle(busy, "abort_requested");
    expect(applyLifecycle(busy, "stop_failed", markers())).toBe(true);
    expect(busy.status).toBe("busy");

    const idle = makeSession("ready");
    applyLifecycle(idle, "terminate_requested", markers());
    applyLifecycle(idle, "stop_failed", markers());
    expect(idle.status).toBe("ready");
  });

  it("ignores an event the phase does not allow and leaves the status", () => {
    const stopped = makeSession("stopped");
    expect(applyLifecycle(stopped, "run_started")).toBe(false);
    expect(applyLifecycle(stopped, "run_settled")).toBe(false);
    expect(stopped.status).toBe("stopped");
  });

  it("records a live runtime at its start, a terminate, and a terminate that failed", () => {
    const store = markers();
    const session = makeSession("ready");
    applyLifecycle(session, "start_begun", store);
    applyLifecycle(session, "start_registered");
    applyLifecycle(session, "terminate_requested", store);
    applyLifecycle(session, "stop_failed", store);
    const aborted = makeSession("busy");
    applyLifecycle(aborted, "abort_requested");
    applyLifecycle(aborted, "stop_failed", store);

    expect(store.markRuntimeLive.mock.calls).toEqual([
      ["s1", "live"],
      ["s1", "terminating"],
      ["s1", "live"],
    ]);
  });

  it("lets a status written elsewhere stand for the phase", () => {
    const session = makeSession("busy");
    applyLifecycle(session, "abort_requested");
    expect(lifecyclePhase(session)).toEqual({ name: "aborting", run: true });

    // The e2e UI harness and new rows set a status directly.
    session.status = "ready";
    expect(lifecyclePhase(session)).toEqual({ name: "idle" });
  });
});

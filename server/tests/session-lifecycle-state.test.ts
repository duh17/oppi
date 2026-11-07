import { describe, expect, it } from "vitest";

import {
  applyLifecycle,
  lifecyclePhase,
  nextLifecyclePhase,
  type LifecycleEvent,
  type LifecyclePhase,
} from "../src/session-lifecycle-state.js";
import type { Session } from "../src/types.js";

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

// A stop phase reads `name>back`: `back` is where a failed stop returns.
const label = (phase: LifecyclePhase | undefined): string =>
  !phase ? "—" : "back" in phase ? `${phase.name}>${phase.back}` : phase.name;

const parse = (text: string): LifecyclePhase => {
  const [name, back] = text.split(">");
  return (back ? { name, back } : { name }) as LifecyclePhase;
};

// Each row: the phase every event leads to, in EVENTS order. "—" is an event the phase ignores.
const EXPECTED: Record<string, string> = {
  starting: "starting idle stopped — — — terminating>idle — stopped failed",
  idle: "starting — — running idle aborting>idle terminating>idle — stopped failed",
  running: "starting — — running idle aborting>running terminating>running — stopped failed",
  failed: "starting — — running failed aborting>failed terminating>failed — stopped failed",
  stopped: "starting — — — — — — — stopped failed",
  "aborting>idle": "starting — — aborting>running idle — terminating>idle idle stopped failed",
  "aborting>running":
    "starting — — aborting>running idle — terminating>running running stopped failed",
  "aborting>failed":
    "starting — — aborting>running failed — terminating>failed failed stopped failed",
  "terminating>idle":
    "starting — — terminating>running terminating>idle — terminating>idle idle stopped failed",
  "terminating>running":
    "starting — — terminating>running terminating>idle — terminating>running running stopped failed",
  "terminating>failed":
    "starting — — terminating>running terminating>failed — terminating>failed failed stopped failed",
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
  it.each(Object.keys(EXPECTED))("from %s", (from) => {
    const next = EVENTS.map((event) => label(nextLifecyclePhase(parse(from), event)));
    expect(next.join(" ")).toBe(EXPECTED[from]);
  });
});

describe("applyLifecycle", () => {
  it("keeps abort and terminate apart while both show stopping", () => {
    const aborted = makeSession("busy");
    applyLifecycle(aborted, "abort_requested");
    const terminated = makeSession("busy");
    applyLifecycle(terminated, "terminate_requested");

    expect([aborted.status, terminated.status]).toEqual(["stopping", "stopping"]);
    applyLifecycle(aborted, "run_settled");
    applyLifecycle(terminated, "run_settled");
    expect([aborted.status, terminated.status]).toEqual(["ready", "stopping"]);
  });

  it("returns a failed stop to what the session was doing", () => {
    const busy = makeSession("busy");
    applyLifecycle(busy, "abort_requested");
    expect(applyLifecycle(busy, "stop_failed")).toBe(true);
    expect(busy.status).toBe("busy");

    const idle = makeSession("ready");
    applyLifecycle(idle, "terminate_requested");
    applyLifecycle(idle, "stop_failed");
    expect(idle.status).toBe("ready");

    // A launch failure still stands after a stop of its runtime failed.
    const failed = makeSession("error");
    applyLifecycle(failed, "terminate_requested");
    applyLifecycle(failed, "stop_failed");
    expect(failed.status).toBe("error");
  });

  it("keeps a launch failure through the settle of the turn it failed", () => {
    const session = makeSession("ready");
    applyLifecycle(session, "run_started");
    applyLifecycle(session, "launch_failed");
    expect(applyLifecycle(session, "run_settled")).toBe(false);
    expect(session.status).toBe("error");

    // A new turn clears it.
    applyLifecycle(session, "run_started");
    applyLifecycle(session, "run_settled");
    expect(session.status).toBe("ready");
  });

  it("ignores an event the phase does not allow and leaves the status", () => {
    const stopped = makeSession("stopped");
    expect(applyLifecycle(stopped, "run_started")).toBe(false);
    expect(applyLifecycle(stopped, "run_settled")).toBe(false);
    expect(stopped.status).toBe("stopped");
  });

  it("lets a status written elsewhere stand for the phase", () => {
    const session = makeSession("busy");
    applyLifecycle(session, "abort_requested");
    expect(lifecyclePhase(session)).toEqual({ name: "aborting", back: "running" });

    // The e2e UI harness and new rows set a status directly.
    session.status = "ready";
    expect(lifecyclePhase(session)).toEqual({ name: "idle" });
  });
});

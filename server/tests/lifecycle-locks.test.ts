import { describe, expect, it } from "vitest";
import { WorkspaceRuntime } from "../src/workspace-runtime.js";

const LIMITS = {
  maxSessionsPerWorkspace: 3,
  maxSessionsGlobal: 5,
  sessionIdleTimeoutMs: 10 * 60_000,
  workspaceIdleTimeoutMs: 30 * 60_000,
};

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

describe("WorkspaceRuntime lifecycle locks", () => {
  it("serializes operations on the same workspace", async () => {
    const runtime = new WorkspaceRuntime(LIMITS);
    const events: string[] = [];

    const first = runtime.withWorkspaceLock("w1", async () => {
      events.push("first-start");
      await sleep(20);
      events.push("first-end");
    });

    const second = runtime.withWorkspaceLock("w1", async () => {
      events.push("second-start");
      events.push("second-end");
    });

    await Promise.all([first, second]);

    expect(events).toEqual([
      "first-start",
      "first-end",
      "second-start",
      "second-end",
    ]);
  });

  it("allows workspace operations in different workspaces to run concurrently", async () => {
    const runtime = new WorkspaceRuntime(LIMITS);
    let inFlight = 0;
    let maxInFlight = 0;

    const run = (workspaceId: string) => runtime.withWorkspaceLock(workspaceId, async () => {
      inFlight += 1;
      maxInFlight = Math.max(maxInFlight, inFlight);
      await sleep(20);
      inFlight -= 1;
    });

    await Promise.all([run("w1"), run("w2")]);

    expect(maxInFlight).toBe(2);
  });

  it("serializes operations on the same session", async () => {
    const runtime = new WorkspaceRuntime(LIMITS);
    const events: string[] = [];

    const first = runtime.withSessionLock("s1", async () => {
      events.push("first-start");
      await sleep(15);
      events.push("first-end");
    });

    const second = runtime.withSessionLock("s1", async () => {
      events.push("second-start");
      events.push("second-end");
    });

    await Promise.all([first, second]);

    expect(events).toEqual([
      "first-start",
      "first-end",
      "second-start",
      "second-end",
    ]);
  });
});

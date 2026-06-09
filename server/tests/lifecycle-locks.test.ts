import { describe, expect, it } from "vitest";
import { WorkspaceRuntime } from "../src/workspace-runtime.js";

const LIMITS = {
  maxSessionsPerWorkspace: 3,
  maxSessionsGlobal: 5,
  sessionIdleTimeoutMs: 10 * 60_000,
  workspaceIdleTimeoutMs: 30 * 60_000,
};

function deferred(): { promise: Promise<void>; resolve: () => void } {
  let resolve!: () => void;
  const promise = new Promise<void>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}

async function yieldMicrotasks(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}

describe("WorkspaceRuntime lifecycle locks", () => {
  it("serializes operations on the same workspace", async () => {
    const runtime = new WorkspaceRuntime(LIMITS);
    const events: string[] = [];
    const firstEntered = deferred();
    const releaseFirst = deferred();

    const first = runtime.withWorkspaceLock("w1", async () => {
      events.push("first-start");
      firstEntered.resolve();
      await releaseFirst.promise;
      events.push("first-end");
    });
    await firstEntered.promise;

    const second = runtime.withWorkspaceLock("w1", async () => {
      events.push("second-start");
      events.push("second-end");
    });
    await yieldMicrotasks();

    expect(events).toEqual(["first-start"]);

    releaseFirst.resolve();
    await Promise.all([first, second]);

    expect(events).toEqual(["first-start", "first-end", "second-start", "second-end"]);
  });

  it("allows workspace operations in different workspaces to run concurrently", async () => {
    const runtime = new WorkspaceRuntime(LIMITS);
    const releaseBoth = deferred();
    const firstEntered = deferred();
    const secondEntered = deferred();
    let inFlight = 0;
    let maxInFlight = 0;

    const run = (workspaceId: string, entered: () => void) =>
      runtime.withWorkspaceLock(workspaceId, async () => {
        inFlight += 1;
        maxInFlight = Math.max(maxInFlight, inFlight);
        entered();
        await releaseBoth.promise;
        inFlight -= 1;
      });

    const first = run("w1", firstEntered.resolve);
    const second = run("w2", secondEntered.resolve);

    await Promise.all([firstEntered.promise, secondEntered.promise]);
    expect(maxInFlight).toBe(2);

    releaseBoth.resolve();
    await Promise.all([first, second]);
    expect(inFlight).toBe(0);
  });

  it("serializes operations on the same session", async () => {
    const runtime = new WorkspaceRuntime(LIMITS);
    const events: string[] = [];
    const firstEntered = deferred();
    const releaseFirst = deferred();

    const first = runtime.withSessionLock("s1", async () => {
      events.push("first-start");
      firstEntered.resolve();
      await releaseFirst.promise;
      events.push("first-end");
    });
    await firstEntered.promise;

    const second = runtime.withSessionLock("s1", async () => {
      events.push("second-start");
      events.push("second-end");
    });
    await yieldMicrotasks();

    expect(events).toEqual(["first-start"]);

    releaseFirst.resolve();
    await Promise.all([first, second]);

    expect(events).toEqual(["first-start", "first-end", "second-start", "second-end"]);
  });
});

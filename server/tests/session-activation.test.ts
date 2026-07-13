import { describe, expect, it, vi } from "vitest";

import { SessionActivationCoordinator } from "../src/session-activation.js";
import { WorkspaceRuntime } from "../src/workspace-runtime.js";
import type { Session } from "../src/types.js";

function makeSession(): Session {
  return {
    id: "sess-1",
    workspaceId: "ws-1",
    status: "ready",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
  };
}

describe("SessionActivationCoordinator", () => {
  it("coalesces duplicate resume and open activation while startup is in flight", async () => {
    const session = makeSession();
    let active: { session: Session } | undefined;
    let finishStart: (() => void) | undefined;
    const startSessionInner = vi.fn(
      () =>
        new Promise<Session>((resolve) => {
          finishStart = () => {
            active = { session };
            resolve(session);
          };
        }),
    );
    const resetIdleTimer = vi.fn();
    const coordinator = new SessionActivationCoordinator({
      runtimeManager: new WorkspaceRuntime(),
      getActiveSession: () => active,
      resetIdleTimer,
      startSessionInner,
    });

    const resume = coordinator.startSession("sess-1", "sess-1");
    const open = coordinator.startSession("sess-1", "sess-1");
    await Promise.resolve();

    expect(startSessionInner).toHaveBeenCalledOnce();
    expect(finishStart).toBeDefined();

    finishStart?.();
    await expect(Promise.all([resume, open])).resolves.toEqual([session, session]);
    expect(startSessionInner).toHaveBeenCalledOnce();

    await expect(coordinator.startSession("sess-1", "sess-1")).resolves.toBe(session);
    expect(startSessionInner).toHaveBeenCalledOnce();
    expect(resetIdleTimer).toHaveBeenCalledOnce();
  });
});

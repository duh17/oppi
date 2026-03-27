import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import type { Session } from "./types.js";
import type {
  SessionLifecycleCoordinatorDeps,
  SessionLifecycleSessionState,
} from "./session-lifecycle.js";
import { SessionLifecycleCoordinator } from "./session-lifecycle.js";

// ─── Factories ───

function makeSession(overrides?: Partial<Session>): Session {
  return {
    id: "child-1",
    status: "ready",
    createdAt: Date.now(),
    lastActivity: Date.now(),
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

function makeActiveSession(
  overrides?: Partial<Session>,
  extraState?: { outputTokensAtStart?: number },
): SessionLifecycleSessionState {
  const session = makeSession(overrides);
  return {
    session,
    sdkBackend: { isDisposed: false, dispose: vi.fn() } as never,
    workspaceId: "ws-1",
    pendingUIRequests: new Map(),
    outputTokensAtStart: extraState?.outputTokensAtStart ?? 0,
  };
}

function makeDeps(
  active: SessionLifecycleSessionState | undefined,
  overrides?: Partial<SessionLifecycleCoordinatorDeps>,
): SessionLifecycleCoordinatorDeps {
  return {
    getActiveSession: vi.fn(() => active),
    removeActiveSession: vi.fn(),
    clearPendingStop: vi.fn(() => null),
    broadcast: vi.fn(),
    persistSessionNow: vi.fn(),
    destroySessionGuard: vi.fn(),
    releaseSession: vi.fn(),
    stopSession: vi.fn(async () => {}),
    getSessionIdleTimeoutMs: () => 300_000,
    getChildAutoStopWhenDone: () => true,
    getChildStartupGraceMs: () => 60_000,
    hasActiveChildren: vi.fn(() => false),
    ...overrides,
  };
}

// ─── Tests ───

describe("SessionLifecycleCoordinator.resetIdleTimer", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("does NOT immediately kill a child with messageCount>0 but no output tokens", () => {
    // This is the exact bug: sendPrompt increments messageCount before the SDK
    // processes the prompt, so resetIdleTimer sees messageCount > 0 while the
    // agent hasn't started yet.
    const active = makeActiveSession({
      parentSessionId: "parent-1",
      status: "ready",
      messageCount: 2,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    });
    const deps = makeDeps(active);
    const coordinator = new SessionLifecycleCoordinator(deps);

    coordinator.resetIdleTimer("key");

    // Immediate setTimeout(0) must NOT fire
    vi.advanceTimersByTime(0);
    expect(deps.stopSession).not.toHaveBeenCalled();

    // Should still be alive after 30 seconds
    vi.advanceTimersByTime(30_000);
    expect(deps.stopSession).not.toHaveBeenCalled();

    // Grace period (60s) expires → stop
    vi.advanceTimersByTime(30_000);
    expect(deps.stopSession).toHaveBeenCalledWith("child-1");
  });

  it("immediately stops a child that has produced output tokens since start", () => {
    const active = makeActiveSession(
      {
        parentSessionId: "parent-1",
        status: "ready",
        messageCount: 4,
        tokens: { input: 1000, output: 500, cacheRead: 0, cacheWrite: 0 },
      },
      { outputTokensAtStart: 0 },
    );
    const deps = makeDeps(active);
    const coordinator = new SessionLifecycleCoordinator(deps);

    coordinator.resetIdleTimer("key");

    vi.advanceTimersByTime(0);
    expect(deps.stopSession).toHaveBeenCalledWith("child-1");
  });

  it("does NOT auto-stop a resumed child that has not done new work", () => {
    // Child had 500 output tokens before being stopped, then was resumed.
    // outputTokensAtStart matches current output — no new work done yet.
    const active = makeActiveSession(
      {
        parentSessionId: "parent-1",
        status: "ready",
        messageCount: 4,
        tokens: { input: 1000, output: 500, cacheRead: 0, cacheWrite: 0 },
      },
      { outputTokensAtStart: 500 },
    );
    const deps = makeDeps(active);
    const coordinator = new SessionLifecycleCoordinator(deps);

    coordinator.resetIdleTimer("key");

    // Should NOT immediately stop — no new work since resume
    vi.advanceTimersByTime(0);
    expect(deps.stopSession).not.toHaveBeenCalled();

    // Should use grace period instead
    vi.advanceTimersByTime(59_999);
    expect(deps.stopSession).not.toHaveBeenCalled();

    vi.advanceTimersByTime(1);
    expect(deps.stopSession).toHaveBeenCalledWith("child-1");
  });

  it("auto-stops a resumed child after it completes new work", () => {
    // Child had 500 output tokens at resume, now has 800 — did new work.
    const active = makeActiveSession(
      {
        parentSessionId: "parent-1",
        status: "ready",
        messageCount: 6,
        tokens: { input: 2000, output: 800, cacheRead: 0, cacheWrite: 0 },
      },
      { outputTokensAtStart: 500 },
    );
    const deps = makeDeps(active);
    const coordinator = new SessionLifecycleCoordinator(deps);

    coordinator.resetIdleTimer("key");

    vi.advanceTimersByTime(0);
    expect(deps.stopSession).toHaveBeenCalledWith("child-1");
  });

  it("uses 60s grace for a child with messageCount=0", () => {
    const active = makeActiveSession({
      parentSessionId: "parent-1",
      status: "ready",
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    });
    const deps = makeDeps(active);
    const coordinator = new SessionLifecycleCoordinator(deps);

    coordinator.resetIdleTimer("key");

    vi.advanceTimersByTime(59_999);
    expect(deps.stopSession).not.toHaveBeenCalled();

    vi.advanceTimersByTime(1);
    expect(deps.stopSession).toHaveBeenCalledWith("child-1");
  });

  it("does NOT auto-stop a busy child", () => {
    const active = makeActiveSession({
      parentSessionId: "parent-1",
      status: "busy",
      messageCount: 2,
      tokens: { input: 100, output: 50, cacheRead: 0, cacheWrite: 0 },
    });
    const deps = makeDeps(active);
    const coordinator = new SessionLifecycleCoordinator(deps);

    coordinator.resetIdleTimer("key");

    // Should fall through to the normal idle timeout path
    vi.advanceTimersByTime(60_000);
    expect(deps.stopSession).not.toHaveBeenCalled();

    // Normal idle timeout (300s from makeDeps) eventually fires
    vi.advanceTimersByTime(240_000);
    expect(deps.stopSession).toHaveBeenCalledWith("child-1");
  });

  it("does NOT auto-stop a non-child session on idle", () => {
    const active = makeActiveSession({
      status: "ready",
      messageCount: 5,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    });
    // No parentSessionId
    const deps = makeDeps(active);
    const coordinator = new SessionLifecycleCoordinator(deps);

    coordinator.resetIdleTimer("key");

    // Should use normal idle timeout, not the child auto-stop
    vi.advanceTimersByTime(60_000);
    expect(deps.stopSession).not.toHaveBeenCalled();

    vi.advanceTimersByTime(240_000);
    expect(deps.stopSession).toHaveBeenCalledWith("child-1");
  });

  it("does NOT auto-stop a completed child when autoStopWhenDone is false", () => {
    const active = makeActiveSession(
      {
        parentSessionId: "parent-1",
        status: "ready",
        messageCount: 4,
        tokens: { input: 1000, output: 500, cacheRead: 0, cacheWrite: 0 },
      },
      { outputTokensAtStart: 0 },
    );
    const deps = makeDeps(active, {
      getChildAutoStopWhenDone: () => false,
    });
    const coordinator = new SessionLifecycleCoordinator(deps);

    coordinator.resetIdleTimer("key");

    // Should NOT immediately stop — autoStopWhenDone is false
    vi.advanceTimersByTime(0);
    expect(deps.stopSession).not.toHaveBeenCalled();

    // Should fall through to normal idle timeout (300s from makeDeps)
    vi.advanceTimersByTime(299_999);
    expect(deps.stopSession).not.toHaveBeenCalled();

    vi.advanceTimersByTime(1);
    expect(deps.stopSession).toHaveBeenCalledWith("child-1");
  });

  it("uses configured startupGraceMs instead of hardcoded 60s", () => {
    const active = makeActiveSession({
      parentSessionId: "parent-1",
      status: "ready",
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    });
    const deps = makeDeps(active, {
      getChildStartupGraceMs: () => 30_000, // 30s instead of 60s
    });
    const coordinator = new SessionLifecycleCoordinator(deps);

    coordinator.resetIdleTimer("key");

    // Should NOT stop at 29s
    vi.advanceTimersByTime(29_999);
    expect(deps.stopSession).not.toHaveBeenCalled();

    // Should stop at 30s
    vi.advanceTimersByTime(1);
    expect(deps.stopSession).toHaveBeenCalledWith("child-1");
  });

  it("clears previous timer on reset", () => {
    const active = makeActiveSession({
      parentSessionId: "parent-1",
      status: "ready",
      messageCount: 0,
    });
    const deps = makeDeps(active);
    const coordinator = new SessionLifecycleCoordinator(deps);

    // Set first timer
    coordinator.resetIdleTimer("key");

    // Advance 50s, then reset
    vi.advanceTimersByTime(50_000);
    expect(deps.stopSession).not.toHaveBeenCalled();

    coordinator.resetIdleTimer("key");

    // Another 50s — old timer would have fired at 60s, but was cleared
    vi.advanceTimersByTime(50_000);
    expect(deps.stopSession).not.toHaveBeenCalled();

    // 10 more seconds → new timer's 60s expires
    vi.advanceTimersByTime(10_000);
    expect(deps.stopSession).toHaveBeenCalledWith("child-1");
  });

  it("defers idle timeout when parent has active children", () => {
    const active = makeActiveSession({
      status: "ready",
      messageCount: 10,
      tokens: { input: 5000, output: 2000, cacheRead: 0, cacheWrite: 0 },
    });
    // No parentSessionId — this is a root session
    const deps = makeDeps(active, {
      hasActiveChildren: vi.fn(() => true),
    });
    const coordinator = new SessionLifecycleCoordinator(deps);

    coordinator.resetIdleTimer("key");

    // Normal idle timeout (300s) fires but should be deferred
    vi.advanceTimersByTime(300_000);
    expect(deps.stopSession).not.toHaveBeenCalled();
    expect(deps.hasActiveChildren).toHaveBeenCalledWith("child-1");
  });

  it("stops parent after children finish", () => {
    const active = makeActiveSession({
      status: "ready",
      messageCount: 10,
      tokens: { input: 5000, output: 2000, cacheRead: 0, cacheWrite: 0 },
    });
    // No parentSessionId — root session
    let childrenActive = true;
    const deps = makeDeps(active, {
      hasActiveChildren: vi.fn(() => childrenActive),
    });
    const coordinator = new SessionLifecycleCoordinator(deps);

    coordinator.resetIdleTimer("key");

    // First timeout fires → children active → deferred
    vi.advanceTimersByTime(300_000);
    expect(deps.stopSession).not.toHaveBeenCalled();

    // Children finish
    childrenActive = false;

    // Second timeout fires → no children → stops
    vi.advanceTimersByTime(300_000);
    expect(deps.stopSession).toHaveBeenCalledWith("child-1");
  });
});

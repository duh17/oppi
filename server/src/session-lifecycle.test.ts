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

function makeActiveSession(overrides?: Partial<Session>): SessionLifecycleSessionState {
  return {
    session: makeSession(overrides),
    sdkBackend: { isDisposed: false, dispose: vi.fn() } as never,
    workspaceId: "ws-1",
    pendingUIRequests: new Map(),
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

  it("immediately stops a child that has produced output tokens", () => {
    const active = makeActiveSession({
      parentSessionId: "parent-1",
      status: "ready",
      messageCount: 4,
      tokens: { input: 1000, output: 500, cacheRead: 0, cacheWrite: 0 },
    });
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

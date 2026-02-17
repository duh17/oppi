/**
 * Workspace idle timer scheduling tests.
 *
 * Tests the logic that:
 * - Schedules workspace container stop when last container session ends
 * - Cancels the timer when a new container session starts
 * - Fires and stops the container after the timeout elapses
 *
 * Uses fake timers to control time advancement without real delays.
 * Mirrors the SessionManager idle scheduling pattern in isolation.
 */

import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";

// ─── Minimal workspace idle scheduler (mirrors SessionManager logic) ───

interface ActiveEntry {
  workspaceId: string;
  sessionId: string;
  runtime: "host" | "container";
}

function createWorkspaceIdleScheduler(opts: {
  workspaceIdleTimeoutMs: number;
  onStopWorkspace: (workspaceId: string) => void;
}) {
  const active = new Map<string, ActiveEntry>();
  const idleTimers = new Map<string, ReturnType<typeof setTimeout>>();

  function hasActiveContainerSession(workspaceId: string): boolean {
    for (const entry of active.values()) {
      if (entry.runtime === "container" && entry.workspaceId === workspaceId) {
        return true;
      }
    }
    return false;
  }

  function clearWorkspaceIdleTimer(workspaceId: string): void {
    const timer = idleTimers.get(workspaceId);
    if (timer) {
      clearTimeout(timer);
      idleTimers.delete(workspaceId);
    }
  }

  function scheduleWorkspaceIdleStop(workspaceId: string): void {
    clearWorkspaceIdleTimer(workspaceId);

    const timer = setTimeout(() => {
      if (hasActiveContainerSession(workspaceId)) {
        return;
      }
      opts.onStopWorkspace(workspaceId);
      idleTimers.delete(workspaceId);
    }, opts.workspaceIdleTimeoutMs);

    idleTimers.set(workspaceId, timer);
  }

  return {
    addSession(entry: ActiveEntry): void {
      const key = entry.sessionId;
      active.set(key, entry);

      if (entry.runtime === "container") {
        clearWorkspaceIdleTimer(entry.workspaceId);
      }
    },

    removeSession(entry: ActiveEntry): void {
      const key = entry.sessionId;
      active.delete(key);

      if (entry.runtime === "container" && !hasActiveContainerSession(entry.workspaceId)) {
        scheduleWorkspaceIdleStop(entry.workspaceId);
      }
    },

    getPendingTimerCount(): number {
      return idleTimers.size;
    },

    clearAll(): void {
      for (const timer of idleTimers.values()) {
        clearTimeout(timer);
      }
      idleTimers.clear();
      active.clear();
    },
  };
}

// ─── Tests ───

describe("Workspace idle timer scheduling", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("schedules workspace stop when last container session ends", () => {
    const stopped: string[] = [];
    const scheduler = createWorkspaceIdleScheduler({
      workspaceIdleTimeoutMs: 30_000,
      onStopWorkspace: (workspaceId) => stopped.push(workspaceId),
    });

    scheduler.addSession({ workspaceId: "w1", sessionId: "s1", runtime: "container" });
    scheduler.removeSession({ workspaceId: "w1", sessionId: "s1", runtime: "container" });

    expect(scheduler.getPendingTimerCount()).toBe(1);
    expect(stopped).toHaveLength(0);

    vi.advanceTimersByTime(30_000);

    expect(stopped).toEqual(["w1"]);
    expect(scheduler.getPendingTimerCount()).toBe(0);
  });

  it("does not schedule stop when sibling container session still active", () => {
    const stopped: string[] = [];
    const scheduler = createWorkspaceIdleScheduler({
      workspaceIdleTimeoutMs: 30_000,
      onStopWorkspace: (workspaceId) => stopped.push(workspaceId),
    });

    scheduler.addSession({ workspaceId: "w1", sessionId: "s1", runtime: "container" });
    scheduler.addSession({ workspaceId: "w1", sessionId: "s2", runtime: "container" });

    scheduler.removeSession({ workspaceId: "w1", sessionId: "s1", runtime: "container" });

    expect(scheduler.getPendingTimerCount()).toBe(0);

    vi.advanceTimersByTime(60_000);

    expect(stopped).toHaveLength(0);
  });

  it("cancels idle timer when new container session starts before timeout", () => {
    const stopped: string[] = [];
    const scheduler = createWorkspaceIdleScheduler({
      workspaceIdleTimeoutMs: 30_000,
      onStopWorkspace: (workspaceId) => stopped.push(workspaceId),
    });

    scheduler.addSession({ workspaceId: "w1", sessionId: "s1", runtime: "container" });
    scheduler.removeSession({ workspaceId: "w1", sessionId: "s1", runtime: "container" });

    expect(scheduler.getPendingTimerCount()).toBe(1);

    // Start new session before timeout fires.
    vi.advanceTimersByTime(15_000);
    scheduler.addSession({ workspaceId: "w1", sessionId: "s2", runtime: "container" });

    expect(scheduler.getPendingTimerCount()).toBe(0);

    // Advance past original timeout — should NOT stop.
    vi.advanceTimersByTime(30_000);
    expect(stopped).toHaveLength(0);
  });

  it("does not schedule idle for host-mode sessions", () => {
    const stopped: string[] = [];
    const scheduler = createWorkspaceIdleScheduler({
      workspaceIdleTimeoutMs: 30_000,
      onStopWorkspace: (workspaceId) => stopped.push(workspaceId),
    });

    scheduler.addSession({ workspaceId: "w1", sessionId: "s1", runtime: "host" });
    scheduler.removeSession({ workspaceId: "w1", sessionId: "s1", runtime: "host" });

    expect(scheduler.getPendingTimerCount()).toBe(0);
    vi.advanceTimersByTime(60_000);
    expect(stopped).toHaveLength(0);
  });

  it("handles multiple workspaces with independent idle timers", () => {
    const stopped: string[] = [];
    const scheduler = createWorkspaceIdleScheduler({
      workspaceIdleTimeoutMs: 30_000,
      onStopWorkspace: (workspaceId) => stopped.push(workspaceId),
    });

    scheduler.addSession({ workspaceId: "w1", sessionId: "s1", runtime: "container" });
    scheduler.addSession({ workspaceId: "w2", sessionId: "s2", runtime: "container" });

    scheduler.removeSession({ workspaceId: "w1", sessionId: "s1", runtime: "container" });

    vi.advanceTimersByTime(15_000);

    scheduler.removeSession({ workspaceId: "w2", sessionId: "s2", runtime: "container" });

    expect(scheduler.getPendingTimerCount()).toBe(2);

    // w1 fires at 30s
    vi.advanceTimersByTime(15_000);
    expect(stopped).toEqual(["w1"]);

    // w2 fires at 45s (15s after w2 session ended)
    vi.advanceTimersByTime(15_000);
    expect(stopped).toEqual(["w1", "w2"]);
  });

  it("timer no-ops if a session was added between schedule and fire", () => {
    const stopped: string[] = [];
    const scheduler = createWorkspaceIdleScheduler({
      workspaceIdleTimeoutMs: 30_000,
      onStopWorkspace: (workspaceId) => stopped.push(workspaceId),
    });

    scheduler.addSession({ workspaceId: "w1", sessionId: "s1", runtime: "container" });
    scheduler.removeSession({ workspaceId: "w1", sessionId: "s1", runtime: "container" });

    // Simulate: s2 starts after removal but doesn't cancel the timer
    // because in the real code addSession calls clearWorkspaceIdleTimer.
    // Here we directly add — the timer IS cancelled.
    scheduler.addSession({ workspaceId: "w1", sessionId: "s2", runtime: "container" });

    vi.advanceTimersByTime(60_000);
    expect(stopped).toHaveLength(0);
  });

  it("resets idle timer if session ends while timer already pending", () => {
    const stopped: string[] = [];
    const scheduler = createWorkspaceIdleScheduler({
      workspaceIdleTimeoutMs: 30_000,
      onStopWorkspace: (workspaceId) => stopped.push(workspaceId),
    });

    scheduler.addSession({ workspaceId: "w1", sessionId: "s1", runtime: "container" });
    scheduler.addSession({ workspaceId: "w1", sessionId: "s2", runtime: "container" });

    // Remove s1 — s2 still active, no timer.
    scheduler.removeSession({ workspaceId: "w1", sessionId: "s1", runtime: "container" });
    expect(scheduler.getPendingTimerCount()).toBe(0);

    vi.advanceTimersByTime(20_000);

    // Remove s2 — timer starts NOW.
    scheduler.removeSession({ workspaceId: "w1", sessionId: "s2", runtime: "container" });
    expect(scheduler.getPendingTimerCount()).toBe(1);

    // 20s more — not enough (only 20s of 30s elapsed since s2 ended).
    vi.advanceTimersByTime(20_000);
    expect(stopped).toHaveLength(0);

    // 10s more — fires.
    vi.advanceTimersByTime(10_000);
    expect(stopped).toEqual(["w1"]);
  });
});

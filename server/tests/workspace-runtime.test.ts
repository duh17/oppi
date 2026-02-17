import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  Mutex,
  WorkspaceRuntime,
  WorkspaceRuntimeError,
  resolveRuntimeLimits,
  type WorkspaceSessionIdentity,
  type RuntimeLimits,
} from "../src/workspace-runtime.js";
import type { ServerConfig } from "../src/types.js";

// ─── Helpers ───

const W = "ws-1";
const W2 = "ws-2";

function id(workspaceId: string, sessionId: string): WorkspaceSessionIdentity {
  return { workspaceId, sessionId };
}

// ─── Mutex ───

describe("Mutex", () => {
  it("serializes access", async () => {
    const mutex = new Mutex();
    const order: number[] = [];

    const release = await mutex.acquire();
    expect(mutex.isLocked).toBe(true);

    // Queue two waiters
    const p1 = mutex.acquire().then((rel) => { order.push(1); rel(); });
    const p2 = mutex.acquire().then((rel) => { order.push(2); rel(); });

    expect(mutex.queueLength).toBe(2);

    // Release — waiters execute in FIFO order
    release();
    await Promise.all([p1, p2]);

    expect(order).toEqual([1, 2]);
    expect(mutex.isLocked).toBe(false);
  });

  it("withLock releases on success", async () => {
    const mutex = new Mutex();
    const result = await mutex.withLock(async () => 42);
    expect(result).toBe(42);
    expect(mutex.isLocked).toBe(false);
  });

  it("withLock releases on error", async () => {
    const mutex = new Mutex();
    await expect(
      mutex.withLock(async () => { throw new Error("boom"); }),
    ).rejects.toThrow("boom");
    expect(mutex.isLocked).toBe(false);
  });

  it("handles high contention", async () => {
    const mutex = new Mutex();
    const results: number[] = [];

    await Promise.all(
      Array.from({ length: 20 }, (_, i) =>
        mutex.withLock(async () => { results.push(i); }),
      ),
    );

    // All 20 ran, in order (FIFO queue)
    expect(results).toEqual(Array.from({ length: 20 }, (_, i) => i));
  });
});

// ─── resolveRuntimeLimits ───

describe("resolveRuntimeLimits", () => {
  it("applies defaults for missing config fields", () => {
    const config = {
      port: 7749,
      host: "0.0.0.0",
      dataDir: "/tmp",
      defaultModel: "sonnet",
      sessionTimeout: 0,
    } as ServerConfig;

    const limits = resolveRuntimeLimits(config);

    expect(limits.maxSessionsPerWorkspace).toBe(3);
    expect(limits.maxSessionsGlobal).toBe(5);
    expect(limits.sessionIdleTimeoutMs).toBe(600_000);
    expect(limits.workspaceIdleTimeoutMs).toBe(1_800_000);
  });

  it("uses config values when present", () => {
    const config = {
      port: 7749,
      host: "0.0.0.0",
      dataDir: "/tmp",
      defaultModel: "sonnet",
      sessionTimeout: 0,
      maxSessionsPerWorkspace: 5,
      maxSessionsGlobal: 10,
      sessionIdleTimeoutMs: 30_000,
      workspaceIdleTimeoutMs: 60_000,
    } as ServerConfig;

    const limits = resolveRuntimeLimits(config);

    expect(limits.maxSessionsPerWorkspace).toBe(5);
    expect(limits.maxSessionsGlobal).toBe(10);
    expect(limits.sessionIdleTimeoutMs).toBe(30_000);
    expect(limits.workspaceIdleTimeoutMs).toBe(60_000);
  });
});

// ─── WorkspaceRuntime ───

describe("WorkspaceRuntime", () => {
  let rt: WorkspaceRuntime;

  beforeEach(() => {
    rt = new WorkspaceRuntime();
  });

  // ─── Slot Tracking ───

  describe("slot tracking", () => {
    it("reserves and counts a session slot", () => {
      rt.reserveSessionStart(id(W, "s1"));
      expect(rt.getWorkspaceSessionCount(W)).toBe(1);
      expect(rt.globalSessionCount).toBe(1);
    });

    it("tracks multiple sessions in one workspace", () => {
      rt.reserveSessionStart(id(W, "s1"));
      rt.reserveSessionStart(id(W, "s2"));
      expect(rt.getWorkspaceSessionCount(W)).toBe(2);
      expect(rt.globalSessionCount).toBe(2);
    });

    it("tracks sessions across workspaces", () => {
      rt.reserveSessionStart(id(W, "s1"));
      rt.reserveSessionStart(id(W2, "s2"));
      expect(rt.getWorkspaceSessionCount(W)).toBe(1);
      expect(rt.getWorkspaceSessionCount(W2)).toBe(1);
      expect(rt.globalSessionCount).toBe(2);
    });

    it("releases a session slot", () => {
      rt.reserveSessionStart(id(W, "s1"));
      rt.releaseSession(id(W, "s1"));
      expect(rt.getWorkspaceSessionCount(W)).toBe(0);
      expect(rt.globalSessionCount).toBe(0);
    });

    it("release is idempotent", () => {
      rt.reserveSessionStart(id(W, "s1"));
      rt.releaseSession(id(W, "s1"));
      rt.releaseSession(id(W, "s1")); // no throw
      expect(rt.getWorkspaceSessionCount(W)).toBe(0);
    });

    it("release of unknown session is safe", () => {
      rt.releaseSession(id(W, "nonexistent")); // no throw
    });

    it("markSessionReady is a noop (no error)", () => {
      rt.reserveSessionStart(id(W, "s1"));
      rt.markSessionReady(id(W, "s1")); // no throw
    });

    it("rejects duplicate reservation", () => {
      rt.reserveSessionStart(id(W, "s1"));
      expect(() => rt.reserveSessionStart(id(W, "s1"))).toThrow("already reserved");
    });
  });

  // ─── Limits ───

  describe("session limits", () => {
    it("enforces per-workspace limit", () => {
      rt = new WorkspaceRuntime({ maxSessionsPerWorkspace: 2 });
      rt.reserveSessionStart(id(W, "s1"));
      rt.reserveSessionStart(id(W, "s2"));

      expect(() => rt.reserveSessionStart(id(W, "s3"))).toThrow("Workspace session limit");
      // Different workspace is fine
      rt.reserveSessionStart(id(W2, "s3"));
    });

    it("enforces global limit", () => {
      rt = new WorkspaceRuntime({ maxSessionsGlobal: 2 });
      rt.reserveSessionStart(id(W, "s1"));
      rt.reserveSessionStart(id(W2, "s2"));

      expect(() => rt.reserveSessionStart(id(W, "s3"))).toThrow("Global session limit");
    });

    it("released slots free up capacity", () => {
      rt = new WorkspaceRuntime({ maxSessionsPerWorkspace: 1 });
      rt.reserveSessionStart(id(W, "s1"));
      rt.releaseSession(id(W, "s1"));

      // Should work now
      rt.reserveSessionStart(id(W, "s2"));
      expect(rt.getWorkspaceSessionCount(W)).toBe(1);
    });

    it("workspace limit checked before global limit", () => {
      rt = new WorkspaceRuntime({ maxSessionsPerWorkspace: 1, maxSessionsGlobal: 10 });
      rt.reserveSessionStart(id(W, "s1"));

      const err = (() => {
        try { rt.reserveSessionStart(id(W, "s2")); }
        catch (e) { return e; }
      })();
      expect(err).toBeInstanceOf(WorkspaceRuntimeError);
      expect((err as WorkspaceRuntimeError).code).toBe("SESSION_LIMIT_WORKSPACE");
    });
  });

  // ─── Locks ───

  describe("locks", () => {
    it("withSessionLock serializes same-session operations", async () => {
      const order: number[] = [];

      const p1 = rt.withSessionLock("s1", async () => {
        await new Promise((r) => setTimeout(r, 10));
        order.push(1);
      });

      const p2 = rt.withSessionLock("s1", async () => {
        order.push(2);
      });

      await Promise.all([p1, p2]);
      expect(order).toEqual([1, 2]);
    });

    it("withSessionLock allows parallel for different sessions", async () => {
      const order: number[] = [];

      const p1 = rt.withSessionLock("s1", async () => {
        await new Promise((r) => setTimeout(r, 20));
        order.push(1);
      });

      const p2 = rt.withSessionLock("s2", async () => {
        order.push(2);
      });

      await Promise.all([p1, p2]);
      // s2 should finish first since it doesn't wait
      expect(order).toEqual([2, 1]);
    });

    it("withWorkspaceLock serializes same-workspace operations", async () => {
      const order: number[] = [];

      const p1 = rt.withWorkspaceLock(W, async () => {
        await new Promise((r) => setTimeout(r, 10));
        order.push(1);
      });

      const p2 = rt.withWorkspaceLock(W, async () => {
        order.push(2);
      });

      await Promise.all([p1, p2]);
      expect(order).toEqual([1, 2]);
    });

    it("withWorkspaceLock allows parallel for different workspaces", async () => {
      const order: number[] = [];

      const p1 = rt.withWorkspaceLock(W, async () => {
        await new Promise((r) => setTimeout(r, 20));
        order.push(1);
      });

      const p2 = rt.withWorkspaceLock(W2, async () => {
        order.push(2);
      });

      await Promise.all([p1, p2]);
      expect(order).toEqual([2, 1]);
    });

    it("lock is released on error", async () => {
      await expect(
        rt.withSessionLock("s1", async () => { throw new Error("oops"); }),
      ).rejects.toThrow("oops");

      // Lock released — second call should succeed immediately
      const result = await rt.withSessionLock("s1", async () => "ok");
      expect(result).toBe("ok");
    });
  });

  // ─── Config ───

  describe("getLimits", () => {
    it("returns configured limits", () => {
      rt = new WorkspaceRuntime({
        maxSessionsPerWorkspace: 7,
        sessionIdleTimeoutMs: 42_000,
      });

      const limits = rt.getLimits();
      expect(limits.maxSessionsPerWorkspace).toBe(7);
      expect(limits.sessionIdleTimeoutMs).toBe(42_000);
      // Defaults for unset
      expect(limits.maxSessionsGlobal).toBe(5);
      expect(limits.workspaceIdleTimeoutMs).toBe(1_800_000);
    });

    it("returns defaults with no config", () => {
      const limits = rt.getLimits();
      expect(limits.maxSessionsPerWorkspace).toBe(3);
      expect(limits.maxSessionsGlobal).toBe(5);
    });
  });

  // ─── Queries ───

  describe("queries", () => {
    it("getWorkspaceSessionCount returns 0 for unknown workspace", () => {
      expect(rt.getWorkspaceSessionCount("unknown")).toBe(0);
    });

    it("globalSessionCount returns 0 initially", () => {
      expect(rt.globalSessionCount).toBe(0);
    });

    it("cleans up workspace slot set when last session released", () => {
      rt.reserveSessionStart(id(W, "s1"));
      rt.releaseSession(id(W, "s1"));

      // Internal: workspace key should be cleaned up (tested via count)
      expect(rt.getWorkspaceSessionCount(W)).toBe(0);
    });
  });
});

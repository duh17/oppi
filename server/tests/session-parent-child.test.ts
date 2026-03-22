/**
 * Parent-child session relationship tests.
 *
 * Tests the data layer for parent-child session trees:
 * - listChildSessions filtering
 * - parentSessionId persistence
 * - Orphan/detached behavior
 * - Session lifecycle with children (idle guard gap)
 *
 * Note: spawnChildSession/spawnDetachedSession require a full GateServer + SDK
 * process and are tested via spawn-agent-extension.test.ts (64 tests through
 * the mock context). These tests focus on the storage + query layer.
 */

import { existsSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { EventRing } from "../src/event-ring.js";
import { SessionManager } from "../src/sessions.js";
import { TurnDedupeCache } from "../src/turn-cache.js";
import type { GateServer } from "../src/gate.js";
import type { Storage } from "../src/storage.js";
import type { ServerConfig, ServerMessage, Session, Workspace } from "../src/types.js";

// ── Test config ──

const TEST_DATA_DIR = join("/tmp", `oppi-parent-child-tests-${process.pid}`);

const TEST_CONFIG: ServerConfig = {
  port: 7749,
  host: "127.0.0.1",
  dataDir: TEST_DATA_DIR,
  defaultModel: "anthropic/claude-sonnet-4-0",
  sessionTimeout: 600_000,
  sessionIdleTimeoutMs: 600_000,
  workspaceIdleTimeoutMs: 1_800_000,
  maxSessionsPerWorkspace: 10,
  maxSessionsGlobal: 20,
};

// ── Helpers ──

let nextId = 1;

function makeSession(overrides: Partial<Session> = {}): Session {
  const id = overrides.id ?? `s${nextId++}`;
  const now = Date.now();
  return {
    id,
    workspaceId: "w1",
    workspaceName: "Test Workspace",
    status: "busy",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

function makeWorkspace(id = "w1"): Workspace {
  return {
    id,
    name: "Test Workspace",
    createdAt: Date.now(),
    status: "ready",
    hostMount: "~/workspace/test",
  };
}

/**
 * In-memory storage mock that behaves like the real Storage for session CRUD.
 * Does NOT persist to disk — all state is in-memory maps.
 */
function makeInMemoryStorage(): Storage & {
  _sessions: Map<string, Session>;
  _workspaces: Map<string, Workspace>;
} {
  const sessions = new Map<string, Session>();
  const workspaces = new Map<string, Workspace>();

  return {
    _sessions: sessions,
    _workspaces: workspaces,
    getConfig: () => TEST_CONFIG,
    createSession(name?: string, model?: string): Session {
      const s = makeSession({ id: `gen-${nextId++}`, name, model, status: "starting" });
      sessions.set(s.id, s);
      return s;
    },
    saveSession(session: Session) {
      sessions.set(session.id, { ...session });
    },
    getSession(sessionId: string) {
      return sessions.get(sessionId);
    },
    listSessions() {
      return [...sessions.values()].sort((a, b) => b.lastActivity - a.lastActivity);
    },
    deleteSession(sessionId: string) {
      return sessions.delete(sessionId);
    },
    getWorkspace(workspaceId: string) {
      return workspaces.get(workspaceId);
    },
    // Stubs for remaining Storage interface
    listWorkspaces: () => [...workspaces.values()],
    saveWorkspace: vi.fn(),
    deleteWorkspace: vi.fn(),
    createWorkspace: vi.fn(),
    getSessionsDir: () => join(TEST_DATA_DIR, "sessions"),
    getWorkspacesDir: () => join(TEST_DATA_DIR, "workspaces"),
    saveConfig: vi.fn(),
  } as unknown as Storage & {
    _sessions: Map<string, Session>;
    _workspaces: Map<string, Workspace>;
  };
}

function makeManager(storage: Storage): SessionManager {
  const gate = {
    destroySessionGuard: vi.fn(),
  } as unknown as GateServer;

  const manager = new SessionManager(storage, gate);

  // Stub idle timer — we're not testing timers here
  (manager as { resetIdleTimer: (key: string) => void }).resetIdleTimer = () => {};

  return manager;
}

/**
 * Seed sessions directly into storage (bypasses startSession which needs GateServer).
 * Use this when you need specific parent-child relationships without SDK processes.
 */
function seedSessions(storage: Storage & { _sessions: Map<string, Session> }, ...sessions: Session[]) {
  for (const s of sessions) {
    storage._sessions.set(s.id, { ...s });
  }
}

// ── Tests ──

describe("session parent-child relationships", () => {
  let storage: ReturnType<typeof makeInMemoryStorage>;
  let manager: SessionManager;

  beforeEach(() => {
    nextId = 1;
    storage = makeInMemoryStorage();
    storage._workspaces.set("w1", makeWorkspace("w1"));
    manager = makeManager(storage);
  });

  // ── listChildSessions ──

  describe("listChildSessions", () => {
    it("returns direct children by parentSessionId", () => {
      const parent = makeSession({ id: "parent" });
      const child1 = makeSession({ id: "child1", parentSessionId: "parent" });
      const child2 = makeSession({ id: "child2", parentSessionId: "parent" });
      seedSessions(storage, parent, child1, child2);

      const children = manager.listChildSessions("parent");
      expect(children).toHaveLength(2);
      expect(children.map((c) => c.id).sort()).toEqual(["child1", "child2"]);
    });

    it("excludes grandchildren (only direct children)", () => {
      const root = makeSession({ id: "root" });
      const child = makeSession({ id: "child", parentSessionId: "root" });
      const grandchild = makeSession({ id: "grandchild", parentSessionId: "child" });
      seedSessions(storage, root, child, grandchild);

      const children = manager.listChildSessions("root");
      expect(children).toHaveLength(1);
      expect(children[0].id).toBe("child");
    });

    it("returns empty array when parent has no children", () => {
      const standalone = makeSession({ id: "standalone" });
      seedSessions(storage, standalone);

      const children = manager.listChildSessions("standalone");
      expect(children).toHaveLength(0);
    });

    it("returns empty array for non-existent parent ID", () => {
      const children = manager.listChildSessions("nonexistent");
      expect(children).toHaveLength(0);
    });

    it("isolates children per parent (no cross-contamination)", () => {
      const parent1 = makeSession({ id: "p1" });
      const parent2 = makeSession({ id: "p2" });
      const child1a = makeSession({ id: "c1a", parentSessionId: "p1" });
      const child1b = makeSession({ id: "c1b", parentSessionId: "p1" });
      const child2a = makeSession({ id: "c2a", parentSessionId: "p2" });
      seedSessions(storage, parent1, parent2, child1a, child1b, child2a);

      const p1Children = manager.listChildSessions("p1");
      expect(p1Children).toHaveLength(2);
      expect(p1Children.every((c) => c.parentSessionId === "p1")).toBe(true);

      const p2Children = manager.listChildSessions("p2");
      expect(p2Children).toHaveLength(1);
      expect(p2Children[0].id).toBe("c2a");
    });

    it("includes children regardless of status", () => {
      const parent = makeSession({ id: "parent" });
      const active = makeSession({ id: "c-active", parentSessionId: "parent", status: "busy" });
      const stopped = makeSession({ id: "c-stopped", parentSessionId: "parent", status: "stopped" });
      const error = makeSession({ id: "c-error", parentSessionId: "parent", status: "error" });
      const ready = makeSession({ id: "c-ready", parentSessionId: "parent", status: "ready" });
      seedSessions(storage, parent, active, stopped, error, ready);

      const children = manager.listChildSessions("parent");
      expect(children).toHaveLength(4);
    });

    it("detached sessions do not appear as children", () => {
      const origin = makeSession({ id: "origin" });
      const child = makeSession({ id: "child", parentSessionId: "origin" });
      // Detached session spawned from origin but has no parentSessionId
      const detached = makeSession({ id: "detached" });
      seedSessions(storage, origin, child, detached);

      const children = manager.listChildSessions("origin");
      expect(children).toHaveLength(1);
      expect(children[0].id).toBe("child");
    });
  });

  // ── parentSessionId persistence ──

  describe("parentSessionId persistence", () => {
    it("parentSessionId survives save/get round-trip", () => {
      const child = makeSession({ id: "child", parentSessionId: "parent-123" });
      storage.saveSession(child);

      const retrieved = storage.getSession("child");
      expect(retrieved).toBeDefined();
      expect(retrieved!.parentSessionId).toBe("parent-123");
    });

    it("session without parentSessionId has undefined", () => {
      const standalone = makeSession({ id: "standalone" });
      storage.saveSession(standalone);

      const retrieved = storage.getSession("standalone");
      expect(retrieved).toBeDefined();
      expect(retrieved!.parentSessionId).toBeUndefined();
    });

    it("parentSessionId included in listSessions", () => {
      const parent = makeSession({ id: "parent" });
      const child = makeSession({ id: "child", parentSessionId: "parent" });
      seedSessions(storage, parent, child);

      const all = storage.listSessions();
      const childInList = all.find((s) => s.id === "child");
      expect(childInList).toBeDefined();
      expect(childInList!.parentSessionId).toBe("parent");
    });
  });

  // ── Root session identification ──

  describe("root session identification", () => {
    it("sessions without parentSessionId are roots", () => {
      const root1 = makeSession({ id: "root1" });
      const root2 = makeSession({ id: "root2" });
      const child = makeSession({ id: "child", parentSessionId: "root1" });
      seedSessions(storage, root1, root2, child);

      const all = storage.listSessions();
      const roots = all.filter((s) => !s.parentSessionId);
      expect(roots).toHaveLength(2);
      expect(roots.map((r) => r.id).sort()).toEqual(["root1", "root2"]);
    });

    it("orphaned children (parent missing) are identifiable as pseudo-roots", () => {
      // Child whose parent was deleted or doesn't exist
      const orphan = makeSession({ id: "orphan", parentSessionId: "deleted-parent" });
      seedSessions(storage, orphan);

      const all = storage.listSessions();
      const allIds = new Set(all.map((s) => s.id));

      // Orphan detection: parentSessionId set but parent not in session list
      const orphans = all.filter((s) => s.parentSessionId && !allIds.has(s.parentSessionId));
      expect(orphans).toHaveLength(1);
      expect(orphans[0].id).toBe("orphan");
    });

    it("root filtering: exclude children, include orphans + standalone", () => {
      const root = makeSession({ id: "root" });
      const child = makeSession({ id: "child", parentSessionId: "root" });
      const orphan = makeSession({ id: "orphan", parentSessionId: "missing" });
      const standalone = makeSession({ id: "standalone" });
      seedSessions(storage, root, child, orphan, standalone);

      const all = storage.listSessions();
      const allIds = new Set(all.map((s) => s.id));
      const roots = all.filter((s) => !s.parentSessionId || !allIds.has(s.parentSessionId));

      expect(roots).toHaveLength(3);
      expect(roots.map((r) => r.id).sort()).toEqual(["orphan", "root", "standalone"]);
      // child is excluded because its parent exists
      expect(roots.find((r) => r.id === "child")).toBeUndefined();
    });
  });

  // ── Child session lookup (ChatView pattern) ──

  describe("child session lookup for ChatView", () => {
    it("finds all direct children sorted by createdAt ascending", () => {
      const now = Date.now();
      const parent = makeSession({ id: "parent" });
      const child3 = makeSession({ id: "c3", parentSessionId: "parent", createdAt: now + 300 });
      const child1 = makeSession({ id: "c1", parentSessionId: "parent", createdAt: now + 100 });
      const child2 = makeSession({ id: "c2", parentSessionId: "parent", createdAt: now + 200 });
      seedSessions(storage, parent, child3, child1, child2);

      const all = storage.listSessions();
      const children = all
        .filter((s) => s.parentSessionId === "parent")
        .sort((a, b) => a.createdAt - b.createdAt);

      expect(children.map((c) => c.id)).toEqual(["c1", "c2", "c3"]);
    });

    it("does not include grandchildren in direct child lookup", () => {
      const parent = makeSession({ id: "parent" });
      const child = makeSession({ id: "child", parentSessionId: "parent" });
      const grandchild = makeSession({ id: "grandchild", parentSessionId: "child" });
      seedSessions(storage, parent, child, grandchild);

      const all = storage.listSessions();
      const directChildren = all.filter((s) => s.parentSessionId === "parent");

      expect(directChildren).toHaveLength(1);
      expect(directChildren[0].id).toBe("child");
    });

    it("returns empty for parent with no children", () => {
      const parent = makeSession({ id: "parent" });
      seedSessions(storage, parent);

      const all = storage.listSessions();
      const children = all.filter((s) => s.parentSessionId === "parent");
      expect(children).toHaveLength(0);
    });

    it("self-referential parentSessionId does not make session its own child", () => {
      const self = makeSession({ id: "self-ref", parentSessionId: "self-ref" });
      seedSessions(storage, self);

      // Filter excludes the parent itself from children
      const all = storage.listSessions();
      const children = all.filter((s) => s.parentSessionId === "self-ref" && s.id !== "self-ref");
      expect(children).toHaveLength(0);
    });
  });

  // ── Permission aggregation pattern ──

  describe("permission aggregation across tree", () => {
    it("aggregates pending counts from parent + all direct children", () => {
      const parent = makeSession({ id: "parent" });
      const child1 = makeSession({ id: "c1", parentSessionId: "parent" });
      const child2 = makeSession({ id: "c2", parentSessionId: "parent" });
      seedSessions(storage, parent, child1, child2);

      // Simulated pending counts (in real app, from PermissionStore)
      const pendingCounts: Record<string, number> = {
        parent: 1,
        c1: 2,
        c2: 0,
      };

      const childIds = manager.listChildSessions("parent").map((c) => c.id);
      const aggregate =
        (pendingCounts["parent"] ?? 0) + childIds.reduce((sum, id) => sum + (pendingCounts[id] ?? 0), 0);

      expect(aggregate).toBe(3);
    });

    it("parent with 0 pending but child with pending shows child count", () => {
      const parent = makeSession({ id: "parent" });
      const child = makeSession({ id: "child", parentSessionId: "parent" });
      seedSessions(storage, parent, child);

      const pendingCounts: Record<string, number> = { parent: 0, child: 3 };
      const childIds = manager.listChildSessions("parent").map((c) => c.id);
      const aggregate =
        (pendingCounts["parent"] ?? 0) + childIds.reduce((sum, id) => sum + (pendingCounts[id] ?? 0), 0);

      expect(aggregate).toBe(3);
    });

    it("grandchild permissions not included in parent aggregate", () => {
      const parent = makeSession({ id: "parent" });
      const child = makeSession({ id: "child", parentSessionId: "parent" });
      const grandchild = makeSession({ id: "gc", parentSessionId: "child" });
      seedSessions(storage, parent, child, grandchild);

      const pendingCounts: Record<string, number> = { parent: 0, child: 0, gc: 5 };
      const childIds = manager.listChildSessions("parent").map((c) => c.id);
      const aggregate =
        (pendingCounts["parent"] ?? 0) + childIds.reduce((sum, id) => sum + (pendingCounts[id] ?? 0), 0);

      // Grandchild's 5 not included — only direct children
      expect(aggregate).toBe(0);
    });
  });

  // ── Cost aggregation ──

  describe("cost aggregation across tree", () => {
    it("sums cost of parent + all children", () => {
      const parent = makeSession({ id: "parent", cost: 1.5 });
      const child1 = makeSession({ id: "c1", parentSessionId: "parent", cost: 0.5 });
      const child2 = makeSession({ id: "c2", parentSessionId: "parent", cost: 0.8 });
      seedSessions(storage, parent, child1, child2);

      const children = manager.listChildSessions("parent");
      const totalCost = parent.cost + children.reduce((sum, c) => sum + c.cost, 0);

      expect(totalCost).toBeCloseTo(2.8);
    });

    it("children with zero cost don't affect total", () => {
      const parent = makeSession({ id: "parent", cost: 2.0 });
      const child = makeSession({ id: "child", parentSessionId: "parent", cost: 0 });
      seedSessions(storage, parent, child);

      const children = manager.listChildSessions("parent");
      const totalCost = parent.cost + children.reduce((sum, c) => sum + c.cost, 0);

      expect(totalCost).toBe(2.0);
    });
  });

  // ── Delete behavior ──

  describe("delete with parent-child relationships", () => {
    it("deleting parent orphans children (parentSessionId points to missing)", () => {
      const parent = makeSession({ id: "parent" });
      const child1 = makeSession({ id: "c1", parentSessionId: "parent" });
      const child2 = makeSession({ id: "c2", parentSessionId: "parent" });
      seedSessions(storage, parent, child1, child2);

      storage.deleteSession("parent");

      // Children still exist with dangling parentSessionId
      const c1 = storage.getSession("c1");
      expect(c1).toBeDefined();
      expect(c1!.parentSessionId).toBe("parent");

      // Parent is gone
      expect(storage.getSession("parent")).toBeUndefined();

      // listChildSessions returns orphans because it filters on parentSessionId
      const orphans = manager.listChildSessions("parent");
      expect(orphans).toHaveLength(2);
    });

    it("deleting child does not affect parent", () => {
      const parent = makeSession({ id: "parent" });
      const child = makeSession({ id: "child", parentSessionId: "parent" });
      seedSessions(storage, parent, child);

      storage.deleteSession("child");

      expect(storage.getSession("parent")).toBeDefined();
      expect(manager.listChildSessions("parent")).toHaveLength(0);
    });

    it("cascade delete: remove parent and all children", () => {
      const parent = makeSession({ id: "parent" });
      const child1 = makeSession({ id: "c1", parentSessionId: "parent" });
      const child2 = makeSession({ id: "c2", parentSessionId: "parent" });
      seedSessions(storage, parent, child1, child2);

      // Cascade pattern: delete children first, then parent
      const children = manager.listChildSessions("parent");
      for (const child of children) {
        storage.deleteSession(child.id);
      }
      storage.deleteSession("parent");

      expect(storage.getSession("parent")).toBeUndefined();
      expect(storage.getSession("c1")).toBeUndefined();
      expect(storage.getSession("c2")).toBeUndefined();
    });
  });

  // ── Current behavior documentation (gaps to fix) ──

  describe("idle timer and children (documenting current gap)", () => {
    it("KNOWN GAP: idle timer has no hasActiveChild check", () => {
      // The current session-lifecycle.ts resetIdleTimer callback
      // calls stopSession without checking for active children.
      // This test documents the gap — a parent can idle-timeout
      // while children are still running.
      //
      // TODO: Fix in session-lifecycle.ts to check listChildSessions
      // before allowing idle stop.
      const parent = makeSession({ id: "parent", status: "ready" });
      const activeChild = makeSession({ id: "child", parentSessionId: "parent", status: "busy" });
      seedSessions(storage, parent, activeChild);

      // hasActiveChild check pattern (not yet implemented in lifecycle):
      const children = manager.listChildSessions("parent");
      const hasActiveChild = children.some((c) => c.status !== "stopped");

      // This SHOULD prevent the parent from being idle-stopped:
      expect(hasActiveChild).toBe(true);
    });

    it("KNOWN GAP: stopping parent does not cascade to children", () => {
      // Currently stopping a parent leaves children running.
      // Document the cascade pattern for future implementation.
      const parent = makeSession({ id: "parent", status: "busy" });
      const child1 = makeSession({ id: "c1", parentSessionId: "parent", status: "busy" });
      const child2 = makeSession({ id: "c2", parentSessionId: "parent", status: "busy" });
      seedSessions(storage, parent, child1, child2);

      // Cascade stop pattern (not yet implemented):
      // 1. Stop parent
      parent.status = "stopped";
      storage.saveSession(parent);
      // 2. Stop all children
      const children = manager.listChildSessions("parent");
      for (const child of children) {
        child.status = "stopped";
        storage.saveSession(child);
      }

      // Verify all stopped
      const allStopped = manager
        .listChildSessions("parent")
        .every((c) => c.status === "stopped");
      expect(allStopped).toBe(true);
    });
  });

  // ── Complex tree scenarios ──

  describe("complex tree scenarios", () => {
    it("three-level tree: root -> child -> grandchild", () => {
      const root = makeSession({ id: "root" });
      const child = makeSession({ id: "child", parentSessionId: "root" });
      const grandchild = makeSession({ id: "gc", parentSessionId: "child" });
      seedSessions(storage, root, child, grandchild);

      // Root's children
      const rootChildren = manager.listChildSessions("root");
      expect(rootChildren).toHaveLength(1);
      expect(rootChildren[0].id).toBe("child");

      // Child's children
      const childChildren = manager.listChildSessions("child");
      expect(childChildren).toHaveLength(1);
      expect(childChildren[0].id).toBe("gc");

      // Grandchild has no children
      const gcChildren = manager.listChildSessions("gc");
      expect(gcChildren).toHaveLength(0);
    });

    it("multiple independent trees don't interfere", () => {
      const tree1Root = makeSession({ id: "t1-root" });
      const tree1Child = makeSession({ id: "t1-child", parentSessionId: "t1-root" });
      const tree2Root = makeSession({ id: "t2-root" });
      const tree2Child = makeSession({ id: "t2-child", parentSessionId: "t2-root" });
      const standalone = makeSession({ id: "standalone" });
      seedSessions(storage, tree1Root, tree1Child, tree2Root, tree2Child, standalone);

      expect(manager.listChildSessions("t1-root")).toHaveLength(1);
      expect(manager.listChildSessions("t1-root")[0].id).toBe("t1-child");
      expect(manager.listChildSessions("t2-root")).toHaveLength(1);
      expect(manager.listChildSessions("t2-root")[0].id).toBe("t2-child");
      expect(manager.listChildSessions("standalone")).toHaveLength(0);
    });

    it("wide tree: parent with many children", () => {
      const parent = makeSession({ id: "parent" });
      const children: Session[] = [];
      for (let i = 0; i < 10; i++) {
        children.push(makeSession({ id: `child-${i}`, parentSessionId: "parent" }));
      }
      seedSessions(storage, parent, ...children);

      const result = manager.listChildSessions("parent");
      expect(result).toHaveLength(10);
    });

    it("full tree cost aggregation (recursive)", () => {
      const root = makeSession({ id: "root", cost: 1.0 });
      const child1 = makeSession({ id: "c1", parentSessionId: "root", cost: 0.5 });
      const child2 = makeSession({ id: "c2", parentSessionId: "root", cost: 0.3 });
      const gc1 = makeSession({ id: "gc1", parentSessionId: "c1", cost: 0.2 });
      seedSessions(storage, root, child1, child2, gc1);

      // Recursive cost aggregation pattern (used by spawn-agent-extension computeTreeCost)
      function treeCost(sessionId: string): number {
        const session = storage.getSession(sessionId);
        if (!session) return 0;
        const childrenCost = manager
          .listChildSessions(sessionId)
          .reduce((sum, c) => sum + treeCost(c.id), 0);
        return session.cost + childrenCost;
      }

      expect(treeCost("root")).toBeCloseTo(2.0); // 1.0 + 0.5 + 0.3 + 0.2
      expect(treeCost("c1")).toBeCloseTo(0.7); // 0.5 + 0.2
      expect(treeCost("c2")).toBeCloseTo(0.3);
      expect(treeCost("gc1")).toBeCloseTo(0.2);
    });
  });
});

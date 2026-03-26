/**
 * spawn_agent extension tests — mock context, no real LLM.
 *
 * Exercises all three tools (spawn_agent, check_agents, inspect_agent)
 * and the internal utility functions (depth, tree cost, trace parsing)
 * through the public createSpawnAgentFactory API with a mock context.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as fs from "node:fs";
import { join } from "node:path";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import type { Session, ServerMessage } from "../src/types.js";
import { createSpawnAgentFactory, type SpawnAgentContext } from "../src/spawn-agent-extension.js";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

let nextSessionId = 1;

function makeSession(overrides: Partial<Session> = {}): Session {
  const id = overrides.id ?? `child-${nextSessionId++}`;
  const now = Date.now();
  return {
    id,
    workspaceId: "ws-1",
    workspaceName: "Test",
    status: "busy",
    createdAt: now - 30_000,
    lastActivity: now,
    messageCount: 3,
    tokens: { input: 100, output: 50, cacheRead: 20, cacheWrite: 10 },
    cost: 0.05,
    model: "anthropic/claude-sonnet-4-0",
    ...overrides,
  };
}

interface RegisteredTool {
  name: string;
  execute: (
    toolCallId: string,
    params: Record<string, unknown>,
    signal?: AbortSignal,
    onUpdate?: (update: unknown) => void,
  ) => Promise<{
    content: Array<{ type: string; text: string }>;
    details: Record<string, unknown>;
  }>;
}

/**
 * Create a mock context + pi, register tools, return tool executors.
 */
function setup(
  opts: {
    sessionId?: string;
    sessions?: Session[];
    models?: string[];
    subscribers?: Map<string, (msg: ServerMessage) => void>;
  } = {},
) {
  const sessions = new Map<string, Session>();
  for (const s of opts.sessions ?? []) sessions.set(s.id, s);

  // Ensure the "current" session exists for depth checks
  const parentId = opts.sessionId ?? "parent-1";
  if (!sessions.has(parentId)) {
    sessions.set(
      parentId,
      makeSession({ id: parentId, status: "busy", parentSessionId: undefined }),
    );
  }

  const subscriberCallbacks = opts.subscribers ?? new Map<string, (msg: ServerMessage) => void>();

  const ctx: SpawnAgentContext = {
    workspaceId: "ws-1",
    sessionId: parentId,

    async spawnChild(params) {
      const child = makeSession({
        id: `child-${nextSessionId++}`,
        name: params.name,
        model: params.model ?? "anthropic/claude-sonnet-4-0",
        status: "starting",
        parentSessionId: parentId,
      });
      sessions.set(child.id, child);
      return child;
    },

    async spawnDetached(params) {
      const child = makeSession({
        id: `detached-${nextSessionId++}`,
        name: params.name,
        model: params.model ?? "anthropic/claude-sonnet-4-0",
        status: "starting",
        // No parentSessionId — detached
      });
      sessions.set(child.id, child);
      return child;
    },

    listChildren() {
      return [...sessions.values()].filter((s) => s.parentSessionId === parentId);
    },

    getSession(id) {
      return sessions.get(id);
    },

    listWorkspaceSessions() {
      return [...sessions.values()].filter((s) => s.workspaceId === "ws-1");
    },

    subscribe(sessionId, callback) {
      subscriberCallbacks.set(sessionId, callback);
      return () => subscriberCallbacks.delete(sessionId);
    },

    getAvailableModelIds() {
      return (
        opts.models ?? ["anthropic/claude-sonnet-4-0", "anthropic/claude-opus-4-0", "openai/gpt-4o"]
      );
    },
  };

  // Collect registered tools
  const tools = new Map<string, RegisteredTool>();
  const mockPi = {
    registerTool(tool: { name: string; execute: RegisteredTool["execute"] }) {
      tools.set(tool.name, { name: tool.name, execute: tool.execute });
    },
  };

  const factory = createSpawnAgentFactory(ctx);
  factory(mockPi as never);

  return {
    ctx,
    sessions,
    subscriberCallbacks,
    spawn: tools.get("spawn_agent")!,
    check: tools.get("check_agents")!,
    inspect: tools.get("inspect_agent")!,
    /** Helper: set a session's status after spawn */
    setStatus(id: string, status: string) {
      const s = sessions.get(id);
      if (s) (s as Record<string, unknown>).status = status;
    },
  };
}

// ---------------------------------------------------------------------------
// JSONL trace helpers
// ---------------------------------------------------------------------------

let tmpDir: string;

beforeEach(() => {
  nextSessionId = 1;
  tmpDir = mkdtempSync(join(tmpdir(), "spawn-agent-test-"));
});

afterEach(() => {
  rmSync(tmpDir, { recursive: true, force: true });
});

function writeTrace(filename: string, entries: unknown[]): string {
  const path = join(tmpDir, filename);
  writeFileSync(path, entries.map((e) => JSON.stringify(e)).join("\n"));
  return path;
}

function makeTraceEntry(role: string, content: unknown[], extra: Record<string, unknown> = {}) {
  return { type: "message", message: { role, content, ...extra } };
}

// ---------------------------------------------------------------------------
// spawn_agent
// ---------------------------------------------------------------------------

describe("spawn_agent", () => {
  it("spawns a child session (fire-and-forget)", async () => {
    const { spawn } = setup();
    const result = await spawn.execute("tc-1", {
      message: "Write tests for auth module",
      name: "auth-tests",
    });

    expect(result.content[0].text).toContain('Spawned agent "auth-tests"');
    expect(result.content[0].text).toContain("running independently");
    expect(result.details.agentId).toBeTruthy();
    expect(result.details.name).toBe("auth-tests");
    expect(result.details.status).toBe("starting");
  });

  it("uses message prefix as name when name is omitted", async () => {
    const { spawn } = setup();
    const result = await spawn.execute("tc-1", {
      message: "Fix the login flow for OAuth2 providers",
    });

    expect(result.details.name).toBe("Fix the login flow for OAuth2 providers");
  });

  it("truncates long messages to 80 chars for default name", async () => {
    const { spawn } = setup();
    const longMessage = "A".repeat(100);
    const result = await spawn.execute("tc-1", { message: longMessage });
    expect((result.details.name as string).length).toBe(80);
  });

  it("passes model to child session", async () => {
    const { spawn } = setup();
    const result = await spawn.execute("tc-1", {
      message: "test",
      model: "openai/gpt-4o",
    });

    expect(result.details.model).toBe("openai/gpt-4o");
  });

  it("rejects unknown model with available list", async () => {
    const { spawn } = setup({ models: ["anthropic/claude-sonnet-4-0", "openai/gpt-4o"] });
    const result = await spawn.execute("tc-1", {
      message: "test",
      model: "nonexistent/model-x",
    });

    expect(result.content[0].text).toContain('Unknown model "nonexistent/model-x"');
    expect(result.content[0].text).toContain("anthropic/claude-sonnet-4-0");
    expect(result.content[0].text).toContain("openai/gpt-4o");
    expect(result.details.status).toBe("error");
  });

  it("skips model validation when catalog is empty", async () => {
    const { spawn } = setup({ models: [] });
    const result = await spawn.execute("tc-1", {
      message: "test",
      model: "any/model",
    });

    // Should succeed — empty catalog means no validation
    expect(result.details.status).toBe("starting");
  });

  it("allows known model", async () => {
    const { spawn } = setup({ models: ["anthropic/claude-sonnet-4-0"] });
    const result = await spawn.execute("tc-1", {
      message: "test",
      model: "anthropic/claude-sonnet-4-0",
    });

    expect(result.details.status).toBe("starting");
  });

  describe("depth limits", () => {
    it("allows spawn at depth 0 (root session)", async () => {
      const { spawn } = setup({ sessionId: "root" });
      const result = await spawn.execute("tc-1", { message: "test" });
      expect(result.details.status).not.toBe("error");
    });

    it("rejects spawn at depth 1 (child cannot spawn grandchildren)", async () => {
      const root = makeSession({ id: "root" });
      const child = makeSession({ id: "child-at-depth-1", parentSessionId: "root" });
      const { spawn } = setup({ sessionId: "child-at-depth-1", sessions: [root, child] });

      const result = await spawn.execute("tc-1", { message: "test" });
      expect(result.content[0].text).toContain("Cannot spawn: max depth reached");
      expect(result.content[0].text).toContain("depth 1");
      expect(result.details.status).toBe("error");
    });

    it("handles circular parentSessionId without infinite loop", async () => {
      const a = makeSession({ id: "a", parentSessionId: "b" });
      const b = makeSession({ id: "b", parentSessionId: "a" });
      const { spawn } = setup({ sessionId: "a", sessions: [a, b] });

      // Should not hang — circular reference guard should catch it
      const result = await spawn.execute("tc-1", { message: "test" });
      // May or may not allow spawn depending on where cycle breaks, but must not hang
      expect(result).toBeTruthy();
    });
  });

  describe("detached mode", () => {
    it("spawns detached session with no parent link", async () => {
      const { spawn } = setup();
      const result = await spawn.execute("tc-1", {
        message: "independent work",
        detached: true,
      });

      expect(result.content[0].text).toContain("detached");
      expect(result.content[0].text).toContain("independent session");
      expect(result.details.detached).toBe(true);
    });
  });

  describe("wait mode", () => {
    it("returns immediately when child is already terminal", async () => {
      // Build a custom context where spawnChild returns an already-stopped session
      const sessions = new Map<string, Session>();
      const parent = makeSession({ id: "parent-1" });
      sessions.set("parent-1", parent);

      const ctx: SpawnAgentContext = {
        workspaceId: "ws-1",
        sessionId: "parent-1",
        async spawnChild(params) {
          const child = makeSession({
            id: "fast-child",
            name: params.name,
            status: "stopped", // Already terminal!
            parentSessionId: "parent-1",
            lastMessage: "I finished instantly",
          });
          sessions.set(child.id, child);
          return child;
        },
        async spawnDetached() {
          throw new Error("unused");
        },
        listChildren: () => [...sessions.values()].filter((s) => s.parentSessionId === "parent-1"),
        getSession: (id) => sessions.get(id),
        listWorkspaceSessions: () => [...sessions.values()].filter((s) => s.workspaceId === "ws-1"),
        subscribe: () => () => {},
        getAvailableModelIds: () => [],
      };

      const tools = new Map<string, RegisteredTool>();
      const factory = createSpawnAgentFactory(ctx);
      factory({
        registerTool(tool: { name: string; execute: RegisteredTool["execute"] }) {
          tools.set(tool.name, tool as RegisteredTool);
        },
      } as never);

      const result = await tools.get("spawn_agent")!.execute("tc-1", {
        message: "quick task",
        wait: true,
      });

      expect(result.details.waited).toBe(true);
      expect(result.details.status).toBe("stopped");
      // Should resolve instantly — no timeout
    });

    it("includes waited flag in details", async () => {
      const s = setup();

      const resultPromise = s.spawn.execute("tc-1", {
        message: "quick task",
        wait: true,
        timeout_seconds: 5,
      });

      // Give the spawn time to register subscriber
      await new Promise((r) => setTimeout(r, 50));

      // Find the child ID from subscriber registrations
      const childId = [...s.subscriberCallbacks.keys()][0];
      expect(childId).toBeTruthy();

      // Mark child as stopped and fire terminal event
      s.setStatus(childId!, "stopped");
      const cb = s.subscriberCallbacks.get(childId!);
      cb?.({ type: "session_ended", sessionId: childId } as ServerMessage);

      const result = await resultPromise;
      expect(result.details.waited).toBe(true);
      expect(result.content[0].text).toContain("finished");
    });

    it("times out when child never finishes", async () => {
      const { spawn } = setup();

      const result = await spawn.execute("tc-1", {
        message: "stuck task",
        wait: true,
        timeout_seconds: 1, // 1 second timeout
      });

      expect(result.content[0].text).toContain("Timed out");
      expect(result.details.waited).toBe(true);
    }, 10_000);

    it("respects abort signal", async () => {
      const { spawn } = setup();
      const controller = new AbortController();

      const resultPromise = spawn.execute(
        "tc-1",
        { message: "abortable task", wait: true, timeout_seconds: 60 },
        controller.signal,
      );

      // Abort after 100ms
      setTimeout(() => controller.abort(), 100);

      const result = await resultPromise;
      expect(result).toBeTruthy();
    }, 5_000);
  });

  it("handles spawnChild failure gracefully", async () => {
    const sessions = new Map<string, Session>();
    sessions.set("parent-1", makeSession({ id: "parent-1" }));

    const ctx: SpawnAgentContext = {
      workspaceId: "ws-1",
      sessionId: "parent-1",
      async spawnChild() {
        throw new Error("Session limit exceeded");
      },
      async spawnDetached() {
        throw new Error("Session limit exceeded");
      },
      listChildren: () => [],
      getSession: (id) => sessions.get(id),
      listWorkspaceSessions: () => [...sessions.values()].filter((s) => s.workspaceId === "ws-1"),
      subscribe: () => () => {},
      getAvailableModelIds: () => [],
    };

    const tools = new Map<string, RegisteredTool>();
    const factory = createSpawnAgentFactory(ctx);
    factory({
      registerTool(tool: { name: string; execute: RegisteredTool["execute"] }) {
        tools.set(tool.name, tool as RegisteredTool);
      },
    } as never);

    const result = await tools.get("spawn_agent")!.execute("tc-1", { message: "test" });
    expect(result.content[0].text).toContain("Failed to spawn agent");
    expect(result.content[0].text).toContain("Session limit exceeded");
    expect(result.details.status).toBe("error");
  });

  it("sends creating progress update", async () => {
    const { spawn } = setup();
    const updates: unknown[] = [];
    await spawn.execute("tc-1", { message: "test", name: "my-agent" }, undefined, (update) =>
      updates.push(update),
    );

    expect(updates.length).toBeGreaterThanOrEqual(1);
    const firstUpdate = updates[0] as {
      content: Array<{ text: string }>;
      details: Record<string, unknown>;
    };
    expect(firstUpdate.content[0].text).toContain('Creating session "my-agent"');
  });
});

// ---------------------------------------------------------------------------
// check_agents
// ---------------------------------------------------------------------------

describe("check_agents", () => {
  it("returns empty message when no children", async () => {
    const { check } = setup();
    const result = await check.execute("tc-1", {});
    expect(result.content[0].text).toBe("No child sessions found.");
    expect(result.details.agents).toEqual([]);
  });

  it("lists child sessions with status icons", async () => {
    const children = [
      makeSession({
        id: "c1",
        name: "auth-tests",
        status: "busy",
        parentSessionId: "parent-1",
        cost: 0.12,
      }),
      makeSession({
        id: "c2",
        name: "db-refactor",
        status: "stopped",
        parentSessionId: "parent-1",
        cost: 0.45,
      }),
      makeSession({
        id: "c3",
        name: "broken",
        status: "error",
        parentSessionId: "parent-1",
        cost: 0.01,
      }),
    ];
    const { check } = setup({ sessions: children });

    const result = await check.execute("tc-1", {});
    const text = result.content[0].text;

    // Status icons
    expect(text).toContain("⏳ auth-tests");
    expect(text).toContain("✓ db-refactor");
    expect(text).toContain("✗ broken");

    // Summary line
    expect(text).toContain("3 child sessions");
    expect(text).toContain("1 working");
    expect(text).toContain("1 done");
    expect(text).toContain("1 error");
  });

  it("shows tree cost aggregation", async () => {
    const children = [
      makeSession({ id: "c1", parentSessionId: "parent-1", cost: 1.0, messageCount: 10 }),
      makeSession({ id: "c2", parentSessionId: "parent-1", cost: 2.0, messageCount: 20 }),
    ];
    const { check } = setup({ sessions: children });

    const result = await check.execute("tc-1", {});
    const text = result.content[0].text;

    // Tree total should include parent + children
    expect(text).toContain("Tree total:");
    expect(text).toContain("3 sessions"); // parent + 2 children
  });

  it("shows grandchild count for children that have their own children", async () => {
    const children = [
      makeSession({ id: "c1", name: "orchestrator", parentSessionId: "parent-1" }),
      makeSession({ id: "gc1", name: "sub-task-1", parentSessionId: "c1" }),
      makeSession({ id: "gc2", name: "sub-task-2", parentSessionId: "c1" }),
    ];
    const { check } = setup({ sessions: children });

    const result = await check.execute("tc-1", {});
    const text = result.content[0].text;

    // Only direct children should be listed (c1 is direct child)
    // c1 should show grandchild indicator
    expect(text).toContain("(+2 children)");
  });

  it("formats cost correctly", async () => {
    const children = [
      makeSession({ id: "c1", parentSessionId: "parent-1", cost: 0 }),
      makeSession({ id: "c2", parentSessionId: "parent-1", cost: 0.001 }),
      makeSession({ id: "c3", parentSessionId: "parent-1", cost: 1.5 }),
    ];
    const { check } = setup({ sessions: children });

    const result = await check.execute("tc-1", {});
    const text = result.content[0].text;

    expect(text).toContain("$0");
    expect(text).toContain("$0.0010");
    expect(text).toContain("$1.50");
  });

  it("includes all agent summaries in details", async () => {
    const children = [
      makeSession({
        id: "c1",
        name: "task-a",
        status: "busy",
        parentSessionId: "parent-1",
        cost: 0.5,
        messageCount: 7,
      }),
    ];
    const { check } = setup({ sessions: children });

    const result = await check.execute("tc-1", {});
    expect(result.details.agents).toHaveLength(1);
    const agent = (result.details.agents as Array<Record<string, unknown>>)[0];
    expect(agent.id).toBe("c1");
    expect(agent.name).toBe("task-a");
    expect(agent.status).toBe("busy");
    expect(agent.cost).toBe(0.5);
    expect(agent.messageCount).toBe(7);
  });
});

// ---------------------------------------------------------------------------
// inspect_agent
// ---------------------------------------------------------------------------

describe("inspect_agent", () => {
  it("returns error for unknown session", async () => {
    const { inspect } = setup();
    const result = await inspect.execute("tc-1", { id: "nonexistent" });
    expect(result.content[0].text).toContain("Session not found");
  });

  it("rejects session not in the workspace", async () => {
    const other = makeSession({ id: "other-session", workspaceId: "ws-other" });
    const { inspect } = setup({ sessions: [other] });

    const result = await inspect.execute("tc-1", { id: "other-session" });
    expect(result.content[0].text).toContain("not in this workspace");
  });

  it("allows inspection of direct children", async () => {
    const child = makeSession({
      id: "my-child",
      parentSessionId: "parent-1",
      piSessionFile: writeTrace("child.jsonl", [
        makeTraceEntry("user", [{ type: "text", text: "hello" }]),
        makeTraceEntry("assistant", [{ type: "text", text: "hi there" }]),
      ]),
    });
    const { inspect } = setup({ sessions: [child] });

    const result = await inspect.execute("tc-1", { id: "my-child" });
    expect(result.content[0].text).toContain("1 turns");
    expect(result.details.level).toBe("overview");
  });

  it("allows inspection of grandchildren in the tree", async () => {
    const child = makeSession({ id: "my-child", parentSessionId: "parent-1" });
    const grandchild = makeSession({
      id: "my-grandchild",
      parentSessionId: "my-child",
      piSessionFile: writeTrace("gc.jsonl", [
        makeTraceEntry("user", [{ type: "text", text: "task" }]),
        makeTraceEntry("assistant", [{ type: "text", text: "done" }]),
      ]),
    });
    const { inspect } = setup({ sessions: [child, grandchild] });

    const result = await inspect.execute("tc-1", { id: "my-grandchild" });
    expect(result.details.level).toBe("overview");
    expect(result.content[0].text).toContain("1 turns");
  });

  it("returns error when trace file is missing", async () => {
    const child = makeSession({ id: "my-child", parentSessionId: "parent-1" });
    // No piSessionFile set
    const { inspect } = setup({ sessions: [child] });

    const result = await inspect.execute("tc-1", { id: "my-child" });
    expect(result.content[0].text).toContain("No trace file available");
  });

  it("returns error when trace is empty", async () => {
    const child = makeSession({
      id: "my-child",
      parentSessionId: "parent-1",
      piSessionFile: writeTrace("empty.jsonl", []),
    });
    const { inspect } = setup({ sessions: [child] });

    const result = await inspect.execute("tc-1", { id: "my-child" });
    expect(result.content[0].text).toContain("Trace is empty");
  });

  describe("overview level", () => {
    it("shows turn count, tool count, and error count", async () => {
      const trace = [
        makeTraceEntry("user", [{ type: "text", text: "fix the bug" }]),
        makeTraceEntry("assistant", [
          { type: "toolCall", name: "read", arguments: { path: "/src/app.ts" }, id: "tc1" },
          { type: "toolCall", name: "edit", arguments: { path: "/src/app.ts" }, id: "tc2" },
        ]),
        makeTraceEntry("toolResult", [{ type: "text", text: "file content" }], {
          toolCallId: "tc1",
        }),
        makeTraceEntry("toolResult", [{ type: "text", text: "error: not found" }], {
          toolCallId: "tc2",
          isError: true,
        }),
        makeTraceEntry("assistant", [{ type: "text", text: "Fixed the bug." }]),
      ];
      const child = makeSession({
        id: "my-child",
        parentSessionId: "parent-1",
        piSessionFile: writeTrace("trace.jsonl", trace),
      });
      const { inspect } = setup({ sessions: [child] });

      const result = await inspect.execute("tc-1", { id: "my-child" });
      const text = result.content[0].text;

      expect(text).toContain("1 turns");
      expect(text).toContain("2 tool calls");
      expect(text).toContain("1 errors");
      expect(result.details.turnCount).toBe(1);
      expect(result.details.toolCount).toBe(2);
      expect(result.details.errorCount).toBe(1);
    });

    it("shows tool breakdown and files changed", async () => {
      const trace = [
        makeTraceEntry("user", [{ type: "text", text: "refactor" }]),
        makeTraceEntry("assistant", [
          { type: "toolCall", name: "read", arguments: { path: "/src/a.ts" }, id: "t1" },
          { type: "toolCall", name: "read", arguments: { path: "/src/b.ts" }, id: "t2" },
          {
            type: "toolCall",
            name: "write",
            arguments: { path: "/src/c.ts", content: "new" },
            id: "t3",
          },
        ]),
        makeTraceEntry("toolResult", [{ type: "text", text: "ok" }], { toolCallId: "t1" }),
        makeTraceEntry("toolResult", [{ type: "text", text: "ok" }], { toolCallId: "t2" }),
        makeTraceEntry("toolResult", [{ type: "text", text: "ok" }], { toolCallId: "t3" }),
        makeTraceEntry("assistant", [{ type: "text", text: "Done" }]),
      ];
      const child = makeSession({
        id: "my-child",
        parentSessionId: "parent-1",
        piSessionFile: writeTrace("tools.jsonl", trace),
      });
      const { inspect } = setup({ sessions: [child] });

      const result = await inspect.execute("tc-1", { id: "my-child" });
      const text = result.content[0].text;

      expect(text).toContain("Tools:");
      expect(text).toContain("read:2");
      expect(text).toContain("write:1");
      expect(text).toContain("1 files changed");
    });

    it("shows last response preview", async () => {
      const trace = [
        makeTraceEntry("user", [{ type: "text", text: "explain" }]),
        makeTraceEntry("assistant", [
          { type: "text", text: "Here is my detailed explanation of the system." },
        ]),
      ];
      const child = makeSession({
        id: "my-child",
        parentSessionId: "parent-1",
        piSessionFile: writeTrace("response.jsonl", trace),
      });
      const { inspect } = setup({ sessions: [child] });

      const result = await inspect.execute("tc-1", { id: "my-child" });
      expect(result.content[0].text).toContain("Last response:");
      expect(result.content[0].text).toContain("detailed explanation");
    });
  });

  describe("turn detail level", () => {
    it("shows tool list for a specific turn", async () => {
      const trace = [
        makeTraceEntry("user", [{ type: "text", text: "fix it" }]),
        makeTraceEntry("assistant", [
          { type: "toolCall", name: "bash", arguments: { command: "npm test" }, id: "t1" },
        ]),
        makeTraceEntry("toolResult", [{ type: "text", text: "3 tests passed" }], {
          toolCallId: "t1",
        }),
        makeTraceEntry("assistant", [{ type: "text", text: "Tests pass now." }]),
      ];
      const child = makeSession({
        id: "my-child",
        parentSessionId: "parent-1",
        piSessionFile: writeTrace("turn.jsonl", trace),
      });
      const { inspect } = setup({ sessions: [child] });

      const result = await inspect.execute("tc-1", { id: "my-child", turn: 1 });
      const text = result.content[0].text;

      expect(text).toContain("Turn 1");
      expect(text).toContain("bash:");
      expect(text).toContain("npm test");
      expect(result.details.level).toBe("turn");
    });

    it("returns error for invalid turn number", async () => {
      const trace = [
        makeTraceEntry("user", [{ type: "text", text: "hello" }]),
        makeTraceEntry("assistant", [{ type: "text", text: "hi" }]),
      ];
      const child = makeSession({
        id: "my-child",
        parentSessionId: "parent-1",
        piSessionFile: writeTrace("turn-invalid.jsonl", trace),
      });
      const { inspect } = setup({ sessions: [child] });

      const result = await inspect.execute("tc-1", { id: "my-child", turn: 99 });
      expect(result.content[0].text).toContain("Turn 99 not found");
    });
  });

  describe("tool detail level", () => {
    it("shows full args and output for a specific tool", async () => {
      const longContent = "line1\nline2\nline3\nline4\nline5";
      const trace = [
        makeTraceEntry("user", [{ type: "text", text: "read the file" }]),
        makeTraceEntry("assistant", [
          {
            type: "toolCall",
            name: "read",
            arguments: { path: "/src/main.ts", offset: 1, limit: 50 },
            id: "t1",
          },
        ]),
        makeTraceEntry("toolResult", [{ type: "text", text: longContent }], { toolCallId: "t1" }),
        makeTraceEntry("assistant", [{ type: "text", text: "Got it." }]),
      ];
      const child = makeSession({
        id: "my-child",
        parentSessionId: "parent-1",
        piSessionFile: writeTrace("tool-detail.jsonl", trace),
      });
      const { inspect } = setup({ sessions: [child] });

      const result = await inspect.execute("tc-1", { id: "my-child", turn: 1, tool: 1 });
      const text = result.content[0].text;

      expect(text).toContain("Name: read");
      expect(text).toContain("Arguments:");
      expect(text).toContain("path: /src/main.ts");
      expect(text).toContain("Output");
      expect(text).toContain("line1");
      expect(result.details.level).toBe("tool");
    });

    it("returns error for invalid tool index", async () => {
      const trace = [
        makeTraceEntry("user", [{ type: "text", text: "hi" }]),
        makeTraceEntry("assistant", [{ type: "text", text: "hello" }]),
      ];
      const child = makeSession({
        id: "my-child",
        parentSessionId: "parent-1",
        piSessionFile: writeTrace("tool-invalid.jsonl", trace),
      });
      const { inspect } = setup({ sessions: [child] });

      const result = await inspect.execute("tc-1", { id: "my-child", turn: 1, tool: 5 });
      expect(result.content[0].text).toContain("Tool [5] not found");
    });
  });

  describe("response level", () => {
    it("returns full last response with response=true", async () => {
      const longResponse = "This is a very detailed response.\n".repeat(100);
      const trace = [
        makeTraceEntry("user", [{ type: "text", text: "explain everything" }]),
        makeTraceEntry("assistant", [{ type: "text", text: longResponse }]),
      ];
      const child = makeSession({
        id: "my-child",
        parentSessionId: "parent-1",
        piSessionFile: writeTrace("full-response.jsonl", trace),
      });
      const { inspect } = setup({ sessions: [child] });

      const result = await inspect.execute("tc-1", { id: "my-child", response: true });
      // Should return full text, not truncated
      expect(result.content[0].text).toContain("This is a very detailed response.");
      expect(result.content[0].text.length).toBeGreaterThan(100);
    });

    it("returns specific turn response with response=true and turn", async () => {
      const trace = [
        makeTraceEntry("user", [{ type: "text", text: "first question" }]),
        makeTraceEntry("assistant", [{ type: "text", text: "first answer" }]),
        makeTraceEntry("user", [{ type: "text", text: "second question" }]),
        makeTraceEntry("assistant", [{ type: "text", text: "second answer" }]),
      ];
      const child = makeSession({
        id: "my-child",
        parentSessionId: "parent-1",
        piSessionFile: writeTrace("turn-response.jsonl", trace),
      });
      const { inspect } = setup({ sessions: [child] });

      const result = await inspect.execute("tc-1", {
        id: "my-child",
        turn: 1,
        response: true,
      });
      expect(result.content[0].text).toBe("first answer");
    });

    it("returns error when no response text exists", async () => {
      const trace = [
        makeTraceEntry("user", [{ type: "text", text: "question" }]),
        makeTraceEntry("assistant", [
          { type: "toolCall", name: "bash", arguments: { command: "echo hi" }, id: "t1" },
        ]),
        makeTraceEntry("toolResult", [{ type: "text", text: "hi" }], { toolCallId: "t1" }),
        // No final text response
      ];
      const child = makeSession({
        id: "my-child",
        parentSessionId: "parent-1",
        piSessionFile: writeTrace("no-response.jsonl", trace),
      });
      const { inspect } = setup({ sessions: [child] });

      const result = await inspect.execute("tc-1", { id: "my-child", response: true });
      expect(result.content[0].text).toContain("No assistant response found");
    });
  });

  describe("multi-turn traces", () => {
    it("parses multi-turn conversation correctly", async () => {
      const trace = [
        makeTraceEntry("user", [{ type: "text", text: "step 1" }]),
        makeTraceEntry("assistant", [
          { type: "toolCall", name: "bash", arguments: { command: "ls" }, id: "t1" },
        ]),
        makeTraceEntry("toolResult", [{ type: "text", text: "file1 file2" }], { toolCallId: "t1" }),
        makeTraceEntry("assistant", [{ type: "text", text: "Found files." }]),
        makeTraceEntry("user", [{ type: "text", text: "step 2" }]),
        makeTraceEntry("assistant", [
          { type: "toolCall", name: "read", arguments: { path: "file1" }, id: "t2" },
          { type: "toolCall", name: "read", arguments: { path: "file2" }, id: "t3" },
        ]),
        makeTraceEntry("toolResult", [{ type: "text", text: "content1" }], { toolCallId: "t2" }),
        makeTraceEntry("toolResult", [{ type: "text", text: "content2" }], { toolCallId: "t3" }),
        makeTraceEntry("assistant", [{ type: "text", text: "Both files read." }]),
      ];
      const child = makeSession({
        id: "my-child",
        parentSessionId: "parent-1",
        piSessionFile: writeTrace("multi-turn.jsonl", trace),
      });
      const { inspect } = setup({ sessions: [child] });

      const result = await inspect.execute("tc-1", { id: "my-child" });
      expect(result.details.turnCount).toBe(2);
      expect(result.details.toolCount).toBe(3);
      expect(result.details.errorCount).toBe(0);
    });

    it("handles malformed JSONL lines gracefully", async () => {
      const path = join(tmpDir, "malformed.jsonl");
      writeFileSync(
        path,
        [
          JSON.stringify(makeTraceEntry("user", [{ type: "text", text: "hello" }])),
          "not valid json {{{",
          JSON.stringify(makeTraceEntry("assistant", [{ type: "text", text: "hi" }])),
        ].join("\n"),
      );

      const child = makeSession({
        id: "my-child",
        parentSessionId: "parent-1",
        piSessionFile: path,
      });
      const { inspect } = setup({ sessions: [child] });

      const result = await inspect.execute("tc-1", { id: "my-child" });
      // Should skip malformed line and still parse the valid ones
      expect(result.details.turnCount).toBe(1);
    });
  });
});

// ---------------------------------------------------------------------------
// formatToolArgs edge cases
// ---------------------------------------------------------------------------

describe("trace formatting", () => {
  it("formats bash tool args with long commands (truncated)", async () => {
    const trace = [
      makeTraceEntry("user", [{ type: "text", text: "run" }]),
      makeTraceEntry("assistant", [
        {
          type: "toolCall",
          name: "bash",
          arguments: { command: "A".repeat(200) + "\nsecond line" },
          id: "t1",
        },
      ]),
      makeTraceEntry("toolResult", [{ type: "text", text: "ok" }], { toolCallId: "t1" }),
      makeTraceEntry("assistant", [{ type: "text", text: "done" }]),
    ];
    const child = makeSession({
      id: "my-child",
      parentSessionId: "parent-1",
      piSessionFile: writeTrace("bash-args.jsonl", trace),
    });
    const { inspect } = setup({ sessions: [child] });

    const result = await inspect.execute("tc-1", { id: "my-child", turn: 1 });
    const text = result.content[0].text;
    // Should use first line, truncated
    expect(text).not.toContain("second line");
  });

  it("formats write tool args with line count", async () => {
    const trace = [
      makeTraceEntry("user", [{ type: "text", text: "write" }]),
      makeTraceEntry("assistant", [
        {
          type: "toolCall",
          name: "write",
          arguments: { path: "/src/app.ts", content: "line1\nline2\nline3" },
          id: "t1",
        },
      ]),
      makeTraceEntry("toolResult", [{ type: "text", text: "ok" }], { toolCallId: "t1" }),
      makeTraceEntry("assistant", [{ type: "text", text: "done" }]),
    ];
    const child = makeSession({
      id: "my-child",
      parentSessionId: "parent-1",
      piSessionFile: writeTrace("write-args.jsonl", trace),
    });
    const { inspect } = setup({ sessions: [child] });

    const result = await inspect.execute("tc-1", { id: "my-child", turn: 1 });
    expect(result.content[0].text).toContain("3 lines");
  });

  it("marks error tool results with ERROR label", async () => {
    const trace = [
      makeTraceEntry("user", [{ type: "text", text: "deploy" }]),
      makeTraceEntry("assistant", [
        { type: "toolCall", name: "bash", arguments: { command: "deploy.sh" }, id: "t1" },
      ]),
      makeTraceEntry("toolResult", [{ type: "text", text: "Permission denied" }], {
        toolCallId: "t1",
        isError: true,
      }),
      makeTraceEntry("assistant", [{ type: "text", text: "deployment failed" }]),
    ];
    const child = makeSession({
      id: "my-child",
      parentSessionId: "parent-1",
      piSessionFile: writeTrace("error-tool.jsonl", trace),
    });
    const { inspect } = setup({ sessions: [child] });

    const result = await inspect.execute("tc-1", { id: "my-child", turn: 1 });
    expect(result.content[0].text).toContain("ERROR");
    expect(result.content[0].text).toContain("Permission denied");
  });
});

// ---------------------------------------------------------------------------
// Tree cost aggregation
// ---------------------------------------------------------------------------

describe("tree cost aggregation (via check_agents)", () => {
  it("aggregates cost across parent and all descendants", async () => {
    const children = [
      makeSession({ id: "c1", parentSessionId: "parent-1", cost: 1.0, messageCount: 5 }),
      makeSession({ id: "c2", parentSessionId: "parent-1", cost: 2.0, messageCount: 10 }),
      makeSession({ id: "gc1", parentSessionId: "c1", cost: 0.5, messageCount: 3 }),
    ];
    // Parent session cost
    const parent = makeSession({ id: "parent-1", cost: 0.1, messageCount: 2 });
    const { check } = setup({ sessions: [parent, ...children] });

    const result = await check.execute("tc-1", {});
    const text = result.content[0].text;

    // Tree total should include parent + c1 + c2 + gc1
    expect(text).toContain("4 sessions");
    expect(text).toContain("20 msgs"); // 2 + 5 + 10 + 3
  });
});

// ---------------------------------------------------------------------------
// Duration formatting
// ---------------------------------------------------------------------------

describe("duration formatting (via check_agents)", () => {
  it("formats seconds-only durations", async () => {
    const child = makeSession({
      id: "c1",
      parentSessionId: "parent-1",
      createdAt: Date.now() - 45_000, // 45 seconds ago
    });
    const { check } = setup({ sessions: [child] });

    const result = await check.execute("tc-1", {});
    // Should show "45s" or similar
    expect(result.content[0].text).toMatch(/\d+s/);
  });

  it("formats minute+second durations", async () => {
    const child = makeSession({
      id: "c1",
      parentSessionId: "parent-1",
      createdAt: Date.now() - 125_000, // 2m5s ago
    });
    const { check } = setup({ sessions: [child] });

    const result = await check.execute("tc-1", {});
    expect(result.content[0].text).toMatch(/2m\d+s/);
  });
});

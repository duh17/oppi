import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

import { createSpawnAgentFactory, type SpawnAgentContext } from "./spawn-agent-extension.js";
import type { Session, ServerMessage } from "./types.js";

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

let nextId = 0;
function makeSession(overrides: Partial<Session> = {}): Session {
  const id = overrides.id ?? `sess-${++nextId}`;
  return {
    id,
    status: "stopped",
    createdAt: Date.now() - 60_000,
    lastActivity: Date.now(),
    messageCount: 5,
    tokens: { input: 1000, output: 500, cacheRead: 0, cacheWrite: 0 },
    cost: 0.05,
    name: `Session ${id}`,
    model: "anthropic/claude-sonnet-4-20250514",
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// Mock ExtensionAPI — captures registerTool calls
// ---------------------------------------------------------------------------

interface RegisteredTool {
  name: string;
  label: string;
  description: string;
  parameters: unknown;
  execute: (
    toolCallId: string,
    params: Record<string, unknown>,
    signal?: AbortSignal,
    onUpdate?: (update: { content: unknown[]; details: unknown }) => void,
    ctx?: unknown,
  ) => Promise<{
    content: { type: string; text: string }[];
    details?: unknown;
    isError?: boolean;
  }>;
}

interface MockExtensionAPI {
  tools: Map<string, RegisteredTool>;
  registerTool(tool: RegisteredTool): void;
  on(event: string, handler: (...args: unknown[]) => unknown): void;
}

function createMockAPI(): MockExtensionAPI {
  return {
    tools: new Map(),
    registerTool(tool) {
      this.tools.set(tool.name, tool);
    },
    on() {
      /* no-op for this test */
    },
  };
}

// ---------------------------------------------------------------------------
// Mock SpawnAgentContext
// ---------------------------------------------------------------------------

interface MockCtx extends SpawnAgentContext {
  sessions: Map<string, Session>;
  subscribers: Map<string, Set<(msg: ServerMessage) => void>>;
  spawnChildCalls: Array<{
    name?: string;
    model?: string;
    thinking?: string;
    prompt: string;
  }>;
  spawnDetachedCalls: Array<{
    name?: string;
    model?: string;
    thinking?: string;
    prompt: string;
  }>;
  /** Set to throw on next spawnChild call */
  spawnChildError?: Error;
}

function createMockCtx(sessionId: string, workspaceId = "ws-1"): MockCtx {
  const ctx: MockCtx = {
    workspaceId,
    sessionId,
    sessions: new Map(),
    subscribers: new Map(),
    spawnChildCalls: [],
    spawnDetachedCalls: [],
    spawnChildError: undefined,

    async spawnChild(params) {
      ctx.spawnChildCalls.push(params);
      if (ctx.spawnChildError) throw ctx.spawnChildError;
      const child = makeSession({
        id: `child-${nextId + 1}`,
        parentSessionId: sessionId,
        status: "busy",
        name: params.name,
        model: params.model,
        firstMessage: params.prompt,
      });
      ctx.sessions.set(child.id, child);
      return child;
    },

    async spawnDetached(params) {
      ctx.spawnDetachedCalls.push(params);
      if (ctx.spawnChildError) throw ctx.spawnChildError;
      const detached = makeSession({
        id: `detached-${nextId + 1}`,
        // No parentSessionId — this is the key difference
        status: "busy",
        name: params.name,
        model: params.model,
        firstMessage: params.prompt,
      });
      ctx.sessions.set(detached.id, detached);
      return detached;
    },

    listChildren() {
      return [...ctx.sessions.values()].filter((s) => s.parentSessionId === sessionId);
    },

    getSession(id) {
      return ctx.sessions.get(id);
    },

    listWorkspaceSessions() {
      return [...ctx.sessions.values()];
    },

    subscribe(id, callback) {
      if (!ctx.subscribers.has(id)) ctx.subscribers.set(id, new Set());
      ctx.subscribers.get(id)!.add(callback);
      return () => {
        ctx.subscribers.get(id)?.delete(callback);
      };
    },

    getAvailableModelIds() {
      return [];
    },
  };

  // Add the parent session itself
  ctx.sessions.set(sessionId, makeSession({ id: sessionId }));
  return ctx;
}

/** Emit a ServerMessage to all subscribers of a session. */
function emitMessage(ctx: MockCtx, sessionId: string, msg: ServerMessage): void {
  const subs = ctx.subscribers.get(sessionId);
  if (subs) {
    for (const cb of subs) cb(msg);
  }
}

// ---------------------------------------------------------------------------
// Factory helper — registers tools and returns lookup
// ---------------------------------------------------------------------------

function setup(sessionId = "parent-1"): {
  ctx: MockCtx;
  api: MockExtensionAPI;
  tool: (name: string) => RegisteredTool;
} {
  const ctx = createMockCtx(sessionId);
  const api = createMockAPI();
  const factory = createSpawnAgentFactory(ctx);
  factory(api as unknown as Parameters<typeof factory>[0]);
  const tool = (name: string): RegisteredTool => {
    const t = api.tools.get(name);
    if (!t) throw new Error(`Tool "${name}" not registered`);
    return t;
  };
  return { ctx, api, tool };
}

// ---------------------------------------------------------------------------
// JSONL trace file helpers
// ---------------------------------------------------------------------------

function writeTrace(dir: string, filename: string, entries: object[]): string {
  const filePath = path.join(dir, filename);
  const content = entries.map((e) => JSON.stringify(e)).join("\n") + "\n";
  fs.writeFileSync(filePath, content);
  return filePath;
}

function userMsg(text: string): object {
  return {
    type: "message",
    message: {
      role: "user",
      content: [{ type: "text", text }],
    },
  };
}

function assistantMsg(
  text: string,
  toolCalls: Array<{ id: string; name: string; arguments: Record<string, unknown> }> = [],
): object {
  const content: object[] = [];
  if (text) content.push({ type: "text", text });
  for (const tc of toolCalls) {
    content.push({
      type: "toolCall",
      id: tc.id,
      name: tc.name,
      arguments: tc.arguments,
    });
  }
  return {
    type: "message",
    message: { role: "assistant", content },
  };
}

function toolResult(callId: string, text: string, isError = false): object {
  return {
    type: "message",
    message: {
      role: "toolResult",
      toolCallId: callId,
      isError,
      content: [{ type: "text", text }],
    },
  };
}

// ===========================================================================
// Tests
// ===========================================================================

describe("spawn-agent-extension", () => {
  let tmpDir: string;

  beforeEach(() => {
    nextId = 0;
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "spawn-agent-test-"));
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  // -----------------------------------------------------------------------
  // Registration
  // -----------------------------------------------------------------------

  describe("tool registration", () => {
    it("registers spawn_agent, check_agents, inspect_agent", () => {
      const { api } = setup();
      expect(api.tools.has("spawn_agent")).toBe(true);
      expect(api.tools.has("check_agents")).toBe(true);
      expect(api.tools.has("inspect_agent")).toBe(true);
      expect(api.tools.size).toBe(3);
    });
  });

  // -----------------------------------------------------------------------
  // spawn_agent
  // -----------------------------------------------------------------------

  describe("spawn_agent", () => {
    it("fire-and-forget (default): returns session info immediately", async () => {
      const { tool } = setup();

      const result = await tool("spawn_agent").execute("tc1", {
        message: "Do the task",
        name: "my-child",
      });

      const text = result.content[0].text;
      expect(text).toContain("Spawned agent");
      expect(text).toContain("my-child");
      expect(text).toContain("running independently");
      expect(text).toContain("check_agents");
    });

    it("fire-and-forget: details include agentId and status", async () => {
      const { tool } = setup();

      const result = await tool("spawn_agent").execute("tc1", {
        message: "Do something",
      });

      const details = result.details as Record<string, unknown>;
      expect(details.agentId).toBeTruthy();
      expect(details.status).toBe("busy");
    });

    it("passes name, model, thinking to spawnChild", async () => {
      const { ctx, tool } = setup();

      await tool("spawn_agent").execute("tc1", {
        message: "task prompt",
        name: "custom-name",
        model: "anthropic/claude-opus-4-20250514",
        thinking: "high",
      });

      expect(ctx.spawnChildCalls.length).toBe(1);
      const call = ctx.spawnChildCalls[0];
      expect(call.name).toBe("custom-name");
      expect(call.model).toBe("anthropic/claude-opus-4-20250514");
      expect(call.thinking).toBe("high");
      expect(call.prompt).toBe("task prompt");
    });

    it("truncates message to 80 chars as default name", async () => {
      const { ctx, tool } = setup();
      const longMessage = "A".repeat(120);

      await tool("spawn_agent").execute("tc1", { message: longMessage });

      expect(ctx.spawnChildCalls[0].name).toBe("A".repeat(80));
    });

    it("rejects when depth >= MAX_SPAWN_DEPTH (2)", async () => {
      // Build a chain: root -> parent -> current (depth=2)
      const { ctx, tool } = setup("grandchild-1");
      ctx.sessions.set("root-1", makeSession({ id: "root-1" }));
      ctx.sessions.set("child-1", makeSession({ id: "child-1", parentSessionId: "root-1" }));
      ctx.sessions.set(
        "grandchild-1",
        makeSession({ id: "grandchild-1", parentSessionId: "child-1" }),
      );

      const result = await tool("spawn_agent").execute("tc1", {
        message: "should fail",
      });

      const text = result.content[0].text;
      expect(text).toContain("Cannot spawn");
      expect(text).toContain("max depth reached");
      expect(text).toContain("depth 2");
      expect(ctx.spawnChildCalls.length).toBe(0);
    });

    it("allows spawn at depth 1 (child of root)", async () => {
      // root -> current (depth=1)
      const { ctx, tool } = setup("child-1");
      ctx.sessions.set("root-1", makeSession({ id: "root-1" }));
      ctx.sessions.set("child-1", makeSession({ id: "child-1", parentSessionId: "root-1" }));

      const result = await tool("spawn_agent").execute("tc1", {
        message: "should succeed",
      });

      expect(result.content[0].text).toContain("Spawned agent");
      expect(ctx.spawnChildCalls.length).toBe(1);
    });

    it("handles circular parentSessionId references without infinite loop", async () => {
      // A -> B -> A (circular)
      const { ctx, tool } = setup("sess-a");
      ctx.sessions.set("sess-a", makeSession({ id: "sess-a", parentSessionId: "sess-b" }));
      ctx.sessions.set("sess-b", makeSession({ id: "sess-b", parentSessionId: "sess-a" }));

      // Should not hang — depth is finite due to visited guard
      const result = await tool("spawn_agent").execute("tc1", {
        message: "test circular",
      });

      // Just verify it completes (doesn't hang)
      expect(result.content[0].text).toBeTruthy();
    });

    it("catches spawnChild errors and returns error text", async () => {
      const { ctx, tool } = setup();
      ctx.spawnChildError = new Error("workspace is locked");

      const result = await tool("spawn_agent").execute("tc1", {
        message: "should error",
      });

      expect(result.content[0].text).toContain("Failed to spawn agent");
      expect(result.content[0].text).toContain("workspace is locked");
    });

    // --- Detached mode ---

    it("detached: calls spawnDetached instead of spawnChild", async () => {
      const { ctx, tool } = setup();

      const result = await tool("spawn_agent").execute("tc1", {
        message: "independent task",
        name: "detached-worker",
        detached: true,
      });

      expect(ctx.spawnDetachedCalls.length).toBe(1);
      expect(ctx.spawnChildCalls.length).toBe(0);
      expect(ctx.spawnDetachedCalls[0].prompt).toBe("independent task");

      const text = result.content[0].text;
      expect(text).toContain("detached");
      expect(text).toContain("independent session");
      expect(text).not.toContain("check_agents");
    });

    it("detached: details include detached=true", async () => {
      const { tool } = setup();

      const result = await tool("spawn_agent").execute("tc1", {
        message: "detached work",
        detached: true,
      });

      const details = result.details as Record<string, unknown>;
      expect(details.detached).toBe(true);
    });

    it("detached: non-detached details include detached=false", async () => {
      const { tool } = setup();

      const result = await tool("spawn_agent").execute("tc1", {
        message: "child work",
      });

      const details = result.details as Record<string, unknown>;
      expect(details.detached).toBe(false);
    });

    it("detached: wait mode works with detached sessions", async () => {
      const { ctx, tool } = setup();

      const promise = tool("spawn_agent").execute("tc1", {
        message: "detached wait task",
        detached: true,
        wait: true,
      });

      await vi.waitFor(() => expect(ctx.spawnDetachedCalls.length).toBe(1));

      const detachedId = [...ctx.sessions.keys()].find(
        (k) => k !== "parent-1" && k.startsWith("detached"),
      )!;
      const detached = ctx.sessions.get(detachedId)!;
      detached.status = "stopped";
      detached.lastMessage = "Detached done";

      emitMessage(ctx, detachedId, { type: "session_ended", reason: "done" });

      const result = await promise;
      expect(result.content[0].text).toContain("STOPPED");
      expect(ctx.spawnChildCalls.length).toBe(0);
    });

    // --- Wait mode ---

    it("wait mode: blocks until child reaches terminal status via subscribe", async () => {
      const { ctx, tool } = setup();

      const promise = tool("spawn_agent").execute("tc1", {
        message: "do work",
        name: "waiter",
        wait: true,
      });

      // Let the spawn happen
      await vi.waitFor(() => expect(ctx.spawnChildCalls.length).toBe(1));

      // Find the child session and make it terminal
      const childId = [...ctx.sessions.keys()].find((k) => k !== "parent-1")!;
      const child = ctx.sessions.get(childId)!;
      child.status = "stopped";
      child.lastMessage = "All done!";
      child.cost = 0.12;
      child.messageCount = 10;

      // Emit session_ended to trigger fast path via subscribe
      emitMessage(ctx, childId, {
        type: "session_ended",
        reason: "completed",
      });

      const result = await promise;
      const text = result.content[0].text;
      expect(text).toContain("waiter");
      expect(text).toContain("STOPPED");
      expect(text).toContain("All done!");

      const details = result.details as Record<string, unknown>;
      expect(details.waited).toBe(true);
      expect(details.cost).toBe(0.12);
    });

    it("wait mode: resolves via state message with terminal status", async () => {
      const { ctx, tool } = setup();

      const promise = tool("spawn_agent").execute("tc1", {
        message: "work",
        wait: true,
      });

      await vi.waitFor(() => expect(ctx.spawnChildCalls.length).toBe(1));

      const childId = [...ctx.sessions.keys()].find((k) => k !== "parent-1")!;
      const child = ctx.sessions.get(childId)!;
      child.status = "stopped";

      emitMessage(ctx, childId, {
        type: "state",
        session: child,
      });

      const result = await promise;
      expect(result.content[0].text).toContain("STOPPED");
    });

    it("wait mode fast path: already terminal resolves immediately with durationMs=0", async () => {
      const { ctx, tool } = setup();

      // Pre-create a stopped child
      const child = makeSession({
        id: "pre-stopped",
        parentSessionId: "parent-1",
        status: "stopped",
        lastMessage: "already done",
        cost: 0.03,
        messageCount: 3,
      });
      ctx.sessions.set(child.id, child);

      // Override spawnChild to return the already-stopped session
      ctx.spawnChild = async (params) => {
        ctx.spawnChildCalls.push(params);
        return child;
      };

      const result = await tool("spawn_agent").execute("tc1", {
        message: "already done task",
        wait: true,
      });

      const details = result.details as Record<string, unknown>;
      expect(details.durationMs).toBe(0);
      expect(details.waited).toBe(true);
      expect(result.content[0].text).toContain("STOPPED");
    });

    it("wait mode: includes changeStats in result", async () => {
      const { ctx, tool } = setup();

      const promise = tool("spawn_agent").execute("tc1", {
        message: "refactor code",
        wait: true,
      });

      await vi.waitFor(() => expect(ctx.spawnChildCalls.length).toBe(1));

      const childId = [...ctx.sessions.keys()].find((k) => k !== "parent-1")!;
      const child = ctx.sessions.get(childId)!;
      child.status = "stopped";
      child.changeStats = {
        mutatingToolCalls: 3,
        filesChanged: 2,
        addedLines: 50,
        removedLines: 10,
        changedFiles: ["/workspace/oppi/server/src/foo.ts", "/workspace/oppi/server/src/bar.ts"],
      };

      emitMessage(ctx, childId, { type: "session_ended", reason: "done" });

      const result = await promise;
      const text = result.content[0].text;
      expect(text).toContain("2 files");
      expect(text).toContain("+50/-10 lines");
    });

    it("wait mode timeout: resolves with timedOut=true", async () => {
      vi.useFakeTimers();
      try {
        const { ctx, tool } = setup();

        const promise = tool("spawn_agent").execute("tc1", {
          message: "slow task",
          wait: true,
          timeout_seconds: 5,
        });

        await vi.waitFor(() => expect(ctx.spawnChildCalls.length).toBe(1));

        // Advance past the timeout + poll interval
        await vi.advanceTimersByTimeAsync(10_000);

        const result = await promise;
        const text = result.content[0].text;
        expect(text).toContain("WARNING");
        expect(text).toContain("Timed out");
      } finally {
        vi.useRealTimers();
      }
    });

    it("wait mode: reads full response from JSONL trace instead of truncated lastMessage", async () => {
      const { ctx, tool } = setup();
      const fullResponse = "This is a very long response that would normally be truncated. ".repeat(
        20,
      );
      const tracePath = writeTrace(tmpDir, "child-trace.jsonl", [
        userMsg("do the analysis"),
        assistantMsg(fullResponse),
      ]);

      const promise = tool("spawn_agent").execute("tc1", {
        message: "analyze",
        wait: true,
      });

      await vi.waitFor(() => expect(ctx.spawnChildCalls.length).toBe(1));

      const childId = [...ctx.sessions.keys()].find((k) => k !== "parent-1")!;
      const child = ctx.sessions.get(childId)!;
      child.status = "stopped";
      child.lastMessage = fullResponse.slice(0, 100); // simulates the 100-char truncation
      child.piSessionFile = tracePath;

      emitMessage(ctx, childId, { type: "session_ended", reason: "done" });

      const result = await promise;
      const text = result.content[0].text;
      // Should contain the FULL response, not the truncated 100-char version
      expect(text).toContain("Last response:");
      expect(text).toContain(fullResponse);
      expect(text.length).toBeGreaterThan(200); // proves it's not truncated
    });

    it("wait mode: falls back to lastMessage when no trace file available", async () => {
      const { ctx, tool } = setup();

      const promise = tool("spawn_agent").execute("tc1", {
        message: "quick task",
        wait: true,
      });

      await vi.waitFor(() => expect(ctx.spawnChildCalls.length).toBe(1));

      const childId = [...ctx.sessions.keys()].find((k) => k !== "parent-1")!;
      const child = ctx.sessions.get(childId)!;
      child.status = "stopped";
      child.lastMessage = "Short truncated msg";
      // No piSessionFile set

      emitMessage(ctx, childId, { type: "session_ended", reason: "done" });

      const result = await promise;
      const text = result.content[0].text;
      expect(text).toContain("Last message:");
      expect(text).toContain("Short truncated msg");
    });

    it("wait mode abort: respects AbortSignal", async () => {
      const { ctx, tool } = setup();
      const controller = new AbortController();

      const promise = tool("spawn_agent").execute(
        "tc1",
        { message: "abortable task", wait: true },
        controller.signal,
      );

      await vi.waitFor(() => expect(ctx.spawnChildCalls.length).toBe(1));

      controller.abort();

      const result = await promise;
      // Should resolve (not throw) with current status
      expect(result.content[0].text).toBeTruthy();
    });
  });

  // -----------------------------------------------------------------------
  // check_agents
  // -----------------------------------------------------------------------

  describe("check_agents", () => {
    it("returns 'No child sessions found.' when no children", async () => {
      const { tool } = setup();

      const result = await tool("check_agents").execute("tc1", {});
      expect(result.content[0].text).toBe("No child sessions found.");
    });

    it("lists children with status icons, message count, cost, duration", async () => {
      const { ctx, tool } = setup();

      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          status: "busy",
          name: "Worker A",
          messageCount: 12,
          cost: 0.15,
        }),
      );
      ctx.sessions.set(
        "c2",
        makeSession({
          id: "c2",
          parentSessionId: "parent-1",
          status: "stopped",
          name: "Worker B",
          messageCount: 8,
          cost: 0.003,
        }),
      );

      const result = await tool("check_agents").execute("tc1", {});
      const text = result.content[0].text;

      // Status icons
      expect(text).toContain("⏳ Worker A");
      expect(text).toContain("✓ Worker B");
      // Counts
      expect(text).toContain("12 msgs");
      expect(text).toContain("8 msgs");
      // Cost formatting
      expect(text).toContain("$0.15");
      expect(text).toContain("$0.0030"); // < 0.01 → 4 decimal
      // Summary line
      expect(text).toContain("2 child sessions");
      expect(text).toContain("1 working");
      expect(text).toContain("1 done");
    });

    it("shows grandchild count per child", async () => {
      const { ctx, tool } = setup();

      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          status: "busy",
          name: "Delegator",
        }),
      );
      ctx.sessions.set("gc1", makeSession({ id: "gc1", parentSessionId: "c1", status: "stopped" }));
      ctx.sessions.set("gc2", makeSession({ id: "gc2", parentSessionId: "c1", status: "busy" }));

      const result = await tool("check_agents").execute("tc1", {});
      expect(result.content[0].text).toContain("+2 children");
    });

    it("shows tree cost aggregation", async () => {
      const { ctx, tool } = setup();

      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          cost: 0.1,
          messageCount: 5,
        }),
      );
      ctx.sessions.set(
        "c2",
        makeSession({
          id: "c2",
          parentSessionId: "parent-1",
          cost: 0.2,
          messageCount: 10,
        }),
      );

      const result = await tool("check_agents").execute("tc1", {});
      const text = result.content[0].text;
      expect(text).toContain("Tree total:");
      expect(text).toContain("3 sessions"); // parent + 2 children
    });

    it("summary counts error sessions", async () => {
      const { ctx, tool } = setup();

      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          status: "error",
          name: "Crashed",
        }),
      );

      const result = await tool("check_agents").execute("tc1", {});
      const text = result.content[0].text;
      expect(text).toContain("✗ Crashed");
      expect(text).toContain("1 error");
    });

    it("details contain agents array", async () => {
      const { ctx, tool } = setup();

      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          status: "stopped",
        }),
      );

      const result = await tool("check_agents").execute("tc1", {});
      const details = result.details as { agents: unknown[] };
      expect(details.agents.length).toBe(1);
    });
  });

  // -----------------------------------------------------------------------
  // inspect_agent
  // -----------------------------------------------------------------------

  describe("inspect_agent", () => {
    it("returns error when session not found", async () => {
      const { tool } = setup();

      const result = await tool("inspect_agent").execute("tc1", {
        id: "nonexistent",
      });

      expect(result.content[0].text).toContain("Session not found");
    });

    it("returns error when session not in tree", async () => {
      const { ctx, tool } = setup();

      // Add a session that isn't related to the parent at all
      ctx.sessions.set(
        "orphan-1",
        makeSession({ id: "orphan-1" }), // no parentSessionId
      );

      const result = await tool("inspect_agent").execute("tc1", {
        id: "orphan-1",
      });

      expect(result.content[0].text).toContain("not in this session's tree");
    });

    it("allows inspecting direct child", async () => {
      const { ctx, tool } = setup();
      const tracePath = writeTrace(tmpDir, "child.jsonl", [
        userMsg("hello"),
        assistantMsg("hi there"),
      ]);
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", { id: "c1" });
      expect(result.content[0].text).toContain("1 turns");
    });

    it("allows inspecting grandchild (descendant in tree)", async () => {
      const { ctx, tool } = setup();
      const tracePath = writeTrace(tmpDir, "gc.jsonl", [
        userMsg("deep task"),
        assistantMsg("done"),
      ]);
      ctx.sessions.set("c1", makeSession({ id: "c1", parentSessionId: "parent-1" }));
      ctx.sessions.set(
        "gc1",
        makeSession({
          id: "gc1",
          parentSessionId: "c1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", { id: "gc1" });
      expect(result.content[0].text).toContain("1 turns");
    });

    it("returns error when no trace file available", async () => {
      const { ctx, tool } = setup();
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          // no piSessionFile
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", { id: "c1" });
      expect(result.content[0].text).toContain("No trace file available");
    });

    it("returns empty trace message when JSONL file is empty", async () => {
      const { ctx, tool } = setup();
      const tracePath = path.join(tmpDir, "empty.jsonl");
      fs.writeFileSync(tracePath, "");
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", { id: "c1" });
      expect(result.content[0].text).toContain("Trace is empty");
    });

    // --- Overview level ---

    it("overview: renders turn count, tool counts, error markers", async () => {
      const { ctx, tool } = setup();
      const tracePath = writeTrace(tmpDir, "trace.jsonl", [
        userMsg("fix the bug"),
        assistantMsg("Let me read the file", [
          { id: "tc1", name: "read", arguments: { path: "/workspace/oppi/server/src/foo.ts" } },
        ]),
        toolResult("tc1", "file contents here"),
        assistantMsg("Now editing", [
          { id: "tc2", name: "edit", arguments: { path: "/workspace/oppi/server/src/foo.ts" } },
        ]),
        toolResult("tc2", "edit failed", true),
        userMsg("try again"),
        assistantMsg("Fixed it", [
          { id: "tc3", name: "edit", arguments: { path: "/workspace/oppi/server/src/foo.ts" } },
        ]),
        toolResult("tc3", "edit applied"),
      ]);
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", { id: "c1" });
      const text = result.content[0].text;

      // Summary line
      expect(text).toContain("2 turns");
      expect(text).toContain("3 tool calls");
      expect(text).toContain("1 errors");

      // Tool breakdown
      expect(text).toContain("edit:2");
      expect(text).toContain("read:1");

      // Error marker on turn 1
      expect(text).toContain("<- 1 error");

      // Last response
      expect(text).toContain('Last response: "Fixed it"');

      // Details
      const details = result.details as Record<string, unknown>;
      expect(details.level).toBe("overview");
      expect(details.turnCount).toBe(2);
      expect(details.toolCount).toBe(3);
      expect(details.errorCount).toBe(1);
    });

    it("overview: shows file changes from write/edit tools", async () => {
      const { ctx, tool } = setup();
      const tracePath = writeTrace(tmpDir, "trace.jsonl", [
        userMsg("create files"),
        assistantMsg("writing", [
          { id: "tc1", name: "write", arguments: { path: "src/new.ts", content: "line1\nline2" } },
          { id: "tc2", name: "edit", arguments: { path: "src/old.ts" } },
        ]),
        toolResult("tc1", "written"),
        toolResult("tc2", "edited"),
      ]);
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", { id: "c1" });
      // 2 unique files changed
      expect(result.content[0].text).toContain("2 files changed");
    });

    it("overview: text-only turn shows 'text only'", async () => {
      const { ctx, tool } = setup();
      const tracePath = writeTrace(tmpDir, "trace.jsonl", [
        userMsg("just chat"),
        assistantMsg("here's your answer"),
      ]);
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", { id: "c1" });
      expect(result.content[0].text).toContain("text only");
    });

    // --- Turn detail level ---

    it("turn detail: renders prompt, tool list with args preview", async () => {
      const { ctx, tool } = setup();
      const tracePath = writeTrace(tmpDir, "trace.jsonl", [
        userMsg("read the config"),
        assistantMsg("reading", [
          {
            id: "tc1",
            name: "bash",
            arguments: { command: "cat /etc/config.yaml\necho done" },
          },
          {
            id: "tc2",
            name: "read",
            arguments: { path: "/workspace/oppi/server/tsconfig.json", offset: 10, limit: 20 },
          },
        ]),
        toolResult("tc1", "config contents"),
        toolResult("tc2", "json contents"),
      ]);
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", {
        id: "c1",
        turn: 1,
      });
      const text = result.content[0].text;

      expect(text).toContain("Turn 1");
      expect(text).toContain("2 tool calls");
      // bash: first line of command
      expect(text).toContain("cat /etc/config.yaml");
      // read: path with offset+limit
      expect(text).toContain(":10");
      expect(text).toContain("+20");

      const details = result.details as Record<string, unknown>;
      expect(details.level).toBe("turn");
    });

    it("turn detail: shows error preview lines", async () => {
      const { ctx, tool } = setup();
      const tracePath = writeTrace(tmpDir, "trace.jsonl", [
        userMsg("run tests"),
        assistantMsg("running", [{ id: "tc1", name: "bash", arguments: { command: "npm test" } }]),
        toolResult("tc1", "FAIL: assertion error\nExpected 3 but got 5\nline3", true),
      ]);
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", {
        id: "c1",
        turn: 1,
      });
      const text = result.content[0].text;
      expect(text).toContain("ERROR");
      expect(text).toContain("FAIL: assertion error");
    });

    it("turn detail: turn not found returns error", async () => {
      const { ctx, tool } = setup();
      const tracePath = writeTrace(tmpDir, "trace.jsonl", [userMsg("hello"), assistantMsg("hi")]);
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", {
        id: "c1",
        turn: 99,
      });
      expect(result.content[0].text).toContain("Turn 99 not found");
      expect(result.content[0].text).toContain("1 turns available");
    });

    // --- Tool detail level ---

    it("tool detail: renders full args and output", async () => {
      const { ctx, tool } = setup();
      const longOutput = "line\n".repeat(50);
      const tracePath = writeTrace(tmpDir, "trace.jsonl", [
        userMsg("edit file"),
        assistantMsg("editing", [
          {
            id: "tc1",
            name: "write",
            arguments: {
              path: "/workspace/oppi/server/src/test.ts",
              content: "const x = 1;\nconst y = 2;\n",
            },
          },
        ]),
        toolResult("tc1", longOutput),
      ]);
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", {
        id: "c1",
        turn: 1,
        tool: 1,
      });
      const text = result.content[0].text;

      expect(text).toContain("Turn 1, Tool [1]");
      expect(text).toContain("Name: write");
      expect(text).toContain("Error: false");
      // Full args
      expect(text).toContain("path: /workspace/oppi/server/src/test.ts");
      expect(text).toContain("content: const x = 1;");
      // Output section
      expect(text).toContain("Output (");
      expect(text).toContain("chars");

      const details = result.details as Record<string, unknown>;
      expect(details.level).toBe("tool");
    });

    it("tool detail: tool not found returns error", async () => {
      const { ctx, tool } = setup();
      const tracePath = writeTrace(tmpDir, "trace.jsonl", [
        userMsg("do thing"),
        assistantMsg("done"), // no tool calls
      ]);
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", {
        id: "c1",
        turn: 1,
        tool: 1,
      });
      expect(result.content[0].text).toContain("Tool [1] not found in turn 1");
    });

    it("tool detail: shows isError=true for errored tool", async () => {
      const { ctx, tool } = setup();
      const tracePath = writeTrace(tmpDir, "trace.jsonl", [
        userMsg("run it"),
        assistantMsg("running", [{ id: "tc1", name: "bash", arguments: { command: "exit 1" } }]),
        toolResult("tc1", "command failed", true),
      ]);
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", {
        id: "c1",
        turn: 1,
        tool: 1,
      });
      expect(result.content[0].text).toContain("Error: true");
    });

    // --- JSONL parsing edge cases ---

    it("handles malformed JSONL lines gracefully", async () => {
      const { ctx, tool } = setup();
      const tracePath = path.join(tmpDir, "bad.jsonl");
      fs.writeFileSync(
        tracePath,
        [
          JSON.stringify({
            type: "message",
            message: { role: "user", content: [{ type: "text", text: "good" }] },
          }),
          "not valid json {{{",
          JSON.stringify({
            type: "message",
            message: { role: "assistant", content: [{ type: "text", text: "response" }] },
          }),
        ].join("\n") + "\n",
      );
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", { id: "c1" });
      // Should still parse the valid lines
      expect(result.content[0].text).toContain("1 turns");
    });

    it("handles missing trace file (returns empty)", async () => {
      const { ctx, tool } = setup();
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: "/nonexistent/trace.jsonl",
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", { id: "c1" });
      expect(result.content[0].text).toContain("Trace is empty");
    });

    it("assistant without prior user creates synthetic turn", async () => {
      const { ctx, tool } = setup();
      const tracePath = writeTrace(tmpDir, "trace.jsonl", [
        // No user message first — assistant starts directly
        assistantMsg("I'm starting up"),
      ]);
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", {
        id: "c1",
        turn: 1,
      });
      expect(result.content[0].text).toContain("(session start)");
    });

    // --- response param ---

    it("response=true without turn: returns full last response text", async () => {
      const { ctx, tool } = setup();
      const longResponse = "Detailed analysis:\n" + "Finding ".repeat(500);
      const tracePath = writeTrace(tmpDir, "trace.jsonl", [
        userMsg("analyze the codebase"),
        assistantMsg("Looking at it...", [
          { id: "tc1", name: "read", arguments: { path: "src/foo.ts" } },
        ]),
        toolResult("tc1", "file contents"),
        userMsg("what did you find?"),
        assistantMsg(longResponse),
      ]);
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", {
        id: "c1",
        response: true,
      });
      const text = result.content[0].text;
      // Full response — no truncation
      expect(text).toBe(longResponse);
    });

    it("response=true with turn: returns that turn's response", async () => {
      const { ctx, tool } = setup();
      const tracePath = writeTrace(tmpDir, "trace.jsonl", [
        userMsg("first question"),
        assistantMsg("first answer — very specific"),
        userMsg("second question"),
        assistantMsg("second answer — different content"),
      ]);
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", {
        id: "c1",
        turn: 1,
        response: true,
      });
      expect(result.content[0].text).toBe("first answer — very specific");
    });

    it("response=true: turn not found returns error", async () => {
      const { ctx, tool } = setup();
      const tracePath = writeTrace(tmpDir, "trace.jsonl", [
        userMsg("only turn"),
        assistantMsg("only response"),
      ]);
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", {
        id: "c1",
        turn: 99,
        response: true,
      });
      expect(result.content[0].text).toContain("Turn 99 not found");
    });

    it("response=true: no response text returns descriptive message", async () => {
      const { ctx, tool } = setup();
      const tracePath = writeTrace(tmpDir, "trace.jsonl", [
        userMsg("do it"),
        assistantMsg("", [{ id: "tc1", name: "bash", arguments: { command: "ls" } }]),
        toolResult("tc1", "file list"),
        // No final text response after tool call
      ]);
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", {
        id: "c1",
        response: true,
      });
      // The last turn has no assistantText (only tool calls)
      expect(result.content[0].text).toContain("No assistant response");
    });
  });

  // -----------------------------------------------------------------------
  // Formatting helpers (tested through tool outputs)
  // -----------------------------------------------------------------------

  describe("formatting (through tool outputs)", () => {
    it("formatDuration: seconds", async () => {
      const { ctx, tool } = setup();
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          status: "stopped",
          createdAt: Date.now() - 45_000, // 45 seconds ago
        }),
      );

      const result = await tool("check_agents").execute("tc1", {});
      expect(result.content[0].text).toMatch(/45s/);
    });

    it("formatDuration: minutes and seconds", async () => {
      const { ctx, tool } = setup();
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          status: "stopped",
          createdAt: Date.now() - 125_000, // 2m5s ago
        }),
      );

      const result = await tool("check_agents").execute("tc1", {});
      expect(result.content[0].text).toMatch(/2m5s/);
    });

    it("formatDuration: exact minutes (no seconds suffix)", async () => {
      const { ctx, tool } = setup();
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          status: "stopped",
          createdAt: Date.now() - 180_000, // exactly 3m
        }),
      );

      const result = await tool("check_agents").execute("tc1", {});
      // Should show "3m" not "3m0s"
      expect(result.content[0].text).toMatch(/\b3m\b/);
    });

    it("formatCost: zero", async () => {
      const { ctx, tool } = setup();
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          status: "stopped",
          cost: 0,
        }),
      );

      const result = await tool("check_agents").execute("tc1", {});
      expect(result.content[0].text).toContain("$0");
    });

    it("formatCost: small amount < 0.01 uses 4 decimals", async () => {
      const { ctx, tool } = setup();
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          status: "stopped",
          cost: 0.0042,
        }),
      );

      const result = await tool("check_agents").execute("tc1", {});
      expect(result.content[0].text).toContain("$0.0042");
    });

    it("formatCost: normal amount >= 0.01 uses 2 decimals", async () => {
      const { ctx, tool } = setup();
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          status: "stopped",
          cost: 1.567,
        }),
      );

      const result = await tool("check_agents").execute("tc1", {});
      expect(result.content[0].text).toContain("$1.57");
    });

    it("formatToolArgs: bash shows first line", async () => {
      const { ctx, tool } = setup();
      const tracePath = writeTrace(tmpDir, "trace.jsonl", [
        userMsg("test"),
        assistantMsg("", [
          {
            id: "tc1",
            name: "bash",
            arguments: { command: "echo first\necho second\necho third" },
          },
        ]),
        toolResult("tc1", "ok"),
      ]);
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", {
        id: "c1",
        turn: 1,
      });
      expect(result.content[0].text).toContain("echo first");
      // Should NOT contain second/third in the args preview
      expect(result.content[0].text).not.toContain("echo second");
    });

    it("formatToolArgs: read shows path:offset+limit", async () => {
      const { ctx, tool } = setup();
      const tracePath = writeTrace(tmpDir, "trace.jsonl", [
        userMsg("read"),
        assistantMsg("", [
          {
            id: "tc1",
            name: "read",
            arguments: { path: "/workspace/oppi/server/src/foo.ts", offset: 50, limit: 100 },
          },
        ]),
        toolResult("tc1", "file content"),
      ]);
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", {
        id: "c1",
        turn: 1,
      });
      const text = result.content[0].text;
      expect(text).toContain(":50");
      expect(text).toContain("+100");
    });

    it("formatToolArgs: write shows path and line count", async () => {
      const { ctx, tool } = setup();
      const tracePath = writeTrace(tmpDir, "trace.jsonl", [
        userMsg("write"),
        assistantMsg("", [
          {
            id: "tc1",
            name: "write",
            arguments: {
              path: "/workspace/oppi/server/src/new.ts",
              content: "a\nb\nc\n",
            },
          },
        ]),
        toolResult("tc1", "written"),
      ]);
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", {
        id: "c1",
        turn: 1,
      });
      expect(result.content[0].text).toMatch(/\(4 lines\)/); // "a\nb\nc\n" → 4 lines
    });

    it("formatToolArgs: edit shows path only", async () => {
      const { ctx, tool } = setup();
      const tracePath = writeTrace(tmpDir, "trace.jsonl", [
        userMsg("edit"),
        assistantMsg("", [
          {
            id: "tc1",
            name: "edit",
            arguments: { path: "/workspace/oppi/server/src/foo.ts", oldText: "a", newText: "b" },
          },
        ]),
        toolResult("tc1", "edited"),
      ]);
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", {
        id: "c1",
        turn: 1,
      });
      // Should show shortened path
      const text = result.content[0].text;
      expect(text).toContain("foo.ts");
    });

    it("formatToolArgs: default shows first string value", async () => {
      const { ctx, tool } = setup();
      const tracePath = writeTrace(tmpDir, "trace.jsonl", [
        userMsg("custom"),
        assistantMsg("", [
          {
            id: "tc1",
            name: "custom_tool",
            arguments: { query: "find all tests", count: 10 },
          },
        ]),
        toolResult("tc1", "results"),
      ]);
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", {
        id: "c1",
        turn: 1,
      });
      expect(result.content[0].text).toContain("find all tests");
    });
  });

  // -----------------------------------------------------------------------
  // Tree utilities (tested through tool behaviors)
  // -----------------------------------------------------------------------

  describe("tree utilities (through tools)", () => {
    it("getDescendants: collects all children and grandchildren", async () => {
      const { ctx, tool } = setup();

      // parent-1 -> c1 -> gc1, gc2
      // parent-1 -> c2
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          cost: 0.1,
          messageCount: 5,
        }),
      );
      ctx.sessions.set(
        "c2",
        makeSession({
          id: "c2",
          parentSessionId: "parent-1",
          cost: 0.2,
          messageCount: 10,
        }),
      );
      ctx.sessions.set(
        "gc1",
        makeSession({
          id: "gc1",
          parentSessionId: "c1",
          cost: 0.05,
          messageCount: 3,
        }),
      );
      ctx.sessions.set(
        "gc2",
        makeSession({
          id: "gc2",
          parentSessionId: "c1",
          cost: 0.08,
          messageCount: 7,
        }),
      );

      const result = await tool("check_agents").execute("tc1", {});
      const text = result.content[0].text;

      // Tree total should include parent + c1 + c2 + gc1 + gc2 = 5 sessions
      expect(text).toContain("5 sessions");
    });

    it("computeTreeCost: sums cost across entire tree", async () => {
      const { ctx, tool } = setup();

      // parent-1 (cost=0.05) -> c1 (cost=0.10)
      const parent = ctx.sessions.get("parent-1")!;
      parent.cost = 0.05;
      parent.messageCount = 2;

      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          cost: 0.1,
          messageCount: 8,
        }),
      );

      const result = await tool("check_agents").execute("tc1", {});
      const text = result.content[0].text;

      // Total cost = 0.05 + 0.10 = 0.15
      expect(text).toContain("$0.15");
      // Total messages = 2 + 8 = 10
      expect(text).toContain("10 msgs");
    });

    it("getDescendants skips visited nodes (circular reference)", async () => {
      const { ctx, tool } = setup();

      // Create a would-be circular: c1 -> c2 -> c1 (via parentSessionId)
      // In practice parentSessionId chains don't form cycles in getDescendants
      // because it only looks at children, but the visited set protects
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          cost: 0.1,
        }),
      );

      const result = await tool("check_agents").execute("tc1", {});
      // Should complete without hanging
      expect(result.content[0].text).toContain("1 child session");
    });

    it("getRootSessionId walks to tree root", async () => {
      // This is tested via check_agents which calls getRootSessionId → computeTreeCost
      // root -> parent -> current
      const { ctx, tool } = setup("mid-1");

      ctx.sessions.set("root-1", makeSession({ id: "root-1", cost: 0.5, messageCount: 20 }));
      ctx.sessions.set(
        "mid-1",
        makeSession({ id: "mid-1", parentSessionId: "root-1", cost: 0.1, messageCount: 5 }),
      );
      ctx.sessions.set(
        "c1",
        makeSession({ id: "c1", parentSessionId: "mid-1", cost: 0.05, messageCount: 3 }),
      );

      const result = await tool("check_agents").execute("tc1", {});
      const text = result.content[0].text;

      // Tree total should start from root-1: root + mid + c1 = 3 sessions
      expect(text).toContain("3 sessions");
      // Total cost = 0.50 + 0.10 + 0.05 = 0.65
      expect(text).toContain("$0.65");
    });
  });
});

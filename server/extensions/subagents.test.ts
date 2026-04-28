import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

import { createSubagentsFactory, type SubagentsContext } from "./subagents.js";
import type { Session, ServerMessage, SubagentConfig } from "../src/types.js";

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
    workspaceId: "ws-1",
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
  sentMessages: Array<{ message: Record<string, unknown>; options?: Record<string, unknown> }>;
  handlers: Map<string, Array<(...args: unknown[]) => unknown>>;
  registerTool(tool: RegisteredTool): void;
  on(event: string, handler: (...args: unknown[]) => unknown): void;
  sendMessage(message: Record<string, unknown>, options?: Record<string, unknown>): void;
}

function createMockAPI(): MockExtensionAPI {
  return {
    tools: new Map(),
    sentMessages: [],
    handlers: new Map(),
    registerTool(tool) {
      this.tools.set(tool.name, tool);
    },
    on(event, handler) {
      const handlers = this.handlers.get(event) ?? [];
      handlers.push(handler);
      this.handlers.set(event, handlers);
    },
    sendMessage(message, options) {
      this.sentMessages.push({ message, options });
    },
  };
}

// ---------------------------------------------------------------------------
// Mock SubagentsContext
// ---------------------------------------------------------------------------

interface MockCtx extends SubagentsContext {
  sessions: Map<string, Session>;
  subscribers: Map<string, Set<(msg: ServerMessage) => void>>;
  stopSessionCalls: string[];
  sendMessageCalls: Array<{
    sessionId: string;
    message: string;
    behavior?: "steer" | "followUp";
  }>;
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
  /** Set to throw on next sendMessage call */
  sendMessageError?: Error;
}

function createMockCtx(sessionId: string, workspaceId = "ws-1"): MockCtx {
  const ctx: MockCtx = {
    workspaceId,
    sessionId,
    sessions: new Map(),
    subscribers: new Map(),
    stopSessionCalls: [],
    sendMessageCalls: [],
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
      return [...ctx.sessions.values()].filter((s) => s.workspaceId === workspaceId);
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

    async stopSession(sessionId: string) {
      ctx.stopSessionCalls.push(sessionId);
      const session = ctx.sessions.get(sessionId);
      if (session) {
        ctx.sessions.set(sessionId, makeSession({ ...session, status: "stopped" }));
      }
    },

    async resumeSession(sessionId: string) {
      const session = ctx.sessions.get(sessionId);
      if (!session) throw new Error(`Session not found: ${sessionId}`);
      const resumed = makeSession({ ...session, status: "ready" });
      ctx.sessions.set(sessionId, resumed);
      return resumed;
    },

    async sendMessage(sessionId: string, message: string, behavior?: "steer" | "followUp") {
      if (ctx.sendMessageError) throw ctx.sendMessageError;
      ctx.sendMessageCalls.push({ sessionId, message, behavior });
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

function setup(
  sessionId = "parent-1",
  options?: { childMode?: boolean; subagentConfig?: SubagentConfig },
): {
  ctx: MockCtx;
  api: MockExtensionAPI;
  tool: (name: string) => RegisteredTool;
} {
  const ctx = createMockCtx(sessionId);
  const api = createMockAPI();
  const factory = createSubagentsFactory(ctx, options);
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

describe("subagents-extension", () => {
  let tmpDir: string;

  beforeEach(() => {
    nextId = 0;
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "subagents-test-"));
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  // -----------------------------------------------------------------------
  // Registration
  // -----------------------------------------------------------------------

  describe("tool registration", () => {
    it("registers spawn_agent, stop_agent, send_message, inspect_agent", () => {
      const { api } = setup();
      expect(api.tools.has("spawn_agent")).toBe(true);
      expect(api.tools.has("stop_agent")).toBe(true);
      expect(api.tools.has("send_message")).toBe(true);
      expect(api.tools.has("inspect_agent")).toBe(true);
      expect(api.tools.has("check_agents")).toBe(false);
      expect(api.tools.size).toBe(4);
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
      expect(text).toContain("subagent_result");
      expect(text).not.toContain("check_agents");
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

    it("fire-and-forget: sends subagent_result immediately when parent is idle", async () => {
      const { api, ctx, tool } = setup();
      ctx.sessions.set(
        "parent-1",
        makeSession({ id: "parent-1", status: "ready", name: "Parent" }),
      );

      await tool("spawn_agent").execute("tc1", {
        message: "Do something",
        name: "worker",
      });

      const childId = [...ctx.sessions.keys()].find((k) => k !== "parent-1")!;
      const child = ctx.sessions.get(childId)!;
      child.status = "stopped";
      child.lastMessage = "Finished the work";

      emitMessage(ctx, childId, { type: "session_ended", reason: "done" });

      expect(api.sentMessages).toHaveLength(1);
      expect(api.sentMessages[0].message.customType).toBe("subagent_result");
      expect(api.sentMessages[0].message.content).toContain("Finished the work");
      expect(api.sentMessages[0].options).toBeUndefined();
    });

    it("fire-and-forget: queues subagent_result as follow-up when parent is busy", async () => {
      const { api, ctx, tool } = setup();
      ctx.sessions.set("parent-1", makeSession({ id: "parent-1", status: "busy", name: "Parent" }));

      await tool("spawn_agent").execute("tc1", {
        message: "Do something",
        name: "worker",
      });

      const childId = [...ctx.sessions.keys()].find((k) => k !== "parent-1")!;
      const child = ctx.sessions.get(childId)!;
      child.status = "stopped";
      child.lastMessage = "Finished the work";

      emitMessage(ctx, childId, { type: "state", session: child });

      expect(api.sentMessages).toHaveLength(1);
      expect(api.sentMessages[0].message.customType).toBe("subagent_result");
      expect(api.sentMessages[0].options).toEqual({ deliverAs: "followUp", triggerTurn: true });
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

    it("applies default subagent model policy when model/thinking are omitted", async () => {
      const { ctx, tool } = setup("parent-1", {
        subagentConfig: {
          maxDepth: 1,
          autoStopWhenDone: false,
          childIdleTimeoutMs: 300_000,
          startupGraceMs: 60_000,
          defaultWaitTimeoutMs: 1_800_000,
          modelPolicy: {
            approvedModels: ["openai-codex/gpt-5.4-mini", "openai-codex/gpt-5.5"],
            defaultModel: "openai-codex/gpt-5.4-mini",
            defaultThinking: "minimal",
          },
        },
      });

      await tool("spawn_agent").execute("tc1", {
        message: "discover the codebase",
      });

      expect(ctx.spawnChildCalls[0].model).toBe("openai-codex/gpt-5.4-mini");
      expect(ctx.spawnChildCalls[0].thinking).toBe("minimal");
    });

    it("applies configured profile defaults and prompt guidelines", async () => {
      const { ctx, tool } = setup("parent-1", {
        subagentConfig: {
          maxDepth: 1,
          autoStopWhenDone: false,
          childIdleTimeoutMs: 300_000,
          startupGraceMs: 60_000,
          defaultWaitTimeoutMs: 1_800_000,
          modelPolicy: {
            approvedModels: ["openai-codex/gpt-5.4-mini", "openai-codex/gpt-5.5"],
            defaultModel: "openai-codex/gpt-5.5",
            profiles: {
              discovery: {
                description: "Fast repo and web discovery lane.",
                model: "openai-codex/gpt-5.4-mini",
                thinking: "minimal",
                guidelines: [
                  "Prefer search and inspection before editing.",
                  "Stay cheap and fast unless the evidence says otherwise.",
                ],
              },
            },
          },
        },
      });

      await tool("spawn_agent").execute("tc1", {
        message: "inspect the repo and summarize hotspots",
        profile: "discovery",
      });

      expect(ctx.spawnChildCalls[0].model).toBe("openai-codex/gpt-5.4-mini");
      expect(ctx.spawnChildCalls[0].thinking).toBe("minimal");
      expect(ctx.spawnChildCalls[0].prompt).toContain("[Subagent profile: discovery]");
      expect(ctx.spawnChildCalls[0].prompt).toContain(
        "Prefer search and inspection before editing.",
      );
      expect(ctx.spawnChildCalls[0].prompt).toContain("inspect the repo and summarize hotspots");
    });

    it("rejects models outside the approved subagent list", async () => {
      const { ctx, tool } = setup("parent-1", {
        subagentConfig: {
          maxDepth: 1,
          autoStopWhenDone: false,
          childIdleTimeoutMs: 300_000,
          startupGraceMs: 60_000,
          defaultWaitTimeoutMs: 1_800_000,
          modelPolicy: {
            approvedModels: ["openai-codex/gpt-5.4-mini"],
          },
        },
      });

      const result = await tool("spawn_agent").execute("tc1", {
        message: "do work",
        model: "openrouter/openai/gpt-5",
      });

      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("not approved for subagents");
      expect(ctx.spawnChildCalls.length).toBe(0);
    });

    it("rejects unknown profiles and lists configured ones", async () => {
      const { ctx, tool } = setup("parent-1", {
        subagentConfig: {
          maxDepth: 1,
          autoStopWhenDone: false,
          childIdleTimeoutMs: 300_000,
          startupGraceMs: 60_000,
          defaultWaitTimeoutMs: 1_800_000,
          modelPolicy: {
            profiles: {
              discovery: { model: "openai-codex/gpt-5.4-mini" },
            },
          },
        },
      });

      const result = await tool("spawn_agent").execute("tc1", {
        message: "do work",
        profile: "review",
      });

      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("Unknown subagent profile");
      expect(result.content[0].text).toContain("discovery");
      expect(ctx.spawnChildCalls.length).toBe(0);
    });

    it("rejects when depth >= MAX_SPAWN_DEPTH (1)", async () => {
      // Build a chain: root -> current (depth=1) — child cannot spawn
      const { ctx, tool } = setup("child-1");
      ctx.sessions.set("root-1", makeSession({ id: "root-1" }));
      ctx.sessions.set("child-1", makeSession({ id: "child-1", parentSessionId: "root-1" }));

      const result = await tool("spawn_agent").execute("tc1", {
        message: "should fail",
      });

      const text = result.content[0].text;
      expect(text).toContain("Cannot spawn");
      expect(text).toContain("max depth reached");
      expect(text).toContain("depth 1");
      expect(ctx.spawnChildCalls.length).toBe(0);
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

    it("rejects unsupported fork parameters", async () => {
      const { ctx, tool } = setup();

      const result = await tool("spawn_agent").execute("tc1", {
        message: "should error",
        fork: true,
        entryId: "entry-123",
      });

      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("does not support fork");
      expect(ctx.spawnChildCalls.length).toBe(0);
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
  // stop_agent
  // -----------------------------------------------------------------------

  describe("stop_agent", () => {
    it("stops a running child session", async () => {
      const { ctx, tool } = setup();
      // Spawn a child first
      await tool("spawn_agent").execute("tc1", { message: "Do work" });
      const childId = ctx.listChildren()[0].id;

      const result = await tool("stop_agent").execute("tc2", { id: childId });
      const details = result.details as Record<string, unknown>;
      expect(result.content[0].text).toContain("Stopped agent");
      expect(details.status).toBe("stopped");
      expect(ctx.stopSessionCalls).toContain(childId);
      // Verify mock updated the session status
      expect(ctx.getSession(childId)?.status).toBe("stopped");
    });

    it("returns error for unknown session ID", async () => {
      const { tool } = setup();
      const result = await tool("stop_agent").execute("tc1", { id: "nonexistent" });
      expect(result.content[0].text).toContain("Session not found");
    });

    it("returns already-stopped for terminal sessions", async () => {
      const { ctx, tool } = setup();
      // Add a stopped child
      ctx.sessions.set(
        "child-done",
        makeSession({ id: "child-done", parentSessionId: "parent-1", status: "stopped" }),
      );

      const result = await tool("stop_agent").execute("tc1", { id: "child-done" });
      expect(result.content[0].text).toContain("already stopped");
      expect(ctx.stopSessionCalls).toHaveLength(0);
    });

    it("rejects sessions outside the spawn tree", async () => {
      const { ctx, tool } = setup();
      // Add an unrelated session (no parentSessionId linking to us)
      ctx.sessions.set("unrelated", makeSession({ id: "unrelated", status: "busy" }));

      const result = await tool("stop_agent").execute("tc1", { id: "unrelated" });
      expect(result.content[0].text).toContain("not in this session's tree");
    });
  });

  // -----------------------------------------------------------------------
  // send_message
  // -----------------------------------------------------------------------

  describe("send_message", () => {
    it("sends as prompt to idle child session", async () => {
      const { ctx, tool } = setup();
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          status: "ready",
          name: "Worker",
        }),
      );

      const result = await tool("send_message").execute("tc1", {
        id: "c1",
        message: "do more work",
      });

      expect(ctx.sendMessageCalls).toHaveLength(1);
      expect(ctx.sendMessageCalls[0].sessionId).toBe("c1");
      expect(ctx.sendMessageCalls[0].message).toContain("do more work");
      expect(ctx.sendMessageCalls[0].message).toContain("[From agent"); // preamble present
      expect(ctx.sendMessageCalls[0].behavior).toBe("steer");

      const text = result.content[0].text;
      expect(text).toContain("Worker");
      expect(text).toContain("new turn (prompt)");

      const details = result.details as Record<string, unknown>;
      expect(details.deliveredAs).toBe("prompt");
    });

    it("sends as steer to busy child (default behavior)", async () => {
      const { ctx, tool } = setup();
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          status: "busy",
          name: "Worker",
        }),
      );

      const result = await tool("send_message").execute("tc1", {
        id: "c1",
        message: "stop, focus on the bug instead",
      });

      expect(ctx.sendMessageCalls).toHaveLength(1);
      expect(ctx.sendMessageCalls[0].behavior).toBe("steer");

      const text = result.content[0].text;
      expect(text).toContain("steer");
      expect(text).toContain("mid-turn");

      const details = result.details as Record<string, unknown>;
      expect(details.deliveredAs).toBe("steer");
    });

    it("sends as follow-up to busy child (behavior='followUp')", async () => {
      const { ctx, tool } = setup();
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          status: "busy",
          name: "Worker",
        }),
      );

      const result = await tool("send_message").execute("tc1", {
        id: "c1",
        message: "also check tests",
        behavior: "followUp",
      });

      expect(ctx.sendMessageCalls).toHaveLength(1);
      expect(ctx.sendMessageCalls[0].behavior).toBe("followUp");

      const text = result.content[0].text;
      expect(text).toContain("follow-up");
      expect(text).toContain("after current turn");

      const details = result.details as Record<string, unknown>;
      expect(details.deliveredAs).toBe("follow_up");
    });

    it("ignores behavior for idle session (always prompt)", async () => {
      const { ctx, tool } = setup();
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          status: "ready",
        }),
      );

      const result = await tool("send_message").execute("tc1", {
        id: "c1",
        message: "new task",
        behavior: "steer",
      });

      const details = result.details as Record<string, unknown>;
      expect(details.deliveredAs).toBe("prompt");
    });

    it("returns error for unknown session ID", async () => {
      const { tool } = setup();
      const result = await tool("send_message").execute("tc1", {
        id: "nonexistent",
        message: "hello",
      });
      expect(result.content[0].text).toContain("Session not found");
    });

    it("rejects sessions outside the workspace", async () => {
      const { ctx, tool } = setup();
      ctx.sessions.set(
        "other-ws",
        makeSession({ id: "other-ws", status: "busy", workspaceId: "ws-other" }),
      );

      const result = await tool("send_message").execute("tc1", {
        id: "other-ws",
        message: "hello",
      });
      expect(result.content[0].text).toContain("not in this workspace");
    });

    it("rejects messages to stopped sessions", async () => {
      const { ctx, tool } = setup();
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          status: "stopped",
          name: "Done Worker",
        }),
      );

      const result = await tool("send_message").execute("tc1", {
        id: "c1",
        message: "hello",
      });
      expect(result.content[0].text).toContain("auto-resuming");
      expect(result.content[0].text).toContain("Done Worker");
      // Verify the session was resumed (status changed from stopped → ready)
      expect(ctx.sessions.get("c1")!.status).toBe("ready");
      // Verify message was sent (with preamble prepended)
      expect(ctx.sendMessageCalls).toHaveLength(1);
      expect(ctx.sendMessageCalls[0].message).toContain("hello");
    });

    it("rejects messages to errored sessions", async () => {
      const { ctx, tool } = setup();
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          status: "error",
        }),
      );

      const result = await tool("send_message").execute("tc1", {
        id: "c1",
        message: "hello",
      });
      expect(result.content[0].text).toContain("error state");
      expect(result.content[0].text).toContain("Spawn a new agent");
    });

    it("handles sendMessage errors gracefully", async () => {
      const { ctx, tool } = setup();
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          status: "busy",
          name: "Worker",
        }),
      );
      ctx.sendMessageError = new Error("session not active");

      const result = await tool("send_message").execute("tc1", {
        id: "c1",
        message: "hello",
      });
      expect(result.content[0].text).toContain("Failed to send message");
      expect(result.content[0].text).toContain("session not active");
    });

    it("works with grandchild sessions (descendant in tree)", async () => {
      const { ctx, tool } = setup();
      ctx.sessions.set("c1", makeSession({ id: "c1", parentSessionId: "parent-1" }));
      ctx.sessions.set(
        "gc1",
        makeSession({
          id: "gc1",
          parentSessionId: "c1",
          status: "busy",
          name: "Grandchild",
        }),
      );

      const result = await tool("send_message").execute("tc1", {
        id: "gc1",
        message: "update on progress",
      });

      expect(ctx.sendMessageCalls).toHaveLength(1);
      expect(ctx.sendMessageCalls[0].sessionId).toBe("gc1");
      expect(result.content[0].text).toContain("Grandchild");
    });

    it("sends to starting session as prompt", async () => {
      const { ctx, tool } = setup();
      ctx.sessions.set(
        "c1",
        makeSession({
          id: "c1",
          parentSessionId: "parent-1",
          status: "starting",
        }),
      );

      const result = await tool("send_message").execute("tc1", {
        id: "c1",
        message: "early instructions",
      });

      const details = result.details as Record<string, unknown>;
      expect(details.deliveredAs).toBe("prompt");
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

    it("returns error when session not in workspace", async () => {
      const { ctx, tool } = setup();

      // Add a session in a different workspace
      ctx.sessions.set("other-ws", makeSession({ id: "other-ws", workspaceId: "ws-other" }));

      const result = await tool("inspect_agent").execute("tc1", {
        id: "other-ws",
      });

      expect(result.content[0].text).toContain("not in this workspace");
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
  // Cross-session: send_message workspace scope
  // -----------------------------------------------------------------------

  describe("send_message workspace scope", () => {
    it("can send to detached session in same workspace", async () => {
      const { ctx, tool } = setup();

      ctx.sessions.set(
        "detached-1",
        makeSession({
          id: "detached-1",
          // no parentSessionId
          status: "busy",
          name: "Detached Worker",
        }),
      );

      const result = await tool("send_message").execute("tc1", {
        id: "detached-1",
        message: "status check",
      });

      expect(result.content[0].text).toContain("Detached Worker");
      expect(ctx.sendMessageCalls).toHaveLength(1);
      expect(ctx.sendMessageCalls[0].sessionId).toBe("detached-1");
    });

    it("can send to unrelated session in same workspace", async () => {
      const { ctx, tool } = setup();

      // Session from a completely different tree
      ctx.sessions.set(
        "sibling-tree",
        makeSession({
          id: "sibling-tree",
          parentSessionId: "some-other-parent",
          status: "busy",
          name: "Sibling",
        }),
      );

      await tool("send_message").execute("tc1", {
        id: "sibling-tree",
        message: "coordinate with me",
      });

      expect(ctx.sendMessageCalls).toHaveLength(1);
      expect(ctx.sendMessageCalls[0].sessionId).toBe("sibling-tree");
    });

    it("rejects sessions not in the workspace", async () => {
      const { ctx, tool } = setup();

      // Session in a different workspace — not in listWorkspaceSessions results
      ctx.sessions.set(
        "other-ws",
        makeSession({ id: "other-ws", status: "busy", workspaceId: "ws-2" }),
      );

      const result = await tool("send_message").execute("tc1", {
        id: "other-ws",
        message: "hello",
      });

      expect(result.content[0].text).toContain("not in this workspace");
      expect(ctx.sendMessageCalls).toHaveLength(0);
    });

    it("prepends agent-origin preamble with sender name and ID", async () => {
      const { ctx, tool } = setup();

      // Give the parent session a name
      const parent = ctx.sessions.get("parent-1")!;
      parent.name = "Coordinator";

      ctx.sessions.set(
        "target-1",
        makeSession({
          id: "target-1",
          parentSessionId: "parent-1",
          status: "busy",
          name: "Worker",
        }),
      );

      await tool("send_message").execute("tc1", {
        id: "target-1",
        message: "please check the tests",
      });

      expect(ctx.sendMessageCalls).toHaveLength(1);
      const sentMessage = ctx.sendMessageCalls[0].message;
      expect(sentMessage).toContain('[From agent "Coordinator" (parent-1)]');
      expect(sentMessage).toContain("please check the tests");
    });

    it("preamble uses session ID when name is not set", async () => {
      const { ctx, tool } = setup();

      // Clear the parent session name
      const parent = ctx.sessions.get("parent-1")!;
      parent.name = undefined;

      ctx.sessions.set(
        "target-1",
        makeSession({
          id: "target-1",
          parentSessionId: "parent-1",
          status: "busy",
        }),
      );

      await tool("send_message").execute("tc1", {
        id: "target-1",
        message: "hello",
      });

      const sentMessage = ctx.sendMessageCalls[0].message;
      expect(sentMessage).toContain("[From agent parent-1]");
      expect(sentMessage).toContain("hello");
    });

    it("existing child messaging still works", async () => {
      const { ctx, tool } = setup();

      ctx.sessions.set(
        "child-1",
        makeSession({
          id: "child-1",
          parentSessionId: "parent-1",
          status: "busy",
          name: "Child",
        }),
      );

      const result = await tool("send_message").execute("tc1", {
        id: "child-1",
        message: "update me",
      });

      expect(ctx.sendMessageCalls).toHaveLength(1);
      expect(result.content[0].text).toContain("Child");
    });
  });

  // -----------------------------------------------------------------------
  // Cross-session: inspect_agent workspace scope
  // -----------------------------------------------------------------------

  describe("inspect_agent workspace scope", () => {
    it("can inspect any session in same workspace", async () => {
      const { ctx, tool } = setup();

      const tracePath = writeTrace(tmpDir, "detached.jsonl", [
        userMsg("analyze code"),
        assistantMsg("found issues"),
      ]);

      ctx.sessions.set(
        "detached-1",
        makeSession({
          id: "detached-1",
          // no parentSessionId, not in tree
          status: "busy",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", { id: "detached-1" });
      expect(result.content[0].text).toContain("1 turns");
    });

    it("rejects sessions not in the workspace", async () => {
      const { ctx, tool } = setup();

      ctx.sessions.set(
        "other-ws",
        makeSession({ id: "other-ws", status: "busy", workspaceId: "ws-2" }),
      );

      const result = await tool("inspect_agent").execute("tc1", { id: "other-ws" });
      expect(result.content[0].text).toContain("not in this workspace");
    });
  });

  // -----------------------------------------------------------------------
  // Cross-session: stop_agent stays tree-scoped
  // -----------------------------------------------------------------------

  describe("stop_agent tree scope (unchanged)", () => {
    it("still rejects sessions outside the spawn tree", async () => {
      const { ctx, tool } = setup();

      ctx.sessions.set(
        "unrelated",
        makeSession({ id: "unrelated", status: "busy", name: "Not Mine" }),
      );

      const result = await tool("stop_agent").execute("tc1", { id: "unrelated" });
      expect(result.content[0].text).toContain("not in this session's tree");
    });
  });

  // -----------------------------------------------------------------------
  // Child mode: restricted tool set
  // -----------------------------------------------------------------------

  describe("child mode (childMode: true)", () => {
    it("registers only send_message and inspect_agent", () => {
      const { api } = setup("child-1", { childMode: true });

      expect(api.tools.has("send_message")).toBe(true);
      expect(api.tools.has("inspect_agent")).toBe(true);
      expect(api.tools.has("check_agents")).toBe(false);
      expect(api.tools.has("spawn_agent")).toBe(false);
      expect(api.tools.has("stop_agent")).toBe(false);
      expect(api.tools.size).toBe(2);
    });

    it("child can send_message to sibling", async () => {
      const { ctx, tool } = setup("child-1", { childMode: true });

      // Set up the child's parent
      ctx.sessions.set("root-1", makeSession({ id: "root-1" }));
      ctx.sessions.set(
        "child-1",
        makeSession({ id: "child-1", parentSessionId: "root-1", status: "busy" }),
      );
      ctx.sessions.set(
        "child-2",
        makeSession({
          id: "child-2",
          parentSessionId: "root-1",
          status: "busy",
          name: "Sibling",
        }),
      );

      const result = await tool("send_message").execute("tc1", {
        id: "child-2",
        message: "hey sibling",
      });

      expect(ctx.sendMessageCalls).toHaveLength(1);
      expect(ctx.sendMessageCalls[0].sessionId).toBe("child-2");
      expect(result.content[0].text).toContain("Sibling");
    });

    it("child can inspect_agent on sibling", async () => {
      const { ctx, tool } = setup("child-1", { childMode: true });

      const tracePath = writeTrace(tmpDir, "sibling.jsonl", [
        userMsg("sibling task"),
        assistantMsg("done"),
      ]);

      ctx.sessions.set(
        "child-1",
        makeSession({ id: "child-1", parentSessionId: "root-1", status: "busy" }),
      );
      ctx.sessions.set(
        "child-2",
        makeSession({
          id: "child-2",
          parentSessionId: "root-1",
          status: "busy",
          piSessionFile: tracePath,
        }),
      );

      const result = await tool("inspect_agent").execute("tc1", { id: "child-2" });
      expect(result.content[0].text).toContain("1 turns");
    });
  });
});

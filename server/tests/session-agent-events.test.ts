import { ToolOutputSnapshots } from "../src/tool-output-sidecar.js";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { SessionBackendEvent } from "../src/pi-events.js";
import {
  SessionAgentEventCoordinator,
  type SessionAgentEventState,
} from "../src/session-agent-events.js";
import { SessionEventProcessor } from "../src/session-events.js";
import { sessionAttachmentMediaDetailsForToolCall } from "../src/session-attachments.js";
import { buildSessionSummary } from "../src/session-summary.js";
import { TurnDedupeCache } from "../src/turn-cache.js";
import type { Session } from "../src/types.js";

function makeSession(overrides?: Partial<Session>): Session {
  return {
    id: "child-1",
    status: "busy",
    createdAt: Date.now(),
    lastActivity: Date.now(),
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

function cacheMessageEvent(timestamp: number, cached: boolean): SessionBackendEvent {
  return {
    type: "message_end",
    message: {
      role: "assistant",
      provider: "anthropic",
      model: "claude-sonnet",
      timestamp,
      stopReason: "stop",
      content: [{ type: "text", text: "done" }],
      usage: {
        input: cached ? 1_000 : 70_000,
        output: 0,
        cacheRead: cached ? 69_000 : 0,
        cacheWrite: 0,
        totalTokens: 70_000,
        cost: {
          input: cached ? 0.012 : 0.84,
          output: 0,
          cacheRead: cached ? 0.069 : 0,
          cacheWrite: 0,
          total: cached ? 0.081 : 0.84,
        },
      },
    },
  } as unknown as SessionBackendEvent;
}

describe("SessionAgentEventCoordinator", () => {
  const tempDirs: string[] = [];

  afterEach(() => {
    for (const dir of tempDirs.splice(0)) {
      rmSync(dir, { recursive: true, force: true });
    }
  });
  function makeActiveSession(overrides?: Partial<Session>): SessionAgentEventState {
    return {
      session: makeSession(overrides),
      pendingUIRequests: new Map(),
      toolOutputSnapshots: new ToolOutputSnapshots(),
      streamedAssistantText: "",
      toolNames: new Map(),
      toolArgs: new Map(),
      streamingToolUpdatesSeen: new Map<string, string>(),
      turnCache: new TurnDedupeCache(),
      pendingTurnStarts: [],
      sdkBackend: { sessionTree: () => undefined, toolDefinition: () => undefined } as never,
      subscribers: new Set<(msg: unknown) => void>(),
      toolFullOutputPaths: new Map<string, string>(),
      cacheMissTracker: {},
      showCacheMissNotices: false,
    };
  }

  function makeCoordinator(
    active: SessionAgentEventState,
    options?: { dataDir?: string; handleSessionSettled?: (key: string) => void },
  ): {
    broadcast: ReturnType<typeof vi.fn>;
    coordinator: SessionAgentEventCoordinator;
    resetIdleTimer: ReturnType<typeof vi.fn>;
    updateSessionFromEvent: ReturnType<typeof vi.fn>;
  } {
    const broadcast = vi.fn();
    const resetIdleTimer = vi.fn();
    const updateSessionFromEvent = vi.fn(() => {
      active.session.status = "ready";
    });
    const coordinator = new SessionAgentEventCoordinator({
      getActiveSession: vi.fn(() => active),
      eventProcessor: {
        translationContext: vi.fn(() => ({
          sessionId: active.session.id,
          toolOutputSnapshots: active.toolOutputSnapshots,
          streamedAssistantText: active.streamedAssistantText,
          currentThinkingContentIndex: active.currentThinkingContentIndex,
          mobileRenderers: {
            renderCall: vi.fn(),
            renderResult: vi.fn(),
            inputPresentation: vi.fn(),
            outputPresentation: vi.fn(),
            outputAvailability: vi.fn(() => ({ complete: true })),
          } as never,
          toolNames: active.toolNames,
          toolArgs: active.toolArgs,
          streamingToolUpdatesSeen: active.streamingToolUpdatesSeen,
        })),
        updateSessionFromEvent,
      } as never,
      stopCoordinator: {
        finishPendingStopOnAgentEnd: vi.fn(),
      } as never,
      turnCoordinator: {
        markNextTurnStarted: vi.fn(),
      } as never,
      broadcast,
      resetIdleTimer,
      ...(options?.handleSessionSettled
        ? { handleSessionSettled: options.handleSessionSettled }
        : {}),
      ...(options?.dataDir ? { dataDir: options.dataDir } : {}),
    });

    return { broadcast, coordinator, resetIdleTimer, updateSessionFromEvent };
  }

  it("indexes Pi full-output paths from updates before publishing a live preview", () => {
    const active = makeActiveSession();
    const { broadcast, coordinator } = makeCoordinator(active);
    broadcast.mockImplementation((_key, message) => {
      if (message.type === "tool_output")
        expect(active.toolFullOutputPaths.get("tc-1")).toBe("/private/live-output.log");
    });
    coordinator.handlePiEvent(active.session.id, {
      type: "tool_execution_update",
      toolCallId: "tc-1",
      toolName: "bash",
      partialResult: {
        content: [{ type: "text", text: "preview" }],
        details: {
          fullOutputPath: "/private/live-output.log",
          truncation: { truncated: true, totalBytes: 100_000 },
        },
      },
    } as unknown as SessionBackendEvent);
    expect(active.toolFullOutputPaths.get("tc-1")).toBe("/private/live-output.log");
    const output = broadcast.mock.calls.find(([, message]) => message.type === "tool_output")?.[1];
    expect(output).toBeDefined();
    expect(output.details).not.toHaveProperty("fullOutputPath");
  });

  it("broadcasts ready summaries to the session key", () => {
    const active = makeActiveSession({ status: "busy" });
    const { broadcast, coordinator } = makeCoordinator(active);

    coordinator.handlePiEvent(active.session.id, {
      type: "agent_end",
      messages: [],
    } as unknown as SessionBackendEvent);

    const summary = buildSessionSummary(active.session);
    const summaryBroadcasts = broadcast.mock.calls.filter(
      ([, message]) => message.type === "session_summary",
    );
    expect(summaryBroadcasts).toEqual([["child-1", { type: "session_summary", summary }]]);
  });

  it("broadcasts session summaries after Pi session name changes", () => {
    const active = makeActiveSession({ status: "ready" });
    const broadcast = vi.fn();
    const eventProcessor = new SessionEventProcessor({
      storage: {} as never,
      mobileRenderers: {
        renderCall: vi.fn(),
        renderResult: vi.fn(),
        inputPresentation: vi.fn(),
        outputPresentation: vi.fn(),
        outputAvailability: vi.fn(() => ({ complete: true })),
      } as never,
      broadcast: vi.fn(),
      persistSessionNow: vi.fn(),
      markSessionDirty: vi.fn(),
    });
    const coordinator = new SessionAgentEventCoordinator({
      getActiveSession: vi.fn(() => active),
      eventProcessor,
      stopCoordinator: {
        finishPendingStopOnAgentEnd: vi.fn(),
      } as never,
      turnCoordinator: {
        markNextTurnStarted: vi.fn(),
      } as never,
      broadcast,
      resetIdleTimer: vi.fn(),
    });

    coordinator.handlePiEvent(active.session.id, {
      type: "session_info_changed",
      name: "Review Session Names",
    } as unknown as SessionBackendEvent);

    expect(active.session.name).toBe("Review Session Names");
    const summary = buildSessionSummary(active.session);
    const summaryBroadcasts = broadcast.mock.calls.filter(
      ([, message]) => message.type === "session_summary",
    );
    expect(summaryBroadcasts).toEqual([["child-1", { type: "session_summary", summary }]]);
  });

  it("broadcasts a visible custom message as the same history card while streaming", () => {
    const active = makeActiveSession({ status: "busy" });
    const guidance =
      "These are background job results, not a new user request. Integrate useful findings, changes, failures, or blockers. Do not reply only to acknowledge results that are already covered.";
    const { broadcast, coordinator } = makeCoordinator(active);

    coordinator.handlePiEvent(active.session.id, {
      type: "entry_appended",
      entry: {
        type: "custom_message",
        id: "job-1",
        parentId: "turn-1",
        timestamp: "2026-01-01T00:00:00.000Z",
        customType: "background-job",
        display: true,
        content: `${guidance}\n\ncommand finished`,
      },
    } as SessionBackendEvent);

    expect(broadcast).toHaveBeenCalledWith(
      active.session.id,
      expect.objectContaining({
        type: "custom_card",
        id: "job-1",
        presentation: expect.objectContaining({
          kind: "custom",
          title: "Custom Message",
        }),
      }),
    );

    broadcast.mockClear();
    coordinator.handlePiEvent(active.session.id, {
      type: "entry_appended",
      entry: {
        type: "custom_message",
        id: "hidden",
        parentId: null,
        timestamp: "2026-01-01T00:00:01.000Z",
        customType: "background-job",
        display: false,
        content: guidance,
      },
    } as SessionBackendEvent);
    expect(broadcast).not.toHaveBeenCalled();
  });

  it("broadcasts the new custom entry when an identical batch is still the leaf", async () => {
    const active = makeActiveSession({ status: "busy" });
    const content = "same batch";
    const entries = new Map<string, { type: string; id: string; parentId: string | null; content: string; display: boolean }>();
    entries.set("old", {
      type: "custom_message",
      id: "old",
      parentId: "turn",
      content,
      display: true,
    });
    let leafId = "old";
    active.sdkBackend = {
      sessionTree: () => ({
        getLeafId: () => leafId,
        getLeafEntry: () => entries.get(leafId),
        getEntry: (id: string) => entries.get(id),
      }),
      toolDefinition: () => undefined,
    } as never;
    const { broadcast, coordinator } = makeCoordinator(active);

    coordinator.handlePiEvent(active.session.id, {
      type: "message_end",
      message: { role: "custom", content, display: true },
    } as SessionBackendEvent);
    entries.set("new", {
      type: "custom_message",
      id: "new",
      parentId: "old",
      content,
      display: true,
    });
    leafId = "new";
    await new Promise((resolve) => queueMicrotask(resolve));

    const cardIds = broadcast.mock.calls.flatMap(([, message]) =>
      message.type === "custom_card" && typeof message.id === "string" ? [message.id] : [],
    );
    expect(cardIds).toContain("new");
  });

  it("broadcasts both equal batches when each is appended before its message_end", async () => {
    const active = makeActiveSession({ status: "busy" });
    const content = "same batch";
    const entries = new Map<string, { type: string; id: string; parentId: string | null; content: string; display: boolean }>();
    entries.set("first", {
      type: "custom_message",
      id: "first",
      parentId: "turn",
      content,
      display: true,
    });
    let leafId = "first";
    active.sdkBackend = {
      sessionTree: () => ({
        getLeafId: () => leafId,
        getLeafEntry: () => entries.get(leafId),
        getEntry: (id: string) => entries.get(id),
      }),
      toolDefinition: () => undefined,
    } as never;
    const { broadcast, coordinator } = makeCoordinator(active);
    const messageEnd = {
      type: "message_end",
      message: { role: "custom", content, display: true },
    } as SessionBackendEvent;

    coordinator.handlePiEvent(active.session.id, messageEnd);
    entries.set("second", {
      type: "custom_message",
      id: "second",
      parentId: "first",
      content,
      display: true,
    });
    leafId = "second";
    coordinator.handlePiEvent(active.session.id, messageEnd);
    await new Promise((resolve) => queueMicrotask(resolve));
    await new Promise((resolve) => queueMicrotask(resolve));

    const cardIds = broadcast.mock.calls.flatMap(([, message]) =>
      message.type === "custom_card" && typeof message.id === "string" ? [message.id] : [],
    );
    expect(cardIds).toEqual(expect.arrayContaining(["first", "second"]));
  });

  it("broadcasts one compatibility-safe message_end with ordered assistant structure", () => {
    const active = makeActiveSession({ status: "busy" });
    const { broadcast, coordinator } = makeCoordinator(active);

    coordinator.handlePiEvent(active.session.id, {
      type: "message_end",
      message: {
        role: "assistant",
        content: [
          { type: "text", text: "Before tool " },
          { type: "output_text", text: "### authored heading text" },
          { type: "toolCall", id: "tool-1", name: "read", arguments: {} },
          { type: "text", text: "After tool" },
          { type: "thinking", thinking: "Check" },
          { type: "text", text: "After thinking" },
          { type: "image", data: "abc", mimeType: "image/png" },
          { type: "text", text: "After media" },
          { type: "future_block", payload: true },
          { type: "text", text: "Tail\n\n" },
        ],
      },
    } as unknown as SessionBackendEvent);

    const messageEnds = broadcast.mock.calls
      .map(([, message]) => message)
      .filter((message) => message.type === "message_end");

    expect(messageEnds).toEqual([
      {
        type: "message_end",
        role: "assistant",
        content:
          "Before tool ### authored heading text\n\nAfter tool\n\nAfter thinking\n\nAfter media\n\nTail\n\n",
        assistantContent: [
          { kind: "text", content: "Before tool ### authored heading text", contentIndex: 0 },
          { kind: "tool", contentIndex: 2, toolCallId: "tool-1" },
          { kind: "text", content: "After tool", contentIndex: 3 },
          { kind: "thinking", content: "Check", contentIndex: 4 },
          { kind: "text", content: "After thinking", contentIndex: 5 },
          { kind: "boundary", contentIndex: 6 },
          { kind: "text", content: "After media", contentIndex: 7 },
          { kind: "boundary", contentIndex: 8 },
          { kind: "text", content: "Tail\n\n", contentIndex: 9 },
        ],
      },
    ]);
  });

  it("preserves older-client assistant behavior after optional structure is stripped", () => {
    const active = makeActiveSession({ status: "busy" });
    const { broadcast, coordinator } = makeCoordinator(active);

    coordinator.handlePiEvent(active.session.id, {
      type: "message_end",
      message: {
        role: "assistant",
        content: [
          { type: "text", text: "First" },
          { type: "thinking", thinking: "between" },
          { type: "text", text: "Second" },
        ],
      },
    } as unknown as SessionBackendEvent);

    const olderClientFrames = broadcast.mock.calls.flatMap(([, message]) => {
      if (message.type !== "message_end") return [];
      const { type, role, content } = message;
      return [{ type, role, content }];
    });

    expect(olderClientFrames).toEqual([
      { type: "message_end", role: "assistant", content: "First\n\nSecond" },
    ]);
  });

  it("does not broadcast cold summaries for hot timeline events", () => {
    const active = makeActiveSession({ status: "busy" });
    const { broadcast, coordinator } = makeCoordinator(active);

    coordinator.handlePiEvent(active.session.id, {
      type: "tool_execution_start",
      toolCallId: "tool-1",
      toolName: "bash",
      args: { command: "echo hi" },
    } as unknown as SessionBackendEvent);
    coordinator.handlePiEvent(active.session.id, {
      type: "tool_execution_end",
      toolCallId: "tool-1",
      toolName: "bash",
      result: { content: [{ type: "text", text: "hi" }] },
      isError: false,
    } as unknown as SessionBackendEvent);
    coordinator.handlePiEvent(active.session.id, {
      type: "message_end",
      message: { role: "assistant", content: [{ type: "text", text: "done" }] },
    } as unknown as SessionBackendEvent);

    const summaryBroadcasts = broadcast.mock.calls.filter(
      ([, message]) => message.type === "session_summary",
    );
    expect(summaryBroadcasts).toHaveLength(0);
  });

  it("keeps structural turn lifecycle events out of info logs", () => {
    const active = makeActiveSession({ status: "busy" });
    const { coordinator } = makeCoordinator(active);
    const writes: string[] = [];
    const stderrSpy = vi.spyOn(process.stderr, "write").mockImplementation(((
      chunk: string | Uint8Array,
    ) => {
      writes.push(typeof chunk === "string" ? chunk : Buffer.from(chunk).toString("utf8"));
      return true;
    }) as typeof process.stderr.write);

    try {
      coordinator.handlePiEvent(active.session.id, {
        type: "turn_start",
      } as unknown as SessionBackendEvent);
      coordinator.handlePiEvent(active.session.id, {
        type: "turn_end",
        message: {},
        toolResults: [],
      } as unknown as SessionBackendEvent);
    } finally {
      stderrSpy.mockRestore();
    }

    const output = writes.join("");
    expect(output).not.toContain('"event":"session_agent_events.pi_event"');
    expect(output).not.toContain('"eventType":"turn_start"');
    expect(output).not.toContain('"eventType":"turn_end"');
  });

  it("emits live cache misses only when Pi's setting is enabled", () => {
    const active = makeActiveSession();
    active.sdkBackend = undefined;
    active.showCacheMissNotices = true;
    active.cacheMissModelPriceSource = {
      find: () => ({ cost: { cacheRead: 1 } }),
    };
    const { broadcast, coordinator } = makeCoordinator(active);

    coordinator.handlePiEvent(active.session.id, cacheMessageEvent(1_000, true));
    coordinator.handlePiEvent(active.session.id, cacheMessageEvent(310_700, false));

    expect(broadcast).toHaveBeenCalledWith(
      "child-1",
      expect.objectContaining({
        type: "cache_miss",
        message: "Cache miss after 5m idle: 70k tokens re-billed (~$0.77)",
      }),
    );

    const hidden = makeActiveSession();
    hidden.sdkBackend = undefined;
    hidden.cacheMissModelPriceSource = active.cacheMissModelPriceSource;
    const hiddenHarness = makeCoordinator(hidden);
    hiddenHarness.coordinator.handlePiEvent(hidden.session.id, cacheMessageEvent(1_000, true));
    hiddenHarness.coordinator.handlePiEvent(hidden.session.id, cacheMessageEvent(310_700, false));
    expect(
      hiddenHarness.broadcast.mock.calls.some(([, message]) => message.type === "cache_miss"),
    ).toBe(false);
  });

  it("keeps cache state when compaction fails without producing a result", () => {
    const active = makeActiveSession();
    active.sdkBackend = undefined;
    active.showCacheMissNotices = true;
    active.cacheMissModelPriceSource = {
      find: () => ({ cost: { cacheRead: 1 } }),
    };
    const { broadcast, coordinator } = makeCoordinator(active);

    coordinator.handlePiEvent(active.session.id, cacheMessageEvent(1_000, true));
    coordinator.handlePiEvent(active.session.id, {
      type: "compaction_end",
      reason: "manual",
      result: undefined,
      aborted: false,
      willRetry: false,
      errorMessage: "compaction failed",
    });
    coordinator.handlePiEvent(active.session.id, cacheMessageEvent(310_700, false));

    expect(broadcast.mock.calls.some(([, message]) => message.type === "cache_miss")).toBe(true);
  });

  it("preserves generic details without executing Pi's TUI result renderer", () => {
    const active = makeActiveSession({ status: "busy" });
    active.sdkBackend = {
      sessionTree: () => undefined,
      toolDefinition: () => ({
        renderResult: (
          result: { details?: unknown },
          options: { expanded: boolean },
          _theme: unknown,
          context: { args: Record<string, unknown> },
        ) => ({
          render: () => {
            const details = result.details as { body?: string } | undefined;
            return [
              options.expanded ? "expanded" : "collapsed",
              `title: ${String(context.args.title ?? "")}`,
              `body: ${details?.body ?? ""}`,
            ];
          },
        }),
      }),
    } as never;
    const { broadcast, coordinator } = makeCoordinator(active);

    coordinator.handlePiEvent(active.session.id, {
      type: "tool_execution_start",
      toolCallId: "tool-1",
      toolName: "todo",
      args: { title: "Ship it" },
    } as unknown as SessionBackendEvent);
    coordinator.handlePiEvent(active.session.id, {
      type: "tool_execution_end",
      toolCallId: "tool-1",
      toolName: "todo",
      result: {
        content: [{ type: "text", text: "saved" }],
        details: { body: "Use the TUI renderer" },
      },
      isError: false,
    } as unknown as SessionBackendEvent);

    const toolEnd = broadcast.mock.calls.find(([, message]) => message.type === "tool_end")?.[1];
    expect(toolEnd).toBeDefined();
    expect(toolEnd).toMatchObject({
      type: "tool_end",
      tool: "todo",
      details: {
        body: "Use the TUI renderer",
      },
    });
    expect(toolEnd?.details).toEqual({ body: "Use the TUI renderer" });
  });

  it("does not attach TUI render snapshots for native tool rows", () => {
    const active = makeActiveSession({ status: "busy" });
    const renderResult = vi.fn(() => ({ render: () => ["native renderer"] }));
    active.sdkBackend = {
      sessionTree: () => undefined,
      toolDefinition: () => ({ renderResult }),
    } as never;
    const { broadcast, coordinator } = makeCoordinator(active);

    coordinator.handlePiEvent(active.session.id, {
      type: "tool_execution_start",
      toolCallId: "tool-1",
      toolName: "bash",
      args: { command: "echo hi" },
    } as unknown as SessionBackendEvent);
    coordinator.handlePiEvent(active.session.id, {
      type: "tool_execution_end",
      toolCallId: "tool-1",
      toolName: "bash",
      result: {
        content: [{ type: "text", text: "hi" }],
        details: { exitCode: 0 },
      },
      isError: false,
    } as unknown as SessionBackendEvent);

    const toolEnd = broadcast.mock.calls.find(([, message]) => message.type === "tool_end")?.[1];
    expect(renderResult).not.toHaveBeenCalled();
    expect(toolEnd?.details).toEqual({ exitCode: 0 });
  });

  it("preserves primitive tool details instead of wrapping them for tuiRender", () => {
    const active = makeActiveSession({ status: "busy" });
    active.sdkBackend = {
      sessionTree: () => undefined,
      toolDefinition: () => ({
        renderResult: () => ({ render: () => ["rendered snapshot"] }),
      }),
    } as never;
    const { broadcast, coordinator } = makeCoordinator(active);

    coordinator.handlePiEvent(active.session.id, {
      type: "tool_execution_start",
      toolCallId: "tool-1",
      toolName: "custom_tool",
      args: {},
    } as unknown as SessionBackendEvent);
    coordinator.handlePiEvent(active.session.id, {
      type: "tool_execution_end",
      toolCallId: "tool-1",
      toolName: "custom_tool",
      result: {
        content: [{ type: "text", text: "ok" }],
        details: "primitive-details",
      },
      isError: false,
    } as unknown as SessionBackendEvent);

    const toolEnd = broadcast.mock.calls.find(([, message]) => message.type === "tool_end")?.[1];
    expect(toolEnd?.details).toBe("primitive-details");
  });

  it("broadcasts edit/write summaries after real change stats update", () => {
    const active = makeActiveSession({ status: "busy" });
    const broadcast = vi.fn();
    const eventProcessor = new SessionEventProcessor({
      storage: {} as never,
      mobileRenderers: {
        renderCall: vi.fn(),
        renderResult: vi.fn(),
        inputPresentation: vi.fn(),
        outputPresentation: vi.fn(),
        outputAvailability: vi.fn(() => ({ complete: true })),
      } as never,
      broadcast: vi.fn(),
      persistSessionNow: vi.fn(),
      markSessionDirty: vi.fn(),
    });
    const coordinator = new SessionAgentEventCoordinator({
      getActiveSession: vi.fn(() => active),
      eventProcessor,
      stopCoordinator: {
        finishPendingStopOnAgentEnd: vi.fn(),
      } as never,
      turnCoordinator: {
        markNextTurnStarted: vi.fn(),
      } as never,
      broadcast,
      resetIdleTimer: vi.fn(),
    });

    coordinator.handlePiEvent(active.session.id, {
      type: "tool_execution_start",
      toolCallId: "tool-1",
      toolName: "edit",
      args: { path: "src/a.ts", oldText: "a", newText: "a\nb\nc" },
    } as unknown as SessionBackendEvent);

    expect(active.session.changeStats).toMatchObject({
      mutatingToolCalls: 1,
      filesChanged: 1,
      changedFiles: ["src/a.ts"],
      addedLines: 2,
      removedLines: 0,
    });
    const summary = buildSessionSummary(active.session);
    const summaryBroadcasts = broadcast.mock.calls.filter(
      ([, message]) => message.type === "session_summary",
    );
    expect(summaryBroadcasts).toEqual([["child-1", { type: "session_summary", summary }]]);
  });

  it("broadcasts summaries for namespaced edit patch tools after change stats update", () => {
    const active = makeActiveSession({ status: "busy" });
    const broadcast = vi.fn();
    const eventProcessor = new SessionEventProcessor({
      storage: {} as never,
      mobileRenderers: {
        renderCall: vi.fn(),
        renderResult: vi.fn(),
        inputPresentation: vi.fn(),
        outputPresentation: vi.fn(),
        outputAvailability: vi.fn(() => ({ complete: true })),
      } as never,
      broadcast: vi.fn(),
      persistSessionNow: vi.fn(),
      markSessionDirty: vi.fn(),
    });
    const coordinator = new SessionAgentEventCoordinator({
      getActiveSession: vi.fn(() => active),
      eventProcessor,
      stopCoordinator: {
        finishPendingStopOnAgentEnd: vi.fn(),
      } as never,
      turnCoordinator: {
        markNextTurnStarted: vi.fn(),
      } as never,
      broadcast,
      resetIdleTimer: vi.fn(),
    });

    coordinator.handlePiEvent(active.session.id, {
      type: "tool_execution_start",
      toolCallId: "tool-1",
      toolName: "functions.edit",
      args: {
        patch: "*** Begin Patch\n*** Update File: src/a.ts\n@@\n-old\n+new\n*** End Patch",
      },
    } as unknown as SessionBackendEvent);

    expect(active.session.changeStats).toMatchObject({
      mutatingToolCalls: 1,
      filesChanged: 1,
      changedFiles: ["src/a.ts"],
      addedLines: 0,
      removedLines: 0,
    });
    const summary = buildSessionSummary(active.session);
    const summaryBroadcasts = broadcast.mock.calls.filter(
      ([, message]) => message.type === "session_summary",
    );
    expect(summaryBroadcasts).toEqual([["child-1", { type: "session_summary", summary }]]);
  });

  it.each([
    {
      toolName: "write",
      args: { path: "src/a.ts", content: "hello" },
    },
    {
      toolName: "functions.write",
      args: { path: "src/a.ts", content: "hello" },
    },
  ])("broadcasts summaries for known mutation tool $toolName", ({ toolName, args }) => {
    const active = makeActiveSession({ status: "busy" });
    const broadcast = vi.fn();
    const eventProcessor = new SessionEventProcessor({
      storage: {} as never,
      mobileRenderers: {
        renderCall: vi.fn(),
        renderResult: vi.fn(),
        inputPresentation: vi.fn(),
        outputPresentation: vi.fn(),
        outputAvailability: vi.fn(() => ({ complete: true })),
      } as never,
      broadcast: vi.fn(),
      persistSessionNow: vi.fn(),
      markSessionDirty: vi.fn(),
    });
    const coordinator = new SessionAgentEventCoordinator({
      getActiveSession: vi.fn(() => active),
      eventProcessor,
      stopCoordinator: {
        finishPendingStopOnAgentEnd: vi.fn(),
      } as never,
      turnCoordinator: {
        markNextTurnStarted: vi.fn(),
      } as never,
      broadcast,
      resetIdleTimer: vi.fn(),
    });

    coordinator.handlePiEvent(active.session.id, {
      type: "tool_execution_start",
      toolCallId: "tool-1",
      toolName,
      args,
    } as unknown as SessionBackendEvent);

    expect(active.session.changeStats).toMatchObject({
      mutatingToolCalls: 1,
      filesChanged: 1,
      changedFiles: ["src/a.ts"],
    });
    const summary = buildSessionSummary(active.session);
    const summaryBroadcasts = broadcast.mock.calls.filter(
      ([, message]) => message.type === "session_summary",
    );
    expect(summaryBroadcasts).toEqual([["child-1", { type: "session_summary", summary }]]);
  });

  it.each(["ext.edit", "my.write", "ask.edit", "something.write"])(
    "does not broadcast change summaries for namespaced false positive %s",
    (toolName) => {
      const active = makeActiveSession({ status: "busy" });
      const broadcast = vi.fn();
      const eventProcessor = new SessionEventProcessor({
        storage: {} as never,
        mobileRenderers: {
          renderCall: vi.fn(),
          renderResult: vi.fn(),
          inputPresentation: vi.fn(),
          outputPresentation: vi.fn(),
          outputAvailability: vi.fn(() => ({ complete: true })),
        } as never,
        broadcast: vi.fn(),
        persistSessionNow: vi.fn(),
        markSessionDirty: vi.fn(),
      });
      const coordinator = new SessionAgentEventCoordinator({
        getActiveSession: vi.fn(() => active),
        eventProcessor,
        stopCoordinator: {
          finishPendingStopOnAgentEnd: vi.fn(),
        } as never,
        turnCoordinator: {
          markNextTurnStarted: vi.fn(),
        } as never,
        broadcast,
        resetIdleTimer: vi.fn(),
      });

      coordinator.handlePiEvent(active.session.id, {
        type: "tool_execution_start",
        toolCallId: "tool-1",
        toolName,
        args: {
          path: "src/a.ts",
          oldText: "a",
          newText: "b",
          content: "hello",
        },
      } as unknown as SessionBackendEvent);

      expect(active.session.changeStats).toBeUndefined();
      const summaryBroadcasts = broadcast.mock.calls.filter(
        ([, message]) => message.type === "session_summary",
      );
      expect(summaryBroadcasts).toEqual([]);
    },
  );

  it("normalizes prompt_error before broadcasting it to clients", () => {
    const active = makeActiveSession();
    const { broadcast, coordinator, resetIdleTimer, updateSessionFromEvent } =
      makeCoordinator(active);

    coordinator.handlePiEvent(active.session.id, {
      type: "prompt_error",
      error:
        'Codex error: {"type":"error","error":{"type":"service_unavailable_error","code":"server_is_overloaded","message":"Our servers are currently overloaded. Please try again later."}}',
    });

    expect(broadcast).toHaveBeenCalledWith("child-1", {
      type: "error",
      error: "Our servers are currently overloaded. Please try again later.",
    });
    expect(updateSessionFromEvent).not.toHaveBeenCalled();
    expect(resetIdleTimer).toHaveBeenCalledWith("child-1");
  });

  it("calls handleSessionSettled on agent_settled, prompt_error, and dialog settle", () => {
    const active = makeActiveSession({ status: "busy" });
    const handleSessionSettled = vi.fn();
    const { coordinator, resetIdleTimer } = makeCoordinator(active, {
      handleSessionSettled,
    });

    coordinator.handlePiEvent(active.session.id, { type: "agent_settled" });
    coordinator.handlePiEvent(active.session.id, {
      type: "prompt_error",
      error: "boom",
    });
    coordinator.handlePiEvent(active.session.id, {
      type: "extension_ui_request_settled",
      id: "ui-1",
    });
    coordinator.handlePiEvent(active.session.id, {
      type: "extension_error",
      extensionPath: "ext.ts",
      error: "failed",
    });

    expect(handleSessionSettled.mock.calls).toEqual([["child-1"], ["child-1"], ["child-1"]]);
    expect(resetIdleTimer).toHaveBeenCalledTimes(1);
    expect(resetIdleTimer).toHaveBeenCalledWith("child-1");
  });

  it("invokes handleSessionSettled when updateSessionFromEvent throws after setting ready", () => {
    const active = makeActiveSession({ status: "busy" });
    const handleSessionSettled = vi.fn();
    const { coordinator, updateSessionFromEvent } = makeCoordinator(active, {
      handleSessionSettled,
    });
    updateSessionFromEvent.mockImplementation(() => {
      active.session.status = "ready";
      throw new Error("persist failed");
    });

    expect(() => coordinator.handlePiEvent(active.session.id, { type: "agent_settled" })).toThrow(
      "persist failed",
    );
    expect(handleSessionSettled).toHaveBeenCalledTimes(1);
    expect(handleSessionSettled).toHaveBeenCalledWith("child-1");
  });

  it("logs the raw prompt_error payload alongside the normalized user-facing message", () => {
    const active = makeActiveSession();
    const { coordinator } = makeCoordinator(active);
    const writes: string[] = [];
    const stderrSpy = vi.spyOn(process.stderr, "write").mockImplementation(((
      chunk: string | Uint8Array,
    ) => {
      writes.push(typeof chunk === "string" ? chunk : Buffer.from(chunk).toString("utf8"));
      return true;
    }) as typeof process.stderr.write);

    try {
      coordinator.handlePiEvent(active.session.id, {
        type: "prompt_error",
        error:
          'Codex error: {"type":"error","error":{"type":"service_unavailable_error","code":"server_is_overloaded","message":"Our servers are currently overloaded. Please try again later."}}',
      });
    } finally {
      stderrSpy.mockRestore();
    }

    const logLine = writes.find((line) =>
      line.includes('"event":"session_agent_events.prompt.error"'),
    );
    expect(logLine).toContain(
      '"error":"Our servers are currently overloaded. Please try again later."',
    );
    expect(logLine).toContain(
      '"rawError":"Codex error: {\\"type\\":\\"error\\",\\"error\\":{\\"type\\":\\"service_unavailable_error\\",\\"code\\":\\"server_is_overloaded\\",\\"message\\":\\"Our servers are currently overloaded. Please try again later.\\"}}"',
    );
  });

  it("broadcasts extension UI settlement so secondary clients dismiss stale dialogs", () => {
    const active = makeActiveSession({ id: "sess-ui", status: "busy" });
    active.pendingUIRequests.set("ui-1", {
      type: "extension_ui_request",
      id: "ui-1",
      method: "select",
      title: "Choose",
      options: ["A", "B"],
    });
    active.pendingAsk = {
      requestId: "ui-1",
      questionCount: 0,
      initiatedAt: Date.now(),
    };
    const { broadcast, coordinator, resetIdleTimer, updateSessionFromEvent } =
      makeCoordinator(active);

    coordinator.handlePiEvent(active.session.id, {
      type: "extension_ui_request_settled",
      id: "ui-1",
    });

    expect(active.pendingUIRequests.has("ui-1")).toBe(false);
    expect(active.pendingAsk).toBeUndefined();
    expect(broadcast).toHaveBeenCalledWith("sess-ui", {
      type: "extension_ui_settled",
      id: "ui-1",
      sessionId: "sess-ui",
    });
    expect(updateSessionFromEvent).not.toHaveBeenCalled();
    expect(resetIdleTimer).toHaveBeenCalledWith("sess-ui");
  });

  it("forwards extension audio stream events without sending them through SDK event translation", () => {
    const active = makeActiveSession();
    const { broadcast, coordinator, resetIdleTimer, updateSessionFromEvent } =
      makeCoordinator(active);

    coordinator.handlePiEvent(active.session.id, {
      type: "extension_audio_stream",
      kind: "audio-stream",
      id: "tts-1",
      event: "chunk",
      mimeType: "audio/pcm; codecs=s16le",
      sampleRate: 24_000,
      channels: 1,
      chunkIndex: 2,
      audioBase64: "AAAA",
      text: "hello",
    });

    expect(broadcast).toHaveBeenCalledWith("child-1", {
      type: "audio_stream",
      kind: "audio-stream",
      id: "tts-1",
      event: "chunk",
      mimeType: "audio/pcm; codecs=s16le",
      sampleRate: 24_000,
      channels: 1,
      chunkIndex: 2,
      audioBase64: "AAAA",
      text: "hello",
      durationSeconds: undefined,
      metrics: undefined,
    });
    expect(updateSessionFromEvent).not.toHaveBeenCalled();
    expect(resetIdleTimer).toHaveBeenCalledWith("child-1");
  });

  it("does not broadcast or materialize image media from partial updates", () => {
    const active = makeActiveSession();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-session-agent-events-"));
    tempDirs.push(dataDir);
    const { broadcast, coordinator } = makeCoordinator(active, { dataDir });

    coordinator.handlePiEvent(active.session.id, {
      type: "tool_execution_update",
      toolCallId: "image-tool-1",
      toolName: "imagen",
      partialResult: {
        content: [
          { type: "image", data: Buffer.from("png").toString("base64"), mimeType: "image/png" },
        ],
        details: {
          status: "preview",
          image: {
            kind: "image",
            mimeType: "image/png",
            base64: Buffer.from("png").toString("base64"),
            fileName: "preview.png",
          },
        },
      },
    } as unknown as SessionBackendEvent);

    const messages = broadcast.mock.calls.map(([, message]) => message);
    const toolOutputs = messages.filter((message) => message.type === "tool_output") as Array<{
      details?: { image?: unknown; media?: unknown[] };
    }>;
    expect(toolOutputs.some((message) => message.details?.image !== undefined)).toBe(false);
    expect(
      toolOutputs.some((message) =>
        message.details?.media?.some((item) => (item as { kind?: string }).kind === "image"),
      ),
    ).toBe(false);
    expect(
      sessionAttachmentMediaDetailsForToolCall(dataDir, active.session.id, "image-tool-1"),
    ).toHaveLength(0);
  });

  it("materializes final image details and strips base64 before broadcast", () => {
    const active = makeActiveSession();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-session-agent-events-"));
    tempDirs.push(dataDir);
    const { broadcast, coordinator } = makeCoordinator(active, { dataDir });
    const base64 =
      "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAACZFr56AAAADElEQVR42mP8z8AARQAIMQH+6k9QbQAAAABJRU5ErkJggg==";

    coordinator.handlePiEvent(active.session.id, {
      type: "tool_execution_end",
      toolCallId: "image-tool-2",
      toolName: "imagen",
      result: {
        content: [{ type: "text", text: "Generated image" }],
        details: {
          image: {
            kind: "image",
            mimeType: "image/png",
            base64,
            fileName: "final.png",
          },
        },
      },
      isError: false,
    } as unknown as SessionBackendEvent);

    const toolEnd = broadcast.mock.calls
      .map(([, message]) => message)
      .find((message) => message.type === "tool_end") as
      | {
          details?: {
            image?: {
              id?: string;
              storageKey?: string;
              base64?: string;
              path?: string;
              sha256?: string;
            };
          };
        }
      | undefined;

    expect(toolEnd?.details?.image?.id).toContain("att_image-tool-2_");
    expect(toolEnd?.details?.image?.storageKey).toContain(`${active.session.id}/`);
    expect(toolEnd?.details?.image?.base64).toBeUndefined();
    expect(toolEnd?.details?.image?.path).toBeUndefined();
    expect(toolEnd?.details?.image?.sha256).toEqual(expect.any(String));
  });

  it("materializes final details.media video entries and strips base64 before broadcast", () => {
    const active = makeActiveSession();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-session-agent-events-"));
    tempDirs.push(dataDir);
    const { broadcast, coordinator } = makeCoordinator(active, { dataDir });

    coordinator.handlePiEvent(active.session.id, {
      type: "tool_execution_end",
      toolCallId: "video-tool-1",
      toolName: "browser_automation_video",
      result: {
        content: [{ type: "text", text: "Recorded browser run" }],
        details: {
          media: [
            {
              kind: "video",
              mimeType: "video/mp4",
              base64: Buffer.from("mp4-video").toString("base64"),
              fileName: "browser-run.mp4",
            },
          ],
        },
      },
      isError: false,
    } as unknown as SessionBackendEvent);

    const toolEnd = broadcast.mock.calls
      .map(([, message]) => message)
      .find((message) => message.type === "tool_end") as
      | {
          details?: {
            media?: Array<{
              id?: string;
              kind?: string;
              storageKey?: string;
              base64?: string;
              path?: string;
            }>;
          };
        }
      | undefined;

    expect(toolEnd?.details?.media?.[0]?.id).toContain("att_video-tool-1_");
    expect(toolEnd?.details?.media?.[0]?.kind).toBe("video");
    expect(toolEnd?.details?.media?.[0]?.storageKey).toContain("child-1/");
    expect(toolEnd?.details?.media?.[0]?.base64).toBeUndefined();
    expect(toolEnd?.details?.media?.[0]?.path).toBeUndefined();
  });

  it("materializes session attachments for any tool that returns audio details", () => {
    const active = makeActiveSession();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-session-agent-events-"));
    tempDirs.push(dataDir);
    const { broadcast, coordinator } = makeCoordinator(active, { dataDir });

    coordinator.handlePiEvent(active.session.id, {
      type: "tool_execution_end",
      toolCallId: "tts-tool-1",
      toolName: "example_tts_speak",
      result: {
        content: [{ type: "text", text: "Hello from a custom TTS extension." }],
        details: {
          kind: "audio_presentation",
          text: "Hello from a custom TTS extension.",
          playbackBehavior: "tapToPlay",
          audio: {
            kind: "audio",
            mimeType: "audio/wav",
            base64: Buffer.from("RIFFtest-audio").toString("base64"),
            fileName: "reply.wav",
          },
        },
      },
      isError: false,
    } as unknown as SessionBackendEvent);

    const toolEnd = broadcast.mock.calls
      .map(([, message]) => message)
      .find((message) => message.type === "tool_end") as
      | {
          details?: {
            audio?: { id?: string; storageKey?: string; base64?: string; path?: string };
          };
        }
      | undefined;

    expect(toolEnd?.details?.audio?.id).toContain("att_tts-tool-1_");
    expect(toolEnd?.details?.audio?.storageKey).toContain("child-1/");
    expect(toolEnd?.details?.audio?.base64).toBeUndefined();
    expect(toolEnd?.details?.audio?.path).toBeUndefined();
  });
});

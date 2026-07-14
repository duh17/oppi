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
      partialResults: new Map(),
      streamedAssistantText: "",
      hasStreamedThinking: false,
      streamedThinkingContentIndexes: new Set(),
      toolNames: new Map(),
      toolArgs: new Map(),
      shellPreviewLastSent: new Map(),
      streamingArgPreviews: new Set<string>(),
      streamingToolUpdatesSeen: new Map<string, string>(),
      turnCache: new TurnDedupeCache(),
      pendingTurnStarts: [],
      sdkBackend: {} as never,
      subscribers: new Set<(msg: unknown) => void>(),
      toolFullOutputPaths: new Map<string, string>(),
      cacheMissTracker: {},
      showCacheMissNotices: false,
    };
  }

  function makeCoordinator(
    active: SessionAgentEventState,
    options?: { dataDir?: string },
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
          partialResults: active.partialResults,
          streamedAssistantText: active.streamedAssistantText,
          hasStreamedThinking: active.hasStreamedThinking,
          streamedThinkingContentIndexes: active.streamedThinkingContentIndexes,
          currentThinkingContentIndex: active.currentThinkingContentIndex,
          mobileRenderers: {
            renderCall: vi.fn(),
            renderResult: vi.fn(),
          } as never,
          toolNames: active.toolNames,
          toolArgs: active.toolArgs,
          shellPreviewLastSent: active.shellPreviewLastSent,
          streamingArgPreviews: active.streamingArgPreviews,
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
      ...(options?.dataDir ? { dataDir: options.dataDir } : {}),
    });

    return { broadcast, coordinator, resetIdleTimer, updateSessionFromEvent };
  }

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

  it("attaches managed SDK renderResult snapshots to tool_end details", () => {
    const active = makeActiveSession({ status: "busy" });
    active.sdkBackend = {
      session: {
        getToolDefinition: () => ({
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
        sessionManager: {
          getHeader: () => ({ cwd: "/tmp/oppi-test" }),
        },
      },
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
        tuiRender: {
          version: 1,
          source: "renderResult",
          width: 80,
        },
      },
    });
    expect(toolEnd?.details?.tuiRender?.expandedText).toContain("title: Ship it");
    expect(toolEnd?.details?.tuiRender?.expandedText).toContain("body: Use the TUI renderer");
  });

  it("does not attach TUI render snapshots for native tool rows", () => {
    const active = makeActiveSession({ status: "busy" });
    const renderResult = vi.fn(() => ({ render: () => ["native renderer"] }));
    active.sdkBackend = {
      session: {
        getToolDefinition: () => ({ renderResult }),
        sessionManager: {
          getHeader: () => ({ cwd: "/tmp/oppi-test" }),
        },
      },
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
      session: {
        getToolDefinition: () => ({
          renderResult: () => ({ render: () => ["rendered snapshot"] }),
        }),
        sessionManager: {
          getHeader: () => ({ cwd: "/tmp/oppi-test" }),
        },
      },
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

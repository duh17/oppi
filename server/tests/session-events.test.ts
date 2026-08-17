import { describe, expect, it, vi } from "vitest";

import { SERVER_METRIC_REGISTRY } from "../src/server-metric-registry.js";
import { SessionEventProcessor, type EventProcessorSessionState } from "../src/session-events.js";
import type { Session } from "../src/types.js";

function makeSession(id = "sess-1"): Session {
  const now = Date.now();
  return {
    id,
    status: "busy",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
  };
}

function makeActiveSession(session: Session): EventProcessorSessionState {
  return {
    session,
    pendingUIRequests: new Map(),
    partialResults: new Map<string, string>(),
    streamedAssistantText: "",
    hasStreamedThinking: false,
    streamedThinkingContentIndexes: new Set(),
    toolNames: new Map<string, string>(),
    shellPreviewLastSent: new Map<string, number>(),
    streamingToolUpdatesSeen: new Map<string, string>(),
  };
}

class MockMetrics {
  samples: Array<{ metric: string; value: number; tags?: Record<string, string> }> = [];

  record(metric: string, value: number, tags?: Record<string, string>): void {
    this.samples.push({ metric, value, tags });
  }
}

describe("SessionEventProcessor", () => {
  it("registers per-tool duration and result metrics", () => {
    expect(SERVER_METRIC_REGISTRY).toHaveProperty("server.tool_duration_ms");
    expect(SERVER_METRIC_REGISTRY).toHaveProperty("server.tool_result");
    expect(SERVER_METRIC_REGISTRY["server.tool_duration_ms"].unit).toBe("ms");
    expect(SERVER_METRIC_REGISTRY["server.tool_result"].unit).toBe("count");
  });

  it("tags turn duration, TTFT, and tool-call counts with exact provider and model", () => {
    vi.useFakeTimers();
    vi.setSystemTime(1_000);
    try {
      const metrics = new MockMetrics();
      const processor = new SessionEventProcessor({
        storage: {} as never,
        broadcast: vi.fn(),
        persistSessionNow: vi.fn(),
        markSessionDirty: vi.fn(),
        metrics: metrics as never,
      });
      const active = makeActiveSession({
        ...makeSession("sess-1"),
        model: "openrouter/z.ai/glm-5",
        thinkingLevel: "high",
      });

      processor.updateSessionFromEvent("sess-1", active, { type: "agent_start" } as never);
      vi.setSystemTime(1_250);
      processor.updateSessionFromEvent("sess-1", active, {
        type: "message_update",
        assistantMessageEvent: { type: "text_delta", delta: "hi" },
      } as never);
      processor.updateSessionFromEvent("sess-1", active, {
        type: "tool_execution_start",
        toolCallId: "tool-1",
        toolName: "bash",
        args: { command: "ls" },
      } as never);
      vi.setSystemTime(2_000);
      processor.updateSessionFromEvent("sess-1", active, {
        type: "agent_end",
        messages: [],
      } as never);

      const expectedTags = {
        sessionId: "sess-1",
        provider: "openrouter",
        model: "z.ai/glm-5",
        thinking: "high",
      };
      expect(metrics.samples).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            metric: "server.turn_ttft_ms",
            value: 250,
            tags: expectedTags,
          }),
          expect.objectContaining({
            metric: "server.turn_duration_ms",
            value: 1_000,
            tags: expectedTags,
          }),
          expect.objectContaining({
            metric: "server.turn_tool_calls",
            value: 1,
            tags: expectedTags,
          }),
        ]),
      );
    } finally {
      vi.useRealTimers();
    }
  });

  it("omits thinking and provider/model tags when they are missing or unsafe", () => {
    const metrics = new MockMetrics();
    const processor = new SessionEventProcessor({
      storage: {} as never,
      broadcast: vi.fn(),
      persistSessionNow: vi.fn(),
      markSessionDirty: vi.fn(),
      metrics: metrics as never,
    });
    const active = makeActiveSession({
      ...makeSession("sess-1"),
      model: "solo-model",
      thinkingLevel: "constructor",
    });

    processor.updateSessionFromEvent("sess-1", active, { type: "agent_start" } as never);
    processor.updateSessionFromEvent("sess-1", active, {
      type: "agent_end",
      messages: [
        { stopReason: "error", errorMessage: "provider overloaded at /Users/chenda/secret" },
      ],
    } as never);

    expect(metrics.samples).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          metric: "server.turn_duration_ms",
          tags: { sessionId: "sess-1" },
        }),
        expect.objectContaining({
          metric: "server.turn_error",
          tags: { sessionId: "sess-1", category: "overloaded" },
        }),
      ]),
    );
    expect(JSON.stringify(metrics.samples)).not.toContain("/Users/chenda/secret");
    for (const sample of metrics.samples) {
      expect(sample.tags).not.toHaveProperty("provider");
      expect(sample.tags).not.toHaveProperty("model");
      expect(sample.tags).not.toHaveProperty("thinking");
    }
  });

  it("pairs concurrent tool calls by toolCallId and records duration plus result", () => {
    vi.useFakeTimers();
    vi.setSystemTime(1_000);
    try {
      const metrics = new MockMetrics();
      const processor = new SessionEventProcessor({
        storage: {} as never,
        broadcast: vi.fn(),
        persistSessionNow: vi.fn(),
        markSessionDirty: vi.fn(),
        metrics: metrics as never,
      });
      const active = makeActiveSession({
        ...makeSession("sess-1"),
        model: "anthropic/claude-sonnet-4-0",
      });

      processor.updateSessionFromEvent("sess-1", active, { type: "agent_start" } as never);
      processor.updateSessionFromEvent("sess-1", active, {
        type: "tool_execution_start",
        toolCallId: "call-a",
        toolName: "bash",
        args: { command: "sleep 1" },
      } as never);
      vi.setSystemTime(1_100);
      processor.updateSessionFromEvent("sess-1", active, {
        type: "tool_execution_start",
        toolCallId: "call-b",
        toolName: "bash",
        args: { command: "pwd" },
      } as never);
      vi.setSystemTime(1_300);
      processor.updateSessionFromEvent("sess-1", active, {
        type: "tool_execution_end",
        toolCallId: "call-b",
        toolName: "bash",
        result: { content: [{ type: "text", text: "/tmp/secret" }] },
        isError: true,
      } as never);
      vi.setSystemTime(1_800);
      processor.updateSessionFromEvent("sess-1", active, {
        type: "tool_execution_end",
        toolCallId: "call-a",
        toolName: "bash",
        result: { content: [] },
        isError: false,
      } as never);

      const routing = {
        sessionId: "sess-1",
        provider: "anthropic",
        model: "claude-sonnet-4-0",
        tool: "bash",
      };
      expect(metrics.samples).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            metric: "server.tool_duration_ms",
            value: 200,
            tags: { ...routing, status: "error" },
          }),
          expect.objectContaining({
            metric: "server.tool_result",
            value: 1,
            tags: { ...routing, status: "error" },
          }),
          expect.objectContaining({
            metric: "server.tool_duration_ms",
            value: 800,
            tags: { ...routing, status: "ok" },
          }),
          expect.objectContaining({
            metric: "server.tool_result",
            value: 1,
            tags: { ...routing, status: "ok" },
          }),
        ]),
      );
      for (const sample of metrics.samples) {
        const serialized = JSON.stringify(sample);
        expect(serialized).not.toContain("sleep 1");
        expect(serialized).not.toContain("/tmp/secret");
        expect(serialized).not.toContain("pwd");
      }
    } finally {
      vi.useRealTimers();
    }
  });

  it("records a tool result without duration when start or end is missing", () => {
    vi.useFakeTimers();
    vi.setSystemTime(1_000);
    try {
      const metrics = new MockMetrics();
      const processor = new SessionEventProcessor({
        storage: {} as never,
        broadcast: vi.fn(),
        persistSessionNow: vi.fn(),
        markSessionDirty: vi.fn(),
        metrics: metrics as never,
      });
      const active = makeActiveSession({
        ...makeSession("sess-1"),
        model: "openai/gpt-5.5",
      });

      processor.updateSessionFromEvent("sess-1", active, { type: "agent_start" } as never);
      processor.updateSessionFromEvent("sess-1", active, {
        type: "tool_execution_start",
        toolCallId: "orphan-start",
        toolName: "read",
        args: { path: "/Users/chenda/secret.ts" },
      } as never);
      processor.updateSessionFromEvent("sess-1", active, {
        type: "tool_execution_end",
        toolCallId: "orphan-end",
        toolName: "edit",
        result: { content: "patched" },
        isError: false,
      } as never);
      processor.updateSessionFromEvent("sess-1", active, {
        type: "tool_execution_end",
        toolName: "/tmp/custom-tool",
        result: { content: "leak-me" },
        isError: true,
      } as never);
      vi.setSystemTime(2_000);
      processor.updateSessionFromEvent("sess-1", active, {
        type: "agent_end",
        messages: [],
      } as never);

      const toolSamples = metrics.samples.filter((sample) =>
        sample.metric.startsWith("server.tool_"),
      );
      expect(toolSamples).toEqual(
        expect.arrayContaining([
          {
            metric: "server.tool_result",
            value: 1,
            tags: {
              sessionId: "sess-1",
              provider: "openai",
              model: "gpt-5.5",
              tool: "edit",
              status: "ok",
            },
          },
          {
            metric: "server.tool_result",
            value: 1,
            tags: {
              sessionId: "sess-1",
              provider: "openai",
              model: "gpt-5.5",
              tool: "unknown",
              status: "error",
            },
          },
        ]),
      );
      expect(toolSamples.some((sample) => sample.metric === "server.tool_duration_ms")).toBe(false);
      const serialized = JSON.stringify(toolSamples);
      expect(serialized).not.toContain("/Users/chenda/secret.ts");
      expect(serialized).not.toContain("patched");
      expect(serialized).not.toContain("leak-me");
      expect(serialized).not.toContain("/tmp/custom-tool");
    } finally {
      vi.useRealTimers();
    }
  });

  it("attributes multi-round usage to the session-configured route at each event", () => {
    const metrics = new MockMetrics();
    const processor = new SessionEventProcessor({
      storage: {} as never,
      broadcast: vi.fn(),
      persistSessionNow: vi.fn(),
      markSessionDirty: vi.fn(),
      metrics: metrics as never,
    });
    const active = makeActiveSession({
      ...makeSession("sess-1"),
      model: "xai/grok-4.6",
      thinkingLevel: "high",
    });

    processor.updateSessionFromEvent("sess-1", active, {
      type: "message_end",
      message: {
        role: "assistant",
        content: [],
        provider: "xai",
        model: "grok-4.6",
        usage: { input: 100, output: 20, cost: { total: 0.01 } },
      },
    } as never);

    active.session.model = "opencode-go/glm-5.3";
    active.session.thinkingLevel = "max";
    processor.updateSessionFromEvent("sess-1", active, {
      type: "message_end",
      message: {
        role: "assistant",
        content: [],
        provider: "opencode-go",
        model: "glm-5.3",
        usage: { input: 200, output: 40, cost: { total: 0.02 } },
      },
    } as never);

    expect(metrics.samples).toEqual(
      expect.arrayContaining([
        {
          metric: "server.turn_input_tokens",
          value: 100,
          tags: {
            sessionId: "sess-1",
            provider: "xai",
            model: "grok-4.6",
            thinking: "high",
          },
        },
        {
          metric: "server.turn_cost",
          value: 20_000,
          tags: {
            sessionId: "sess-1",
            provider: "opencode-go",
            model: "glm-5.3",
            thinking: "max",
          },
        },
      ]),
    );
  });

  it.each(["edit", "write", "functions.edit", "functions.write", "bash"])(
    "schedules git status refresh after %s tool end",
    (toolName) => {
      vi.useFakeTimers();
      try {
        const storage = { getWorkspace: vi.fn(() => undefined) };
        const processor = new SessionEventProcessor({
          storage: storage as never,
          mobileRenderers: {} as never,
          broadcast: vi.fn(),
          persistSessionNow: vi.fn(),
          markSessionDirty: vi.fn(),
        });
        const active = makeActiveSession({ ...makeSession("sess-1"), workspaceId: "ws-1" });

        processor.updateSessionFromEvent("sess-1", active, {
          type: "tool_execution_end",
          toolName,
          toolCallId: "tool-1",
          result: { content: [] },
          isError: false,
        } as never);

        expect(storage.getWorkspace).not.toHaveBeenCalled();
        vi.advanceTimersByTime(2_000);
        expect(storage.getWorkspace).toHaveBeenCalledWith("ws-1");
      } finally {
        vi.useRealTimers();
      }
    },
  );

  it.each(["ext.edit", "my.write", "ask.edit", "something.write"])(
    "does not schedule git status for namespaced tool %s",
    (toolName) => {
      vi.useFakeTimers();
      try {
        const storage = { getWorkspace: vi.fn(() => undefined) };
        const processor = new SessionEventProcessor({
          storage: storage as never,
          mobileRenderers: {} as never,
          broadcast: vi.fn(),
          persistSessionNow: vi.fn(),
          markSessionDirty: vi.fn(),
        });
        const active = makeActiveSession({ ...makeSession("sess-1"), workspaceId: "ws-1" });

        processor.updateSessionFromEvent("sess-1", active, {
          type: "tool_execution_end",
          toolName,
          toolCallId: "tool-1",
          result: { content: [] },
          isError: false,
        } as never);

        vi.advanceTimersByTime(2_000);
        expect(storage.getWorkspace).not.toHaveBeenCalled();
      } finally {
        vi.useRealTimers();
      }
    },
  );

  it("mirrors Pi session_info_changed events into session name state", () => {
    const persistSessionNow = vi.fn();
    const markSessionDirty = vi.fn();
    const processor = new SessionEventProcessor({
      storage: {} as never,
      mobileRenderers: {} as never,
      broadcast: vi.fn(),
      persistSessionNow,
      markSessionDirty,
    });
    const active = makeActiveSession(makeSession("sess-1"));

    processor.updateSessionFromEvent("sess-1", active, {
      type: "session_info_changed",
      name: "  Pi Session Name  ",
    } as never);

    expect(active.session.name).toBe("Pi Session Name");
    expect(persistSessionNow).toHaveBeenCalledWith("sess-1", active.session);
    expect(markSessionDirty).not.toHaveBeenCalled();
  });

  it("clears session name when Pi clears session_info", () => {
    const persistSessionNow = vi.fn();
    const processor = new SessionEventProcessor({
      storage: {} as never,
      mobileRenderers: {} as never,
      broadcast: vi.fn(),
      persistSessionNow,
      markSessionDirty: vi.fn(),
    });
    const active = makeActiveSession({ ...makeSession("sess-1"), name: "Old Name" });

    processor.updateSessionFromEvent("sess-1", active, {
      type: "session_info_changed",
      name: undefined,
    } as never);

    expect(active.session.name).toBeUndefined();
    expect(persistSessionNow).toHaveBeenCalledWith("sess-1", active.session);
  });

  it("rate-limits estimated context state broadcasts", () => {
    vi.useFakeTimers();
    vi.setSystemTime(1_000);
    try {
      const broadcast = vi.fn();
      const processor = new SessionEventProcessor({
        storage: {} as never,
        broadcast,
        persistSessionNow: vi.fn(),
        markSessionDirty: vi.fn(),
      });
      const active = makeActiveSession({ ...makeSession("sess-1"), contextTokens: 1_000 });

      processor.updateSessionFromEvent("sess-1", active, { type: "agent_start" } as never);
      for (let index = 0; index < 4; index += 1) {
        processor.updateSessionFromEvent("sess-1", active, {
          type: "message_update",
          assistantMessageEvent: { type: "text_delta", delta: "x".repeat(512) },
        } as never);
      }
      expect(broadcast).toHaveBeenCalledTimes(1);

      vi.advanceTimersByTime(500);
      processor.updateSessionFromEvent("sess-1", active, {
        type: "message_update",
        assistantMessageEvent: { type: "text_delta", delta: "x".repeat(512) },
      } as never);
      expect(broadcast).toHaveBeenCalledTimes(2);
      expect(broadcast).toHaveBeenLastCalledWith(
        "sess-1",
        expect.objectContaining({
          type: "state",
          session: expect.objectContaining({ contextTokens: 1_640 }),
        }),
      );

      vi.advanceTimersByTime(500);
      processor.updateSessionFromEvent("sess-1", active, {
        type: "message_update",
        assistantMessageEvent: { type: "text_delta", delta: "tiny" },
      } as never);
      expect(broadcast).toHaveBeenCalledTimes(2);
    } finally {
      vi.useRealTimers();
    }
  });
});

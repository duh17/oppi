import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { SessionBackendEvent } from "./pi-events.js";
import {
  SessionAgentEventCoordinator,
  type SessionAgentEventState,
} from "./session-agent-events.js";
import { buildSessionSummary } from "./session-summary.js";
import { TurnDedupeCache } from "./turn-cache.js";
import type { Session } from "./types.js";

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
      toolNames: new Map(),
      shellPreviewLastSent: new Map(),
      streamingArgPreviews: new Set<string>(),
      streamingToolUpdatesSeen: new Set<string>(),
      turnCache: new TurnDedupeCache(),
      pendingTurnStarts: [],
      sdkBackend: {} as never,
      subscribers: new Set<(msg: unknown) => void>(),
      toolFullOutputPaths: new Map<string, string>(),
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
          mobileRenderers: {
            renderCall: vi.fn(),
            renderResult: vi.fn(),
          } as never,
          toolNames: active.toolNames,
          shellPreviewLastSent: active.shellPreviewLastSent,
          streamingArgPreviews: active.streamingArgPreviews,
          streamingToolUpdatesSeen: active.streamingToolUpdatesSeen,
        })),
        updateSessionFromEvent,
        handleExtensionUIRequest: vi.fn(),
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

  it("mirrors child ready summaries to the parent session key", () => {
    const active = makeActiveSession({ parentSessionId: "parent-1", status: "busy" });
    const { broadcast, coordinator } = makeCoordinator(active);

    coordinator.handlePiEvent(active.session.id, {
      type: "agent_end",
      messages: [],
    } as unknown as SessionBackendEvent);

    const summary = buildSessionSummary(active.session);
    const summaryBroadcasts = broadcast.mock.calls.filter(
      ([, message]) => message.type === "session_summary",
    );
    expect(summaryBroadcasts).toHaveLength(2);
    expect(summaryBroadcasts).toEqual([
      ["child-1", { type: "session_summary", summary }],
      ["parent-1", { type: "session_summary", summary }],
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
          presentation: "voice",
          message: "Hello from a custom TTS extension.",
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

import { describe, expect, it, vi } from "vitest";
import type { SessionBackendEvent } from "./pi-events.js";
import {
  SessionAgentEventCoordinator,
  type SessionAgentEventState,
} from "./session-agent-events.js";
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
      turnCache: new TurnDedupeCache(),
      pendingTurnStarts: [],
      sdkBackend: {} as never,
      subscribers: new Set<(msg: unknown) => void>(),
      toolFullOutputPaths: new Map<string, string>(),
    };
  }

  function makeCoordinator(active: SessionAgentEventState): {
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
          mobileRenderers: {} as never,
          toolNames: active.toolNames,
          shellPreviewLastSent: active.shellPreviewLastSent,
          streamingArgPreviews: active.streamingArgPreviews,
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
    });

    return { broadcast, coordinator, resetIdleTimer, updateSessionFromEvent };
  }

  it("mirrors child ready state updates to the parent session key", () => {
    const active = makeActiveSession({ parentSessionId: "parent-1", status: "busy" });
    const { broadcast, coordinator } = makeCoordinator(active);

    coordinator.handlePiEvent(active.session.id, {
      type: "agent_end",
      messages: [],
    } as unknown as SessionBackendEvent);

    const stateBroadcasts = broadcast.mock.calls.filter(([, message]) => message.type === "state");
    expect(stateBroadcasts).toHaveLength(2);
    expect(stateBroadcasts).toEqual([
      ["child-1", { type: "state", session: active.session }],
      ["parent-1", { type: "state", session: active.session }],
    ]);
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
});

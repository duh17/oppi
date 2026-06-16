import { describe, expect, it, vi } from "vitest";

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
    streamingArgPreviews: new Set<string>(),
    streamingToolUpdatesSeen: new Map<string, string>(),
  };
}

describe("SessionEventProcessor", () => {
  it("schedules git status refresh after mutating tool end", () => {
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
        toolName: "bash",
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
  });

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
});

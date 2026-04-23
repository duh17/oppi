import { describe, expect, it, vi } from "vitest";

import {
  SessionEventProcessor,
  type EventProcessorSessionState,
  type ExtensionUIRequest,
} from "./session-events.js";
import { SessionUICoordinator, type SessionUIState } from "./session-ui.js";
import type { Session } from "./types.js";

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

function createHarness(): {
  key: string;
  active: EventProcessorSessionState & SessionUIState;
  processor: SessionEventProcessor;
  ui: SessionUICoordinator;
  broadcast: ReturnType<typeof vi.fn>;
  sdkBackend: SessionUIState["sdkBackend"];
} {
  const key = "sess-1";
  const broadcast = vi.fn();

  const sdkBackend = {
    respondToExtensionUIRequest: vi.fn(() => true),
  } as unknown as SessionUIState["sdkBackend"];

  const active = {
    session: makeSession(key),
    pendingUIRequests: new Map<string, ExtensionUIRequest>(),
    partialResults: new Map<string, string>(),
    streamedAssistantText: "",
    hasStreamedThinking: false,
    toolNames: new Map<string, string>(),
    shellPreviewLastSent: new Map<string, number>(),
    streamingArgPreviews: new Set<string>(),
    sdkBackend,
  } as unknown as EventProcessorSessionState & SessionUIState;

  const uiRef: { current: SessionUICoordinator | null } = { current: null };
  const processor = new SessionEventProcessor({
    storage: {} as never,
    mobileRenderers: {} as never,
    broadcast,
    persistSessionNow: () => {},
    markSessionDirty: () => {},
    respondToUIRequest: (_key, response) => {
      const coordinator = uiRef.current;
      if (!coordinator) return false;
      return coordinator.respondToUIRequest(_key, response);
    },
  });

  const ui = new SessionUICoordinator({
    getActiveSession: () => active,
    eventProcessor: processor,
  });
  uiRef.current = ui;

  return { key, active, processor, ui, broadcast, sdkBackend };
}

describe("direct ask flow", () => {
  it("forwards a single ask request to the phone", () => {
    const { key, active, processor, broadcast } = createHarness();

    processor.handleExtensionUIRequest(key, active, {
      type: "extension_ui_request",
      id: "ask-1",
      method: "ask",
      allowCustom: false,
      timeout: 45_000,
      questions: [
        {
          id: "approach",
          question: "Which testing approach?",
          options: [
            { value: "unit", label: "Unit tests" },
            { value: "integration", label: "Integration tests" },
          ],
        },
      ],
    });

    expect(active.pendingUIRequests.has("ask-1")).toBe(true);
    expect(active.pendingAsk?.requestId).toBe("ask-1");
    expect(broadcast).toHaveBeenCalledTimes(1);
    expect(broadcast.mock.calls[0][1]).toMatchObject({
      type: "extension_ui_request",
      id: "ask-1",
      sessionId: key,
      method: "ask",
      allowCustom: false,
      timeout: 45_000,
      questions: [
        {
          id: "approach",
          question: "Which testing approach?",
        },
      ],
    });
  });

  it("clears pending ask state when the answer arrives", () => {
    const { key, active, processor, ui, sdkBackend } = createHarness();

    processor.handleExtensionUIRequest(key, active, {
      type: "extension_ui_request",
      id: "ask-1",
      method: "ask",
      questions: [
        {
          id: "approach",
          question: "Which testing approach?",
          options: [
            { value: "unit", label: "Unit tests" },
            { value: "integration", label: "Integration tests" },
          ],
        },
      ],
    });

    const response = {
      type: "extension_ui_response" as const,
      id: "ask-1",
      value: JSON.stringify({ approach: "unit" }),
    };
    const handled = ui.respondToUIRequest(key, response);

    expect(handled).toBe(true);
    expect(active.pendingAsk).toBeUndefined();
    expect(active.pendingUIRequests.size).toBe(0);
    expect(sdkBackend.respondToExtensionUIRequest).toHaveBeenCalledWith(response);
  });

  it("does not synthesize ask UI from tool_execution_start", () => {
    const { key, active, processor, broadcast } = createHarness();

    processor.updateSessionFromEvent(key, active, {
      type: "tool_execution_start",
      toolName: "ask",
      toolCallId: "tc-ask-1",
      args: {
        questions: [
          {
            id: "approach",
            question: "Which testing approach?",
            options: [{ value: "unit", label: "Unit tests" }],
          },
        ],
      },
    } as never);

    expect(active.pendingAsk).toBeUndefined();
    expect(broadcast).not.toHaveBeenCalled();
  });
});

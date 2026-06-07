import { describe, expect, it, vi } from "vitest";

import { SessionEventProcessor, type EventProcessorSessionState } from "../src/session-events.js";
import {
  buildPendingExtensionUIRequestMessages,
  drainExtensionUITeardownMessages,
  handleExtensionUIRequest,
  respondToExtensionUIRequest,
  type ExtensionUIRequest,
} from "../src/extension-ui-state.js";
import type { SdkBackend } from "../src/sdk-backend.js";
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

function createHarness(): {
  key: string;
  active: EventProcessorSessionState & {
    sdkBackend: Pick<SdkBackend, "respondToExtensionUIRequest">;
  };
  processor: SessionEventProcessor;
  broadcast: ReturnType<typeof vi.fn>;
  sdkBackend: Pick<SdkBackend, "respondToExtensionUIRequest">;
} {
  const key = "sess-1";
  const broadcast = vi.fn();

  const sdkBackend = {
    respondToExtensionUIRequest: vi.fn(() => true),
  } as unknown as Pick<SdkBackend, "respondToExtensionUIRequest">;

  const active = {
    session: makeSession(key),
    pendingUIRequests: new Map<string, ExtensionUIRequest>(),
    partialResults: new Map<string, string>(),
    streamedAssistantText: "",
    hasStreamedThinking: false,
    streamedThinkingContentIndexes: new Set(),
    toolNames: new Map<string, string>(),
    shellPreviewLastSent: new Map<string, number>(),
    streamingArgPreviews: new Set<string>(),
    streamingToolUpdatesSeen: new Map<string, string>(),
    sdkBackend,
  } as unknown as EventProcessorSessionState & {
    sdkBackend: Pick<SdkBackend, "respondToExtensionUIRequest">;
  };

  const processor = new SessionEventProcessor({
    storage: {} as never,
    mobileRenderers: {} as never,
    broadcast,
    persistSessionNow: () => {},
    markSessionDirty: () => {},
  });

  return { key, active, processor, broadcast, sdkBackend };
}

function emitExtensionUIRequest(
  harness: Pick<ReturnType<typeof createHarness>, "key" | "active" | "broadcast">,
  req: ExtensionUIRequest,
): void {
  handleExtensionUIRequest(harness.active, req, {
    broadcast: (message) => harness.broadcast(harness.key, message),
  });
}

describe("direct ask flow", () => {
  it("clears terminal-only mirror status instead of surfacing it to clients", () => {
    const harness = createHarness();
    const { key, broadcast } = harness;

    emitExtensionUIRequest(harness, {
      type: "extension_ui_request",
      id: "mirror-status-1",
      method: "setStatus",
      statusKey: "oppi-mirror",
      statusText: "Mirror | live",
    });

    expect(broadcast).toHaveBeenCalledWith(key, {
      type: "extension_ui_notification",
      method: "setStatus",
      message: undefined,
      notifyType: undefined,
      statusKey: "oppi-mirror",
      statusText: undefined,
      title: undefined,
      text: undefined,
      widgetKey: undefined,
      widgetLines: undefined,
      widgetPlacement: undefined,
    });
  });

  it("forwards a single ask request to the phone", () => {
    const harness = createHarness();
    const { key, active, broadcast } = harness;

    emitExtensionUIRequest(harness, {
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
    expect(buildPendingExtensionUIRequestMessages(active)).toEqual([
      expect.objectContaining({
        type: "extension_ui_request",
        id: "ask-1",
        sessionId: key,
        method: "ask",
        allowCustom: false,
        timeout: 45_000,
      }),
    ]);
  });

  it("clears pending ask state when the answer arrives", () => {
    const harness = createHarness();
    const { active, sdkBackend } = harness;

    emitExtensionUIRequest(harness, {
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
    const handled = respondToExtensionUIRequest(active, response, {
      deliver: (payload) => {
        active.sdkBackend.respondToExtensionUIRequest(payload);
        return true;
      },
    });

    expect(handled).toBe(true);
    expect(active.pendingAsk).toBeUndefined();
    expect(active.pendingUIRequests.size).toBe(0);
    expect(sdkBackend.respondToExtensionUIRequest).toHaveBeenCalledWith(response);
  });

  it("keeps a pending request when response delivery fails", () => {
    const harness = createHarness();
    const { active } = harness;

    emitExtensionUIRequest(harness, {
      type: "extension_ui_request",
      id: "ask-undelivered",
      method: "ask",
      questions: [
        {
          id: "approach",
          question: "Which testing approach?",
          options: [{ value: "unit", label: "Unit tests" }],
        },
      ],
    });

    const handled = respondToExtensionUIRequest(
      active,
      {
        type: "extension_ui_response",
        id: "ask-undelivered",
        value: JSON.stringify({ approach: "unit" }),
      },
      {
        deliver: () => false,
      },
    );

    expect(handled).toBe(false);
    expect(active.pendingAsk?.requestId).toBe("ask-undelivered");
    expect(active.pendingUIRequests.has("ask-undelivered")).toBe(true);
  });

  it("drains teardown messages and clears shared extension UI state", () => {
    const harness = createHarness();
    const { key, active } = harness;

    emitExtensionUIRequest(harness, {
      type: "extension_ui_request",
      id: "widget-1",
      method: "setWidget",
      widgetKey: "agents",
      widgetLines: ["running"],
    });
    emitExtensionUIRequest(harness, {
      type: "extension_ui_request",
      id: "thinking-label-1",
      method: "setHiddenThinkingLabel",
      hiddenThinkingLabel: "Private reasoning",
    });
    emitExtensionUIRequest(harness, {
      type: "extension_ui_request",
      id: "tools-expanded-1",
      method: "setToolsExpanded",
      toolsExpanded: true,
    });
    emitExtensionUIRequest(harness, {
      type: "extension_ui_request",
      id: "ask-1",
      method: "ask",
      questions: [
        {
          id: "approach",
          question: "Which testing approach?",
          options: [{ value: "unit", label: "Unit tests" }],
        },
      ],
    });

    expect(buildPendingExtensionUIRequestMessages(active)).toHaveLength(4);

    const messages = drainExtensionUITeardownMessages(active, { cancelled: true });

    expect(messages).toEqual([
      { type: "extension_ui_settled", id: "ask-1", sessionId: key },
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setWidget",
        widgetKey: "agents",
        widgetLines: undefined,
      }),
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setHiddenThinkingLabel",
        hiddenThinkingLabel: undefined,
      }),
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setToolsExpanded",
        toolsExpanded: false,
      }),
    ]);
    expect(active.pendingUIRequests.size).toBe(0);
    expect(active.pendingAsk).toBeUndefined();
    expect(active.persistentExtensionUINotifications?.size ?? 0).toBe(0);
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

  it("tracks the active turn start on agent_start and clears it on agent_end", () => {
    const { key, active, processor } = createHarness();

    processor.updateSessionFromEvent(key, active, {
      type: "agent_start",
    } as never);

    expect(active.session.status).toBe("busy");
    expect(typeof active.session.currentTurnStartedAt).toBe("number");

    processor.updateSessionFromEvent(key, active, {
      type: "agent_end",
      messages: [],
    } as never);

    expect(active.session.status).toBe("ready");
    expect(active.session.currentTurnStartedAt).toBeUndefined();
  });
});

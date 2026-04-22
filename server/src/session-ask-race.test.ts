import { describe, expect, it, vi } from "vitest";

import {
  SessionEventProcessor,
  type EventProcessorSessionState,
  type ExtensionUIRequest,
  type PendingAskState,
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

function makePendingAsk(sessionId = "sess-1"): PendingAskState {
  return {
    requestId: "ask-1",
    questions: [
      { id: "q1", question: "Question 1" },
      { id: "q2", question: "Question 2" },
    ],
    deferred: [],
    broadcastMessage: {
      type: "extension_ui_request",
      id: "ask-1",
      sessionId,
      method: "ask",
      questions: [],
      allowCustom: true,
    },
    initiatedAt: Date.now(),
    resolvedDeferredCount: 0,
  };
}

function createHarness(): {
  key: string;
  active: EventProcessorSessionState & SessionUIState;
  processor: SessionEventProcessor;
  ui: SessionUICoordinator;
  broadcast: ReturnType<typeof vi.fn>;
  sdkResponses: Array<{ id: string; value?: string; cancelled?: boolean }>;
} {
  const key = "sess-1";
  const broadcast = vi.fn();
  const sdkResponses: Array<{ id: string; value?: string; cancelled?: boolean }> = [];

  const sdkBackend = {
    respondToExtensionUIRequest: vi.fn(
      (response: { id: string; value?: string; cancelled?: boolean }) => {
        sdkResponses.push(response);
        return true;
      },
    ),
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
    pendingAsk: makePendingAsk(key),
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

  return { key, active, processor, ui, broadcast, sdkResponses };
}

describe("ask response/deferred race", () => {
  it("resolves late deferred select requests when ask answer arrives first", () => {
    const { key, active, processor, ui, broadcast, sdkResponses } = createHarness();

    // Synthetic ask request is pending, but no deferred select() requests yet.
    active.pendingUIRequests.set("ask-1", {
      type: "extension_ui_request",
      id: "ask-1",
      method: "ask",
    });

    const handled = ui.respondToUIRequest(key, {
      type: "extension_ui_response",
      id: "ask-1",
      value: JSON.stringify({ q1: "Alpha", q2: "Beta" }),
    });

    expect(handled).toBe(true);
    expect(active.pendingAsk).toBeDefined();

    // Deferred select requests arrive AFTER the ask response.
    processor.handleExtensionUIRequest(key, active, {
      type: "extension_ui_request",
      id: "sel-1",
      method: "select",
      options: ["Alpha", "Other"],
    });

    expect(sdkResponses[0]).toMatchObject({ id: "sel-1", value: "Alpha" });
    expect(active.pendingAsk).toBeDefined();

    processor.handleExtensionUIRequest(key, active, {
      type: "extension_ui_request",
      id: "sel-2",
      method: "select",
      options: ["Beta", "Other"],
    });

    expect(sdkResponses[1]).toMatchObject({ id: "sel-2", value: "Beta" });
    expect(active.pendingAsk).toBeUndefined();
    expect(active.pendingUIRequests.size).toBe(0);

    // Nothing should leak into normal phone dialog flow.
    expect(broadcast).not.toHaveBeenCalled();
  });

  it("cancels late deferred select requests when ask is cancelled first", () => {
    const { key, active, processor, ui, sdkResponses } = createHarness();

    active.pendingUIRequests.set("ask-1", {
      type: "extension_ui_request",
      id: "ask-1",
      method: "ask",
    });

    const handled = ui.respondToUIRequest(key, {
      type: "extension_ui_response",
      id: "ask-1",
      cancelled: true,
    });

    expect(handled).toBe(true);
    expect(active.pendingAsk).toBeDefined();

    processor.handleExtensionUIRequest(key, active, {
      type: "extension_ui_request",
      id: "sel-1",
      method: "select",
      options: ["Alpha", "Other"],
    });
    processor.handleExtensionUIRequest(key, active, {
      type: "extension_ui_request",
      id: "sel-2",
      method: "select",
      options: ["Beta", "Other"],
    });

    expect(sdkResponses).toMatchObject([
      { id: "sel-1", cancelled: true },
      { id: "sel-2", cancelled: true },
    ]);
    expect(active.pendingAsk).toBeUndefined();
    expect(active.pendingUIRequests.size).toBe(0);
  });
});

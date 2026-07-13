import { describe, expect, it, vi } from "vitest";

import { buildExtensionUINotificationMessage } from "../src/extension-ui-contract.js";
import {
  buildPendingExtensionUIRequestMessages,
  handleExtensionUIRequest,
  respondToExtensionUIRequest,
  settleExtensionUIRequest,
  type ExtensionUIRequest,
  type ExtensionUIState,
} from "../src/extension-ui-state.js";
import type { SessionBackendEvent } from "../src/pi-events.js";
import { SdkUiBridge } from "../src/sdk-ui-bridge.js";
import type { AskQuestion, ServerMessage } from "../src/types.js";

function makeState(sessionId = "session-1"): ExtensionUIState {
  return {
    session: { id: sessionId },
    pendingUIRequests: new Map(),
  };
}

function request(id: string, method: string): ExtensionUIRequest {
  return {
    type: "extension_ui_request",
    id,
    method,
    ...(method === "ask"
      ? {
          questions: [
            {
              id: "scope",
              question: "Choose scope",
              options: [{ value: "focused", label: "Focused" }],
            },
          ],
        }
      : {}),
  };
}

describe("extension UI request state lifecycle", () => {
  it("coalesces duplicate request state and rejects duplicate or stale responses", () => {
    const active = makeState();
    const broadcast = vi.fn();
    const duplicate = request("dialog-1", "confirm");

    handleExtensionUIRequest(active, duplicate, { broadcast });
    handleExtensionUIRequest(active, duplicate, { broadcast });

    expect(active.pendingUIRequests.size).toBe(1);
    expect(buildPendingExtensionUIRequestMessages(active)).toEqual([
      expect.objectContaining({ id: "dialog-1", method: "confirm", sessionId: "session-1" }),
    ]);

    const deliver = vi.fn(() => true);
    expect(
      respondToExtensionUIRequest(
        active,
        { type: "extension_ui_response", id: "dialog-1", confirmed: true },
        { deliver },
      ),
    ).toBe(true);
    expect(
      respondToExtensionUIRequest(
        active,
        { type: "extension_ui_response", id: "dialog-1", confirmed: true },
        { deliver },
      ),
    ).toBe(false);
    expect(
      respondToExtensionUIRequest(
        active,
        { type: "extension_ui_response", id: "stale-dialog", cancelled: true },
        { deliver },
      ),
    ).toBe(false);
    expect(deliver).toHaveBeenCalledTimes(1);
  });

  it("settles replayed requests after reconnect and acknowledges already-missing state", () => {
    const active = makeState();
    handleExtensionUIRequest(active, request("editor-1", "editor"), { broadcast: vi.fn() });

    expect(buildPendingExtensionUIRequestMessages(active)).toEqual([
      expect.objectContaining({ id: "editor-1", method: "editor", sessionId: "session-1" }),
    ]);

    const settled: ServerMessage[] = [];
    expect(
      settleExtensionUIRequest(active, "editor-1", {
        broadcastSettled: (message) => settled.push(message),
      }),
    ).toBe(true);
    expect(
      settleExtensionUIRequest(active, "editor-1", {
        broadcastIfMissing: true,
        broadcastSettled: (message) => settled.push(message),
      }),
    ).toBe(false);
    expect(settled).toEqual([
      { type: "extension_ui_settled", id: "editor-1", sessionId: "session-1" },
      { type: "extension_ui_settled", id: "editor-1", sessionId: "session-1" },
    ]);
  });

  it("tracks concurrent ask, editor, and dialog requests independently", () => {
    const active = makeState();
    const broadcast = vi.fn();
    handleExtensionUIRequest(active, request("ask-1", "ask"), { broadcast, now: () => 1_000 });
    handleExtensionUIRequest(active, request("editor-1", "editor"), { broadcast });
    handleExtensionUIRequest(active, request("confirm-1", "confirm"), { broadcast });

    expect(active.pendingUIRequests.size).toBe(3);
    expect(active.pendingAsk?.requestId).toBe("ask-1");

    expect(
      respondToExtensionUIRequest(
        active,
        { type: "extension_ui_response", id: "editor-1", value: "edited" },
        { deliver: () => true },
      ),
    ).toBe(true);
    expect(active.pendingAsk?.requestId).toBe("ask-1");
    expect(active.pendingUIRequests.has("confirm-1")).toBe(true);

    expect(
      respondToExtensionUIRequest(
        active,
        { type: "extension_ui_response", id: "confirm-1", confirmed: true },
        { deliver: () => true },
      ),
    ).toBe(true);
    expect(active.pendingAsk?.requestId).toBe("ask-1");

    expect(
      respondToExtensionUIRequest(
        active,
        {
          type: "extension_ui_response",
          id: "ask-1",
          value: JSON.stringify({ scope: "focused" }),
        },
        { deliver: () => true },
      ),
    ).toBe(true);
    expect(active.pendingAsk).toBeUndefined();
    expect(active.pendingUIRequests.size).toBe(0);
  });
});

describe("SDK UI bridge lifecycle", () => {
  it("settles concurrent ask, editor, and dialog promises by request id", async () => {
    const events: SessionBackendEvent[] = [];
    const bridge = new SdkUiBridge(
      (event) => events.push(event),
      () => false,
    );
    const ui = bridge.createContext();
    const questions: AskQuestion[] = [
      {
        id: "scope",
        question: "Choose scope",
        options: [{ value: "focused", label: "Focused" }],
      },
    ];

    const askPromise = ui.ask(questions, false);
    const editorPromise = ui.editor("Edit", "draft");
    const confirmPromise = ui.confirm("Proceed?", "Run now");
    const pending = events.filter(
      (event): event is Extract<SessionBackendEvent, { type: "extension_ui_request" }> =>
        event.type === "extension_ui_request",
    );
    const idFor = (method: string): string => {
      const id = pending.find((event) => event.method === method)?.id;
      if (!id) throw new Error(`Missing ${method} request`);
      return id;
    };

    expect(bridge.respond({ id: idFor("confirm"), confirmed: true })).toBe(true);
    expect(bridge.respond({ id: idFor("ask"), value: JSON.stringify({ scope: "focused" }) })).toBe(
      true,
    );
    expect(bridge.respond({ id: idFor("editor"), value: "revised" })).toBe(true);

    await expect(confirmPromise).resolves.toBe(true);
    await expect(askPromise).resolves.toEqual({
      answers: { scope: "focused" },
      allIgnored: false,
    });
    await expect(editorPromise).resolves.toBe("revised");
    expect(bridge.respond({ id: idFor("editor"), value: "late" })).toBe(false);
    expect(
      events
        .filter((event) => event.type === "extension_ui_request_settled")
        .map((event) => event.id),
    ).toEqual([idFor("confirm"), idFor("ask"), idFor("editor")]);
  });

  it("ignores late responses after the bridge is replaced", async () => {
    const oldEvents: SessionBackendEvent[] = [];
    const oldBridge = new SdkUiBridge(
      (event) => oldEvents.push(event),
      () => false,
    );
    const oldPromise = oldBridge.createContext().input("Old input", "old");
    const oldId = oldEvents.find((event) => event.type === "extension_ui_request")?.id;
    if (!oldId) throw new Error("Missing old request");

    oldBridge.dispose();
    await expect(oldPromise).resolves.toBeUndefined();

    const newEvents: SessionBackendEvent[] = [];
    const newBridge = new SdkUiBridge(
      (event) => newEvents.push(event),
      () => false,
    );
    const newPromise = newBridge.createContext().input("New input", "new");
    const newId = newEvents.find((event) => event.type === "extension_ui_request")?.id;
    if (!newId) throw new Error("Missing replacement request");

    expect(oldBridge.respond({ id: oldId, value: "late old value" })).toBe(false);
    expect(newBridge.respond({ id: oldId, value: "late old value" })).toBe(false);
    expect(newBridge.respond({ id: newId, value: "current value" })).toBe(true);
    await expect(newPromise).resolves.toBe("current value");
  });
});

describe("extension UI semantic metadata", () => {
  const nativeSurface = {
    version: 1,
    id: "extension-surface",
    source: "widget",
    presentation: { style: "surfacePanel" },
    blocks: [
      {
        type: "text",
        spans: [
          {
            text: "Forward-compatible semantics",
            role: "future-emphasis",
            traits: ["future-trait"],
          },
        ],
      },
      {
        type: "activityList",
        rows: [{ id: "row-1", title: "Work", state: "future-state" }],
      },
    ],
  };

  it("preserves bounded unknown semantic strings for forward-compatible clients", () => {
    const message = buildExtensionUINotificationMessage({
      id: "widget-1",
      method: "setWidget",
      widgetKey: "surface",
      nativeSurface,
    });

    expect(message.nativeSurface).toMatchObject({
      id: "widget:surface",
      blocks: [
        {
          type: "text",
          spans: [{ role: "future-emphasis", traits: ["future-trait"] }],
        },
        {
          type: "activityList",
          rows: [{ state: "future-state" }],
        },
      ],
    });
  });

  type MutableSemanticSurface = {
    blocks: Array<{
      spans?: Array<{ role?: unknown; traits?: unknown }>;
      rows?: Array<{ state?: unknown }>;
    }>;
  };

  it.each([
    {
      label: "role",
      mutate: (surface: MutableSemanticSurface) => {
        const span = surface.blocks[0]?.spans?.[0];
        if (span) span.role = 7;
      },
    },
    {
      label: "trait",
      mutate: (surface: MutableSemanticSurface) => {
        const span = surface.blocks[0]?.spans?.[0];
        if (span) span.traits = [false];
      },
    },
    {
      label: "activity state",
      mutate: (surface: MutableSemanticSurface) => {
        const row = surface.blocks[1]?.rows?.[0];
        if (row) row.state = {};
      },
    },
  ])("drops a native surface with malformed $label metadata", ({ mutate }) => {
    const malformed = structuredClone(nativeSurface) as unknown as MutableSemanticSurface;
    mutate(malformed);

    const message = buildExtensionUINotificationMessage({
      id: "widget-1",
      method: "setWidget",
      widgetKey: "surface",
      nativeSurface: malformed,
    });

    expect(message.nativeSurface).toBeUndefined();
  });
});

import { describe, expect, it, vi } from "vitest";
import type { SessionEntry } from "@earendil-works/pi-coding-agent";

import type { SessionBackendEvent } from "../src/pi-events.js";
import {
  SessionAgentEventCoordinator,
  type SessionAgentEventState,
} from "../src/session-agent-events.js";
import { TurnDedupeCache } from "../src/turn-cache.js";
import type { Session } from "../src/types.js";
import type { CanonicalSessionTree } from "../src/canonical-message.js";
import type { PiMessage } from "../src/pi-events.js";

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

function makeActiveSession(
  tree?: CanonicalSessionTree,
  overrides?: Partial<Session>,
): SessionAgentEventState {
  return {
    session: makeSession(overrides),
    pendingUIRequests: new Map(),
    persistentExtensionUINotifications: new Map(),
    partialResults: new Map(),
    streamedAssistantText: "",
    toolNames: new Map(),
    toolArgs: new Map(),
    shellPreviewLastSent: new Map(),
    streamingToolUpdatesSeen: new Map<string, string>(),
    turnCache: new TurnDedupeCache(),
    pendingTurnStarts: [],
    sdkBackend: tree
      ? ({
          session: { sessionManager: tree },
        } as SessionAgentEventState["sdkBackend"])
      : ({} as SessionAgentEventState["sdkBackend"]),
    subscribers: new Set<(msg: unknown) => void>(),
    toolFullOutputPaths: new Map<string, string>(),
    cacheMissTracker: {},
    showCacheMissNotices: false,
  };
}

function makeCoordinator(active: SessionAgentEventState) {
  const broadcast = vi.fn();
  const coordinator = new SessionAgentEventCoordinator({
    getActiveSession: vi.fn(() => active),
    eventProcessor: {
      translationContext: vi.fn(() => ({
        sessionId: active.session.id,
        partialResults: active.partialResults,
        streamedAssistantText: active.streamedAssistantText,
        currentThinkingContentIndex: active.currentThinkingContentIndex,
        mobileRenderers: {
          renderCall: vi.fn(),
          renderResult: vi.fn(),
        } as never,
        toolNames: active.toolNames,
        toolArgs: active.toolArgs,
        shellPreviewLastSent: active.shellPreviewLastSent,
        streamingToolUpdatesSeen: active.streamingToolUpdatesSeen,
      })),
      updateSessionFromEvent: vi.fn(),
    } as never,
    stopCoordinator: {
      finishPendingStopOnAgentEnd: vi.fn(),
    } as never,
    turnCoordinator: {
      markNextTurnStarted: vi.fn(),
    } as never,
    broadcast,
    resetIdleTimer: vi.fn(),
  });
  return { broadcast, coordinator };
}

function createMutableTree(initialLeafId: string | null = null) {
  const entries = new Map<string, SessionEntry>();
  let leafId = initialLeafId;
  const tree: CanonicalSessionTree & {
    appendMessage: (message: PiMessage, id?: string) => string;
  } = {
    getLeafId: () => leafId,
    getLeafEntry: () => (leafId ? entries.get(leafId) : undefined),
    getEntry: (id) => entries.get(id),
    getEntries: () => [...entries.values()],
    appendMessage(message, id = `entry-${entries.size + 1}`) {
      const entry: Extract<SessionEntry, { type: "message" }> = {
        type: "message",
        id,
        parentId: leafId,
        timestamp: new Date().toISOString(),
        message: message as Extract<SessionEntry, { type: "message" }>["message"],
      };
      entries.set(id, entry);
      leafId = id;
      return id;
    },
  };
  return tree;
}

const ASSISTANT_MESSAGE: PiMessage = {
  role: "assistant",
  content: [
    { type: "text", text: "Before" },
    { type: "thinking", thinking: "Check" },
    { type: "text", text: "After" },
  ],
};

function messageEndEvent(message: PiMessage): SessionBackendEvent {
  return { type: "message_end", message } as SessionBackendEvent;
}

function messageEnds(broadcast: ReturnType<typeof vi.fn>) {
  return broadcast.mock.calls
    .map(([, message]) => message)
    .filter((message) => message.type === "message_end");
}

describe("SessionAgentEventCoordinator canonical message_end", () => {
  it("broadcasts the appended entry ID after the post-append microtask", async () => {
    const tree = createMutableTree("root");
    const active = makeActiveSession(tree);
    const { broadcast, coordinator } = makeCoordinator(active);

    coordinator.handlePiEvent(active.session.id, messageEndEvent(ASSISTANT_MESSAGE));
    expect(messageEnds(broadcast)).toEqual([]);

    const entryId = tree.appendMessage(ASSISTANT_MESSAGE, "persisted-1");
    await Promise.resolve();

    expect(messageEnds(broadcast)).toEqual([
      {
        type: "message_end",
        role: "assistant",
        content: "Before\n\nAfter",
        entryId,
        assistantContent: [
          { kind: "text", content: "Before", contentIndex: 0, id: `${entryId}-text-0` },
          { kind: "thinking", content: "Check", contentIndex: 1, id: `${entryId}-think-1` },
          { kind: "text", content: "After", contentIndex: 2, id: `${entryId}-text-2` },
        ],
      },
    ]);
  });

  it("broadcasts enriched message_end before a synchronous internal event", async () => {
    const tree = createMutableTree("root");
    const active = makeActiveSession(tree);
    const { broadcast, coordinator } = makeCoordinator(active);

    coordinator.handlePiEvent(active.session.id, messageEndEvent(ASSISTANT_MESSAGE));
    tree.appendMessage(ASSISTANT_MESSAGE, "persisted-2");
    coordinator.handlePiEvent(active.session.id, {
      type: "auto_retry_end",
      success: true,
      attempt: 1,
    } as SessionBackendEvent);

    const types = broadcast.mock.calls.map(([, message]) => message.type);
    expect(types[0]).toBe("message_end");
    expect(messageEnds(broadcast)[0]?.entryId).toBe("persisted-2");
    await Promise.resolve();
    expect(messageEnds(broadcast)).toHaveLength(1);
  });

  it("resolves immediately when the leaf is already the persisted message", () => {
    const tree = createMutableTree("root");
    const entryId = tree.appendMessage(ASSISTANT_MESSAGE, "already-there");
    const active = makeActiveSession(tree);
    const { broadcast, coordinator } = makeCoordinator(active);

    coordinator.handlePiEvent(active.session.id, messageEndEvent(ASSISTANT_MESSAGE));

    expect(messageEnds(broadcast)[0]?.entryId).toBe(entryId);
  });

  it("gives two equal assistant messages different canonical IDs", async () => {
    const tree = createMutableTree("root");
    const active = makeActiveSession(tree);
    const { broadcast, coordinator } = makeCoordinator(active);
    const first = { role: "assistant" as const, content: "same text" };
    const second = { role: "assistant" as const, content: "same text" };

    coordinator.handlePiEvent(active.session.id, messageEndEvent(first));
    const firstId = tree.appendMessage(first, "same-a");
    await Promise.resolve();

    coordinator.handlePiEvent(active.session.id, messageEndEvent(second));
    const secondId = tree.appendMessage(second, "same-b");
    await Promise.resolve();

    expect(messageEnds(broadcast).map((message) => message.entryId)).toEqual([firstId, secondId]);
    expect(messageEnds(broadcast).map((message) => message.assistantContent?.[0]?.id)).toEqual([
      firstId,
      secondId,
    ]);
  });

  it("does not attach an unrelated ID when no child entry exists", async () => {
    const tree = createMutableTree("root");
    tree.appendMessage({ role: "user", content: "unrelated" }, "user-1");
    const active = makeActiveSession(tree);
    const { broadcast, coordinator } = makeCoordinator(active);

    coordinator.handlePiEvent(active.session.id, messageEndEvent(ASSISTANT_MESSAGE));
    await Promise.resolve();

    const ends = messageEnds(broadcast);
    expect(ends).toHaveLength(1);
    expect(ends[0]?.entryId).toBeUndefined();
    expect(ends[0]?.assistantContent?.every((part) => part.id === undefined)).toBe(true);
  });

  it("skips canonical resolution for non-user/assistant message_end roles", async () => {
    const tree = createMutableTree("root");
    const getEntries = vi.fn(() => tree.getEntries?.() ?? []);
    tree.getEntries = getEntries;
    const active = makeActiveSession(tree);
    const { broadcast, coordinator } = makeCoordinator(active);

    coordinator.handlePiEvent(
      active.session.id,
      messageEndEvent({ role: "custom", content: "lifecycle" } as PiMessage),
    );
    await Promise.resolve();

    expect(messageEnds(broadcast)).toEqual([]);
    expect(getEntries).not.toHaveBeenCalled();
  });

  it("keeps the un-enriched compatibility frame when no session tree exists", () => {
    const active = makeActiveSession();
    const { broadcast, coordinator } = makeCoordinator(active);

    coordinator.handlePiEvent(active.session.id, messageEndEvent(ASSISTANT_MESSAGE));

    expect(messageEnds(broadcast)).toEqual([
      {
        type: "message_end",
        role: "assistant",
        content: "Before\n\nAfter",
        assistantContent: [
          { kind: "text", content: "Before", contentIndex: 0 },
          { kind: "thinking", content: "Check", contentIndex: 1 },
          { kind: "text", content: "After", contentIndex: 2 },
        ],
      },
    ]);
  });
});

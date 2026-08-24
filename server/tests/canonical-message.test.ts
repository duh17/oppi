import { describe, expect, it } from "vitest";
import type { SessionEntry } from "@earendil-works/pi-coding-agent";

import {
  canonicalAssistantBlockId,
  isMatchingPersistedMessage,
  renderableCanonicalBlockIds,
  resolvePersistedMessageEntry,
  resolvePersistedMessageEntrySlow,
  type CanonicalSessionTree,
} from "../src/canonical-message.js";
import { projectAssistantMessageContent } from "../src/session-protocol.js";
import { collectAssistantTraceIds } from "../src/trace.js";
import type { PiMessage } from "../src/pi-events.js";

const MIXED_ASSISTANT: PiMessage = {
  role: "assistant",
  content: [
    { type: "text", text: "Before" },
    { type: "thinking", thinking: "Check" },
    { type: "toolCall", id: "tool-1", name: "read", arguments: {} },
    { type: "text", text: "After" },
  ],
};

function messageEntry(
  id: string,
  message: PiMessage,
  parentId: string | null = null,
): Extract<SessionEntry, { type: "message" }> {
  return {
    type: "message",
    id,
    parentId,
    timestamp: "2026-01-01T00:00:00.000Z",
    message: message as Extract<SessionEntry, { type: "message" }>["message"],
  };
}

function createTree(entries: SessionEntry[], leafId: string | null): CanonicalSessionTree {
  const byId = new Map(entries.map((entry) => [entry.id, entry]));
  return {
    getLeafId: () => leafId,
    getLeafEntry: () => (leafId ? byId.get(leafId) : undefined),
    getEntry: (id) => byId.get(id),
    getEntries: () => [...entries],
  };
}

describe("canonical assistant block IDs", () => {
  it("matches the persisted-content identity table", () => {
    expect(
      canonicalAssistantBlockId({
        entryId: "e1",
        kind: "text",
        contentIndex: 0,
        stringContent: true,
      }),
    ).toBe("e1");
    expect(
      canonicalAssistantBlockId({ entryId: "e1", kind: "text", contentIndex: 2 }),
    ).toBe("e1-text-2");
    expect(
      canonicalAssistantBlockId({ entryId: "e1", kind: "thinking", contentIndex: 1 }),
    ).toBe("e1-think-1");
    expect(
      canonicalAssistantBlockId({
        entryId: "e1",
        kind: "tool",
        contentIndex: 3,
        toolCallId: "call-9",
      }),
    ).toBe("call-9");
    expect(
      canonicalAssistantBlockId({ entryId: "e1", kind: "tool", contentIndex: 3 }),
    ).toBe("e1-tool-3");
    expect(
      canonicalAssistantBlockId({ entryId: "e1", kind: "boundary", contentIndex: 4 }),
    ).toBeUndefined();
  });

  it("gives live assistantContent the same ordered IDs as trace", () => {
    const entry = messageEntry("entry-mixed", MIXED_ASSISTANT);
    const liveIds = renderableCanonicalBlockIds(
      projectAssistantMessageContent(entry.message, { entryId: entry.id }),
    );
    expect(liveIds).toEqual(collectAssistantTraceIds(entry));
    expect(liveIds).toEqual(["entry-mixed-text-0", "entry-mixed-think-1", "tool-1", "entry-mixed-text-3"]);
  });

  it("uses the entry id for string assistant content in both paths", () => {
    const entry = messageEntry("entry-string", {
      role: "assistant",
      content: "plain",
    });
    const liveIds = renderableCanonicalBlockIds(
      projectAssistantMessageContent(entry.message, { entryId: entry.id }),
    );
    expect(liveIds).toEqual(collectAssistantTraceIds(entry));
    expect(liveIds).toEqual(["entry-string"]);
  });

  it("omits empty thinking from both live and trace ID lists", () => {
    const entry = messageEntry("entry-empty-think", {
      role: "assistant",
      content: [
        { type: "text", text: "Before" },
        { type: "thinking", thinking: "" },
        { type: "text", text: "After" },
      ],
    });
    const liveIds = renderableCanonicalBlockIds(
      projectAssistantMessageContent(entry.message, { entryId: entry.id }),
    );
    expect(liveIds).toEqual(collectAssistantTraceIds(entry));
    expect(liveIds).toEqual(["entry-empty-think-text-0", "entry-empty-think-text-2"]);
  });

  it("keeps identical text under different entry IDs", () => {
    const first = messageEntry("e-a", { role: "assistant", content: "same" });
    const second = messageEntry("e-b", { role: "assistant", content: "same" });
    expect(projectAssistantMessageContent(first.message, { entryId: first.id })[0]?.id).toBe("e-a");
    expect(projectAssistantMessageContent(second.message, { entryId: second.id })[0]?.id).toBe("e-b");
    expect(collectAssistantTraceIds(first)).not.toEqual(collectAssistantTraceIds(second));
  });
});

describe("persisted message resolution", () => {
  it("accepts a leaf that is already the persisted message", () => {
    const entry = messageEntry("leaf-1", MIXED_ASSISTANT, "root");
    const tree = createTree([entry], entry.id);
    const resolved = resolvePersistedMessageEntry(tree, {
      preAppendLeafId: "root",
      event: { type: "message_end", message: MIXED_ASSISTANT },
    });
    expect(resolved?.id).toBe("leaf-1");
  });

  it("skips intervening custom entries on the parent walk", () => {
    const custom: SessionEntry = {
      type: "custom",
      id: "custom-1",
      parentId: "root",
      timestamp: "2026-01-01T00:00:00.000Z",
      customType: "oppi-lifecycle",
    };
    const entry = messageEntry("leaf-2", MIXED_ASSISTANT, "custom-1");
    const tree = createTree([custom, entry], entry.id);
    const resolved = resolvePersistedMessageEntry(tree, {
      preAppendLeafId: "root",
      event: { type: "message_end", message: MIXED_ASSISTANT },
    });
    expect(resolved?.id).toBe("leaf-2");
  });

  it("does not guess when the captured leaf is not an ancestor", () => {
    const other = messageEntry(
      "other",
      {
        role: "assistant",
        content: [...(MIXED_ASSISTANT.content as unknown[])],
      },
      "branch-a",
    );
    const tree = createTree([other], other.id);
    expect(
      resolvePersistedMessageEntry(tree, {
        preAppendLeafId: "branch-b",
        event: { type: "message_end", message: MIXED_ASSISTANT },
      }),
    ).toBeNull();
  });

  it("does not attach an unrelated role even when text matches", () => {
    const user = messageEntry("user-1", { role: "user", content: "same" }, "root");
    const tree = createTree([user], user.id);
    expect(
      isMatchingPersistedMessage(user, { role: "assistant", content: "same" }),
    ).toBe(false);
    expect(
      resolvePersistedMessageEntry(tree, {
        preAppendLeafId: "root",
        event: { type: "message_end", message: { role: "assistant", content: "same" } },
      }),
    ).toBeNull();
  });

  it("slow path only returns a unique child of the captured leaf", () => {
    const first = messageEntry("a", MIXED_ASSISTANT, "root");
    const second = messageEntry("b", MIXED_ASSISTANT, "root");
    const tree = createTree([first, second], second.id);
    expect(
      resolvePersistedMessageEntrySlow(tree, {
        preAppendLeafId: "root",
        event: { type: "message_end", message: MIXED_ASSISTANT },
      }),
    ).toBeNull();
    expect(
      resolvePersistedMessageEntrySlow(createTree([first], first.id), {
        preAppendLeafId: "root",
        event: { type: "message_end", message: MIXED_ASSISTANT },
      })?.id,
    ).toBe("a");
  });
});

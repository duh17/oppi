import { describe, expect, it, vi } from "vitest";

import { createMirrorCanonicalFlush } from "./canonical-message-flush.ts";
import type { MirrorSessionEntry, MirrorSessionTree } from "./canonical-message.ts";

function createTree(initialLeafId: string | null = null) {
  const entries = new Map<string, MirrorSessionEntry>();
  let leafId = initialLeafId;
  const tree: MirrorSessionTree & {
    appendMessage: (message: { role: string; content: unknown }, id?: string) => string;
    appendCustom: (id: string) => void;
  } = {
    getLeafId: () => leafId,
    getLeafEntry: () => (leafId ? entries.get(leafId) : undefined),
    getEntry: (id) => entries.get(id),
    appendMessage(message, id = `entry-${entries.size + 1}`) {
      const entry: MirrorSessionEntry = {
        type: "message",
        id,
        parentId: leafId,
        message,
      };
      entries.set(id, entry);
      leafId = id;
      return id;
    },
    appendCustom(id) {
      entries.set(id, { type: "custom", id, parentId: leafId });
      leafId = id;
    },
  };
  return tree;
}

describe("mirror canonical next-event barrier", () => {
  it("emits enriched message_end before turn_end", () => {
    const tree = createTree("root");
    const sent: unknown[] = [];
    const flush = createMirrorCanonicalFlush();
    const callback = { content: "callback text", role: "assistant" };
    const persisted = { content: "persisted text", role: "assistant" };

    flush.captureMessageEnd({ type: "message_end", message: callback }, tree);
    const entryId = tree.appendMessage(persisted, "persisted-1");

    const pending = flush.flush(tree);
    if (pending) sent.push(pending.event);
    sent.push({ type: "turn_end" });

    expect(sent).toEqual([
      {
        type: "message_end",
        message: persisted,
        entryId,
      },
      { type: "turn_end" },
    ]);
  });

  it("keeps a pending message when the leaf has not advanced", () => {
    const tree = createTree("root");
    const flush = createMirrorCanonicalFlush();
    flush.captureMessageEnd(
      { type: "message_end", message: { role: "assistant", content: "hello" } },
      tree,
    );
    expect(flush.flush(tree)).toBeNull();
    expect(flush.hasPending()).toBe(true);
  });

  it("emits enriched message_end before auto_retry_end", () => {
    const tree = createTree("root");
    const sent: unknown[] = [];
    const flush = createMirrorCanonicalFlush();
    const message = { role: "assistant", content: "done" };

    flush.captureMessageEnd({ type: "message_end", message }, tree);
    const entryId = tree.appendMessage(message, "retry-msg");

    const pending = flush.flush(tree);
    if (pending) sent.push(pending.event);
    sent.push({ type: "auto_retry_end", success: true, attempt: 1 });

    expect(sent).toEqual([
      {
        type: "message_end",
        message,
        entryId,
      },
      { type: "auto_retry_end", success: true, attempt: 1 },
    ]);
  });

  it("resolves a tool-calling assistant message before tool_execution_start", () => {
    const tree = createTree("root");
    const flush = createMirrorCanonicalFlush();
    const message = {
      role: "assistant",
      content: [{ type: "toolCall", id: "call-1", name: "bash", arguments: {} }],
    };

    flush.captureMessageEnd({ type: "message_end", message }, tree);
    tree.appendMessage(message, "tool-msg");
    const pending = flush.flush(tree);

    expect(pending?.guessed).toBe(false);
    expect(pending && "entryId" in pending.event ? pending.event.entryId : undefined).toBe(
      "tool-msg",
    );
    expect(
      pending && "message" in pending.event
        ? (pending.event.message as { content: unknown }).content
        : undefined,
    ).toEqual(message.content);
  });

  it("projects persisted content when a later extension replaced the callback", () => {
    const tree = createTree("root");
    const flush = createMirrorCanonicalFlush();
    flush.captureMessageEnd(
      { type: "message_end", message: { role: "assistant", content: "callback" } },
      tree,
    );
    tree.appendMessage({ role: "assistant", content: "persisted wins" }, "e1");
    const pending = flush.flush(tree);
    expect(pending && "message" in pending.event ? pending.event.message : undefined).toEqual({
      role: "assistant",
      content: "persisted wins",
    });
    expect(pending && "entryId" in pending.event ? pending.event.entryId : undefined).toBe("e1");
  });

  it("does not attach a guessed ID when the captured leaf is not an ancestor", () => {
    const tree = createTree("root");
    const onUnresolved = vi.fn();
    const flush = createMirrorCanonicalFlush(onUnresolved);
    flush.captureMessageEnd(
      { type: "message_end", message: { role: "assistant", content: "hello" } },
      tree,
    );
    tree.appendMessage({ role: "assistant", content: "hello" }, "other-branch");
    // Simulate a branch switch: leaf parent is not the captured root... wait,
    // appendMessage parents to current leaf. Force a disconnected leaf instead.
    const disconnected = createTree("unrelated");
    disconnected.appendMessage({ role: "assistant", content: "hello" }, "guess");
    const pending = flush.flush(disconnected);
    expect(pending?.guessed).toBe(true);
    expect(
      pending && typeof pending.event === "object" && pending.event && "entryId" in pending.event
        ? pending.event.entryId
        : undefined,
    ).toBeUndefined();
    expect(onUnresolved).toHaveBeenCalledWith({
      expectedRole: "assistant",
      capturedLeaf: "root",
      observedLeaf: "guess",
    });
  });
});

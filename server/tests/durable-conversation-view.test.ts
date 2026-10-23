import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { diffRevisions } from "@earendil-works/chord/delta";
import type { JsonObject } from "@earendil-works/chord";
import type { EntryRecord } from "@earendil-works/pi-durable";

import {
  CONVERSATION_CLIENT_DOCS,
  projectEntry,
  type DocPresenter,
  type ToolPresenter,
} from "../src/durable-conversation-view.js";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";

const PNG_1X1 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";

const tools: ToolPresenter = {
  call: () => ({}),
  committedCall: () => undefined,
};

function userEntry(content: unknown[], id = 8): EntryRecord {
  return {
    id,
    conversationId: 3,
    kind: "pi.user",
    model: [{ role: "user", content, timestamp: 1_791_650_000_000 } as never],
  };
}

/** The projected content blocks of the entry's first model message. */
function projectedBlocks(entry: EntryRecord, dataDir: string) {
  const view = projectEntry(
    entry,
    new MobileRendererRegistry(),
    tools,
    {},
    {
      dataDir,
      sessionId: "s-view",
    },
  );
  const content = view.model?.[0]?.content;
  if (!Array.isArray(content)) throw new Error("expected content blocks");
  return content as Array<Record<string, unknown>>;
}

describe("conversation entry view: user message images", () => {
  let dataDir: string;

  beforeEach(() => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-conversation-view-"));
  });
  afterEach(() => {
    rmSync(dataDir, { recursive: true, force: true });
  });

  it("sends a stored image reference instead of its bytes", () => {
    const blocks = projectedBlocks(
      userEntry([
        { type: "text", text: "look at this" },
        { type: "image", data: PNG_1X1, mimeType: "image/png" },
      ]),
      dataDir,
    );

    expect(blocks).toHaveLength(2);
    expect(blocks[0]).toEqual({ type: "text", text: "look at this" });
    expect(blocks[1]).not.toHaveProperty("data");
    expect(blocks[1]?.type).toBe("image");
    expect(blocks[1]?.mimeType).toBe("image/png");
    expect(blocks[1]?.attachment).toMatchObject({
      kind: "image",
      mimeType: "image/png",
      sessionId: "s-view",
      fileName: "user-image.png",
      width: 1,
      height: 1,
    });
    expect(String((blocks[1]?.attachment as { id: string }).id)).toMatch(/^att_user_/);

    // The bytes are in the session attachment store, under this session.
    const manifest = JSON.parse(
      readFileSync(join(dataDir, "session-attachments", "s-view", "manifest.json"), "utf8"),
    ) as { attachments: Array<{ id: string }> };
    expect(manifest.attachments).toHaveLength(1);
    expect(manifest.attachments[0]?.id).toBe((blocks[1]?.attachment as { id: string }).id);
  });

  it("keeps the inline data URI for an image it cannot store", () => {
    const blocks = projectedBlocks(
      userEntry([{ type: "image", data: "not base64!", mimeType: "image/png" }]),
      dataDir,
    );

    expect(blocks[0]).toEqual({ type: "image", data: "not base64!", mimeType: "image/png" });
  });

  it("keeps block order when a message mixes a stored image and an inline fallback", () => {
    const blocks = projectedBlocks(
      userEntry([
        { type: "image", data: "not base64!", mimeType: "image/jpeg" },
        { type: "image", data: PNG_1X1, mimeType: "image/png" },
      ]),
      dataDir,
    );

    // The unstorable block keeps its bytes and its place; the stored one is a reference.
    expect(blocks[0]).toEqual({ type: "image", data: "not base64!", mimeType: "image/jpeg" });
    expect(blocks[1]).not.toHaveProperty("data");
    expect(String((blocks[1]?.attachment as { id: string }).id)).toMatch(/^att_user_/);
  });

  it("leaves images inline when projection has no attachment scope", () => {
    const view = projectEntry(
      userEntry([{ type: "image", data: PNG_1X1, mimeType: "image/png" }]),
      new MobileRendererRegistry(),
      tools,
    );
    const content = view.model?.[0]?.content as Array<Record<string, unknown>>;

    expect(content[0]).toEqual({ type: "image", data: PNG_1X1, mimeType: "image/png" });
  });

  it("stores the same image once across projections", () => {
    const entry = userEntry([{ type: "image", data: PNG_1X1, mimeType: "image/png" }]);
    const first = projectedBlocks(entry, dataDir)[0]?.attachment as { id: string };
    const second = projectedBlocks(entry, dataDir)[0]?.attachment as { id: string };

    expect(second.id).toBe(first.id);
    const manifest = JSON.parse(
      readFileSync(join(dataDir, "session-attachments", "s-view", "manifest.json"), "utf8"),
    ) as { attachments: unknown[] };
    expect(manifest.attachments).toHaveLength(1);
  });
});

/** The projected content blocks of an assistant entry. */
function assistantBlocks(content: unknown[]): Array<Record<string, unknown>> {
  const entry: EntryRecord = {
    id: 9,
    conversationId: 3,
    kind: "pi.assistant",
    model: [{ role: "assistant", content, timestamp: 1_791_650_000_000 } as never],
  };
  const view = projectEntry(entry, new MobileRendererRegistry(), tools);
  const projected = view.model?.[0]?.content;
  if (!Array.isArray(projected)) throw new Error("expected content blocks");
  return projected as Array<Record<string, unknown>>;
}

describe("conversation entry view: tool call arguments", () => {
  it("resolves a falsy call's arguments from its partialJson and drops the raw text", () => {
    const [block] = assistantBlocks([
      {
        type: "toolCall",
        id: "call-1",
        name: "bash",
        arguments: "",
        partialJson: '{"command":"ls"}',
      },
    ]);

    expect(block).toEqual({
      type: "toolCall",
      id: "call-1",
      name: "bash",
      arguments: { command: "ls" },
    });
    expect(block).not.toHaveProperty("partialJson");
  });

  it("keeps a call's arguments as they are and drops its streamed text", () => {
    const [block] = assistantBlocks([
      {
        type: "toolCall",
        id: "call-2",
        name: "read",
        arguments: { path: "a.ts" },
        partialJson: '{"path":"a.ts"}',
      },
    ]);

    expect(block).toEqual({
      type: "toolCall",
      id: "call-2",
      name: "read",
      arguments: { path: "a.ts" },
    });
  });

  it("leaves a call without arguments when neither source is an object", () => {
    const [block] = assistantBlocks([
      { type: "toolCall", id: "call-3", name: "bash", partialJson: '{"comm' },
    ]);

    expect(block).toEqual({ type: "toolCall", id: "call-3", name: "bash" });
  });

  it("keeps text and thinking signatures on the server", () => {
    const blocks = assistantBlocks([
      { type: "thinking", thinking: "plan", signature: "c2ln" },
      { type: "text", text: "hi", signature: "c2ln" },
    ]);

    expect(blocks).toEqual([
      { type: "thinking", thinking: "plan" },
      { type: "text", text: "hi" },
    ]);
  });
});

describe("conversation live view", () => {
  const live = CONVERSATION_CLIENT_DOCS.find((spec) => spec.kind === "pi.live");
  if (!live) throw new Error("pi.live has no client projection");
  const presenter: DocPresenter = {
    call: () => ({}),
    committedCall: () => undefined,
    queuedInput: () => undefined,
  };
  const project = (value: object) => live.project(value as JsonObject, presenter);

  type Streaming = {
    generation: { message: { content: Array<Record<string, unknown>> } };
    [key: string]: unknown;
  };
  const blocksOf = (view: JsonObject) =>
    ((view as Streaming).generation.message.content as Array<Record<string, unknown>>) ?? [];
  /** A `pi.live` revision whose generation answers with `content`. */
  const revision = (content: Array<Record<string, unknown>>, tools?: unknown[]): object => ({
    run: { taskId: 7, inputs: [3] },
    generation: {
      attempt: 1,
      message: { role: "assistant", content, stopReason: "pending", timestamp: 1_791_650_003_000 },
    },
    ...(tools ? { tools } : {}),
  });

  it("projects the streaming message like an entry and resolves a call's arguments", () => {
    const view = project(
      revision([
        { type: "thinking", thinking: "plan", signature: "c2ln" },
        {
          type: "toolCall",
          id: "call-1",
          name: "bash",
          arguments: "",
          partialJson: '{"command":"ls"}',
        },
      ]),
    );

    const message = (view as Streaming).generation.message as Record<string, unknown>;
    expect(Object.keys(message).sort()).toEqual(["content", "role", "stopReason", "timestamp"]);
    expect(blocksOf(view)).toEqual([
      { type: "thinking", thinking: "plan" },
      { type: "toolCall", id: "call-1", name: "bash", arguments: { command: "ls" } },
    ]);
    expect(JSON.stringify(view)).not.toContain("partialJson");
    expect(JSON.stringify(view)).not.toContain("signature");
  });

  it("projects an unchanged block and generation to the identical object", () => {
    // What a pi-durable commit does: the unchanged paths are shared, the grown one is new.
    const thinking = { type: "thinking", thinking: "plan", signature: "c2ln" };
    const answer = (text: string) => revision([thinking, { type: "text", text }]);
    const first = project(answer("Hel"));
    const next = project(answer("Hello"));

    expect(blocksOf(next)[0]).toBe(blocksOf(first)[0]);
    expect(blocksOf(next)[1]).not.toBe(blocksOf(first)[1]);
    // The changed block is still an append, so a frame costs the new text.
    expect(diffRevisions(first, next)).toEqual([
      ["a", ["generation", "message", "content", 1, "text"], "lo"],
    ]);

    // Nothing under the generation changed: a tool-round update reuses it whole.
    const shared = {
      attempt: 1,
      message: { role: "assistant", content: [thinking], timestamp: 2 },
    };
    const withTools = project({
      generation: shared,
      tools: [{ callId: "a", name: "bash", status: "running" }],
    });
    const laterTools = project({
      generation: shared,
      tools: [{ callId: "a", name: "bash", status: "running", output: "x" }],
    });
    expect((laterTools as Streaming).generation).toBe((withTools as Streaming).generation);
  });
});

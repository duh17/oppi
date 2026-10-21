import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { EntryRecord } from "@earendil-works/pi-durable";

import { projectEntry, type ToolPresenter } from "../src/durable-conversation-view.js";
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

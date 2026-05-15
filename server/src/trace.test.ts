import { mkdtempSync, rmSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { getSessionAttachment, materializeToolMediaContentBlocks } from "./session-attachments.js";
import { parseJsonl } from "./trace.js";

describe("trace media replay", () => {
  const tempDirs: string[] = [];

  afterEach(() => {
    for (const dir of tempDirs.splice(0)) {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("does not replay update-only attachments when final toolResult has no media", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-trace-"));
    tempDirs.push(dataDir);
    const pngBase64 =
      "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAACZFr56AAAADElEQVR42mP8z8AARQAIMQH+6k9QbQAAAABJRU5ErkJggg==";

    materializeToolMediaContentBlocks({
      dataDir,
      sessionId: "session-1",
      toolCallId: "tool-1",
      contents: [
        {
          type: "image",
          data: pngBase64,
          mimeType: "image/png",
          fileName: "preview.png",
        },
      ],
    });

    const trace = parseJsonl(
      `${JSON.stringify({
        type: "message",
        id: "entry-1",
        timestamp: "2026-05-13T00:00:00.000Z",
        message: {
          role: "toolResult",
          toolCallId: "tool-1",
          toolName: "screenshot",
          content: "done",
        },
      })}\n`,
      { attachmentDataDir: dataDir, attachmentSessionId: "session-1" },
    );

    const toolResult = trace[0] as {
      type: string;
      output?: string;
      details?: { media?: unknown[] };
    };
    expect(toolResult.type).toBe("toolResult");
    expect(toolResult.output).toBe("done");
    expect(toolResult.details?.media).toBeUndefined();
  });

  it("replays final inline media from non-PNG session attachments with metadata", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-trace-"));
    tempDirs.push(dataDir);
    const icoBytes = makeICO(32, 16);
    const icoBase64 = icoBytes.toString("base64");

    const blocks = materializeToolMediaContentBlocks({
      dataDir,
      sessionId: "session-ico",
      toolCallId: "tool-ico",
      contents: [
        {
          type: "image",
          data: icoBase64,
          mimeType: "image/x-icon",
          fileName: "favicon.ico",
        },
      ],
    }) as Array<{ id: string }>;

    const trace = parseJsonl(
      `${JSON.stringify({
        type: "message",
        id: "entry-ico",
        timestamp: "2026-05-13T00:00:00.000Z",
        message: {
          role: "toolResult",
          toolCallId: "tool-ico",
          toolName: "screenshot",
          content: [
            { type: "text", text: "captured" },
            { type: "image", data: icoBase64, mimeType: "image/x-icon", fileName: "favicon.ico" },
          ],
        },
      })}\n`,
      { attachmentDataDir: dataDir, attachmentSessionId: "session-ico" },
    );

    const toolResult = trace[0] as {
      type: string;
      output?: string;
      details?: { media?: Array<{ id: string; mimeType: string; storageKey: string }> };
    };
    expect(toolResult.type).toBe("toolResult");
    expect(toolResult.output).toBe("captured");
    expect(toolResult.details?.media).toMatchObject([
      {
        kind: "image",
        id: blocks[0]!.id,
        mimeType: "image/x-icon",
        fileName: "favicon.ico",
        storageKey: expect.stringMatching(/\.ico$/),
        sizeBytes: icoBytes.length,
        width: 32,
        height: 16,
      },
    ]);
  });

  it("replays final inline media from session attachments without leaking base64", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-trace-"));
    tempDirs.push(dataDir);
    const pngBase64 =
      "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAACZFr56AAAADElEQVR42mP8z8AARQAIMQH+6k9QbQAAAABJRU5ErkJggg==";

    const pngBytes = Buffer.from(pngBase64, "base64");
    const blocks = materializeToolMediaContentBlocks({
      dataDir,
      sessionId: "session-2",
      toolCallId: "tool-2",
      contents: [
        {
          type: "image",
          data: pngBase64,
          mimeType: "image/png",
          fileName: "chart.png",
        },
      ],
    }) as Array<{ id: string }>;

    const trace = parseJsonl(
      `${JSON.stringify({
        type: "message",
        id: "entry-2",
        timestamp: "2026-05-13T00:00:00.000Z",
        message: {
          role: "toolResult",
          toolCallId: "tool-2",
          toolName: "screenshot",
          content: [
            { type: "text", text: "captured" },
            { type: "image", data: pngBase64, mimeType: "image/png", fileName: "chart.png" },
          ],
        },
      })}\n`,
      { attachmentDataDir: dataDir, attachmentSessionId: "session-2" },
    );

    const toolResult = trace[0] as {
      type: string;
      output?: string;
      details?: { media?: Array<{ id: string; mimeType: string }> };
    };
    expect(toolResult.type).toBe("toolResult");
    expect(toolResult.output).toBe("captured");
    expect(toolResult.details?.media).toMatchObject([
      {
        kind: "image",
        id: blocks[0]!.id,
        mimeType: "image/png",
        fileName: "chart.png",
        sizeBytes: pngBytes.length,
        width: 2,
        height: 3,
      },
    ]);

    const attachment = await getSessionAttachment(dataDir, "session-2", blocks[0]!.id);
    expect(attachment ? await readFile(attachment.path) : null).toEqual(pngBytes);
  });
});

function makeICO(width: number, height: number): Buffer {
  const bytes = Buffer.alloc(22);
  bytes.writeUInt16LE(0, 0);
  bytes.writeUInt16LE(1, 2);
  bytes.writeUInt16LE(1, 4);
  bytes[6] = width === 256 ? 0 : width;
  bytes[7] = height === 256 ? 0 : height;
  bytes[8] = 0;
  bytes[9] = 0;
  bytes.writeUInt16LE(1, 10);
  bytes.writeUInt16LE(32, 12);
  bytes.writeUInt32LE(0, 14);
  bytes.writeUInt32LE(22, 18);
  return bytes;
}

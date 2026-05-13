import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import {
  getSessionAttachment,
  materializeToolAudioDetails,
  materializeToolMediaContentBlocks,
  materializeToolMediaDetails,
  sessionAttachmentDetailsForToolCall,
  sessionAttachmentMediaDetailsForToolCall,
} from "./session-attachments.js";

let root: string;

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), "oppi-session-attachments-"));
});

afterEach(async () => {
  await rm(root, { recursive: true, force: true });
});

describe("session attachments", () => {
  it("materializes audio details from an explicitly trusted file path and sanitizes the result", async () => {
    const sourcePath = join(root, "source.wav");
    const bytes = Buffer.from("RIFFtest-audio");
    await writeFile(sourcePath, bytes);

    const details = materializeToolAudioDetails({
      dataDir: root,
      sessionId: "s1",
      toolCallId: "tool-1",
      details: {
        message: "hello",
        audio: {
          kind: "audio",
          mimeType: "audio/wav",
          path: sourcePath,
          fileName: "preview.wav",
          durationSeconds: 1.25,
        },
      },
      trustedSourceRoots: [root],
    }) as { audio: { id: string; storageKey: string; fileName: string; mimeType: string } };

    expect(details.audio.id).toContain("att_tool-1_");
    expect(details.audio.storageKey).toContain("s1/");
    expect(details.audio.fileName).toBe("preview.wav");
    expect(details.audio.mimeType).toBe("audio/wav");
    expect((details as { audio: { path?: string; base64?: string } }).audio.path).toBeUndefined();
    expect((details as { audio: { path?: string; base64?: string } }).audio.base64).toBeUndefined();

    const attachment = await getSessionAttachment(root, "s1", details.audio.id);
    expect(attachment?.record.text).toBe("hello");
    expect(attachment?.record.toolCallId).toBe("tool-1");
    expect(attachment?.record.durationSeconds).toBe(1.25);
    expect(attachment ? await readFile(attachment.path) : null).toEqual(bytes);
  });

  it("does not materialize audio attachments from arbitrary server paths", async () => {
    const sourcePath = join(root, "secret.wav");
    await writeFile(sourcePath, Buffer.from("RIFFsecret-audio"));

    const details = materializeToolAudioDetails({
      dataDir: root,
      sessionId: "s-audio-path",
      toolCallId: "tool-audio-path",
      details: {
        audio: {
          kind: "audio",
          mimeType: "audio/wav",
          path: sourcePath,
          fileName: "secret.wav",
        },
      },
    }) as { audio: { id?: string; path?: string; base64?: string } };

    expect(details.audio.id).toBeUndefined();
    expect(details.audio.path).toBeUndefined();
    expect(details.audio.base64).toBeUndefined();
    expect(
      sessionAttachmentMediaDetailsForToolCall(root, "s-audio-path", "tool-audio-path"),
    ).toEqual([]);
  });

  it("falls back to base64 audio bytes when an audio path is not trusted", async () => {
    const sourcePath = join(root, "ignored.wav");
    const bytes = Buffer.from("RIFFbase64-audio");
    await writeFile(sourcePath, Buffer.from("RIFFignored-audio"));

    const details = materializeToolAudioDetails({
      dataDir: root,
      sessionId: "s-audio-base64",
      toolCallId: "tool-audio-base64",
      details: {
        audio: {
          kind: "audio",
          mimeType: "audio/wav",
          path: sourcePath,
          base64: bytes.toString("base64"),
          fileName: "reply.wav",
        },
      },
    }) as { audio: { id: string; path?: string; base64?: string } };

    expect(details.audio.id).toContain("att_tool-audio-base64_");
    expect(details.audio.path).toBeUndefined();
    expect(details.audio.base64).toBeUndefined();

    const attachment = await getSessionAttachment(root, "s-audio-base64", details.audio.id);
    expect(attachment ? await readFile(attachment.path) : null).toEqual(bytes);
  });

  it("replays sanitized attachment details from the manifest", () => {
    const materialized = materializeToolAudioDetails({
      dataDir: root,
      sessionId: "s2",
      toolCallId: "tool-2",
      details: {
        message: "preview",
        audio: {
          kind: "audio",
          mimeType: "audio/wav",
          base64: Buffer.from("wav-data").toString("base64"),
          fileName: "voice.wav",
        },
      },
    });

    const replayed = sessionAttachmentDetailsForToolCall(root, "s2", "tool-2", {
      message: "preview",
      audio: {
        kind: "audio",
        mimeType: "audio/wav",
        base64: "should-not-leak",
      },
    }) as { audio: { id: string; storageKey: string; base64?: string; path?: string } };

    expect((materialized as { audio: { id: string } }).audio.id).toBe(replayed.audio.id);
    expect(replayed.audio.storageKey).toContain("s2/");
    expect(replayed.audio.base64).toBeUndefined();
    expect(replayed.audio.path).toBeUndefined();
  });

  it("materializes image content blocks and exposes dimensions", async () => {
    const png = Buffer.from(
      "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAACZFr56AAAADElEQVR42mP8z8AARQAIMQH+6k9QbQAAAABJRU5ErkJggg==",
      "base64",
    );

    const blocks = materializeToolMediaContentBlocks({
      dataDir: root,
      sessionId: "s-img",
      toolCallId: "tool-img",
      contents: [
        {
          type: "image",
          data: png.toString("base64"),
          mimeType: "image/png",
          fileName: "preview.png",
        },
      ],
    }) as Array<{ id: string; data?: string; kind: string; width?: number; height?: number }>;

    expect(blocks[0]?.id).toContain("att_tool-img_");
    expect(blocks[0]?.data).toBeUndefined();
    expect(blocks[0]?.kind).toBe("image");
    expect(blocks[0]?.width).toBe(2);
    expect(blocks[0]?.height).toBe(3);

    const media = sessionAttachmentMediaDetailsForToolCall(root, "s-img", "tool-img");
    expect(media).toHaveLength(1);
    expect(media[0]?.kind).toBe("image");
    expect(media[0]?.width).toBe(2);

    const attachment = await getSessionAttachment(root, "s-img", blocks[0]!.id);
    expect(attachment ? await readFile(attachment.path) : null).toEqual(png);
  });

  it("preserves image base64 when materializing details for collapsed previews", () => {
    const pngBase64 =
      "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAACZFr56AAAADElEQVR42mP8z8AARQAIMQH+6k9QbQAAAABJRU5ErkJggg==";

    const details = materializeToolMediaDetails({
      dataDir: root,
      sessionId: "s-img-preview",
      toolCallId: "tool-img-preview",
      details: {
        image: {
          kind: "image",
          mimeType: "image/png",
          base64: pngBase64,
          fileName: "preview.png",
        },
      },
    }) as { image: { id?: string; base64?: string; path?: string } };

    expect(details.image.id).toContain("att_tool-img-preview_");
    expect(details.image.base64).toBe(pngBase64);
    expect(details.image.path).toBeUndefined();
  });

  it("replays image details with the matching attachment and preserved base64", () => {
    const firstBase64 =
      "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAACZFr56AAAADElEQVR42mP8z8AARQAIMQH+6k9QbQAAAABJRU5ErkJggg==";
    const secondBase64 =
      "iVBORw0KGgoAAAANSUhEUgAAAAMAAAAECAYAAACAcVaiAAAAFUlEQVR42mP8z/CfAQgwgImBQQAA5JwCCg6MUi0AAAAASUVORK5CYII=";

    materializeToolMediaDetails({
      dataDir: root,
      sessionId: "s-img-replay",
      toolCallId: "tool-img-replay",
      details: {
        image: {
          kind: "image",
          mimeType: "image/png",
          base64: firstBase64,
          fileName: "first.png",
        },
      },
    });
    materializeToolMediaDetails({
      dataDir: root,
      sessionId: "s-img-replay",
      toolCallId: "tool-img-replay",
      details: {
        image: {
          kind: "image",
          mimeType: "image/png",
          base64: secondBase64,
          fileName: "second.png",
        },
      },
    });

    const replayed = sessionAttachmentDetailsForToolCall(root, "s-img-replay", "tool-img-replay", {
      image: {
        kind: "image",
        mimeType: "image/png",
        base64: secondBase64,
        fileName: "second.png",
      },
    }) as { image: { id?: string; fileName?: string; base64?: string } };

    const expected = materializeToolMediaDetails({
      dataDir: root,
      sessionId: "s-img-replay-expected",
      toolCallId: "tool-img-replay",
      details: {
        image: {
          kind: "image",
          mimeType: "image/png",
          base64: secondBase64,
          fileName: "second.png",
        },
      },
    }) as { image: { id?: string } };

    expect(replayed.image.id).toBe(expected.image.id);
    expect(replayed.image.fileName).toBe("second.png");
    expect(replayed.image.base64).toBe(secondBase64);
  });

  it("does not materialize image attachments from arbitrary server paths", async () => {
    const outsidePath = join(root, "outside.png");
    await writeFile(outsidePath, Buffer.from("not actually a png"));

    const details = materializeToolMediaDetails({
      dataDir: root,
      sessionId: "s-path",
      toolCallId: "tool-path",
      details: {
        image: {
          kind: "image",
          mimeType: "image/png",
          path: outsidePath,
          fileName: "outside.png",
        },
      },
    }) as { image: { id?: string; path?: string } };

    expect(details.image.id).toBeUndefined();
    expect(details.image.path).toBeUndefined();
    expect(sessionAttachmentMediaDetailsForToolCall(root, "s-path", "tool-path")).toEqual([]);
  });

  it("sanitizes legacy trace details when the manifest is missing", () => {
    const replayed = sessionAttachmentDetailsForToolCall(root, "s3", "tool-3", {
      message: "preview",
      audio: {
        kind: "audio",
        mimeType: "audio/wav",
        base64: Buffer.from("legacy-wav").toString("base64"),
        path: "/tmp/legacy.wav",
        fileName: "legacy.wav",
      },
    }) as { audio: { id?: string; storageKey?: string; base64?: string; path?: string } };

    expect(replayed.audio.id).toBeUndefined();
    expect(replayed.audio.storageKey).toBeUndefined();
    expect(replayed.audio.base64).toBeUndefined();
    expect(replayed.audio.path).toBeUndefined();
  });
});

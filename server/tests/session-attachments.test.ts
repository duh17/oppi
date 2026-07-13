import type { IncomingMessage, ServerResponse } from "node:http";
import { once } from "node:events";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import {
  addSessionAttachmentFile,
  getSessionAttachment,
  materializeToolAudioDetails,
  materializeToolMediaContentBlocks,
  materializeToolMediaDetails,
  sessionAttachmentDetailsForToolCall,
  sessionAttachmentMediaDetailsForToolCall,
  streamSessionAttachment,
} from "../src/session-attachments.js";

class MockWritableResponse extends PassThrough {
  statusCode = 0;
  headers: Record<string, string> = {};
  body = Buffer.alloc(0);

  constructor() {
    super();
    this.on("data", (chunk) => {
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      this.body = Buffer.concat([this.body, buffer]);
    });
  }

  writeHead(statusCode: number, headers: Record<string, string | number> = {}): this {
    this.statusCode = statusCode;
    this.headers = Object.fromEntries(
      Object.entries(headers).map(([key, value]) => [key, String(value)]),
    );
    return this;
  }
}

function makeIncoming(headers: Record<string, string> = {}): IncomingMessage {
  return { headers } as IncomingMessage;
}

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

  it("streams audio attachment byte ranges", async () => {
    const bytes = Buffer.from("0123456789");
    const details = materializeToolAudioDetails({
      dataDir: root,
      sessionId: "s-range",
      toolCallId: "tool-range",
      details: {
        audio: {
          kind: "audio",
          mimeType: "audio/wav",
          base64: bytes.toString("base64"),
          fileName: "range.wav",
        },
      },
    }) as { audio: { id: string } };

    const attachment = await getSessionAttachment(root, "s-range", details.audio.id);
    expect(attachment).not.toBeNull();
    const res = new MockWritableResponse();
    const finished = once(res, "finish");

    streamSessionAttachment(
      attachment!,
      makeIncoming({ range: "bytes=2-5" }),
      res as unknown as ServerResponse,
    );
    await finished;

    expect(res.statusCode).toBe(206);
    expect(res.headers["Content-Type"]).toBe("audio/wav");
    expect(res.headers["Accept-Ranges"]).toBe("bytes");
    expect(res.headers["Content-Range"]).toBe("bytes 2-5/10");
    expect(res.headers["Content-Length"]).toBe("4");
    expect(res.body.toString("utf8")).toBe("2345");
  });

  it("handles audio attachment HEAD requests without a body", async () => {
    const bytes = Buffer.from("0123456789");
    const details = materializeToolAudioDetails({
      dataDir: root,
      sessionId: "s-head",
      toolCallId: "tool-head",
      details: {
        audio: {
          kind: "audio",
          mimeType: "audio/wav",
          base64: bytes.toString("base64"),
          fileName: "head.wav",
        },
      },
    }) as { audio: { id: string } };

    const attachment = await getSessionAttachment(root, "s-head", details.audio.id);
    expect(attachment).not.toBeNull();
    const res = new MockWritableResponse();
    const finished = once(res, "finish");

    streamSessionAttachment(attachment!, makeIncoming(), res as unknown as ServerResponse, "HEAD");
    await finished;

    expect(res.statusCode).toBe(200);
    expect(res.headers["Content-Type"]).toBe("audio/wav");
    expect(res.headers["Accept-Ranges"]).toBe("bytes");
    expect(res.headers["Content-Length"]).toBe("10");
    expect(res.body).toHaveLength(0);
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

  it("drops malformed base64 media without persisting attachment bytes", () => {
    const details = materializeToolMediaDetails({
      dataDir: root,
      sessionId: "s-malformed-base64",
      toolCallId: "tool-malformed",
      details: {
        audio: {
          kind: "audio",
          mimeType: "text/html",
          base64: "!!!!",
          path: "/tmp/must-not-be-read.wav",
        },
        image: {
          kind: "image",
          mimeType: "text/html",
          data: "!!!!",
          path: "/tmp/must-not-be-read.png",
        },
      },
    }) as {
      audio: { base64?: string; path?: string };
      image: { data?: string; path?: string };
    };

    expect(details.audio).toEqual({ kind: "audio", mimeType: "text/html" });
    expect(details.image).toEqual({ kind: "image", mimeType: "text/html" });
    expect(
      sessionAttachmentMediaDetailsForToolCall(root, "s-malformed-base64", "tool-malformed"),
    ).toEqual([]);
  });

  it("replays duplicate media materialization as one durable attachment record", async () => {
    const contents = [
      {
        type: "image",
        data: Buffer.from("same-image-bytes").toString("base64"),
        mimeType: "image/png",
        fileName: "same.png",
      },
    ];

    const first = materializeToolMediaContentBlocks({
      dataDir: root,
      sessionId: "s-duplicate",
      toolCallId: "tool-duplicate",
      contents,
    }) as Array<{ id: string }>;
    const second = materializeToolMediaContentBlocks({
      dataDir: root,
      sessionId: "s-duplicate",
      toolCallId: "tool-duplicate",
      contents,
    }) as Array<{ id: string }>;

    expect(second[0]?.id).toBe(first[0]?.id);
    expect(
      sessionAttachmentMediaDetailsForToolCall(root, "s-duplicate", "tool-duplicate"),
    ).toHaveLength(1);
    const attachment = first[0]
      ? await getSessionAttachment(root, "s-duplicate", first[0].id)
      : null;
    expect(attachment ? await readFile(attachment.path) : null).toEqual(
      Buffer.from("same-image-bytes"),
    );
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

  it("extracts cheap dimensions for WebP, BMP, TIFF, and ICO attachments", () => {
    const cases = [
      {
        name: "webp",
        mimeType: "image/webp",
        fileName: "preview.webp",
        bytes: makeWebPVP8X(17, 23),
        width: 17,
        height: 23,
      },
      {
        name: "bmp",
        mimeType: "image/bmp",
        fileName: "preview.bmp",
        bytes: makeBMP(31, 19),
        width: 31,
        height: 19,
      },
      {
        name: "tiff",
        mimeType: "image/tiff",
        fileName: "preview.tif",
        bytes: makeTIFF(41, 37),
        width: 41,
        height: 37,
      },
      {
        name: "ico",
        mimeType: "image/x-icon",
        fileName: "preview.ico",
        bytes: makeICO(32, 16),
        width: 32,
        height: 16,
      },
    ];

    for (const item of cases) {
      const blocks = materializeToolMediaContentBlocks({
        dataDir: root,
        sessionId: `s-${item.name}`,
        toolCallId: `tool-${item.name}`,
        contents: [
          {
            type: "image",
            data: item.bytes.toString("base64"),
            mimeType: item.mimeType,
            fileName: item.fileName,
          },
        ],
      }) as Array<{ width?: number; height?: number; storageKey?: string }>;

      expect(blocks[0]?.width).toBe(item.width);
      expect(blocks[0]?.height).toBe(item.height);
      if (item.name === "ico") expect(blocks[0]?.storageKey).toMatch(/\.ico$/);
      if (item.name === "tiff") expect(blocks[0]?.storageKey).toMatch(/\.tif$/);
    }
  });

  it("extracts SVG dimensions from root width and height", () => {
    const svg = Buffer.from(
      '<svg xmlns="http://www.w3.org/2000/svg" width="320" height="180"><rect width="320" height="180"/></svg>',
    );

    const blocks = materializeToolMediaContentBlocks({
      dataDir: root,
      sessionId: "s-svg-wh",
      toolCallId: "tool-svg-wh",
      contents: [
        {
          type: "image",
          data: svg.toString("base64"),
          mimeType: "image/svg+xml",
          fileName: "chart.svg",
        },
      ],
    }) as Array<{ width?: number; height?: number }>;

    expect(blocks[0]?.width).toBe(320);
    expect(blocks[0]?.height).toBe(180);
  });

  it("materializes image details and strips base64 from the result", () => {
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
    }) as { image: { id?: string; base64?: string; path?: string; sha256?: string } };

    expect(details.image.id).toContain("att_tool-img-preview_");
    expect(details.image.base64).toBeUndefined();
    expect(details.image.path).toBeUndefined();
    expect(details.image.sha256).toEqual(expect.any(String));
  });

  it("replays image details with the matching attachment and strips base64", () => {
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
    }) as { image: { id?: string; fileName?: string; base64?: string; sha256?: string } };

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
    expect(replayed.image.base64).toBeUndefined();
    expect(replayed.image.sha256).toEqual(expect.any(String));
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

  it("adds a video file as a session attachment for details.media", async () => {
    const videoPath = join(root, "browser-run.mp4");
    const bytes = Buffer.from("mp4-video-bytes");
    await writeFile(videoPath, bytes);

    const video = addSessionAttachmentFile({
      dataDir: root,
      sessionId: "s-video-add-file",
      toolCallId: "tool-video-add-file",
      path: videoPath,
      kind: "video",
      mimeType: "video/mp4",
      fileName: "browser-run.mp4",
      durationSeconds: 2.5,
      width: 640,
      height: 360,
    }) as { id: string; kind: string; mimeType: string; width?: number; height?: number };

    expect(video.id).toContain("att_tool-video-add-file_");
    expect(video.kind).toBe("video");
    expect(video.mimeType).toBe("video/mp4");
    expect(video.width).toBe(640);
    expect(video.height).toBe(360);

    const media = sessionAttachmentMediaDetailsForToolCall(
      root,
      "s-video-add-file",
      "tool-video-add-file",
    );
    expect(media[0]?.kind).toBe("video");
    expect(media[0]?.width).toBe(640);

    const attachment = await getSessionAttachment(root, "s-video-add-file", video.id);
    expect(attachment ? await readFile(attachment.path) : null).toEqual(bytes);
  });

  it("materializes video entries from details.media and strips inline bytes", async () => {
    const bytes = Buffer.from("mp4-inline-video");
    const details = materializeToolMediaDetails({
      dataDir: root,
      sessionId: "s-video-media",
      toolCallId: "tool-video-media",
      details: {
        message: "Recorded browser run",
        media: [
          {
            kind: "video",
            mimeType: "video/mp4",
            base64: bytes.toString("base64"),
            fileName: "recording.mp4",
            durationSeconds: 1.25,
          },
        ],
      },
    }) as { media: Array<{ id?: string; base64?: string; path?: string; kind?: string }> };

    expect(details.media[0]?.id).toContain("att_tool-video-media_");
    expect(details.media[0]?.kind).toBe("video");
    expect(details.media[0]?.base64).toBeUndefined();
    expect(details.media[0]?.path).toBeUndefined();

    const replayed = sessionAttachmentDetailsForToolCall(
      root,
      "s-video-media",
      "tool-video-media",
      {
        media: [
          {
            kind: "video",
            mimeType: "video/mp4",
            base64: bytes.toString("base64"),
            fileName: "recording.mp4",
          },
        ],
      },
    ) as { media: Array<{ id?: string; base64?: string; path?: string; kind?: string }> };
    expect(replayed.media[0]?.id).toBe(details.media[0]?.id);
    expect(replayed.media[0]?.base64).toBeUndefined();

    const attachment = await getSessionAttachment(root, "s-video-media", details.media[0]!.id!);
    expect(attachment ? await readFile(attachment.path) : null).toEqual(bytes);
  });

  it("does not materialize video entries from arbitrary server paths", async () => {
    const outsidePath = join(root, "outside.mp4");
    await writeFile(outsidePath, Buffer.from("secret-video"));

    const details = materializeToolMediaDetails({
      dataDir: root,
      sessionId: "s-video-path",
      toolCallId: "tool-video-path",
      details: {
        media: [
          {
            kind: "video",
            mimeType: "video/mp4",
            path: outsidePath,
            fileName: "outside.mp4",
          },
        ],
      },
    }) as { media: Array<{ id?: string; path?: string }> };

    expect(details.media[0]?.id).toBeUndefined();
    expect(details.media[0]?.path).toBeUndefined();
    expect(
      sessionAttachmentMediaDetailsForToolCall(root, "s-video-path", "tool-video-path"),
    ).toEqual([]);
  });

  it("does not replay an invalid media array entry as another same-kind attachment", async () => {
    const validBytes = Buffer.from("valid-video");
    const outsidePath = join(root, "outside-replay.mp4");
    await writeFile(outsidePath, Buffer.from("outside-video"));

    const materialized = materializeToolMediaDetails({
      dataDir: root,
      sessionId: "s-video-replay-array",
      toolCallId: "tool-video-replay-array",
      details: {
        media: [
          {
            kind: "video",
            mimeType: "video/mp4",
            base64: validBytes.toString("base64"),
            fileName: "valid.mp4",
          },
          {
            kind: "video",
            mimeType: "video/mp4",
            path: outsidePath,
            fileName: "outside.mp4",
          },
        ],
      },
    }) as { media: Array<{ id?: string; path?: string; kind?: string }> };

    expect(materialized.media[0]?.id).toContain("att_tool-video-replay-array_");
    expect(materialized.media[1]?.id).toBeUndefined();
    expect(materialized.media[1]?.path).toBeUndefined();

    const replayed = sessionAttachmentDetailsForToolCall(
      root,
      "s-video-replay-array",
      "tool-video-replay-array",
      {
        media: [
          {
            kind: "video",
            mimeType: "video/mp4",
            id: materialized.media[0]?.id,
            fileName: "valid.mp4",
          },
          {
            kind: "video",
            mimeType: "video/mp4",
            path: outsidePath,
            fileName: "outside.mp4",
          },
        ],
      },
    ) as { media: Array<{ id?: string; path?: string; kind?: string }> };

    expect(replayed.media[0]?.id).toBe(materialized.media[0]?.id);
    expect(replayed.media[1]?.id).toBeUndefined();
    expect(replayed.media[1]?.path).toBeUndefined();
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

function makeWebPVP8X(width: number, height: number): Buffer {
  const bytes = Buffer.alloc(30);
  bytes.write("RIFF", 0, "ascii");
  bytes.writeUInt32LE(22, 4);
  bytes.write("WEBP", 8, "ascii");
  bytes.write("VP8X", 12, "ascii");
  bytes.writeUInt32LE(10, 16);
  bytes.writeUIntLE(width - 1, 24, 3);
  bytes.writeUIntLE(height - 1, 27, 3);
  return bytes;
}

function makeBMP(width: number, height: number): Buffer {
  const bytes = Buffer.alloc(54);
  bytes.write("BM", 0, "ascii");
  bytes.writeUInt32LE(bytes.length, 2);
  bytes.writeUInt32LE(54, 10);
  bytes.writeUInt32LE(40, 14);
  bytes.writeInt32LE(width, 18);
  bytes.writeInt32LE(height, 22);
  bytes.writeUInt16LE(1, 26);
  bytes.writeUInt16LE(24, 28);
  return bytes;
}

function makeTIFF(width: number, height: number): Buffer {
  const bytes = Buffer.alloc(38);
  bytes.write("II", 0, "ascii");
  bytes.writeUInt16LE(42, 2);
  bytes.writeUInt32LE(8, 4);
  bytes.writeUInt16LE(2, 8);
  bytes.writeUInt16LE(256, 10);
  bytes.writeUInt16LE(4, 12);
  bytes.writeUInt32LE(1, 14);
  bytes.writeUInt32LE(width, 18);
  bytes.writeUInt16LE(257, 22);
  bytes.writeUInt16LE(4, 24);
  bytes.writeUInt32LE(1, 26);
  bytes.writeUInt32LE(height, 30);
  return bytes;
}

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

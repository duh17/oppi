import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import {
  getSessionAttachment,
  materializeVoiceSpeakAudioDetails,
  sessionAttachmentDetailsForToolCall,
} from "./session-attachments.js";

let root: string;

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), "oppi-session-attachments-"));
});

afterEach(async () => {
  await rm(root, { recursive: true, force: true });
});

describe("session attachments", () => {
  it("materializes audio details from a file path and sanitizes the result", async () => {
    const sourcePath = join(root, "source.wav");
    const bytes = Buffer.from("RIFFtest-audio");
    await writeFile(sourcePath, bytes);

    const details = materializeVoiceSpeakAudioDetails({
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

  it("replays sanitized attachment details from the manifest", () => {
    const materialized = materializeVoiceSpeakAudioDetails({
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

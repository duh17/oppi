import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { Storage } from "../src/storage.js";
import {
  createVoiceFactory,
  normalizeVoiceDelivery,
  readVoicePreferences,
  resolveConfiguredDefaultVoiceId,
  saveVoicePreferences,
} from "./voice.js";

type RegisteredTool = {
  name: string;
  execute: (
    toolCallId: string,
    params: Record<string, unknown>,
    signal?: AbortSignal,
    onUpdate?: (update: { content: unknown[]; details?: unknown }) => void,
    ctx?: unknown,
  ) => Promise<{ content: Array<{ type: string; text: string }>; details?: unknown }>;
};

function createMockAPI(): {
  tools: Map<string, RegisteredTool>;
  registerTool(tool: RegisteredTool): void;
  registerCommand(name: string, command: unknown): void;
} {
  return {
    tools: new Map(),
    registerTool(tool) {
      this.tools.set(tool.name, tool);
    },
    registerCommand() {
      // Not needed for these tests.
    },
  };
}

function makeNDJSONResponse(events: unknown[], trailingNewline = true): Response {
  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      const lines = events.map((event) => JSON.stringify(event)).join("\n");
      controller.enqueue(encoder.encode(lines + (trailingNewline ? "\n" : "")));
      controller.close();
    },
  });
  return new Response(stream, {
    status: 200,
    headers: { "Content-Type": "application/x-ndjson" },
  });
}

describe("createVoiceFactory", () => {
  let tempDir: string;

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "oppi-voice-test-"));
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
    rmSync(tempDir, { recursive: true, force: true });
  });

  it("skips embedded WAV replay when Oppi already streamed directSpeak audio", async () => {
    const fetchMock = vi.fn(async (input: string | URL) => {
      const url = input instanceof URL ? input : new URL(input);
      if (url.pathname === "/v1/info") {
        return new Response("{}", { status: 200 });
      }
      if (url.pathname === "/v1/audio/speech/stream") {
        const pcmChunk = Buffer.from([0, 0, 1, 0, 255, 127, 0, 128]).toString("base64");
        return makeNDJSONResponse([
          { event: "metadata", sample_rate: 24_000, channels: 1 },
          { event: "audio", chunk: 0, seconds: 0.1, audio: pcmChunk },
          { event: "done", audio_duration_seconds: 0.1 },
        ]);
      }
      throw new Error(`Unexpected fetch: ${url.pathname}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    const api = createMockAPI();
    createVoiceFactory()(api as never);
    const tool = api.tools.get("voice_speak");
    expect(tool).toBeDefined();

    const audioStream = vi.fn();
    const result = await tool!.execute(
      "tc-direct",
      {
        text: "Hello from streaming direct speak.",
        delivery: "directSpeak",
        stream: true,
        play: true,
        out: join(tempDir, "direct.wav"),
      },
      undefined,
      undefined,
      { ui: { audioStream } },
    );

    const details = result.details as {
      audio?: { base64?: string; stream?: boolean };
      played?: boolean;
      delivery?: string;
    };

    expect(details.delivery).toBe("directSpeak");
    expect(details.played).toBe(true);
    expect(details.audio?.stream).toBe(true);
    expect(details.audio?.base64).toBeUndefined();

    expect(audioStream).toHaveBeenCalled();
    expect(audioStream.mock.calls[0]?.[0]).toMatchObject({
      id: "tc-direct",
      kind: "audio-stream",
      event: "metadata",
      delivery: "directSpeak",
    });
  });

  it("processes a final NDJSON stream line without trailing newline", async () => {
    const fetchMock = vi.fn(async (input: string | URL) => {
      const url = input instanceof URL ? input : new URL(input);
      if (url.pathname === "/v1/info") {
        return new Response("{}", { status: 200 });
      }
      if (url.pathname === "/v1/audio/speech/stream") {
        const pcmChunk = Buffer.from([0, 0, 1, 0]).toString("base64");
        return makeNDJSONResponse(
          [
            { event: "metadata", sample_rate: 24_000, channels: 1 },
            { event: "audio", chunk: 0, seconds: 0.1, audio: pcmChunk },
            { event: "done", audio_duration_seconds: 0.1 },
          ],
          false,
        );
      }
      throw new Error(`Unexpected fetch: ${url.pathname}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    const api = createMockAPI();
    createVoiceFactory()(api as never);
    const tool = api.tools.get("voice_speak");
    const audioStream = vi.fn();

    const result = await tool!.execute(
      "tc-no-newline",
      {
        text: "This stream ends without a newline.",
        delivery: "voiceMessage",
        stream: true,
        play: false,
        out: join(tempDir, "no-newline.wav"),
      },
      undefined,
      undefined,
      { ui: { audioStream } },
    );

    const details = result.details as { audio?: { durationSeconds?: number } };
    expect(details.audio?.durationSeconds).toBe(0.1);
    expect(audioStream).toHaveBeenCalledWith(expect.objectContaining({ event: "done" }));
  });

  it("keeps embedded WAV data for streamed voiceMessage replies", async () => {
    const fetchMock = vi.fn(async (input: string | URL) => {
      const url = input instanceof URL ? input : new URL(input);
      if (url.pathname === "/v1/info") {
        return new Response("{}", { status: 200 });
      }
      if (url.pathname === "/v1/audio/speech/stream") {
        const pcmChunk = Buffer.from([0, 0, 1, 0, 255, 127, 0, 128]).toString("base64");
        return makeNDJSONResponse([
          { event: "metadata", sample_rate: 24_000, channels: 1 },
          { event: "audio", chunk: 0, seconds: 0.1, audio: pcmChunk },
          { event: "done", audio_duration_seconds: 0.1 },
        ]);
      }
      throw new Error(`Unexpected fetch: ${url.pathname}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    const api = createMockAPI();
    createVoiceFactory()(api as never);
    const tool = api.tools.get("voice_speak");
    expect(tool).toBeDefined();

    const result = await tool!.execute(
      "tc-card",
      {
        text: "Keep this as a replayable voice card.",
        delivery: "voiceMessage",
        stream: true,
        play: true,
        out: join(tempDir, "card.wav"),
      },
      undefined,
      undefined,
      { ui: { audioStream: vi.fn() } },
    );

    const details = result.details as {
      audio?: { base64?: string; stream?: boolean };
      delivery?: string;
    };

    expect(details.delivery).toBe("voiceMessage");
    expect(details.audio?.stream).toBe(true);
    expect(details.audio?.base64).toEqual(expect.any(String));
  });
});

describe("voice reply mode", () => {
  it("registers a session-scoped voice reply mode tool", async () => {
    const api = createMockAPI();
    createVoiceFactory()(api as never);
    const tool = api.tools.get("voice_reply_mode");
    expect(tool).toBeDefined();

    const result = await tool!.execute("tc-session-mode", { mode: "autoplay" });
    expect(result.content[0]?.text).toContain("autoplay voice replies by default");
    expect(result.details).toMatchObject({
      kind: "voice_reply_mode",
      scope: "session",
      mode: "autoplay",
    });
  });
});

describe("voice preferences", () => {
  let tempDir: string;

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "voice-prefs-"));
  });

  afterEach(() => {
    rmSync(tempDir, { recursive: true, force: true });
  });

  it("persists and reloads the saved default voice", () => {
    const storage = new Storage(tempDir);

    expect(readVoicePreferences(storage)).toEqual({});

    const saved = saveVoicePreferences(storage, { defaultVoiceId: "warm-technical-teammate" });
    expect(saved.defaultVoiceId).toBe("warm-technical-teammate");
    expect(saved.updatedAt).toBeTypeOf("string");

    expect(readVoicePreferences(storage).defaultVoiceId).toBe("warm-technical-teammate");
    expect(resolveConfiguredDefaultVoiceId(storage)).toBe("warm-technical-teammate");
  });

  it("normalizes supported delivery values", () => {
    expect(normalizeVoiceDelivery("voiceMessage")).toBe("voiceMessage");
    expect(normalizeVoiceDelivery("directSpeak")).toBe("directSpeak");
    expect(normalizeVoiceDelivery("somethingElse")).toBeUndefined();
  });
});

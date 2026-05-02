import { describe, expect, it, vi } from "vitest";

import {
  createTTSAudioStreamEmitter,
  createTTSToolVoiceDetails,
  createTTSVoicePresentationDetails,
} from "./tts-provider.js";

describe("tts-provider helpers", () => {
  it("decorates stream events with toolCallId and delivery", () => {
    const audioStream = vi.fn();
    const emit = createTTSAudioStreamEmitter({
      ui: { audioStream },
      toolCallId: "tc-1",
      delivery: "directSpeak",
    });

    expect(emit).toBeTypeOf("function");

    emit?.({
      kind: "audio-stream",
      event: "metadata",
      mimeType: "audio/pcm; codecs=s16le",
      sampleRate: 24_000,
      channels: 1,
    });

    expect(audioStream).toHaveBeenCalledWith({
      id: "tc-1",
      kind: "audio-stream",
      event: "metadata",
      mimeType: "audio/pcm; codecs=s16le",
      sampleRate: 24_000,
      channels: 1,
      delivery: "directSpeak",
    });
  });

  it("does not emit when Oppi UI streaming is unavailable or toolCallId is missing", () => {
    expect(createTTSAudioStreamEmitter({ ui: {}, toolCallId: "tc-1" })).toBeUndefined();
    expect(
      createTTSAudioStreamEmitter({ ui: { audioStream: vi.fn() }, toolCallId: "" }),
    ).toBeUndefined();
    expect(
      createTTSAudioStreamEmitter({ ui: { audioStream: vi.fn() }, toolCallId: undefined }),
    ).toBeUndefined();
  });

  it("builds generic in-flight voice presentation details", () => {
    const details = createTTSVoicePresentationDetails({
      message: "Still speaking…",
      delivery: "directSpeak",
      provider: { id: "example-tts", model: "demo-v1" },
      extra: { status: "speaking" },
    });

    expect(details).toMatchObject({
      presentation: "voice",
      message: "Still speaking…",
      delivery: "directSpeak",
      provider: { id: "example-tts", model: "demo-v1" },
      status: "speaking",
    });
  });

  it("builds generic voice tool details and preserves extension-specific extras", () => {
    const details = createTTSToolVoiceDetails({
      message: "Hello from a provider-agnostic TTS extension.",
      delivery: "voiceMessage",
      provider: {
        id: "example-tts",
        model: "demo-v1",
        voiceId: "warm-1",
        sourceMimeType: "audio/wav",
      },
      audio: {
        kind: "audio",
        mimeType: "audio/wav",
        path: "/tmp/reply.wav",
        fileName: "reply.wav",
        sizeBytes: 42,
        durationSeconds: 0.5,
      },
      extra: {
        played: false,
        serverUrl: "http://127.0.0.1:9999",
      },
    });

    expect(details).toMatchObject({
      presentation: "voice",
      message: "Hello from a provider-agnostic TTS extension.",
      delivery: "voiceMessage",
      provider: {
        id: "example-tts",
        model: "demo-v1",
        voiceId: "warm-1",
      },
      audio: {
        kind: "audio",
        mimeType: "audio/wav",
        fileName: "reply.wav",
      },
      played: false,
      serverUrl: "http://127.0.0.1:9999",
    });
  });
});

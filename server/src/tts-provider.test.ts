import { describe, expect, it, vi } from "vitest";

import { createAudioPresentationDetails, createAudioStreamEmitter } from "./tts-provider.js";

describe("tts-provider helpers", () => {
  it("builds generic audio presentation details", () => {
    const details = createAudioPresentationDetails({
      audio: {
        kind: "audio",
        mimeType: "audio/wav",
        path: "/tmp/reply.wav",
        durationSeconds: 1.2,
      },
      text: "hello there",
      playbackBehavior: "tapToPlay",
      extra: { source: "test" },
    });

    expect(details).toMatchObject({
      kind: "audio_presentation",
      audio: {
        kind: "audio",
        mimeType: "audio/wav",
        path: "/tmp/reply.wav",
      },
      text: "hello there",
      playbackBehavior: "tapToPlay",
      source: "test",
    });
  });

  it("decorates generic stream events with stream id", () => {
    const audioStream = vi.fn();
    const emit = createAudioStreamEmitter({
      ui: { audioStream },
      streamId: "tc-audio-1",
    });

    expect(emit).toBeTypeOf("function");

    emit?.({
      kind: "audio-stream",
      event: "metadata",
      mimeType: "audio/pcm; codecs=s16le",
      playbackBehavior: "playNow",
      text: "hello",
      sampleRate: 24_000,
      channels: 1,
    });

    expect(audioStream).toHaveBeenCalledWith({
      id: "tc-audio-1",
      kind: "audio-stream",
      event: "metadata",
      mimeType: "audio/pcm; codecs=s16le",
      playbackBehavior: "playNow",
      text: "hello",
      sampleRate: 24_000,
      channels: 1,
    });
  });

  it("does not emit when Oppi UI streaming is unavailable or stream id is missing", () => {
    expect(createAudioStreamEmitter({ ui: {}, streamId: "tc-1" })).toBeUndefined();
    expect(
      createAudioStreamEmitter({ ui: { audioStream: vi.fn() }, streamId: "" }),
    ).toBeUndefined();
    expect(
      createAudioStreamEmitter({ ui: { audioStream: vi.fn() }, streamId: undefined }),
    ).toBeUndefined();
  });
});

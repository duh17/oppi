/**
 * Shared audio presentation contract for Oppi extensions.
 *
 * Extensions can stream generic audio events with `createAudioStreamEmitter(...)`
 * and return final attachment-backed audio cards with
 * `createAudioPresentationDetails(...)`.
 *
 * Provider-specific auth, transport, and synthesis details stay inside the
 * extension itself.
 */

export type AudioPlaybackBehavior = "tapToPlay" | "playNow";

export type AudioLiveMimeType = "audio/pcm; codecs=s16le" | "audio/wav";

export interface TTSProviderCapabilities {
  streaming?: boolean;
  listVoices?: boolean;
  cloneVoice?: boolean;
  designVoice?: boolean;
  timestamps?: boolean;
  asyncJobs?: boolean;
  continuityHints?: boolean;
  pronunciationLexicon?: boolean;
  providerNativeFormats?: readonly string[];
}

export interface TTSProviderInfo {
  id: string;
  displayName?: string;
  model?: string;
  voiceId?: string;
  requestId?: string;
  sourceMimeType?: string;
  capabilities?: TTSProviderCapabilities;
  metadata?: Record<string, unknown>;
}

export interface TTSTimestampSegment {
  startMs: number;
  endMs: number;
  text: string;
}

export interface TTSTimestampTrack {
  kind: "word" | "sentence";
  items: TTSTimestampSegment[];
}

export interface AudioAttachment {
  kind: "audio";
  mimeType: string;
  path?: string;
  base64?: string;
  id?: string;
  fileName?: string;
  sizeBytes?: number;
  durationSeconds?: number;
  stream?: boolean;
  metrics?: Record<string, unknown>;
}

export interface AudioPresentation {
  kind: "audio_presentation";
  audio: AudioAttachment;
  text?: string;
  playbackBehavior?: AudioPlaybackBehavior;
}

export interface AudioStreamEvent {
  kind: "audio-stream";
  id: string;
  event: "metadata" | "chunk" | "done" | "error";
  mimeType: AudioLiveMimeType;
  sampleRate?: number;
  channels?: number;
  chunkIndex?: number;
  audioBase64?: string;
  text?: string;
  durationSeconds?: number;
  metrics?: Record<string, unknown>;
  playbackBehavior?: AudioPlaybackBehavior;
}

export type AudioStreamUpdate = Omit<AudioStreamEvent, "id">;
export type AudioStreamEmitter = (event: AudioStreamUpdate) => void;

function resolveAudioStream(ui: unknown): ((event: AudioStreamEvent) => void) | undefined {
  if (!ui || typeof ui !== "object") {
    return undefined;
  }

  const audioStream = (ui as { audioStream?: unknown }).audioStream;
  return typeof audioStream === "function"
    ? (audioStream as (event: AudioStreamEvent) => void)
    : undefined;
}

export function createAudioStreamEmitter(options: {
  ui: unknown;
  streamId?: string | null;
}): AudioStreamEmitter | undefined {
  const audioStream = resolveAudioStream(options.ui);
  const streamId = typeof options.streamId === "string" ? options.streamId.trim() : "";
  if (!audioStream || !streamId) {
    return undefined;
  }

  return (event) => {
    audioStream({
      id: streamId,
      ...event,
    });
  };
}

export function createAudioPresentationDetails<
  TExtra extends Record<string, unknown> = Record<string, never>,
>(input: {
  audio: AudioAttachment;
  text?: string;
  playbackBehavior?: AudioPlaybackBehavior;
  extra?: TExtra;
}): AudioPresentation & TExtra {
  return {
    kind: "audio_presentation",
    audio: input.audio,
    ...(input.text ? { text: input.text } : {}),
    ...(input.playbackBehavior ? { playbackBehavior: input.playbackBehavior } : {}),
    ...(input.extra ?? ({} as TExtra)),
  };
}

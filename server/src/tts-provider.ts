/**
 * Provider-agnostic TTS seam for Oppi extensions.
 *
 * An extension does not need to implement a shared runtime class or register a
 * provider adapter with Oppi. To plug in cleanly, it only needs to:
 *
 * 1. optionally stream live audio with `createTTSAudioStreamEmitter(...)`
 * 2. return final structured voice details with `createTTSToolVoiceDetails(...)`
 *
 * Provider-specific auth, transport, cloning, voice design, and normalization
 * stay inside the extension itself.
 */

export type TTSVoiceReplyDelivery = "voiceMessage" | "directSpeak";

export type TTSLiveAudioMimeType = "audio/pcm; codecs=s16le" | "audio/wav";

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

export interface TTSToolAudioDetails {
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

export interface TTSVoicePresentationDetails {
  presentation: "voice";
  message: string;
  delivery?: TTSVoiceReplyDelivery;
  provider?: TTSProviderInfo;
  timestamps?: TTSTimestampTrack;
}

export interface TTSToolVoiceDetails extends TTSVoicePresentationDetails {
  audio: TTSToolAudioDetails;
}

export interface TTSAudioStreamEvent {
  kind: "audio-stream";
  id: string;
  event: "metadata" | "chunk" | "done" | "error";
  mimeType: TTSLiveAudioMimeType;
  sampleRate?: number;
  channels?: number;
  chunkIndex?: number;
  audioBase64?: string;
  text?: string;
  durationSeconds?: number;
  metrics?: Record<string, unknown>;
  delivery?: TTSVoiceReplyDelivery;
}

export type TTSAudioStreamUpdate = Omit<TTSAudioStreamEvent, "id" | "delivery">;

export type TTSAudioStreamEmitter = (event: TTSAudioStreamUpdate) => void;

function resolveTTSAudioStream(ui: unknown): ((event: TTSAudioStreamEvent) => void) | undefined {
  if (!ui || typeof ui !== "object") {
    return undefined;
  }

  const audioStream = (ui as { audioStream?: unknown }).audioStream;
  return typeof audioStream === "function"
    ? (audioStream as (event: TTSAudioStreamEvent) => void)
    : undefined;
}

export function createTTSAudioStreamEmitter(options: {
  ui: unknown;
  toolCallId?: string | null;
  delivery?: TTSVoiceReplyDelivery;
}): TTSAudioStreamEmitter | undefined {
  const audioStream = resolveTTSAudioStream(options.ui);
  const toolCallId = typeof options.toolCallId === "string" ? options.toolCallId.trim() : "";
  if (!audioStream || !toolCallId) {
    return undefined;
  }

  return (event) => {
    audioStream({
      id: toolCallId,
      delivery: options.delivery,
      ...event,
    });
  };
}

export function createTTSVoicePresentationDetails<
  TExtra extends Record<string, unknown> = Record<string, never>,
>(input: {
  message: string;
  delivery?: TTSVoiceReplyDelivery;
  provider?: TTSProviderInfo;
  timestamps?: TTSTimestampTrack;
  extra?: TExtra;
}): TTSVoicePresentationDetails & TExtra {
  return {
    presentation: "voice",
    message: input.message,
    ...(input.delivery ? { delivery: input.delivery } : {}),
    ...(input.provider ? { provider: input.provider } : {}),
    ...(input.timestamps ? { timestamps: input.timestamps } : {}),
    ...(input.extra ?? ({} as TExtra)),
  };
}

export function createTTSToolVoiceDetails<
  TAudio extends TTSToolAudioDetails = TTSToolAudioDetails,
  TExtra extends Record<string, unknown> = Record<string, never>,
>(input: {
  message: string;
  delivery?: TTSVoiceReplyDelivery;
  provider?: TTSProviderInfo;
  audio: TAudio;
  timestamps?: TTSTimestampTrack;
  extra?: TExtra;
}): TTSToolVoiceDetails & { audio: TAudio } & TExtra {
  return {
    ...createTTSVoicePresentationDetails({
      message: input.message,
      delivery: input.delivery,
      provider: input.provider,
      timestamps: input.timestamps,
    }),
    audio: input.audio,
    ...(input.extra ?? ({} as TExtra)),
  };
}

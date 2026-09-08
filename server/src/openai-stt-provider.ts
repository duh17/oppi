/**
 * OpenAI Audio Transcriptions adapter.
 *
 * Official API is POST /v1/audio/transcriptions (multipart file upload).
 * `stream=true` streams the transcript after the whole file is uploaded;
 * it is not live microphone partials. This adapter buffers PCM and
 * transcribes on stop so dictation_result ticks are not faked.
 *
 * Docs: https://platform.openai.com/docs/api-reference/audio/createTranscription
 */

import {
  SttSessionCreateError,
  type SttFinalTranscript,
  type SttProvider,
  type SttStartOptions,
  type SttStartResult,
  type SttTranscriptUpdate,
} from "./stt-provider.js";

export const DEFAULT_OPENAI_STT_ENDPOINT = "https://api.openai.com";
export const DEFAULT_OPENAI_STT_MODEL = "gpt-4o-mini-transcribe";

const PCM_SAMPLE_RATE = 16_000;

export interface OpenAiSttOptions {
  endpoint?: string;
  model?: string;
  resolveApiKey: () => string | undefined | Promise<string | undefined>;
}

function pcmS16leMonoToWav(pcm: Buffer, sampleRate = PCM_SAMPLE_RATE): Buffer {
  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + pcm.length, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(1, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(sampleRate * 2, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}

export function openaiTranscriptionsUrl(endpoint: string): string {
  const trimmed = endpoint.trim().replace(/\/+$/, "").replace(/\/v1$/i, "");
  return `${trimmed}/v1/audio/transcriptions`;
}

export class OpenAiSttProvider implements SttProvider {
  readonly name = "openai-codex";
  readonly model: string;
  private readonly endpoint: string;
  private readonly resolveApiKey: () => string | undefined | Promise<string | undefined>;
  private readonly fetchFn: typeof globalThis.fetch;
  private audioQueue: Buffer[] = [];
  private stopped = false;
  private takePrompt: string | undefined;
  private contextApplied = false;

  constructor(opts: OpenAiSttOptions, fetchFn: typeof globalThis.fetch = globalThis.fetch) {
    this.endpoint = opts.endpoint?.trim() || DEFAULT_OPENAI_STT_ENDPOINT;
    this.model = opts.model?.trim() || DEFAULT_OPENAI_STT_MODEL;
    this.resolveApiKey = opts.resolveApiKey;
    this.fetchFn = fetchFn;
  }

  async start(options?: SttStartOptions): Promise<SttStartResult> {
    const apiKey = (await this.resolveApiKey())?.trim();
    if (!apiKey) {
      throw new SttSessionCreateError({ category: "auth" });
    }

    this.stopped = false;
    this.audioQueue = [];
    this.takePrompt =
      options?.contextualStrings && options.contextualStrings.length > 0
        ? options.contextualStrings.join(", ")
        : undefined;
    this.contextApplied = this.takePrompt !== undefined;
    return { contextApplied: this.contextApplied };
  }

  feedAudio(pcm: Buffer): void {
    if (this.stopped) return;
    this.audioQueue.push(pcm);
  }

  onToken(_cb: (update: SttTranscriptUpdate) => void): void {
    // OpenAI has no live microphone partials. Do not emit dictation_result ticks.
  }

  async stop(): Promise<SttFinalTranscript> {
    this.stopped = true;
    const pcm = Buffer.concat(this.audioQueue);
    this.audioQueue = [];
    const prompt = this.takePrompt;
    this.takePrompt = undefined;
    this.contextApplied = false;

    if (pcm.length === 0) {
      return { text: "" };
    }

    const apiKey = (await this.resolveApiKey())?.trim();
    if (!apiKey) {
      throw new Error("STT transcription failed: (auth)");
    }

    const wav = pcmS16leMonoToWav(pcm);
    const form = new FormData();
    form.append("model", this.model);
    if (prompt) form.append("prompt", prompt);
    form.append("file", new Blob([new Uint8Array(wav)], { type: "audio/wav" }), "audio.wav");

    let res: Response;
    try {
      res = await this.fetchFn(openaiTranscriptionsUrl(this.endpoint), {
        method: "POST",
        headers: { Authorization: `Bearer ${apiKey}` },
        body: form,
        signal: AbortSignal.timeout(60_000),
      });
    } catch {
      throw new Error("STT transcription failed: (network)");
    }

    if (!res.ok) {
      await res.arrayBuffer().catch(() => undefined);
      throw new Error(`STT transcription failed: HTTP ${res.status}`);
    }

    let data: unknown;
    try {
      data = await res.json();
    } catch {
      throw new Error("STT transcription failed: (invalid_response)");
    }
    if (typeof data !== "object" || data === null || Array.isArray(data)) {
      throw new Error("STT transcription failed: (invalid_response)");
    }
    const text =
      typeof (data as { text?: unknown }).text === "string" ? (data as { text: string }).text : "";
    return { text };
  }

  async dispose(): Promise<void> {
    this.stopped = true;
    this.audioQueue = [];
    this.takePrompt = undefined;
    this.contextApplied = false;
  }
}

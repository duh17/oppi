/**
 * In-process STT provider backed by a Pi package ./host export.
 *
 * Converts incoming s16le 16 kHz mono PCM to Float32Array, serializes host
 * feed() calls, and maps stop() to host finalize(). Constructor must not
 * prepare(); DictationManager awaits start() before dictation_ready.
 */

import type { SttFinalTranscript, SttProvider, SttTranscriptUpdate } from "./stt-provider.js";
import type { TranscriptionHost } from "./pi-extension-stt-host.js";

export type PiExtensionSttProviderOptions =
  | { host: TranscriptionHost }
  | { getHost: () => Promise<TranscriptionHost> };

export class PiExtensionSttProvider implements SttProvider {
  readonly name = "pi-extension";

  private host: TranscriptionHost | undefined;
  private readonly getHost: (() => Promise<TranscriptionHost>) | undefined;
  private stream: ReturnType<TranscriptionHost["createDictation"]> | undefined;
  private tokenCb: ((update: SttTranscriptUpdate) => void) | null = null;
  private lastText = "";
  private stopped = false;
  private startWork: Promise<void> | undefined;
  private feedQueue: Promise<void> = Promise.resolve();

  constructor(options: PiExtensionSttProviderOptions) {
    if ("host" in options) {
      this.host = options.host;
    } else {
      this.getHost = options.getHost;
    }
  }

  get model(): string {
    return this.host?.model ?? "";
  }

  async start(): Promise<void> {
    this.stopped = false;
    this.lastText = "";
    this.feedQueue = Promise.resolve();
    this.stream = undefined;

    const work = this.startStream();
    this.startWork = work;
    try {
      await work;
    } finally {
      if (this.startWork === work) this.startWork = undefined;
    }
  }

  private async startStream(): Promise<void> {
    if (!this.host) {
      if (!this.getHost) {
        throw new Error("Pi extension STT host is not configured");
      }
      this.host = await this.getHost();
      if (this.stopped) return;
    }

    await this.host.prepare();
    if (this.stopped) return;

    const stream = this.host.createDictation();
    this.stream = stream;
    try {
      await stream.ready;
    } catch (error) {
      if (this.stream === stream) this.stream = undefined;
      stream.cancel();
      throw error;
    }
    if (this.stopped) {
      this.releaseStream();
    }
  }

  private releaseStream(): void {
    const stream = this.stream;
    if (!stream) return;
    this.stream = undefined;
    stream.cancel();
  }

  feedAudio(pcm: Buffer): void {
    if (this.stopped || !this.stream) return;
    const samples = s16leToF32(pcm);
    this.feedQueue = this.feedQueue
      .then(async () => {
        // stop() still drains feeds that were already queued.
        if (!this.stream) return;
        const update = await this.stream.feed(samples);
        if (!update) return;
        this.lastText = update.text;
        this.tokenCb?.({
          text: update.text,
          ...(update.snap ? { snap: true } : {}),
          ...(update.committedText !== undefined ? { committedText: update.committedText } : {}),
          ...(update.activeText !== undefined ? { activeText: update.activeText } : {}),
        });
      })
      .catch(() => {
        // Keep the queue alive after a feed failure so stop() can still finalize.
      });
  }

  onToken(cb: (update: SttTranscriptUpdate) => void): void {
    this.tokenCb = cb;
  }

  async stop(): Promise<SttFinalTranscript> {
    this.stopped = true;
    await this.startWork?.catch(() => {});
    await this.feedQueue.catch(() => {});

    if (!this.stream) {
      return { text: this.lastText };
    }

    const stream = this.stream;
    this.stream = undefined;
    const final = await stream.finalize();
    this.lastText = final.text;
    return {
      text: final.text,
      ...(final.committedText !== undefined ? { committedText: final.committedText } : {}),
      ...(final.activeText !== undefined ? { activeText: final.activeText } : {}),
    };
  }
}

function s16leToF32(pcm: Buffer): Float32Array {
  const count = Math.floor(pcm.length / 2);
  const out = new Float32Array(count);
  for (let i = 0; i < count; i++) {
    out[i] = pcm.readInt16LE(i * 2) / 32768;
  }
  return out;
}

/**
 * Live Voice over OpenRouter's plain HTTP audio endpoints, for a server whose only credential
 * is an OpenRouter key.
 *
 * OpenRouter has no realtime or streaming speech-to-text, only `POST /audio/transcriptions`
 * (whole clip in, text out) and `POST /audio/speech` (text in, audio bytes out). So this side
 * decides when the caller's turn ends: an energy detector over the phone's 16 kHz PCM opens an
 * utterance on sustained speech and closes it after a fixed pause, and each closed utterance
 * is uploaded as one WAV. There are no live captions; a turn's text arrives when its upload
 * is transcribed, so a reply starts at best the pause plus one transcription request later.
 *
 * Model ids and the voice are fixed below. The speech model must return 16-bit mono PCM at
 * LIVE_VOICE_PLAYBACK_SAMPLE_RATE: OpenRouter documents `pcm` from Azure MAI-Voice as 24 kHz
 * mono, and other models' rates are not documented.
 */

import type { LiveVoiceTtsPort } from "./continuous-voice-media.js";
import { createLogger } from "./logger.js";
import type {
  LiveTranscription,
  LiveTranscriptionEvents,
  LiveTurnEndReason,
} from "./realtime-transcription.js";
import { SttSessionCreateError } from "./stt-provider.js";

const log = createLogger({ base: { component: "openrouter_live_voice" } });

export const OPENROUTER_API_BASE = "https://openrouter.ai/api/v1";
/** Served by Groq and DeepInfra; the cheapest and fastest Whisper on OpenRouter. */
export const OPENROUTER_LIVE_VOICE_STT_MODEL = "openai/whisper-large-v3-turbo";
/** Azure's low-latency voice; OpenRouter documents its `pcm` as 24 kHz mono. */
export const OPENROUTER_LIVE_VOICE_TTS_MODEL = "microsoft/mai-voice-2.1-flash";
export const OPENROUTER_LIVE_VOICE_TTS_VOICE = "en-US-Harper:MAI-Voice-2.1-Flash";

/** The phone sends 16-bit mono PCM at this rate. */
const INPUT_SAMPLE_RATE = 16_000;
const FRAME_MS = 20;
const FRAME_BYTES = (INPUT_SAMPLE_RATE * 2 * FRAME_MS) / 1_000;
/** Speech this long, without a silent frame, opens an utterance; shorter clicks and coughs do not. */
const MIN_SPEECH_MS = 200;
/** Audio kept from before the utterance opened, so its first syllable is not clipped. */
const PRE_ROLL_MS = 400;
/** Silence kept at the end of an upload; the rest of the closing pause is not sent. */
const TRAILING_SILENCE_MS = 300;
/**
 * An utterance this long is cut and sent even mid-speech: transcription requests stay bounded
 * (OpenRouter's upstreams time out after 60 s of processing), and steady noise that reads as
 * speech cannot hold a turn open for the whole call.
 */
const MAX_UTTERANCE_MS = 30_000;
/** A frame is speech when it is this far above the noise floor... */
const SPEECH_OVER_FLOOR_DB = 12;
/** ...and at least this loud. The phone's voice processing leaves silence far below it. */
const MIN_SPEECH_DBFS = -50;
const INITIAL_FLOOR_DBFS = -70;
const MIN_FLOOR_DBFS = -90;
const TRANSCRIPTION_TIMEOUT_MS = 30_000;
/** How long End waits for the caller's last words to be transcribed before giving up on them. */
const DRAIN_TIMEOUT_MS = 10_000;

export interface OpenRouterAudioOptions {
  /** The server's OpenRouter credential, resolved per request. */
  resolveApiKey: () => Promise<string | undefined>;
  /** Defaults to OPENROUTER_API_BASE; tests point it at a fake. */
  baseUrl?: string;
  fetchFn?: typeof globalThis.fetch;
}

export interface OpenRouterLiveTranscriptionOptions extends OpenRouterAudioOptions {
  /** The pause that ends a turn, and how long an open turn may go without audio. */
  silenceDurationMs: number;
  transcriptionTimeoutMs?: number;
  drainTimeoutMs?: number;
}

interface PendingTurn {
  reason: LiveTurnEndReason;
  committedAt: number;
  /** Set when the transcription request settles; "" when it failed or heard nothing. */
  text?: string;
}

/** Root-mean-square level of one frame of 16-bit PCM, in dBFS. */
function frameDbfs(frame: Buffer): number {
  let sum = 0;
  const samples = frame.length / 2;
  for (let i = 0; i < samples; i++) {
    const sample = frame.readInt16LE(i * 2);
    sum += sample * sample;
  }
  const rms = Math.sqrt(sum / samples);
  return rms === 0 ? MIN_FLOOR_DBFS : Math.max(MIN_FLOOR_DBFS, 20 * Math.log10(rms / 32_768));
}

/** 16 kHz 16-bit mono PCM as a WAV file. */
export function pcm16kToWav(pcm: Buffer): Buffer {
  const header = Buffer.alloc(44);
  header.write("RIFF", 0, "ascii");
  header.writeUInt32LE(36 + pcm.length, 4);
  header.write("WAVE", 8, "ascii");
  header.write("fmt ", 12, "ascii");
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20); // PCM
  header.writeUInt16LE(1, 22); // mono
  header.writeUInt32LE(INPUT_SAMPLE_RATE, 24);
  header.writeUInt32LE(INPUT_SAMPLE_RATE * 2, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36, "ascii");
  header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}

/** OpenRouter's error message from a JSON error body; never the request. */
async function errorMessage(response: Response): Promise<string> {
  try {
    const body = (await response.json()) as { error?: { message?: unknown } };
    const message = body.error?.message;
    if (typeof message === "string" && message) return `HTTP ${response.status}: ${message}`;
  } catch {
    // Not JSON.
  }
  return `HTTP ${response.status}`;
}

/**
 * The listening half: turn detection on this server, one OpenRouter transcription per turn.
 * Turns are handed over in the order they ended, whichever transcription finishes first.
 */
export class OpenRouterLiveTranscription implements LiveTranscription {
  private events: LiveTranscriptionEvents | undefined;
  private apiKey = "";
  private closing = false;
  private readonly baseUrl: string;
  private readonly fetchFn: typeof globalThis.fetch;
  /** Bytes fed that do not yet fill a frame. */
  private carry: Buffer = Buffer.alloc(0);
  private noiseFloorDb = INITIAL_FLOOR_DBFS;
  /** Recent frames while no utterance is open: the pre-roll, ending in the current speech run. */
  private preRoll: Buffer[] = [];
  private speechRunMs = 0;
  /** The open utterance's frames; undefined between turns. */
  private utterance: Buffer[] | undefined;
  private utteranceMs = 0;
  private silenceMs = 0;
  private lastAudioAt = 0;
  private stallTimer: ReturnType<typeof setTimeout> | undefined;
  /** Turns cut and not yet handed over, in the order they ended. */
  private readonly pending: PendingTurn[] = [];
  private readonly requests = new Set<AbortController>();
  private drainWait: (() => void) | undefined;

  constructor(private readonly options: OpenRouterLiveTranscriptionOptions) {
    this.baseUrl = (options.baseUrl ?? OPENROUTER_API_BASE).replace(/\/+$/, "");
    this.fetchFn = options.fetchFn ?? globalThis.fetch;
  }

  /** Nothing to connect: a call starts once the server has an OpenRouter credential. */
  async start(events: LiveTranscriptionEvents): Promise<void> {
    const key = (await this.options.resolveApiKey())?.trim();
    if (!key) throw new SttSessionCreateError({ category: "auth" });
    this.apiKey = key;
    this.events = events;
  }

  feedAudio(pcm: Buffer): void {
    if (this.closing || !this.events || pcm.length === 0) return;
    this.lastAudioAt = Date.now();
    let bytes = this.carry.length > 0 ? Buffer.concat([this.carry, pcm]) : pcm;
    while (bytes.length >= FRAME_BYTES) {
      // A copy: the phone's frame buffer is not ours to keep.
      this.handleFrame(Buffer.from(bytes.subarray(0, FRAME_BYTES)));
      bytes = bytes.subarray(FRAME_BYTES);
    }
    this.carry = Buffer.from(bytes);
  }

  async stop(): Promise<void> {
    if (this.closing) return;
    this.closing = true;
    this.clearStallTimer();
    // End can arrive mid-sentence: what the caller was saying still goes to the agent.
    if (this.utterance) this.cut("call_stop");
    if (this.pending.length > 0) {
      await new Promise<void>((resolve) => {
        const timer = setTimeout(() => {
          log.warn("openrouter_live_voice.drain_timeout", { pendingTurns: this.pending.length });
          resolve();
        }, this.options.drainTimeoutMs ?? DRAIN_TIMEOUT_MS);
        this.drainWait = () => {
          clearTimeout(timer);
          resolve();
        };
      });
      this.drainWait = undefined;
    }
    for (const request of this.requests) request.abort();
    this.requests.clear();
    this.events = undefined;
  }

  // ─── Turn detection ───

  private handleFrame(frame: Buffer): void {
    const db = frameDbfs(frame);
    const speech = db >= Math.max(MIN_SPEECH_DBFS, this.noiseFloorDb + SPEECH_OVER_FLOOR_DB);
    if (this.utterance) {
      this.utterance.push(frame);
      this.utteranceMs += FRAME_MS;
      this.silenceMs = speech ? 0 : this.silenceMs + FRAME_MS;
      if (this.silenceMs >= this.options.silenceDurationMs) this.cut("server_vad");
      else if (this.utteranceMs >= MAX_UTTERANCE_MS) this.cut("max_duration");
      return;
    }
    if (!speech) {
      // Follows the room: down quickly, up slowly, and only between turns.
      const rate = db < this.noiseFloorDb ? 0.3 : 0.05;
      this.noiseFloorDb += (db - this.noiseFloorDb) * rate;
    }
    this.preRoll.push(frame);
    if (this.preRoll.length > PRE_ROLL_MS / FRAME_MS) this.preRoll.shift();
    this.speechRunMs = speech ? this.speechRunMs + FRAME_MS : 0;
    if (this.speechRunMs >= MIN_SPEECH_MS) this.open();
  }

  private open(): void {
    this.utterance = this.preRoll;
    this.utteranceMs = this.preRoll.length * FRAME_MS;
    this.preRoll = [];
    this.speechRunMs = 0;
    this.silenceMs = 0;
    this.armStallTimer(this.options.silenceDurationMs);
    this.events?.speechStarted();
  }

  /** Close the open utterance and send it for transcription. */
  private cut(reason: LiveTurnEndReason): void {
    const frames = this.utterance;
    if (!frames) return;
    this.utterance = undefined;
    this.clearStallTimer();
    // Most of the closing pause is silence the recognizer does not need.
    const trailingFrames = Math.max(
      0,
      Math.floor((this.silenceMs - TRAILING_SILENCE_MS) / FRAME_MS),
    );
    const audio = Buffer.concat(frames.slice(0, frames.length - trailingFrames));
    const turn: PendingTurn = { reason, committedAt: Date.now() };
    this.pending.push(turn);
    void this.transcribe(audio).then((text) => {
      turn.text = text;
      this.deliver();
    });
  }

  /** Hand over settled turns from the front, so they reach the agent in the order spoken. */
  private deliver(): void {
    while (this.pending[0]?.text !== undefined) {
      const turn = this.pending.shift() as PendingTurn;
      this.events?.turn({
        text: turn.text ?? "",
        reason: turn.reason,
        finalMs: Date.now() - turn.committedAt,
      });
    }
    if (this.pending.length === 0) this.drainWait?.();
  }

  /**
   * Mute or hold stops the phone's audio mid-utterance; without frames the pause is never
   * counted. Cut the utterance once no audio has arrived for the same pause.
   */
  private armStallTimer(delayMs: number): void {
    this.stallTimer = setTimeout(() => {
      this.stallTimer = undefined;
      if (!this.utterance || this.closing) return;
      const quietMs = Date.now() - this.lastAudioAt;
      if (quietMs < this.options.silenceDurationMs) {
        this.armStallTimer(this.options.silenceDurationMs - quietMs);
        return;
      }
      this.cut("audio_stalled");
    }, delayMs);
  }

  private clearStallTimer(): void {
    if (this.stallTimer) clearTimeout(this.stallTimer);
    this.stallTimer = undefined;
  }

  // ─── OpenRouter ───

  /** The utterance's text, or "" when the request failed. Never throws. */
  private async transcribe(pcm: Buffer): Promise<string> {
    const request = new AbortController();
    this.requests.add(request);
    const startedAt = Date.now();
    const audioMs = Math.round(pcm.length / ((INPUT_SAMPLE_RATE * 2) / 1_000));
    try {
      const response = await this.fetchFn(`${this.baseUrl}/audio/transcriptions`, {
        method: "POST",
        headers: { Authorization: `Bearer ${this.apiKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          model: OPENROUTER_LIVE_VOICE_STT_MODEL,
          input_audio: { data: pcm16kToWav(pcm).toString("base64"), format: "wav" },
        }),
        signal: AbortSignal.any([
          request.signal,
          AbortSignal.timeout(this.options.transcriptionTimeoutMs ?? TRANSCRIPTION_TIMEOUT_MS),
        ]),
      });
      if (!response.ok) {
        log.warn("openrouter_live_voice.transcription_failed", {
          error: await errorMessage(response),
          audioMs,
        });
        return "";
      }
      const body = (await response.json()) as { text?: unknown };
      const text = typeof body.text === "string" ? body.text.trim() : "";
      // Durations only, never the words.
      log.info("openrouter_live_voice.transcribed", {
        audioMs,
        requestMs: Date.now() - startedAt,
        empty: text === "",
      });
      return text;
    } catch (error) {
      if (!request.signal.aborted) {
        log.warn("openrouter_live_voice.transcription_failed", {
          error: error instanceof Error ? error.message : String(error),
          audioMs,
        });
      }
      return "";
    } finally {
      this.requests.delete(request);
    }
  }
}

/**
 * The speaking half: one OpenRouter speech request per sentence, its PCM passed on as it
 * streams in.
 */
export class OpenRouterLiveVoiceTts implements LiveVoiceTtsPort {
  private readonly baseUrl: string;
  private readonly fetchFn: typeof globalThis.fetch;

  constructor(private readonly options: OpenRouterAudioOptions) {
    this.baseUrl = (options.baseUrl ?? OPENROUTER_API_BASE).replace(/\/+$/, "");
    this.fetchFn = options.fetchFn ?? globalThis.fetch;
  }

  async *speak(text: string, signal: AbortSignal): AsyncIterable<Buffer> {
    const key = (await this.options.resolveApiKey())?.trim();
    if (!key) throw new Error("No OpenRouter credential");
    const response = await this.fetchFn(`${this.baseUrl}/audio/speech`, {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: OPENROUTER_LIVE_VOICE_TTS_MODEL,
        voice: OPENROUTER_LIVE_VOICE_TTS_VOICE,
        input: text,
        response_format: "pcm",
      }),
      signal,
    });
    if (!response.ok) throw new Error(`OpenRouter speech failed: ${await errorMessage(response)}`);
    if (!response.body) return;
    // Network chunks can split a sample; hold the odd byte for the next one.
    let odd: Buffer | undefined;
    for await (const chunk of response.body) {
      let bytes = Buffer.from(chunk);
      if (odd) bytes = Buffer.concat([odd, bytes]);
      const even = bytes.length - (bytes.length % 2);
      odd = even < bytes.length ? bytes.subarray(even) : undefined;
      if (even > 0) yield bytes.subarray(0, even);
    }
  }
}

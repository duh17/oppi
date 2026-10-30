/**
 * Live Voice's ears: one OpenAI Realtime transcription WebSocket per call.
 *
 * `{endpoint}/v1/realtime?intent=transcription` (Yuwp's `yuwp-asr`). The client sends a
 * `session.update` (type `transcription`, PCM16 mono, semantic VAD), then streams
 * `input_audio_buffer.append`. The server's VAD cuts the audio into items: `speech_started`
 * when the caller starts, `input_audio_buffer.committed` when the pause ends the item, and
 * `conversation.item.input_audio_transcription.completed` with its punctuated final text.
 * That completed transcript is the turn. Nothing here decides when a turn ends; the server does.
 *
 * Items are ordered by commit. Transcription of one item can finish after the next item was
 * committed, so a finished item waits for the ones committed before it and turns are handed
 * over in commit order. A `failed` item is an empty turn and never stalls the ones behind it.
 * `delta` events are append-only text for the item still being heard (the stable prefix, for
 * Yuwp) and feed the caller's live caption; `completed` replaces what streamed.
 */

import { WebSocket, type RawData } from "ws";

import { createLogger } from "./logger.js";
import { SttSessionCreateError } from "./stt-provider.js";

const log = createLogger({ base: { component: "realtime_transcription" } });

/** The phone sends 16-bit mono PCM at this rate; Yuwp's realtime wire accepts it as is. */
const WIRE_SAMPLE_RATE = 16_000;
const START_TIMEOUT_MS = 10_000;
/** How long End waits for the caller's last words to be transcribed before giving up on them. */
const DRAIN_TIMEOUT_MS = 5_000;
/**
 * Yuwp closes a realtime socket that receives nothing for 15 minutes. A call that sits muted or
 * on hold sends no audio, so a ping every minute keeps the socket (and the call) open.
 */
const PING_INTERVAL_MS = 60_000;
/**
 * Audio that may wait in the socket's send buffer before frames are dropped: 5 s of PCM at the
 * wire rate, as base64 inside JSON (about 4/3 the size). A server that stops reading must not
 * grow this call's memory without bound; a few seconds of dropped speech is the lesser harm.
 */
const MAX_BUFFERED_BYTES = Math.ceil((5 * WIRE_SAMPLE_RATE * 2 * 4) / 3);
/** Yuwp rejects a `transcription.prompt` past this many UTF-8 bytes, which fails the call's start. */
const MAX_PROMPT_BYTES = 8192;
const VOCABULARY_PREFIX = "Vocabulary: ";
const VOCABULARY_SEPARATOR = ", ";

/**
 * Dictionary phrases as the realtime `transcription.prompt`, in the same `Vocabulary: a, b` form
 * Yuwp builds from dictation's `contextual_strings`. Phrases past Yuwp's prompt limit are left
 * out, in order. Undefined when nothing fits.
 */
export function vocabularyPrompt(phrases: readonly string[]): string | undefined {
  const kept: string[] = [];
  let bytes = Buffer.byteLength(VOCABULARY_PREFIX, "utf8");
  for (const phrase of phrases) {
    const cost =
      Buffer.byteLength(phrase, "utf8") +
      (kept.length > 0 ? Buffer.byteLength(VOCABULARY_SEPARATOR, "utf8") : 0);
    if (bytes + cost > MAX_PROMPT_BYTES) break;
    kept.push(phrase);
    bytes += cost;
  }
  return kept.length > 0 ? VOCABULARY_PREFIX + kept.join(VOCABULARY_SEPARATOR) : undefined;
}

/** What ended a user turn. Telemetry only. */
export type LiveTurnEndReason =
  /** Voice detection (the ASR server's, or Oppi's for OpenRouter) ended the item after the caller's pause. */
  | "server_vad"
  /** The call ended and this client cut the audio the VAD had not. */
  | "call_stop"
  /** The phone stopped sending audio mid-item (mute, hold), so this client cut the item. */
  | "audio_stalled"
  /** OpenRouter only: the item reached its length cap and was cut mid-speech. */
  | "max_duration";

/** Why the listening socket ended while the call was still running. */
export type LiveTranscriptionClosedReason = "socket_closed" | "socket_error";

export interface LiveTranscriptionEvents {
  /** The server heard the caller start talking (`input_audio_buffer.speech_started`). */
  speechStarted(): void;
  /**
   * The caller's words so far, for every item not yet handed over as a turn, joined in commit
   * order. Called when that text changes, including to "" when it drains.
   */
  partial(text: string): void;
  /**
   * One finished item, in commit order. `text` is empty for a failed or silent item: nothing
   * was said, the caller's caption should clear.
   */
  turn(turn: { text: string; reason: LiveTurnEndReason; finalMs: number | undefined }): void;
  /** The socket ended while the call was listening. Never called after `stop()`. */
  closed(reason: LiveTranscriptionClosedReason, detail: { code?: number }): void;
}

/** A call's listening half. */
export interface LiveTranscription {
  /** Connect and wait until the server accepted the session. Throws `SttSessionCreateError`. */
  start(events: LiveTranscriptionEvents): Promise<void>;
  /** Phone audio: 16 kHz, 16-bit mono PCM. */
  feedAudio(pcm: Buffer): void;
  /**
   * End of call: cut what the caller was still saying, wait (bounded) for the items in flight
   * to be transcribed and handed over, then close the socket.
   */
  stop(): Promise<void>;
}

export interface RealtimeTranscriptionOptions {
  /** `ws(s)` URL from `realtimeTranscriptionUrl`. */
  url: string;
  /**
   * The pause that ends an item on a Yuwp without semantic_vad, and how long an open item may
   * go without audio before this client cuts it (the stalled-audio guard).
   */
  silenceDurationMs: number;
  /** Dictionary phrases the recognizer should favor; sent as `vocabularyPrompt`. */
  vocabulary?: readonly string[];
  startTimeoutMs?: number;
  drainTimeoutMs?: number;
  pingIntervalMs?: number;
}

/** `http(s)://host:port[/prefix]` to the realtime transcription socket URL. */
export function realtimeTranscriptionUrl(endpoint: string): string {
  const url = new URL(endpoint.trim());
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  url.pathname = `${url.pathname.replace(/\/+$/, "").replace(/\/v1$/i, "")}/v1/realtime`;
  url.search = "?intent=transcription";
  url.hash = "";
  return url.toString();
}

interface Item {
  /** Text streamed so far. */
  partial: string;
  /** Final text; set by `completed` (replaces `partial`) or "" by `failed`. */
  result?: string;
  committedAt?: number;
  /** Cut by this client (End, or stalled audio) instead of the server's VAD. */
  cut?: "call_stop" | "audio_stalled";
}

function rawToString(data: RawData): string {
  if (Array.isArray(data)) return Buffer.concat(data).toString("utf8");
  return Buffer.isBuffer(data) ? data.toString("utf8") : Buffer.from(data).toString("utf8");
}

/** `session.audio.input.transcription.prompt` of the server's effective session, if any. */
function echoedPrompt(event: Record<string, unknown>): unknown {
  return echoedInput(event)?.transcription?.prompt;
}

/** The turn detection the server applied, as its type string; undefined when not echoed. */
function echoedTurnDetection(event: Record<string, unknown>): string | undefined {
  const type = echoedInput(event)?.turn_detection?.type;
  return typeof type === "string" ? type : undefined;
}

type EchoedInput = {
  transcription?: { prompt?: unknown };
  turn_detection?: { type?: unknown } | null;
};

/** `session.audio.input` of the server's effective session (`session.updated`). */
function echoedInput(event: Record<string, unknown>): EchoedInput | undefined {
  return (event.session as { audio?: { input?: EchoedInput } } | undefined)?.audio?.input;
}

function parseEvent(data: RawData): Record<string, unknown> | undefined {
  try {
    const parsed: unknown = JSON.parse(rawToString(data));
    if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>;
    }
  } catch {
    // A frame that is not JSON carries nothing for us.
  }
  return undefined;
}

export class RealtimeTranscriptionClient implements LiveTranscription {
  private socket: WebSocket | undefined;
  private events: LiveTranscriptionEvents | undefined;
  private ready = false;
  private readonly prompt: string | undefined;
  /** `stop()`, a failed start, or a close already reported: the socket ending is not a call event. */
  private closing = false;
  private socketErrored = false;
  private audioQueue: Buffer[] = [];
  /** Items by id, in the order first heard. Delivered items leave the map. */
  private readonly items = new Map<string, Item>();
  /** Committed items, not yet delivered, in commit order. */
  private readonly order: string[] = [];
  /**
   * Commits this client sent that the server has not answered, oldest first. The server answers
   * each with a `committed` (an item was cut) or a commit_empty error (nothing was open), in
   * order, so each answer takes the oldest entry. A VAD commit that lands between ours cannot be
   * told apart and takes an entry too; that can only mislabel a turn's end reason.
   */
  private readonly pendingCommits: Array<"call_stop" | "audio_stalled"> = [];
  /**
   * An item is open: the server heard speech start and has not committed it. Yuwp's VAD ends an
   * item only on audio that keeps arriving, so this is what the stalled-audio guard watches.
   */
  private itemOpen = false;
  private itemOpenedAt = 0;
  private lastAudioAt = 0;
  private starveTimer: ReturnType<typeof setTimeout> | undefined;
  private pingTimer: ReturnType<typeof setInterval> | undefined;
  /** Frames are being dropped because the socket's send buffer is full. */
  private droppingAudio = false;
  private droppedFrames = 0;
  private startWait:
    { resolve: () => void; reject: (error: SttSessionCreateError) => void } | undefined;
  private startTimer: ReturnType<typeof setTimeout> | undefined;
  private drainWait: (() => void) | undefined;

  constructor(private readonly options: RealtimeTranscriptionOptions) {
    this.prompt = vocabularyPrompt(options.vocabulary ?? []);
  }

  async start(events: LiveTranscriptionEvents): Promise<void> {
    this.events = events;
    const socket = new WebSocket(this.options.url);
    this.socket = socket;
    const prompt = this.prompt;
    socket.on("open", () => {
      this.send({
        type: "session.update",
        session: {
          type: "transcription",
          audio: {
            input: {
              format: { type: "audio/pcm", rate: WIRE_SAMPLE_RATE },
              ...(prompt ? { transcription: { prompt } } : {}),
              // Yuwp scores each pause with Smart Turn and waits longer when the caller sounds
              // mid-thought (`auto` = `medium`, up to 4 s). A Yuwp from before semantic_vad
              // reads this as server_vad, so `silence_duration_ms` keeps its pause from
              // falling to Yuwp's 500 ms default; semantic_vad ignores it.
              turn_detection: {
                type: "semantic_vad",
                eagerness: "auto",
                silence_duration_ms: this.options.silenceDurationMs,
              },
            },
          },
        },
      });
    });
    socket.on("message", (data) => this.handleMessage(data));
    socket.on("unexpected-response", (_request, response) => {
      const status = response.statusCode;
      this.failStart(
        status === 401 || status === 403
          ? new SttSessionCreateError({ category: "auth" })
          : new SttSessionCreateError({ category: "http_error", status }),
      );
      socket.terminate();
    });
    socket.on("error", (error) => {
      this.socketErrored = true;
      if (!this.ready && !this.closing) {
        log.warn("realtime_transcription.connect_failed", { error: error.message });
      }
    });
    socket.on("close", (code) => this.handleClose(code));

    await new Promise<void>((resolve, reject) => {
      this.startWait = { resolve, reject };
      this.startTimer = setTimeout(() => {
        this.startTimer = undefined;
        this.failStart(new SttSessionCreateError({ category: "network" }));
        socket.terminate();
      }, this.options.startTimeoutMs ?? START_TIMEOUT_MS);
    });
  }

  feedAudio(pcm: Buffer): void {
    if (this.closing || pcm.length === 0) return;
    this.lastAudioAt = Date.now();
    if (this.ready) this.append(pcm);
    else this.audioQueue.push(pcm);
  }

  async stop(): Promise<void> {
    const socket = this.socket;
    if (this.closing || !socket) return;
    if (!this.ready || socket.readyState !== WebSocket.OPEN) {
      this.failStart(new SttSessionCreateError({ category: "network" }));
      this.closeSocket();
      return;
    }
    // From here the socket closing is ours; no more audio goes out.
    this.closing = true;
    this.clearStarveTimer();
    // Cuts whatever the server VAD has not: the words the caller was still saying.
    this.pendingCommits.push("call_stop");
    this.send({ type: "input_audio_buffer.commit" });
    await new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        log.warn("realtime_transcription.drain_timeout", { pendingItems: this.order.length });
        resolve();
      }, this.options.drainTimeoutMs ?? DRAIN_TIMEOUT_MS);
      this.drainWait = () => {
        clearTimeout(timer);
        resolve();
      };
      this.maybeDrained();
    });
    this.drainWait = undefined;
    this.closeSocket();
  }

  // ─── Wire ───

  private send(event: Record<string, unknown>): void {
    const socket = this.socket;
    if (socket?.readyState !== WebSocket.OPEN) return;
    socket.send(JSON.stringify(event));
  }

  private append(pcm: Buffer): void {
    const buffered = this.socket?.bufferedAmount ?? 0;
    if (buffered > MAX_BUFFERED_BYTES) {
      this.droppedFrames += 1;
      if (!this.droppingAudio) {
        this.droppingAudio = true;
        log.warn("realtime_transcription.audio_backpressure", { bufferedBytes: buffered });
      }
      return;
    }
    if (this.droppingAudio) {
      this.droppingAudio = false;
      log.info("realtime_transcription.audio_backpressure_cleared", {
        droppedFrames: this.droppedFrames,
      });
      this.droppedFrames = 0;
    }
    this.send({ type: "input_audio_buffer.append", audio: pcm.toString("base64") });
  }

  private handleMessage(data: RawData): void {
    const event = parseEvent(data);
    if (!event) return;
    const itemId = typeof event.item_id === "string" ? event.item_id : undefined;
    switch (event.type) {
      case "session.updated": {
        if (this.ready) return;
        this.ready = true;
        // Counts only: dictionary phrases are private vocabulary.
        log.info("realtime_transcription.session_ready", {
          // `semantic_vad`, or `server_vad` from a Yuwp that predates it.
          turnDetection: echoedTurnDetection(event),
          vocabularyPhrases: this.options.vocabulary?.length ?? 0,
          promptApplied: this.prompt !== undefined && echoedPrompt(event) === this.prompt,
        });
        // Audio fed while the session was being accepted goes first, in order.
        for (const chunk of this.audioQueue) this.append(chunk);
        this.audioQueue = [];
        this.clearStartTimer();
        this.startWait?.resolve();
        this.startWait = undefined;
        this.startPing();
        return;
      }
      case "input_audio_buffer.speech_started":
        this.itemOpen = true;
        this.itemOpenedAt = Date.now();
        this.armStarveTimer(this.options.silenceDurationMs);
        this.events?.speechStarted();
        return;
      case "input_audio_buffer.committed": {
        if (!itemId) return;
        const item = this.item(itemId);
        item.committedAt = Date.now();
        this.itemOpen = false;
        item.cut = this.pendingCommits.shift();
        if (!this.order.includes(itemId)) this.order.push(itemId);
        this.deliver();
        this.maybeDrained();
        return;
      }
      case "conversation.item.input_audio_transcription.delta":
        if (!itemId || typeof event.delta !== "string") return;
        this.item(itemId).partial += event.delta;
        this.emitPartial();
        return;
      case "conversation.item.input_audio_transcription.completed":
        if (!itemId) return;
        this.item(itemId).result =
          typeof event.transcript === "string" ? event.transcript.trim() : "";
        this.settle();
        return;
      case "conversation.item.input_audio_transcription.failed":
        if (!itemId) return;
        // Nothing was transcribed: an empty item, so the ones behind it are not held up.
        this.item(itemId).result = "";
        this.settle();
        return;
      case "error": {
        const error = (event.error ?? {}) as { code?: unknown; type?: unknown };
        const code = typeof error.code === "string" ? error.code : undefined;
        if (!this.ready) {
          log.warn("realtime_transcription.session_rejected", { code });
          this.failStart(new SttSessionCreateError({ category: "invalid_response" }));
          this.socket?.terminate();
        } else if (code === "input_audio_buffer_commit_empty") {
          // Expected whenever a commit of ours found nothing left to cut (the VAD committed
          // everything the caller said first); never worth a log line.
          this.pendingCommits.shift();
          this.maybeDrained();
        } else {
          // The session stays open.
          log.warn("realtime_transcription.event_error", { code });
        }
        return;
      }
      default:
        return;
    }
  }

  private item(id: string): Item {
    let item = this.items.get(id);
    if (!item) {
      item = { partial: "" };
      this.items.set(id, item);
    }
    return item;
  }

  private settle(): void {
    this.deliver();
    this.emitPartial();
    this.maybeDrained();
  }

  /** Hand over finished items from the front of the commit order. */
  private deliver(): void {
    while (this.order.length > 0) {
      const id = this.order[0] as string;
      const item = this.items.get(id);
      if (item?.result === undefined) return;
      this.order.shift();
      this.items.delete(id);
      this.events?.turn({
        text: item.result,
        reason: item.cut ?? "server_vad",
        finalMs: item.committedAt === undefined ? undefined : Date.now() - item.committedAt,
      });
    }
  }

  private emitPartial(): void {
    const parts: string[] = [];
    for (const item of this.items.values()) {
      const text = (item.result ?? item.partial).trim();
      if (text) parts.push(text);
    }
    this.events?.partial(parts.join(" "));
  }

  // ─── Lifecycle ───

  private maybeDrained(): void {
    // End is done when its own commit was answered (stall commits ahead of it answer first)
    // and every item cut so far has been handed over.
    if (this.drainWait && !this.pendingCommits.includes("call_stop") && this.order.length === 0) {
      this.drainWait();
    }
  }

  /**
   * Audio-starvation guard, not a speech timer: the server's VAD ends an item only on frames
   * that keep arriving, so when the phone stops sending audio mid-item (mute, hold) the item
   * would stay open until the caller returns. If no audio frame arrives for the same pause the
   * VAD would have needed, cut the item once; a commit_empty answer means it had already ended.
   * While audio keeps flowing the VAD alone decides and this never fires.
   */
  private armStarveTimer(delayMs: number): void {
    if (this.starveTimer) return;
    this.starveTimer = setTimeout(() => {
      this.starveTimer = undefined;
      if (!this.itemOpen || this.closing) return;
      const quietMs = Date.now() - Math.max(this.lastAudioAt, this.itemOpenedAt);
      if (quietMs < this.options.silenceDurationMs) {
        this.armStarveTimer(this.options.silenceDurationMs - quietMs);
        return;
      }
      this.itemOpen = false;
      this.pendingCommits.push("audio_stalled");
      log.info("realtime_transcription.audio_stalled_commit", { quietMs });
      this.send({ type: "input_audio_buffer.commit" });
    }, delayMs);
  }

  private clearStarveTimer(): void {
    if (this.starveTimer) clearTimeout(this.starveTimer);
    this.starveTimer = undefined;
  }

  private startPing(): void {
    this.pingTimer = setInterval(() => {
      if (this.socket?.readyState === WebSocket.OPEN) this.socket.ping();
    }, this.options.pingIntervalMs ?? PING_INTERVAL_MS);
  }

  /** Timers that run while the socket is up. Every close path ends them. */
  private clearSocketTimers(): void {
    if (this.droppingAudio) {
      // The episode ends with the socket; say how much it cost (counts only).
      log.warn("realtime_transcription.audio_dropped_at_close", {
        droppedFrames: this.droppedFrames,
      });
      this.droppingAudio = false;
      this.droppedFrames = 0;
    }
    this.clearStarveTimer();
    if (this.pingTimer) clearInterval(this.pingTimer);
    this.pingTimer = undefined;
  }

  private failStart(error: SttSessionCreateError): void {
    this.clearStartTimer();
    const wait = this.startWait;
    this.startWait = undefined;
    if (!wait) return;
    this.closing = true;
    wait.reject(error);
  }

  private clearStartTimer(): void {
    if (this.startTimer) clearTimeout(this.startTimer);
    this.startTimer = undefined;
  }

  private closeSocket(): void {
    this.closing = true;
    this.clearSocketTimers();
    this.audioQueue = [];
    this.socket?.close();
  }

  private handleClose(code: number): void {
    this.clearSocketTimers();
    if (this.startWait) {
      this.failStart(new SttSessionCreateError({ category: "network" }));
      return;
    }
    // Whoever is waiting on the drain must not wait for items that can no longer arrive.
    this.drainWait?.();
    if (this.closing) return;
    this.closing = true;
    const reason: LiveTranscriptionClosedReason = this.socketErrored
      ? "socket_error"
      : "socket_closed";
    log.warn("realtime_transcription.closed", { reason, code, inFlightItems: this.items.size });
    this.events?.closed(reason, { code });
  }
}

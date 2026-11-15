/**
 * STT provider interface and implementations.
 *
 * Single interface: SttProvider (streaming).
 * Lifecycle: start() → feedAudio()* → onToken() → stop() → final text
 *
 * StreamingSttProvider talks to any server implementing the stateful
 * session API (see docs/asr.md). The API was designed alongside
 * any Yuwp-compatible streaming session endpoint (not tied to a specific backend).
 */

import { createLogger } from "./logger.js";

// ─── Interface ───

/**
 * Streaming transcript update forwarded from the upstream STT backend.
 *
 * `text` is the full visible transcript. When available, `committedText` and
 * `activeText` preserve Yuwp's segment-commit split so downstream clients can
 * render settled vs. volatile text without guessing.
 */
export interface SttTranscriptUpdate {
  text: string;
  snap?: boolean;
  committedText?: string;
  activeText?: string;
}

/** Final transcript payload returned when the backend session is closed. */
export interface SttFinalTranscript {
  text: string;
  committedText?: string;
  activeText?: string;
  /** Set when the text may miss part of the take; the text is still the best one known. */
  incomplete?: SttIncompleteReason;
}

/**
 * Why a take's final transcript may miss speech:
 * - `stt_final_incomplete`: the backend did not return a final (timeout, error, lost session),
 *   so the text is the last streaming partial.
 * - `stt_audio_lost`: an audio upload kept failing past its retries, so the backend never
 *   heard part of the take.
 * The values double as the `error_kind` telemetry tag.
 */
export type SttIncompleteReason = "stt_final_incomplete" | "stt_audio_lost";

/** Immutable per-take vocabulary forwarded to the STT backend. */
export interface SttStartOptions {
  readonly contextualStrings?: readonly string[];
}

/** Result of creating the upstream streaming session for this take. */
export interface SttStartResult {
  /** True only when the backend acknowledged consuming this take's hints. */
  contextApplied: boolean;
}

/**
 * Streaming STT provider. Audio is piped incrementally and transcript
 * updates arrive via callback as they're produced.
 *
 * Lifecycle: start() → feedAudio()* → onToken() callbacks → stop() → final text
 */
export interface SttProvider {
  /** Provider identifier for logs/metrics. */
  readonly name: string;
  /** Model identifier: the one the backend reports when it does, else the configured one. */
  readonly model: string;
  /** Audio uploads retried during the current or last take, when the provider retries them. */
  readonly audioRetries?: number;
  /** Spawn the STT process / prepare for audio input. Throws if the backend is unreachable. */
  start(options?: SttStartOptions): Promise<SttStartResult>;
  /** Write raw PCM audio (s16le, 16kHz, mono). */
  feedAudio(pcm: Buffer): void;
  /** Register callback for transcript updates (full replacement text each time). */
  onToken(cb: (update: SttTranscriptUpdate) => void): void;
  /**
   * Close audio input, wait for completion, return full final text. When the text
   * may miss speech it is still returned, marked `incomplete`, never passed off as whole.
   */
  stop(): Promise<SttFinalTranscript>;
  /** Clean up provider resources (e.g. remote sessions). Call on shutdown. */
  dispose?(): Promise<void>;
}

// ─── Streaming Session Provider ───

export interface StreamingSttOptions {
  /** Base URL of the STT server. */
  endpoint: string;
  /** Model identifier sent to the backend. */
  model: string;
}

export type SttSessionCreateErrorCategory = "http_error" | "invalid_response" | "network" | "auth";

/**
 * What the user reads when speech recognition cannot start. Dictation and Live Voice pass
 * a create failure's message to the phone as is, so it is plain copy, not a diagnostic.
 */
function sttSessionCreateMessage(category: SttSessionCreateErrorCategory, status?: number): string {
  switch (category) {
    case "network":
      return "Speech recognition is unavailable. Check that the speech service is running, then try again.";
    case "auth":
      return "Speech recognition was not accepted by the speech service. Check its credentials, then try again.";
    case "http_error":
      return `Speech recognition could not start${status !== undefined ? ` (HTTP ${status})` : ""}. Try again.`;
    case "invalid_response":
      return "Speech recognition got an unexpected reply from the speech service. Check that it is up to date.";
  }
}

/** Bounded create failure. Never includes upstream bodies, parser text, or hints. */
export class SttSessionCreateError extends Error {
  readonly status: number | undefined;
  readonly category: SttSessionCreateErrorCategory;

  constructor(opts: { category: SttSessionCreateErrorCategory; status?: number }) {
    super(sttSessionCreateMessage(opts.category, opts.status));
    this.name = "SttSessionCreateError";
    this.category = opts.category;
    this.status = opts.status;
  }
}

/**
 * Streaming STT via stateful session endpoints.
 *
 * Talks to any server implementing the streaming session API:
 *   POST   {endpoint}/v1/audio/transcriptions/stream       → create session
 *   POST   {endpoint}/v1/audio/transcriptions/stream/:id   → feed audio chunk
 *   DELETE  {endpoint}/v1/audio/transcriptions/stream/:id   → stop, get final text
 *
 * Uses encoder window caching + decoder KV reuse for O(1) per-chunk latency.
 * Compatible with any streaming STT endpoint that implements the session API.
 */
const log = createLogger({ base: { component: "stt_provider" } });

function parseSttCreateEnvelope(
  data: unknown,
  sentHints: boolean,
): { sessionId: string; contextApplied: boolean } {
  if (typeof data !== "object" || data === null || Array.isArray(data)) {
    throw new SttSessionCreateError({ category: "invalid_response" });
  }
  const record = data as Record<string, unknown>;
  if (typeof record.session_id !== "string" || record.session_id.length === 0) {
    throw new SttSessionCreateError({ category: "invalid_response" });
  }
  if (record.context_applied !== undefined && typeof record.context_applied !== "boolean") {
    throw new SttSessionCreateError({ category: "invalid_response" });
  }
  return {
    sessionId: record.session_id,
    contextApplied: sentHints && record.context_applied === true,
  };
}

// Keep the server proxy behaviorally close to direct Yuwp usage.
// Large batching here adds noticeable pause-to-commit lag even on localhost.
const DEFAULT_FEED_INTERVAL_MS = 200;

/** 200ms of s16le 16kHz mono. Yuwp E7 peeks first-text only while pending is in [0.9s, 1.2s]. */
const STARTUP_FEED_MAX_BYTES = 6400;
/** Leave startup after this much audio is successfully forwarded, even if Yuwp text stays empty. */
const STARTUP_EXIT_FORWARDED_BYTES = 48_000;
/** Retries for one unsent chunk before the take stops uploading and is marked incomplete. */
const MAX_FEED_RETRIES = 3;

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Take up to `maxBytes` from the front of `queue`, leaving any remainder in place and in order. */
function takeQueuedBytes(queue: Buffer[], maxBytes: number): Buffer {
  const chunks: Buffer[] = [];
  let remaining = maxBytes;
  while (queue.length > 0 && remaining > 0) {
    const head = queue[0];
    if (!head) break;
    if (head.length <= remaining) {
      chunks.push(head);
      remaining -= head.length;
      queue.shift();
    } else {
      chunks.push(head.subarray(0, remaining));
      queue[0] = head.subarray(remaining);
      remaining = 0;
    }
  }
  if (chunks.length === 0) return Buffer.alloc(0);
  const only = chunks[0];
  if (chunks.length === 1 && only) return only;
  return Buffer.concat(chunks);
}

export class StreamingSttProvider implements SttProvider {
  /** Constant: it reaches telemetry tags and the client, so it never carries the endpoint host. */
  readonly name = "streaming";
  readonly endpoint: string;
  /** Model requested on session create. Yuwp serves whatever it loaded, regardless. */
  private readonly configuredModel: string;
  /** Model id from the engine's `GET /v1/info`, refreshed each take. */
  private engineModel: string | undefined;
  private fetchFn: typeof globalThis.fetch;
  private sessionId: string | null = null;
  private tokenCb: ((update: SttTranscriptUpdate) => void) | null = null;
  private lastText = "";
  /**
   * Last preview signature emitted to the client.
   * Includes committed/active split when the backend provides it so a
   * segment-commit can still surface even when the visible text is unchanged.
   */
  private lastPreviewSignature: string | null = null;
  private audioQueue: Buffer[] = [];
  private feeding = false;
  private stopped = false;
  private feedTimer: ReturnType<typeof setInterval> | null = null;
  private inFlightFlush: Promise<boolean> | null = null;
  /** Max time audio may sit in the proxy queue before forwarding upstream. */
  private feedIntervalMs: number;
  /** True until the first nonempty transcript or 1.5s of successfully forwarded audio. */
  private startupFeed = true;
  /** Bytes accepted by Yuwp during startup. Failed feeds are requeued, not counted. */
  private forwardedStartupBytes = 0;
  /** Failed uploads of the chunk now at the front of the queue. */
  private consecutiveFeedFailures = 0;
  /** Retried uploads this take, for telemetry. */
  private retriedFeeds = 0;
  /** A chunk exhausted its retries or the session could not be recreated: the take misses audio. */
  private audioLost = false;
  /** Frozen vocabulary for the current take. Never reused across different hints. */
  private takeContextualStrings: readonly string[] | undefined;
  private contextApplied = false;

  constructor(
    opts: StreamingSttOptions,
    fetchFn: typeof globalThis.fetch = globalThis.fetch,
    feedIntervalMs = DEFAULT_FEED_INTERVAL_MS,
  ) {
    this.endpoint = opts.endpoint;
    this.configuredModel = opts.model;
    this.fetchFn = fetchFn;
    this.feedIntervalMs = feedIntervalMs;
  }

  get model(): string {
    return this.engineModel ?? this.configuredModel;
  }

  get audioRetries(): number {
    return this.retriedFeeds;
  }

  async start(options?: SttStartOptions): Promise<SttStartResult> {
    // Cleanup existing active session if start() called again without stop()
    if (this.sessionId) {
      void this.deleteSession(this.sessionId);
      this.sessionId = null;
    }
    if (this.feedTimer) {
      clearInterval(this.feedTimer);
      this.feedTimer = null;
    }

    this.lastText = "";
    this.lastPreviewSignature = null;
    this.audioQueue = [];
    this.feeding = false;
    this.inFlightFlush = null;
    this.stopped = false;
    this.startupFeed = true;
    this.forwardedStartupBytes = 0;
    this.consecutiveFeedFailures = 0;
    this.retriedFeeds = 0;
    this.audioLost = false;
    this.contextApplied = false;
    this.takeContextualStrings =
      options?.contextualStrings && options.contextualStrings.length > 0
        ? Object.freeze([...options.contextualStrings])
        : undefined;

    // The info read runs beside the create so it adds no setup latency.
    await Promise.all([this.createSession(), this.refreshEngineModel()]);

    // stop()/cancel() landed while the create was in flight and saw no session to close;
    // release the new one instead of orphaning it with a feed timer.
    if (this.stopped && this.sessionId) {
      void this.deleteSession(this.sessionId);
      this.sessionId = null;
      return { contextApplied: this.contextApplied };
    }

    if (!this.sessionId) {
      throw new SttSessionCreateError({ category: "invalid_response" });
    }

    this.feedTimer = setInterval(() => void this.flushAudio(), this.feedIntervalMs);
    return { contextApplied: this.contextApplied };
  }

  feedAudio(pcm: Buffer): void {
    // After lost audio nothing more can reach the backend; buffering would only grow memory.
    if (this.stopped || this.audioLost) return;
    this.audioQueue.push(pcm);
    // First startup audio must not wait for the coalesce timer; a large iOS
    // dictation_ready dump would otherwise land as one >=1.5s Yuwp POST.
    // A chunk awaiting retry waits for the timer so retries stay spaced.
    if (this.startupFeed && this.sessionId && this.consecutiveFeedFailures === 0) {
      void this.flushAudio();
    }
  }

  onToken(cb: (update: SttTranscriptUpdate) => void): void {
    this.tokenCb = cb;
  }

  async stop(): Promise<SttFinalTranscript> {
    this.stopped = true;
    if (this.feedTimer) {
      clearInterval(this.feedTimer);
      this.feedTimer = null;
    }

    // Flush remaining audio and wait for any in-flight feed request before
    // closing the upstream session. Without this, dictation_stop can race a
    // POST already carrying microphone audio and DELETE the session first.
    if (this.sessionId) {
      await this.drainAudioQueue();
    }

    const sessionId = this.sessionId;
    this.sessionId = null;
    this.inFlightFlush = null;
    this.takeContextualStrings = undefined;
    this.contextApplied = false;

    // Lost audio still keeps what the backend heard: its final when the session
    // lives, else the last partial.
    const audioLost: SttIncompleteReason | undefined = this.audioLost
      ? "stt_audio_lost"
      : undefined;
    if (!sessionId) {
      return audioLost ? { text: this.lastText, incomplete: audioLost } : { text: this.lastText };
    }

    // Stop session and get final text. Anything short of the backend's own final
    // leaves only the last partial, which may miss the tail of the take.
    let data: { text?: string; committed_text?: string; active_text?: string };
    try {
      const res = await this.fetchFn(`${this.basePath}/${sessionId}`, {
        method: "DELETE",
        signal: AbortSignal.timeout(10_000),
      });
      if (!res.ok) {
        await res.arrayBuffer().catch(() => undefined);
        throw new Error(`HTTP ${res.status}`);
      }
      data = (await res.json()) as typeof data;
    } catch (err) {
      log.warn("stt.final.failed", {
        sessionId,
        error: err instanceof Error ? err.message : String(err),
      });
      return { text: this.lastText, incomplete: audioLost ?? "stt_final_incomplete" };
    }
    this.lastText = data.text ?? this.lastText;
    const result: SttFinalTranscript = { text: this.lastText };
    if (data.committed_text !== undefined) result.committedText = data.committed_text;
    if (data.active_text !== undefined) result.activeText = data.active_text;
    if (audioLost) result.incomplete = audioLost;
    return result;
  }

  /** Cleanup all sessions. Call on server shutdown. */
  async dispose(): Promise<void> {
    this.stopped = true;
    if (this.feedTimer) {
      clearInterval(this.feedTimer);
      this.feedTimer = null;
    }

    if (this.sessionId) {
      await this.deleteSession(this.sessionId);
      this.sessionId = null;
    }
    this.takeContextualStrings = undefined;
    this.contextApplied = false;
  }

  // ─── Internal ───

  /** Base path for streaming session endpoints. */
  private get basePath(): string {
    return `${this.endpoint}/v1/audio/transcriptions/stream`;
  }

  /** DELETE a session. Best-effort, logs errors. */
  private async deleteSession(id: string): Promise<void> {
    try {
      await this.fetchFn(`${this.basePath}/${id}`, {
        method: "DELETE",
        signal: AbortSignal.timeout(5_000),
      });
    } catch (err) {
      log.warn("stt.session_delete.failed", {
        sessionId: id,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }

  /** Build the JSON body for session creation (model + optional stream_config). */
  private sessionCreateBody(): string {
    const body: Record<string, unknown> = { model: this.configuredModel };
    const streamConfig: Record<string, unknown> = {};
    if (this.takeContextualStrings && this.takeContextualStrings.length > 0) {
      streamConfig.contextual_strings = [...this.takeContextualStrings];
    }
    if (Object.keys(streamConfig).length > 0) body.stream_config = streamConfig;
    return JSON.stringify(body);
  }

  /** Read the engine's loaded model id. A failed read keeps the last known id. */
  private async refreshEngineModel(): Promise<void> {
    try {
      const res = await this.fetchFn(`${this.endpoint}/v1/info`, {
        signal: AbortSignal.timeout(2_000),
      });
      if (!res.ok) {
        await res.arrayBuffer().catch(() => undefined);
        return;
      }
      const data = (await res.json()) as unknown;
      const model =
        typeof data === "object" && data !== null
          ? (data as Record<string, unknown>).model
          : undefined;
      if (typeof model === "string" && model.trim().length > 0) {
        this.engineModel = model.trim();
      }
    } catch {
      // Older engines without /v1/info keep the configured label.
    }
  }

  private async createSession(): Promise<void> {
    if (this.stopped) return;
    const sentHints =
      this.takeContextualStrings !== undefined && this.takeContextualStrings.length > 0;
    let res: Response;
    try {
      res = await this.fetchFn(this.basePath, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: this.sessionCreateBody(),
        signal: AbortSignal.timeout(10_000),
      });
    } catch {
      throw new SttSessionCreateError({ category: "network" });
    }
    if (!res.ok) {
      await res.arrayBuffer().catch(() => undefined);
      throw new SttSessionCreateError({ category: "http_error", status: res.status });
    }
    let data: unknown;
    try {
      data = await res.json();
    } catch {
      throw new SttSessionCreateError({ category: "invalid_response", status: res.status });
    }
    const parsed = parseSttCreateEnvelope(data, sentHints);
    this.sessionId = parsed.sessionId;
    this.contextApplied = parsed.contextApplied;
  }

  private async drainAudioQueue(): Promise<void> {
    while (this.sessionId && !this.audioLost) {
      if (this.inFlightFlush) {
        await this.inFlightFlush;
        continue;
      }
      if (this.audioQueue.length === 0) return;
      // Space retries like the live feed timer would, so a brief blip can recover.
      if (this.consecutiveFeedFailures > 0) await delay(this.feedIntervalMs);
      await this.flushAudio();
    }
  }

  private shouldDrainImmediately(): boolean {
    return this.startupFeed || this.stopped;
  }

  private dequeueFlushPcm(): Buffer {
    if (this.stopped || !this.startupFeed) {
      const pcm = Buffer.concat(this.audioQueue);
      this.audioQueue = [];
      return pcm;
    }
    return takeQueuedBytes(this.audioQueue, STARTUP_FEED_MAX_BYTES);
  }

  private async flushAudio(): Promise<void> {
    if (this.inFlightFlush) {
      await this.inFlightFlush;
      if (!this.shouldDrainImmediately()) return;
    }

    while (this.sessionId && this.audioQueue.length > 0) {
      if (this.inFlightFlush) {
        await this.inFlightFlush;
        if (!this.shouldDrainImmediately()) return;
        continue;
      }
      if (this.feeding || !this.sessionId || this.audioQueue.length === 0) return;

      const flush = this.flushAudioOnce();
      this.inFlightFlush = flush;
      let delivered: boolean;
      try {
        delivered = await flush;
      } finally {
        if (this.inFlightFlush === flush) {
          this.inFlightFlush = null;
        }
      }

      // A failed chunk waits for the next timer tick (or stop's spaced drain).
      if (!delivered || !this.shouldDrainImmediately()) return;
    }
  }

  /**
   * Put an undelivered chunk back at the front of the queue for the next flush.
   * After MAX_FEED_RETRIES the take is marked as missing audio and feeding stops.
   */
  private requeueFailedChunk(pcm: Buffer, reason: string): void {
    this.consecutiveFeedFailures += 1;
    if (this.consecutiveFeedFailures > MAX_FEED_RETRIES) {
      log.warn("stt.feed.audio_lost", { attempts: this.consecutiveFeedFailures, reason });
      this.markAudioLost();
      return;
    }
    this.retriedFeeds += 1;
    this.audioQueue.unshift(pcm);
  }

  private markAudioLost(): void {
    this.audioLost = true;
    this.audioQueue = [];
    if (this.feedTimer) {
      clearInterval(this.feedTimer);
      this.feedTimer = null;
    }
  }

  /** One upload. Resolves true when the backend accepted the chunk (or there was none). */
  private async flushAudioOnce(): Promise<boolean> {
    this.feeding = true;

    try {
      const pcm = this.dequeueFlushPcm();
      if (pcm.length === 0) return true;

      let res: Response;
      try {
        res = await this.fetchFn(`${this.basePath}/${this.sessionId}`, {
          method: "POST",
          headers: { "Content-Type": "application/octet-stream" },
          body: new Uint8Array(pcm),
          signal: AbortSignal.timeout(10_000),
        });
      } catch (err) {
        const error = err instanceof Error ? err.message : String(err);
        log.warn("stt.feed.failed", { error });
        this.requeueFailedChunk(pcm, error);
        return false;
      }

      if (res.ok) {
        this.consecutiveFeedFailures = 0;
        if (this.startupFeed) {
          this.forwardedStartupBytes += pcm.length;
        }
        const data = (await res.json()) as {
          text?: string;
          batch_corrected?: boolean;
          committed_text?: string;
          active_text?: string;
        } & Record<string, unknown>;
        const text = (data.text ?? "").trim();
        if (
          this.startupFeed &&
          (text.length > 0 || this.forwardedStartupBytes >= STARTUP_EXIT_FORWARDED_BYTES)
        ) {
          this.startupFeed = false;
        }
        const snap = data.batch_corrected === true;
        const committedText = data.committed_text?.trim();
        const activeText = data.active_text?.trim();
        const signature =
          committedText !== undefined || activeText !== undefined
            ? JSON.stringify([text, committedText ?? "", activeText ?? ""])
            : JSON.stringify([text, snap]);

        if (text && signature !== this.lastPreviewSignature) {
          this.lastText = text;
          this.lastPreviewSignature = signature;
          this.tokenCb?.({
            text,
            ...(snap ? { snap: true } : {}),
            ...(committedText !== undefined ? { committedText } : {}),
            ...(activeText !== undefined ? { activeText } : {}),
          });
        }
        return true;
      }

      await res.arrayBuffer().catch(() => undefined);
      this.requeueFailedChunk(pcm, `HTTP ${res.status}`);
      if (res.status === 404 && !this.audioLost) {
        // Stale session — server likely restarted. The chunk goes to the new
        // session; its empty pending audio restarts the startup byte budget.
        log.warn("stt.session_not_found_recreating", {
          sessionId: this.sessionId,
          status: res.status,
        });
        this.sessionId = null;
        try {
          await this.createSession();
        } catch (err) {
          log.warn("stt.session_recreate.failed", {
            error: err instanceof Error ? err.message : String(err),
          });
        }
        // No session (failed, or stop already began) leaves the requeued chunk nowhere to go.
        if (this.sessionId) {
          this.startupFeed = true;
          this.forwardedStartupBytes = 0;
          // The new session's first text starts a new transcript, even if it repeats the old one.
          this.lastPreviewSignature = null;
        } else {
          this.markAudioLost();
        }
      }
      return false;
    } catch (err) {
      // The backend accepted the chunk but its reply was unreadable; the audio is not replayed.
      log.warn("stt.feed.response_invalid", {
        error: err instanceof Error ? err.message : String(err),
      });
      return true;
    } finally {
      this.feeding = false;
    }
  }
}

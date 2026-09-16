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
}

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
  /** Model identifier. */
  readonly model: string;
  /** Spawn the STT process / prepare for audio input. Throws if the backend is unreachable. */
  start(options?: SttStartOptions): Promise<SttStartResult>;
  /** Write raw PCM audio (s16le, 16kHz, mono). */
  feedAudio(pcm: Buffer): void;
  /** Register callback for transcript updates (full replacement text each time). */
  onToken(cb: (update: SttTranscriptUpdate) => void): void;
  /** Close audio input, wait for completion, return full final text. */
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

/** Bounded create failure. Never includes upstream bodies, parser text, or hints. */
export class SttSessionCreateError extends Error {
  readonly status: number | undefined;
  readonly category: SttSessionCreateErrorCategory;

  constructor(opts: { category: SttSessionCreateErrorCategory; status?: number }) {
    const statusPart = opts.status !== undefined ? ` HTTP ${opts.status}` : "";
    super(`STT session create failed:${statusPart} (${opts.category})`);
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
  readonly name: string;
  readonly model: string;
  readonly endpoint: string;
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
  private inFlightFlush: Promise<void> | null = null;
  /** Max time audio may sit in the proxy queue before forwarding upstream. */
  private feedIntervalMs: number;
  /** True until the first nonempty transcript or 1.5s of successfully forwarded audio. */
  private startupFeed = true;
  /** Bytes accepted by Yuwp during startup. Failed dequeued feeds are not counted or replayed. */
  private forwardedStartupBytes = 0;
  /** Frozen vocabulary for the current take. Never reused across different hints. */
  private takeContextualStrings: readonly string[] | undefined;
  private contextApplied = false;

  constructor(
    opts: StreamingSttOptions,
    fetchFn: typeof globalThis.fetch = globalThis.fetch,
    feedIntervalMs = DEFAULT_FEED_INTERVAL_MS,
  ) {
    this.endpoint = opts.endpoint;
    this.model = opts.model;
    this.fetchFn = fetchFn;
    this.feedIntervalMs = feedIntervalMs;
    // Derive name from endpoint hostname for metrics disambiguation
    try {
      const host = new URL(opts.endpoint).hostname;
      this.name = `streaming-${host}`;
    } catch {
      this.name = "streaming";
    }
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
    this.contextApplied = false;
    this.takeContextualStrings =
      options?.contextualStrings && options.contextualStrings.length > 0
        ? Object.freeze([...options.contextualStrings])
        : undefined;

    await this.createSession();

    if (!this.sessionId) {
      throw new SttSessionCreateError({ category: "invalid_response" });
    }

    this.feedTimer = setInterval(() => void this.flushAudio(), this.feedIntervalMs);
    return { contextApplied: this.contextApplied };
  }

  feedAudio(pcm: Buffer): void {
    if (this.stopped) return;
    this.audioQueue.push(pcm);
    // First startup audio must not wait for the coalesce timer; a large iOS
    // dictation_ready dump would otherwise land as one >=1.5s Yuwp POST.
    if (this.startupFeed && this.sessionId) {
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
      try {
        await this.drainAudioQueue();
      } catch {
        // Best effort
      }
    }

    // Stop session and get final text
    if (this.sessionId) {
      try {
        const url = `${this.endpoint}/v1/audio/transcriptions/stream/${this.sessionId}`;
        const res = await this.fetchFn(url, {
          method: "DELETE",
          signal: AbortSignal.timeout(10_000),
        });
        if (res.ok) {
          const data = (await res.json()) as {
            text?: string;
            committed_text?: string;
            active_text?: string;
          };
          this.lastText = data.text ?? this.lastText;
          const result: SttFinalTranscript = { text: this.lastText };
          if (data.committed_text !== undefined) result.committedText = data.committed_text;
          if (data.active_text !== undefined) result.activeText = data.active_text;
          this.sessionId = null;
          this.takeContextualStrings = undefined;
          this.contextApplied = false;
          return result;
        }
      } catch {
        // Return whatever we had
      }
      this.sessionId = null;
    }

    this.inFlightFlush = null;
    this.takeContextualStrings = undefined;
    this.contextApplied = false;

    return { text: this.lastText };
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
    const body: Record<string, unknown> = { model: this.model };
    if (this.takeContextualStrings && this.takeContextualStrings.length > 0) {
      body.stream_config = { contextual_strings: [...this.takeContextualStrings] };
    }
    return JSON.stringify(body);
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
    while (this.sessionId) {
      if (this.inFlightFlush) {
        await this.inFlightFlush;
        continue;
      }
      if (this.audioQueue.length === 0) return;
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
      try {
        await flush;
      } finally {
        if (this.inFlightFlush === flush) {
          this.inFlightFlush = null;
        }
      }

      if (!this.shouldDrainImmediately()) return;
    }
  }

  private async flushAudioOnce(): Promise<void> {
    this.feeding = true;

    try {
      const pcm = this.dequeueFlushPcm();
      if (pcm.length === 0) return;

      const res = await this.fetchFn(`${this.basePath}/${this.sessionId}`, {
        method: "POST",
        headers: { "Content-Type": "application/octet-stream" },
        body: new Uint8Array(pcm),
        signal: AbortSignal.timeout(10_000),
      });

      if (res.ok) {
        if (this.startupFeed) {
          this.forwardedStartupBytes += pcm.length;
        }
        const data = (await res.json()) as {
          text?: string;
          batch_corrected?: boolean;
          committed_text?: string;
          active_text?: string;
        };
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
      } else if (res.status === 404) {
        // Stale session — server likely restarted. The new Yuwp session has
        // empty pending audio, so the startup byte budget must restart too.
        log.warn("stt.session_not_found_recreating", {
          sessionId: this.sessionId,
          status: res.status,
        });
        this.sessionId = null;
        try {
          await this.createSession();
          this.startupFeed = true;
          this.forwardedStartupBytes = 0;
        } catch (err) {
          log.warn("stt.session_recreate.failed", {
            error: err instanceof Error ? err.message : String(err),
          });
        }
      }
    } catch (err) {
      log.warn("stt.feed.failed", {
        error: err instanceof Error ? err.message : String(err),
      });
    } finally {
      this.feeding = false;
    }
  }
}

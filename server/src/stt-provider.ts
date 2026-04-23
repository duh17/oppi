/**
 * STT provider interface and implementations.
 *
 * Single interface: SttProvider (streaming).
 * Lifecycle: start() → feedAudio()* → onToken() → stop() → final text
 *
 * StreamingSttProvider talks to any server implementing the stateful
 * session API (see docs/asr.md). The API was designed alongside
 * any OpenAI-compatible streaming STT endpoint (not tied to a specific backend).
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
  start(): Promise<void>;
  /** Write raw PCM audio (s16le, 16kHz, mono). */
  feedAudio(pcm: Buffer): void;
  /** Register callback for transcript updates (full replacement text each time). */
  onToken(cb: (update: SttTranscriptUpdate) => void): void;
  /** Close audio input, wait for completion, return full final text. */
  stop(): Promise<SttFinalTranscript>;
  /** Clean up provider resources (e.g. remote sessions). Call on shutdown. */
  dispose?(): Promise<void>;
  /** Update the ASR system prompt (e.g. domain term sheet). */
  setSystemPrompt?(prompt: string | undefined): void;
}

// ─── Streaming Session Provider ───

export interface StreamingSttOptions {
  /** Base URL of the STT server. */
  endpoint: string;
  /** Model identifier sent to the backend. */
  model: string;
  /** ASR system prompt (domain term sheet). */
  systemPrompt?: string;
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

// Keep the server proxy behaviorally close to direct Yuwp usage.
// Large batching here adds noticeable pause-to-commit lag even on localhost.
const DEFAULT_FEED_INTERVAL_MS = 200;

export class StreamingSttProvider implements SttProvider {
  readonly name: string;
  readonly model: string;
  readonly endpoint: string;
  private fetchFn: typeof globalThis.fetch;
  private sessionId: string | null = null;
  private warmSessionId: string | null = null;
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
  /** Max time audio may sit in the proxy queue before forwarding upstream. */
  private feedIntervalMs: number;
  /** ASR system prompt (domain term sheet). Injected into every session. */
  private systemPrompt: string | undefined;

  constructor(
    opts: StreamingSttOptions,
    fetchFn: typeof globalThis.fetch = globalThis.fetch,
    feedIntervalMs = DEFAULT_FEED_INTERVAL_MS,
  ) {
    this.endpoint = opts.endpoint;
    this.model = opts.model;
    this.systemPrompt = opts.systemPrompt;
    this.fetchFn = fetchFn;
    this.feedIntervalMs = feedIntervalMs;
    // Derive name from endpoint hostname for metrics disambiguation
    try {
      const host = new URL(opts.endpoint).hostname;
      this.name = `streaming-${host}`;
    } catch {
      this.name = "streaming";
    }
    // Pre-warm a session at construction time
    void this.warmUpSession();
  }

  /** Update the system prompt (e.g., after term sheet rebuild). */
  setSystemPrompt(prompt: string | undefined): void {
    this.systemPrompt = prompt;
  }

  async start(): Promise<void> {
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
    this.stopped = false;

    // Use warm session if available, otherwise create fresh.
    // Both paths validate the session is reachable before returning.
    if (this.warmSessionId) {
      // Verify the warm session is still valid with a no-op health check.
      // If it's stale (sidecar restarted), create a fresh one instead.
      const valid = await this.verifySession(this.warmSessionId);
      if (valid) {
        this.sessionId = this.warmSessionId;
        this.warmSessionId = null;
      } else {
        // Warm session is stale — delete it and create fresh
        void this.deleteSession(this.warmSessionId);
        this.warmSessionId = null;
        await this.createSession();
      }
    } else {
      await this.createSession();
    }

    if (!this.sessionId) {
      throw new Error("STT backend unreachable");
    }

    this.feedTimer = setInterval(() => void this.flushAudio(), this.feedIntervalMs);
  }

  feedAudio(pcm: Buffer): void {
    if (this.stopped) return;
    this.audioQueue.push(pcm);
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

    // Flush remaining audio
    if (this.sessionId && this.audioQueue.length > 0) {
      try {
        await this.flushAudio();
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
          void this.warmUpSession();
          return result;
        }
      } catch {
        // Return whatever we had
      }
      this.sessionId = null;
    }

    // Pre-warm next session so next mic tap is instant
    void this.warmUpSession();

    return { text: this.lastText };
  }

  /** Cleanup all sessions. Call on server shutdown. */
  async dispose(): Promise<void> {
    this.stopped = true;
    if (this.feedTimer) {
      clearInterval(this.feedTimer);
      this.feedTimer = null;
    }

    const promises: Promise<void>[] = [];
    if (this.sessionId) {
      promises.push(this.deleteSession(this.sessionId));
      this.sessionId = null;
    }
    if (this.warmSessionId) {
      promises.push(this.deleteSession(this.warmSessionId));
      this.warmSessionId = null;
    }
    await Promise.allSettled(promises);
  }

  /** Detect if the sidecar returned our system prompt text instead of a real transcript. */
  private isPromptLeak(text: string): boolean {
    if (!this.systemPrompt) return false;
    // The prompt starts with "Domain terms and proper nouns".
    // If the transcript starts with the same prefix, it's a hallucination.
    const promptPrefix = this.systemPrompt.slice(0, 30);
    return text.startsWith(promptPrefix);
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
    if (this.systemPrompt) {
      body.stream_config = { system_prompt: this.systemPrompt };
    }
    return JSON.stringify(body);
  }

  private async warmUpSession(): Promise<void> {
    // Cleanup existing warm session to prevent leak
    if (this.warmSessionId) {
      await this.deleteSession(this.warmSessionId);
      this.warmSessionId = null;
    }

    try {
      const res = await this.fetchFn(this.basePath, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: this.sessionCreateBody(),
        signal: AbortSignal.timeout(10_000),
      });
      if (res.ok) {
        const data = (await res.json()) as { session_id?: string };
        this.warmSessionId = data.session_id ?? null;
      }
    } catch {
      // Non-fatal — will create on demand in start()
    }
  }

  /** Verify a session is still valid by sending an empty audio chunk. */
  private async verifySession(id: string): Promise<boolean> {
    try {
      const res = await this.fetchFn(`${this.basePath}/${id}`, {
        method: "POST",
        headers: { "Content-Type": "application/octet-stream" },
        body: new Uint8Array(0),
        signal: AbortSignal.timeout(5_000),
      });
      return res.ok;
    } catch {
      return false;
    }
  }

  private async createSession(): Promise<void> {
    if (this.stopped) return;
    const res = await this.fetchFn(this.basePath, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: this.sessionCreateBody(),
      signal: AbortSignal.timeout(10_000),
    });
    if (!res.ok) {
      const body = await res.text().catch(() => "");
      throw new Error(`Create session HTTP ${res.status}: ${body}`);
    }
    const data = (await res.json()) as { session_id?: string };
    this.sessionId = data.session_id ?? null;
  }

  private async flushAudio(): Promise<void> {
    if (this.feeding || !this.sessionId || this.audioQueue.length === 0) return;
    this.feeding = true;

    try {
      const pcm = Buffer.concat(this.audioQueue);
      this.audioQueue = [];

      const res = await this.fetchFn(`${this.basePath}/${this.sessionId}`, {
        method: "POST",
        headers: { "Content-Type": "application/octet-stream" },
        body: new Uint8Array(pcm),
        signal: AbortSignal.timeout(10_000),
      });

      if (res.ok) {
        const data = (await res.json()) as {
          text?: string;
          batch_corrected?: boolean;
          committed_text?: string;
          active_text?: string;
        };
        const text = (data.text ?? "").trim();
        const snap = data.batch_corrected === true;
        const committedText = data.committed_text?.trim();
        const activeText = data.active_text?.trim();
        const signature =
          committedText !== undefined || activeText !== undefined
            ? JSON.stringify([text, committedText ?? "", activeText ?? ""])
            : JSON.stringify([text, snap]);

        if (text && signature !== this.lastPreviewSignature && !this.isPromptLeak(text)) {
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
        // Stale session — server likely restarted
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

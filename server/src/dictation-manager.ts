/**
 * Dictation pipeline manager.
 *
 * Handles per-connection lifecycle: forwarding audio to the SttProvider,
 * relaying transcript updates to the client, and emitting dictation metrics.
 *
 * Final transcript correctness lives in the upstream streaming STT service
 * (Yuwp segment-commit). Oppi forwards streaming updates and the provider's
 * final text instead of re-running a second whole-audio batch pass.
 *
 * Oppi no longer persists dictation audio locally.
 */

import type { DictationClientMessage, DictationServerMessage } from "./dictation-types.js";
import type { SttProvider } from "./stt-provider.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import { createLogger } from "./logger.js";

// ─── Constants ───

/** PCM audio format: 16-bit signed, 16kHz, mono. */
const SAMPLE_RATE = 16000;
const BITS_PER_SAMPLE = 16;
const NUM_CHANNELS = 1;
const BYTES_PER_SAMPLE = BITS_PER_SAMPLE / 8;

const log = createLogger({ base: { component: "dictation_manager" } });

// ─── Per-connection session state ───

interface DictationSession {
  /** Total PCM bytes received for this session. */
  totalBytes: number;
  /** High-res monotonic start time for latency measurement. */
  startHrMs: number;
  /** Set to true once dictation_stop is received. */
  stopping: boolean;
}

// ─── DictationManager ───

/** Callback for sending dictation responses through the transport layer. */
export type DictationSendFn = (msg: DictationServerMessage) => void;

export class DictationManager {
  private sttProvider: SttProvider;

  /** Optional metrics collector for pipeline telemetry. */
  private metrics: ServerMetricCollector | null;

  /** Active dictation session state. */
  private session: DictationSession | null = null;

  /** Callback for sending messages to the client. Set by handleControlMessage. */
  private sendFn: DictationSendFn | null = null;

  constructor(sttProvider: SttProvider, metrics?: ServerMetricCollector) {
    this.sttProvider = sttProvider;
    this.metrics = metrics ?? null;
  }

  // ─── Public API ───

  /** Handle a parsed dictation control message from the transport layer. */
  handleControlMessage(msg: DictationClientMessage, send: DictationSendFn): void {
    this.sendFn = send;

    switch (msg.type) {
      case "dictation_start":
        if (this.session) {
          this.send({
            type: "dictation_error",
            error: "Dictation already active",
            fatal: false,
          });
          return;
        }
        this.session = {
          totalBytes: 0,
          startHrMs: performance.now(),
          stopping: false,
        };
        this.startSession();
        break;

      case "dictation_stop":
        if (!this.session) {
          this.send({
            type: "dictation_error",
            error: "No active dictation session",
            fatal: false,
          });
          return;
        }
        this.session.stopping = true;
        {
          const sessionToFinalize = this.session;
          this.session = null;
          this.finalizeSession(sessionToFinalize);
        }
        break;

      case "dictation_cancel":
        if (this.session) {
          this.cancelSession();
          this.session = null;
        }
        break;

      default:
        this.send({
          type: "dictation_error",
          error: `Unknown message type: ${(msg as { type: string }).type}`,
          fatal: false,
        });
    }
  }

  /** Handle an incoming binary audio frame. */
  handleAudioData(buf: Buffer): void {
    if (!this.session) return;

    this.session.totalBytes += buf.length;
    this.sttProvider.feedAudio(buf);
  }

  /** Clean up on transport disconnect. */
  handleDisconnect(): void {
    if (this.session) {
      this.cancelSession();
      this.session = null;
    }
    this.sendFn = null;
  }

  // ─── Private send ───

  /** Send a dictation message through the stored transport callback. */
  private send(msg: DictationServerMessage): void {
    this.sendFn?.(msg);
  }

  // ─── Session lifecycle ───

  private startSession(): void {
    // Start the STT provider (async — validates backend is reachable).
    // Only send dictation_ready after the session is confirmed.
    void this.startSttAndSignalReady();
  }

  private async startSttAndSignalReady(): Promise<void> {
    try {
      await this.sttProvider.start();
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : String(err);
      log.error("dictation.stt_start.failed", { error: errorMsg });
      this.send({
        type: "dictation_error",
        error: `STT failed to start: ${errorMsg}`,
        fatal: true,
      });
      // Clear the session so the manager knows dictation is not active
      this.session = null;
      return;
    }

    // STT session is confirmed — now tell the client
    this.send({
      type: "dictation_ready",
      sttProvider: this.sttProvider.name,
      sttModel: this.sttProvider.model,
    });

    // Forward transcript updates to the client.
    // Keep this as a thin proxy for the upstream STT semantics so iOS can
    // render committed vs. active text like Yuwp without inferring splits.
    this.sttProvider.onToken((update) => {
      if (!this.session || this.session.stopping) return;
      this.send({
        type: "dictation_result",
        text: update.text,
        ...(update.snap ? { snap: true } : {}),
        ...(update.committedText !== undefined ? { committedText: update.committedText } : {}),
        ...(update.activeText !== undefined ? { activeText: update.activeText } : {}),
      });
    });
  }

  private cancelSession(): void {
    void this.sttProvider.stop().catch(() => {});
  }

  private async finalizeSession(session: DictationSession): Promise<void> {
    const finalizeT0 = performance.now();
    const langTag = "auto";

    // Emit session-level metrics
    const sessionMs = Math.round(performance.now() - session.startHrMs);
    const audioDurationMs = Math.round(
      (session.totalBytes / (SAMPLE_RATE * BYTES_PER_SAMPLE * NUM_CHANNELS)) * 1000,
    );
    this.metrics?.record(
      "server.dictation_session_ms",
      sessionMs,
      this.metricTags({ language: langTag }),
    );
    this.metrics?.record(
      "server.dictation_audio_duration_ms",
      audioDurationMs,
      this.metricTags({ language: langTag }),
    );

    if (session.totalBytes === 0) {
      await this.sttProvider.stop().catch(() => {});
      this.send({ type: "dictation_final", text: "" });
      return;
    }

    // Final STT — close audio stream, get final text
    const audioSeconds = session.totalBytes / (SAMPLE_RATE * BYTES_PER_SAMPLE * NUM_CHANNELS);
    let finalTranscript;
    let finalSttMs = 0;
    const sttT0 = performance.now();
    try {
      finalTranscript = await this.sttProvider.stop();
      finalSttMs = Math.round(performance.now() - sttT0);
      this.metrics?.record(
        "server.dictation_stt_ms",
        finalSttMs,
        this.metricTags({
          phase: "finalize",
          audio_seconds: String(Math.round(audioSeconds)),
          language: langTag,
        }),
      );
      if (audioSeconds > 0) {
        this.metrics?.record(
          "server.dictation_stt_audio_ratio",
          Math.round((finalSttMs / (audioSeconds * 1000)) * 100) / 100,
          this.metricTags({ phase: "finalize", language: langTag }),
        );
      }
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : String(err);
      this.metrics?.record(
        "server.dictation_error",
        1,
        this.metricTags({ phase: "stt", fatal: "true", error_kind: "stt", language: langTag }),
      );
      this.send({ type: "dictation_error", error: `STT failed: ${errorMsg}`, fatal: true });
      return;
    }

    const finalizeMs = Math.round(performance.now() - finalizeT0);
    this.metrics?.record(
      "server.dictation_finalize_ms",
      finalizeMs,
      this.metricTags({ language: langTag }),
    );

    this.send({
      type: "dictation_final",
      text: finalTranscript.text,
      ...(finalTranscript.committedText !== undefined
        ? { committedText: finalTranscript.committedText }
        : {}),
      ...(finalTranscript.activeText !== undefined
        ? { activeText: finalTranscript.activeText }
        : {}),
    });
  }

  // ─── Metrics ───

  private metricTags(extra: Record<string, string>): Record<string, string> {
    return {
      provider_id: `stt_${this.sttProvider.name.replace(/[^a-z0-9]+/gi, "_").toLowerCase()}`,
      stt_backend: this.sttProvider.name,
      model: this.sttProvider.model,
      ...extra,
    };
  }
}

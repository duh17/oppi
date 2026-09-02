/**
 * Tests for DictationManager — STT provider integration (streaming),
 * final transcript forwarding, and error handling.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { DictationManager, type DictationSendFn } from "../src/dictation-manager.js";

import type { DictationServerMessage } from "../src/dictation-types.js";
import type { ServerMetricCollector } from "../src/server-metric-collector.js";
import type { ServerMetricName } from "../src/server-metric-registry.js";
import type { SttProvider } from "../src/stt-provider.js";

// ─── Test helpers ───

/** Drain pending microtasks (multiple levels for chained async). */
async function drain(): Promise<void> {
  for (let i = 0; i < 10; i++) await Promise.resolve();
}

/** Generate PCM silence (zero-filled). */
function silencePcm(durationMs: number): Buffer {
  const samples = Math.floor((16000 * durationMs) / 1000);
  return Buffer.alloc(samples * 2);
}

/** Collect messages of a given type from a sent message array. */
function messagesOfType<T extends DictationServerMessage["type"]>(
  sent: DictationServerMessage[],
  type: T,
): Extract<DictationServerMessage, { type: T }>[] {
  return sent.filter((m) => m.type === type) as Extract<DictationServerMessage, { type: T }>[];
}

function mockMetrics(): {
  collector: {
    record: (metric: ServerMetricName, value: number, tags?: Record<string, string>) => void;
  };
  records: Array<{ metric: ServerMetricName; value: number; tags?: Record<string, string> }>;
} {
  const records: Array<{ metric: ServerMetricName; value: number; tags?: Record<string, string> }> =
    [];
  return {
    collector: {
      record(metric, value, tags) {
        records.push({ metric, value, tags });
      },
    },
    records,
  };
}

/**
 * Create a mock SttProvider (streaming interface).
 * Simulates progressive token accumulation on _fireTokens().
 */
// eslint-disable-next-line @typescript-eslint/explicit-function-return-type
function mockSttProvider(tokens: string[]) {
  let tokenCb:
    | ((update: {
        text: string;
        snap?: boolean;
        committedText?: string;
        activeText?: string;
      }) => void)
    | null = null;
  const accumulated = tokens.join(" ");

  const startFn = vi.fn<() => Promise<void>>().mockResolvedValue(undefined);
  const feedAudioFn = vi.fn<(pcm: Buffer) => void>();
  const stopFn = vi
    .fn<
      () => Promise<{
        text: string;
        committedText?: string;
        activeText?: string;
      }>
    >()
    .mockResolvedValue({ text: accumulated });

  const provider: SttProvider & {
    _fireTokens: () => void;
    _fireUpdate: (update: {
      text: string;
      snap?: boolean;
      committedText?: string;
      activeText?: string;
    }) => void;
  } = {
    name: "mock",
    model: "mock-model",
    start: startFn,
    feedAudio: feedAudioFn,
    onToken(
      cb: (update: {
        text: string;
        snap?: boolean;
        committedText?: string;
        activeText?: string;
      }) => void,
    ) {
      tokenCb = cb;
    },
    stop: stopFn,
    _fireTokens() {
      let running = "";
      for (const t of tokens) {
        running += (running.length > 0 ? " " : "") + t;
        tokenCb?.({ text: running });
      }
    },
    _fireUpdate(update) {
      tokenCb?.(update);
    },
  };
  return Object.assign(provider, { start: startFn, feedAudio: feedAudioFn, stop: stopFn });
}

/** Create a mock SttProvider whose stop() rejects. */
// eslint-disable-next-line @typescript-eslint/explicit-function-return-type
function failingSttProvider(error: string) {
  const startFn = vi.fn<() => Promise<void>>().mockResolvedValue(undefined);
  const feedAudioFn = vi.fn<(pcm: Buffer) => void>();
  const stopFn = vi.fn<() => Promise<{ text: string }>>().mockRejectedValue(new Error(error));

  const provider: SttProvider = {
    name: "mock",
    model: "mock-model",
    start: startFn,
    feedAudio: feedAudioFn,
    onToken() {},
    stop: stopFn,
  };
  return Object.assign(provider, { start: startFn, feedAudio: feedAudioFn, stop: stopFn });
}

// ─── DictationManager with streaming provider ───

describe("DictationManager", () => {
  let manager: DictationManager;
  let sent: DictationServerMessage[];
  let sendFn: (msg: DictationServerMessage) => void;
  let provider: ReturnType<typeof mockSttProvider>;

  beforeEach(() => {
    vi.useFakeTimers();
    provider = mockSttProvider(["hello", "world"]);
    manager = new DictationManager(provider);
    sent = [];
    sendFn = (msg: DictationServerMessage) => sent.push(msg);
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  describe("session lifecycle", () => {
    it("sends dictation_ready on dictation_start", async () => {
      manager.handleControlMessage({ type: "dictation_start" }, sendFn);
      await drain();
      expect(messagesOfType(sent, "dictation_ready")).toHaveLength(1);
    });

    it("dictation_ready includes provider metadata", async () => {
      manager.handleControlMessage({ type: "dictation_start" }, sendFn);
      await drain();
      const ready = messagesOfType(sent, "dictation_ready")[0];
      expect(ready.sttProvider).toBe("mock");
      expect(ready.sttModel).toBe("mock-model");
    });

    it("calls start() on dictation_start", async () => {
      manager.handleControlMessage({ type: "dictation_start" }, sendFn);
      await drain();
      expect(provider.start).toHaveBeenCalledTimes(1);
    });

    it("pipes audio via feedAudio()", async () => {
      manager.handleControlMessage({ type: "dictation_start" }, sendFn);
      await drain();
      const pcm = silencePcm(500);
      manager.handleAudioData(pcm);
      expect(provider.feedAudio).toHaveBeenCalledWith(pcm);
    });

    it("rejects duplicate dictation_start", () => {
      manager.handleControlMessage({ type: "dictation_start" }, sendFn);
      manager.handleControlMessage({ type: "dictation_start" }, sendFn);
      const errors = messagesOfType(sent, "dictation_error");
      expect(errors).toHaveLength(1);
      expect(errors[0].error).toContain("already active");
    });

    it("rejects dictation_stop without active session", () => {
      manager.handleControlMessage({ type: "dictation_stop" }, sendFn);
      expect(messagesOfType(sent, "dictation_error")).toHaveLength(1);
    });

    it("sends empty dictation_final for stop with no audio", async () => {
      manager.handleControlMessage({ type: "dictation_start" }, sendFn);
      manager.handleControlMessage({ type: "dictation_stop" }, sendFn);
      vi.advanceTimersByTime(10);
      await drain();
      const finals = messagesOfType(sent, "dictation_final");
      expect(finals).toHaveLength(1);
      expect(finals[0]).toEqual({ type: "dictation_final", text: "" });
    });

    it("stays active until dictation_final is sent", async () => {
      manager.handleControlMessage({ type: "dictation_start" }, sendFn);
      await drain();
      expect(manager.isActive()).toBe(true);

      manager.handleControlMessage({ type: "dictation_stop" }, sendFn);
      expect(manager.isActive()).toBe(true);
      expect(messagesOfType(sent, "dictation_final")).toHaveLength(0);

      await drain();
      expect(messagesOfType(sent, "dictation_final")).toHaveLength(1);
      expect(manager.isActive()).toBe(false);
    });

    it("handles dictation_cancel silently", () => {
      manager.handleControlMessage({ type: "dictation_start" }, sendFn);
      manager.handleControlMessage({ type: "dictation_cancel" }, sendFn);
      expect(messagesOfType(sent, "dictation_final")).toHaveLength(0);
      expect(provider.stop).toHaveBeenCalledTimes(1);
    });

    it("cleans up on disconnect", () => {
      manager.handleControlMessage({ type: "dictation_start" }, sendFn);
      manager.handleDisconnect();
      expect(provider.stop).toHaveBeenCalledTimes(1);
    });

    it("reports unknown message types", () => {
      manager.handleControlMessage({ type: "dictation_start" }, sendFn);
      manager.handleControlMessage(
        { type: "bogus_type" } as unknown as Parameters<typeof manager.handleControlMessage>[0],
        sendFn,
      );
      expect(messagesOfType(sent, "dictation_error")).toHaveLength(1);
    });

    it("allows new session after disconnect", async () => {
      manager.handleControlMessage({ type: "dictation_start" }, sendFn);
      await drain();
      manager.handleDisconnect();

      // Reset sent messages and start a fresh session
      sent.length = 0;
      manager.handleControlMessage({ type: "dictation_start" }, sendFn);
      await drain();

      const readyMsgs = messagesOfType(sent, "dictation_ready");
      expect(readyMsgs).toHaveLength(1);
      expect(provider.start).toHaveBeenCalledTimes(2);
    });

    it("allows new session after cancel", async () => {
      manager.handleControlMessage({ type: "dictation_start" }, sendFn);
      await drain();
      manager.handleControlMessage({ type: "dictation_cancel" }, sendFn);

      sent.length = 0;
      manager.handleControlMessage({ type: "dictation_start" }, sendFn);
      await drain();

      expect(messagesOfType(sent, "dictation_ready")).toHaveLength(1);
    });

    it("persists send callback across multiple sessions", async () => {
      // The send function is set per-call. Verify each session gets
      // its messages routed to the callback provided with that call.
      const sent1: DictationServerMessage[] = [];
      const sent2: DictationServerMessage[] = [];
      manager.handleControlMessage({ type: "dictation_start" }, (m) => sent1.push(m));
      await drain();
      manager.handleDisconnect();
      manager.handleControlMessage({ type: "dictation_start" }, (m) => sent2.push(m));
      await drain();

      expect(sent1).toHaveLength(1); // dictation_ready
      expect(sent2).toHaveLength(1); // dictation_ready
    });

    it("sends fatal error when STT backend is unreachable", async () => {
      const failStartProvider = mockSttProvider(["test"]);
      failStartProvider.start.mockRejectedValue(new Error("STT backend unreachable"));
      const mgr = new DictationManager(failStartProvider);
      const mgrSent: DictationServerMessage[] = [];

      mgr.handleControlMessage({ type: "dictation_start" }, (m) => mgrSent.push(m));
      await drain();

      const errors = messagesOfType(mgrSent, "dictation_error");
      expect(errors).toHaveLength(1);
      expect(errors[0].fatal).toBe(true);
      expect(errors[0].error).toContain("STT failed to start");
      // No dictation_ready should have been sent
      expect(messagesOfType(mgrSent, "dictation_ready")).toHaveLength(0);
    });
  });

  describe("token streaming", () => {
    it("sends dictation_result with accumulated text", async () => {
      manager.handleControlMessage({ type: "dictation_start" }, sendFn);
      await drain();
      manager.handleAudioData(silencePcm(500));
      provider._fireTokens();

      const results = messagesOfType(sent, "dictation_result");
      expect(results).toHaveLength(2);
      expect(results[0].text).toBe("hello");
      expect(results[1].text).toBe("hello world");
    });

    it("forwards committed and active transcript split unchanged", async () => {
      manager.handleControlMessage({ type: "dictation_start" }, sendFn);
      await drain();

      provider._fireUpdate({
        text: "hello world",
        committedText: "hello",
        activeText: "world",
      });

      const results = messagesOfType(sent, "dictation_result");
      expect(results).toHaveLength(1);
      expect(results[0]).toEqual({
        type: "dictation_result",
        text: "hello world",
        committedText: "hello",
        activeText: "world",
      });
    });

    it("records server-side first audio, first result, and update count metrics", async () => {
      const metrics = mockMetrics();
      const metricProvider = mockSttProvider(["hello", "world"]);
      const mgr = new DictationManager(
        metricProvider,
        metrics.collector as unknown as ServerMetricCollector,
      );
      const mgrSent: DictationServerMessage[] = [];

      mgr.handleControlMessage({ type: "dictation_start" }, (msg) => mgrSent.push(msg));
      await drain();
      vi.advanceTimersByTime(25);
      mgr.handleAudioData(silencePcm(500));
      metricProvider._fireTokens();
      mgr.handleControlMessage({ type: "dictation_stop" }, (msg) => mgrSent.push(msg));
      await drain();

      expect(metrics.records.some((r) => r.metric === "server.dictation_first_audio_ms")).toBe(
        true,
      );
      expect(metrics.records).toContainEqual(
        expect.objectContaining({ metric: "server.dictation_first_result_audio_ms", value: 500 }),
      );
      expect(metrics.records).toContainEqual(
        expect.objectContaining({ metric: "server.dictation_result_updates", value: 2 }),
      );
    });

    it("ignores audio data before dictation_start", () => {
      manager.handleAudioData(silencePcm(500));
      expect(messagesOfType(sent, "dictation_error")).toHaveLength(0);
    });
  });

  describe("finalize", () => {
    it("calls stop() and returns accumulated text", async () => {
      manager.handleControlMessage({ type: "dictation_start" }, sendFn);
      await drain();
      manager.handleAudioData(silencePcm(1000));
      manager.handleControlMessage({ type: "dictation_stop" }, sendFn);
      vi.advanceTimersByTime(10);
      await drain();

      expect(provider.stop).toHaveBeenCalledTimes(1);
      const finals = messagesOfType(sent, "dictation_final");
      expect(finals).toHaveLength(1);
      expect(finals[0]).toEqual({ type: "dictation_final", text: "hello world" });
    });

    it("handles stop() failure with fatal error", async () => {
      const failProvider = failingSttProvider("process crashed");
      const mgr = new DictationManager(failProvider);
      const mgrSent: DictationServerMessage[] = [];
      const mgrSendFn: DictationSendFn = (msg) => {
        mgrSent.push(msg);
      };

      mgr.handleControlMessage({ type: "dictation_start" }, mgrSendFn);
      await drain();
      mgr.handleAudioData(silencePcm(500));
      mgr.handleControlMessage({ type: "dictation_stop" }, mgrSendFn);
      expect(mgr.isActive()).toBe(true);
      expect(messagesOfType(mgrSent, "dictation_error")).toHaveLength(0);
      vi.advanceTimersByTime(10);
      await drain();

      const errors = messagesOfType(mgrSent, "dictation_error");
      expect(errors).toHaveLength(1);
      expect(errors[0].error).toContain("STT failed");
      expect(errors[0].fatal).toBe(true);
      expect(mgr.isActive()).toBe(false);
    });
  });

  describe("final transcript forwarding", () => {
    it("forwards provider final text unchanged", async () => {
      manager.handleControlMessage({ type: "dictation_start" }, sendFn);
      await drain();
      manager.handleAudioData(silencePcm(1000));
      manager.handleControlMessage({ type: "dictation_stop" }, sendFn);
      vi.advanceTimersByTime(10);
      await drain();

      const finals = messagesOfType(sent, "dictation_final");
      expect(finals).toHaveLength(1);
      expect(finals[0].text).toBe("hello world");
    });

    it("forwards final committed and active split unchanged", async () => {
      const splitProvider = mockSttProvider(["hello", "world"]);
      splitProvider.stop.mockResolvedValue({
        text: "hello world",
        committedText: "hello world",
        activeText: "",
      });
      const mgr = new DictationManager(splitProvider);
      const mgrSent: DictationServerMessage[] = [];

      mgr.handleControlMessage({ type: "dictation_start" }, (msg) => mgrSent.push(msg));
      await drain();
      mgr.handleAudioData(silencePcm(1000));
      mgr.handleControlMessage({ type: "dictation_stop" }, (msg) => mgrSent.push(msg));
      vi.advanceTimersByTime(10);
      await drain();

      const finals = messagesOfType(mgrSent, "dictation_final");
      expect(finals).toHaveLength(1);
      expect(finals[0]).toEqual({
        type: "dictation_final",
        text: "hello world",
        committedText: "hello world",
        activeText: "",
      });
    });
  });
});

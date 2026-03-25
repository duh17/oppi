/**
 * Tests for ServerMetricCollector and JsonlMetricWriter.
 */

import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { ServerMetricCollector, type ServerMetricSample } from "./server-metric-collector.js";
import { JsonlMetricWriter, type MetricWriter } from "./server-metric-writer.js";

// ─── Helpers ───

/** In-memory writer that captures batches for assertions. */
class MockWriter implements MetricWriter {
  batches: ServerMetricSample[][] = [];

  writeBatch(samples: ServerMetricSample[]): void {
    this.batches.push([...samples]);
  }

  get totalSamples(): number {
    return this.batches.reduce((sum, b) => sum + b.length, 0);
  }
}

// ─── Collector Tests ───

describe("ServerMetricCollector", () => {
  it("buffers records without flushing", () => {
    const writer = new MockWriter();
    const collector = new ServerMetricCollector(writer);

    collector.record("server.ws_ping_rtt_ms", 12);
    collector.record("server.ws_ping_rtt_ms", 15);

    expect(writer.batches).toHaveLength(0);
    expect(collector.bufferedCount).toBe(2);
  });

  it("flush() writes buffered samples and clears buffer", () => {
    const writer = new MockWriter();
    const collector = new ServerMetricCollector(writer);

    collector.record("server.ws_handshake_ms", 34);
    collector.record("server.ws_ping_rtt_ms", 12);
    collector.flush();

    expect(writer.batches).toHaveLength(1);
    expect(writer.batches[0]).toHaveLength(2);
    expect(writer.batches[0][0].metric).toBe("server.ws_handshake_ms");
    expect(writer.batches[0][0].value).toBe(34);
    expect(writer.batches[0][1].metric).toBe("server.ws_ping_rtt_ms");
    expect(collector.bufferedCount).toBe(0);
  });

  it("flush() is a no-op when buffer is empty", () => {
    const writer = new MockWriter();
    const collector = new ServerMetricCollector(writer);

    collector.flush();
    expect(writer.batches).toHaveLength(0);
  });

  it("auto-flushes when buffer reaches maxBufferSize", () => {
    const writer = new MockWriter();
    const collector = new ServerMetricCollector(writer, { maxBufferSize: 3 });

    collector.record("server.ws_ping_rtt_ms", 10);
    collector.record("server.ws_ping_rtt_ms", 11);
    expect(writer.batches).toHaveLength(0);

    collector.record("server.ws_ping_rtt_ms", 12); // triggers flush
    expect(writer.batches).toHaveLength(1);
    expect(writer.batches[0]).toHaveLength(3);
    expect(collector.bufferedCount).toBe(0);
  });

  it("stop() flushes remaining samples", () => {
    const writer = new MockWriter();
    const collector = new ServerMetricCollector(writer);

    collector.record("server.ws_session_duration_ms", 5000);
    collector.stop();

    expect(writer.batches).toHaveLength(1);
    expect(writer.batches[0][0].metric).toBe("server.ws_session_duration_ms");
  });

  it("records tags on samples", () => {
    const writer = new MockWriter();
    const collector = new ServerMetricCollector(writer);

    collector.record("server.ws_close_code", 1, { code: "1000" });
    collector.flush();

    expect(writer.batches[0][0].tags).toEqual({ code: "1000" });
  });

  it("truncates tag values exceeding 128 characters", () => {
    const writer = new MockWriter();
    const collector = new ServerMetricCollector(writer);
    const longValue = "a".repeat(200);

    collector.record("server.ws_close_code", 1, { code: longValue });
    collector.flush();

    expect(writer.batches[0][0].tags!.code).toHaveLength(128);
  });

  it("caps tags at 8 per sample", () => {
    const writer = new MockWriter();
    const collector = new ServerMetricCollector(writer);

    const tags: Record<string, string> = {};
    for (let i = 0; i < 12; i++) {
      tags[`tag${i}`] = `val${i}`;
    }

    collector.record("server.ws_close_code", 1, tags);
    collector.flush();

    expect(Object.keys(writer.batches[0][0].tags!)).toHaveLength(8);
  });

  it("never throws even if writer throws", () => {
    const writer: MetricWriter = {
      writeBatch: () => {
        throw new Error("disk full");
      },
    };
    const collector = new ServerMetricCollector(writer, { maxBufferSize: 1 });

    // Should not throw
    expect(() => collector.record("server.ws_ping_rtt_ms", 12)).not.toThrow();
    expect(() => collector.flush()).not.toThrow();
  });

  it("start() creates a flush timer and stop() clears it", () => {
    vi.useFakeTimers();
    try {
      const writer = new MockWriter();
      const collector = new ServerMetricCollector(writer, { flushIntervalMs: 100 });

      collector.start();
      collector.record("server.ws_ping_rtt_ms", 10);

      vi.advanceTimersByTime(100);
      expect(writer.batches).toHaveLength(1);

      collector.record("server.ws_ping_rtt_ms", 20);
      collector.stop();
      expect(writer.batches).toHaveLength(2);

      // No more flushes after stop
      collector.record("server.ws_ping_rtt_ms", 30);
      vi.advanceTimersByTime(200);
      expect(writer.batches).toHaveLength(2);
    } finally {
      vi.useRealTimers();
    }
  });

  it("samples have a timestamp", () => {
    const writer = new MockWriter();
    const collector = new ServerMetricCollector(writer);
    const before = Date.now();

    collector.record("server.ws_ping_rtt_ms", 5);
    collector.flush();

    const after = Date.now();
    const ts = writer.batches[0][0].ts;
    expect(ts).toBeGreaterThanOrEqual(before);
    expect(ts).toBeLessThanOrEqual(after);
  });
});

// ─── Writer Tests ───

describe("JsonlMetricWriter", () => {
  let tempDir: string;

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "ops-metrics-test-"));
  });

  afterEach(() => {
    rmSync(tempDir, { recursive: true, force: true });
  });

  it("writes correct JSONL format to daily file", () => {
    const writer = new JsonlMetricWriter(tempDir);
    const samples: ServerMetricSample[] = [
      { ts: Date.now(), metric: "server.ws_ping_rtt_ms", value: 12 },
      { ts: Date.now(), metric: "server.ws_handshake_ms", value: 34, tags: { code: "200" } },
    ];

    writer.writeBatch(samples);

    const files = readdirSync(tempDir).filter((f) => f.startsWith("server-ops-metrics-"));
    expect(files).toHaveLength(1);
    expect(files[0]).toMatch(/^server-ops-metrics-\d{4}-\d{2}-\d{2}\.jsonl$/);

    const content = readFileSync(join(tempDir, files[0]), "utf-8").trim();
    const record = JSON.parse(content);

    expect(record.flushedAt).toBeTypeOf("number");
    expect(record.sampleCount).toBe(2);
    expect(record.samples).toHaveLength(2);
    expect(record.samples[0].metric).toBe("server.ws_ping_rtt_ms");
    expect(record.samples[0].value).toBe(12);
    expect(record.samples[1].tags).toEqual({ code: "200" });
  });

  it("appends multiple batches to the same daily file", () => {
    const writer = new JsonlMetricWriter(tempDir);

    writer.writeBatch([{ ts: Date.now(), metric: "server.ws_ping_rtt_ms", value: 10 }]);
    writer.writeBatch([{ ts: Date.now(), metric: "server.ws_ping_rtt_ms", value: 20 }]);

    const files = readdirSync(tempDir).filter((f) => f.startsWith("server-ops-metrics-"));
    expect(files).toHaveLength(1);

    const lines = readFileSync(join(tempDir, files[0]), "utf-8").trim().split("\n");
    expect(lines).toHaveLength(2);

    const record1 = JSON.parse(lines[0]);
    const record2 = JSON.parse(lines[1]);
    expect(record1.samples[0].value).toBe(10);
    expect(record2.samples[0].value).toBe(20);
  });

  it("skips empty batches", () => {
    const writer = new JsonlMetricWriter(tempDir);
    writer.writeBatch([]);

    const files = readdirSync(tempDir).filter((f) => f.startsWith("server-ops-metrics-"));
    expect(files).toHaveLength(0);
  });

  it("creates telemetry directory if it doesn't exist", () => {
    const nestedDir = join(tempDir, "deep", "nested", "telemetry");
    const writer = new JsonlMetricWriter(nestedDir);

    writer.writeBatch([{ ts: Date.now(), metric: "server.ws_ping_rtt_ms", value: 5 }]);

    expect(existsSync(nestedDir)).toBe(true);
    const files = readdirSync(nestedDir);
    expect(files).toHaveLength(1);
  });

  it("prunes files older than retention period", () => {
    // Create an old file (40 days ago)
    mkdirSync(tempDir, { recursive: true });
    const oldDate = new Date(Date.now() - 40 * 24 * 60 * 60 * 1000);
    const y = oldDate.getUTCFullYear();
    const m = String(oldDate.getUTCMonth() + 1).padStart(2, "0");
    const d = String(oldDate.getUTCDate()).padStart(2, "0");
    const oldFileName = `server-ops-metrics-${y}-${m}-${d}.jsonl`;
    writeFileSync(join(tempDir, oldFileName), '{"old": true}\n');

    // Write a new batch — should trigger pruning
    const writer = new JsonlMetricWriter(tempDir, 30);
    writer.writeBatch([{ ts: Date.now(), metric: "server.ws_ping_rtt_ms", value: 5 }]);

    const files = readdirSync(tempDir).filter((f) => f.startsWith("server-ops-metrics-"));
    // Old file should be gone, only today's file remains
    expect(files).toHaveLength(1);
    expect(files[0]).not.toBe(oldFileName);
  });

  it("preserves files within retention period", () => {
    mkdirSync(tempDir, { recursive: true });
    // Create a recent file (5 days ago)
    const recentDate = new Date(Date.now() - 5 * 24 * 60 * 60 * 1000);
    const y = recentDate.getUTCFullYear();
    const m = String(recentDate.getUTCMonth() + 1).padStart(2, "0");
    const d = String(recentDate.getUTCDate()).padStart(2, "0");
    const recentFileName = `server-ops-metrics-${y}-${m}-${d}.jsonl`;
    writeFileSync(join(tempDir, recentFileName), '{"recent": true}\n');

    const writer = new JsonlMetricWriter(tempDir, 30);
    writer.writeBatch([{ ts: Date.now(), metric: "server.ws_ping_rtt_ms", value: 5 }]);

    const files = readdirSync(tempDir).filter((f) => f.startsWith("server-ops-metrics-"));
    // Both recent file and today's file should exist
    expect(files.length).toBeGreaterThanOrEqual(2);
    expect(files).toContain(recentFileName);
  });

  it("does not throw on write failure", () => {
    // Point to an invalid path (file as dir)
    const filePath = join(tempDir, "not-a-dir");
    writeFileSync(filePath, "block");
    const writer = new JsonlMetricWriter(join(filePath, "nested"));

    // Should not throw
    expect(() =>
      writer.writeBatch([{ ts: Date.now(), metric: "server.ws_ping_rtt_ms", value: 5 }]),
    ).not.toThrow();
  });
});

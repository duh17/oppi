import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { ServerResourceSampler, type ServerMetricsDeps } from "../src/server-resource-sampler.js";

describe("ServerResourceSampler", () => {
  let telemetryDir: string;

  beforeEach(() => {
    telemetryDir = mkdtempSync(join(tmpdir(), "oppi-server-resource-sampler-"));
  });

  afterEach(() => {
    delete process.env.OPPI_SERVER_METRICS_INTERVAL_MS;
    delete process.env.OPPI_SERVER_METRICS_RETENTION_DAYS;
    delete process.env.OPPI_SERVER_METRICS_DAILY_FILE_MAX_BYTES;
    vi.restoreAllMocks();
    rmSync(telemetryDir, { recursive: true, force: true });
  });

  it("writes a deterministic sample record and emits drill-down ops metrics", () => {
    const opsMetrics: Array<{ metric: string; value: number; tags?: Record<string, string> }> = [];
    const deps: ServerMetricsDeps = {
      telemetryDir,
      getSessionCounts: () => ({ busy: 1, ready: 2, starting: 0, total: 3 }),
      getWebSocketCount: () => 7,
      recordOpsMetric: (metric, value, tags) => opsMetrics.push({ metric, value, tags }),
      getEventRingSnapshots: () => [
        { ring: "timeline", length: 3, capacity: 4 },
        { ring: "empty", length: 1, capacity: 0 },
      ],
    };

    vi.spyOn(Date, "now").mockReturnValue(2_000);
    vi.spyOn(process, "memoryUsage").mockReturnValue({
      rss: 100 * 1024 * 1024,
      heapTotal: 50 * 1024 * 1024,
      heapUsed: 25 * 1024 * 1024,
      external: 5 * 1024 * 1024,
      arrayBuffers: 0,
    });
    vi.spyOn(process, "cpuUsage").mockReturnValue({ user: 250_000, system: 50_000 });

    const sampler = new ServerResourceSampler(deps);
    sampler.recordActiveSessionCount(5);
    let eventLoopResetCalled = false;
    (
      sampler as unknown as {
        eventLoopDelay: {
          percentile: (percentile: number) => number;
          max: number;
          reset: () => void;
        };
      }
    ).eventLoopDelay = {
      percentile: (percentile) => percentile * 1_000_000,
      max: 200_000_000,
      reset: () => {
        eventLoopResetCalled = true;
      },
    };
    (
      sampler as unknown as { lastCpu: { user: number; system: number; timestamp: number } }
    ).lastCpu = {
      user: 0,
      system: 0,
      timestamp: 1_000,
    };

    expect(() => {
      (
        sampler as unknown as {
          sample: () => void;
        }
      ).sample();
    }).not.toThrow();

    expect(opsMetrics).toEqual([
      { metric: "server.event_ring_utilization", value: 0.75, tags: { ring: "timeline" } },
    ]);

    const files = readdirSync(telemetryDir);
    expect(files).toHaveLength(1);
    expect(files[0]).toMatch(/^server-metrics-\d{4}-\d{2}-\d{2}\.jsonl$/);

    const [line] = readFileSync(join(telemetryDir, files[0]), "utf8").trim().split("\n");
    const record = JSON.parse(line);

    expect(record).toEqual({
      ts: 2_000,
      cpu: { user: 25, system: 5, total: 30 },
      memory: { heapUsed: 25, heapTotal: 50, rss: 100, external: 5 },
      sessions: { busy: 1, ready: 2, starting: 0, total: 3, peak: 5 },
      wsConnections: 7,
      eventLoop: { p50: 50, p95: 95, p99: 99, max: 200 },
    });
    expect(eventLoopResetCalled).toBe(true);
    expect((sampler as unknown as { activeSessionPeak: number }).activeSessionPeak).toBe(3);
  });

  it("uses the default interval for invalid env values and custom values when valid", () => {
    const fakeTimer = { unref: vi.fn() } as unknown as NodeJS.Timeout;
    const setIntervalSpy = vi.spyOn(globalThis, "setInterval").mockReturnValue(fakeTimer);

    const deps: ServerMetricsDeps = {
      telemetryDir,
      getSessionCounts: () => ({ busy: 0, ready: 0, starting: 0, total: 0 }),
      getWebSocketCount: () => 0,
    };

    process.env.OPPI_SERVER_METRICS_INTERVAL_MS = "4999";
    const defaultSampler = new ServerResourceSampler(deps);
    defaultSampler.start();
    defaultSampler.stop();

    process.env.OPPI_SERVER_METRICS_INTERVAL_MS = "6000";
    const customSampler = new ServerResourceSampler(deps);
    customSampler.start();
    customSampler.stop();

    expect(setIntervalSpy.mock.calls[0]?.[1]).toBe(30_000);
    expect(setIntervalSpy.mock.calls[1]?.[1]).toBe(6_000);
    expect((fakeTimer.unref as ReturnType<typeof vi.fn>).mock.calls).toHaveLength(2);
  });

  it("drops samples that would exceed the daily JSONL byte cap", () => {
    process.env.OPPI_SERVER_METRICS_DAILY_FILE_MAX_BYTES = "32";
    vi.spyOn(process.stderr, "write").mockReturnValue(true);
    vi.spyOn(Date, "now").mockReturnValue(2_000);
    vi.spyOn(process, "memoryUsage").mockReturnValue({
      rss: 100 * 1024 * 1024,
      heapTotal: 50 * 1024 * 1024,
      heapUsed: 25 * 1024 * 1024,
      external: 5 * 1024 * 1024,
      arrayBuffers: 0,
    });
    vi.spyOn(process, "cpuUsage").mockReturnValue({ user: 0, system: 0 });

    const existingFile = join(telemetryDir, "server-metrics-1970-01-01.jsonl");
    writeFileSync(existingFile, '{"existing":true}\n');
    const before = statSync(existingFile).size;

    const sampler = new ServerResourceSampler({
      telemetryDir,
      getSessionCounts: () => ({ busy: 0, ready: 0, starting: 0, total: 0 }),
      getWebSocketCount: () => 0,
    });

    (
      sampler as unknown as {
        sample: () => void;
      }
    ).sample();

    expect(statSync(existingFile).size).toBe(before);
    expect(readFileSync(existingFile, "utf8")).toBe('{"existing":true}\n');
  });

  it("swallows sampling errors without writing a record", () => {
    const stderr = vi.spyOn(process.stderr, "write").mockReturnValue(true);
    const sampler = new ServerResourceSampler({
      telemetryDir,
      getSessionCounts: () => {
        throw new Error("boom");
      },
      getWebSocketCount: () => 0,
    });

    expect(() => {
      (
        sampler as unknown as {
          sample: () => void;
        }
      ).sample();
    }).not.toThrow();
    expect(readdirSync(telemetryDir)).toEqual([]);
    expect(stderr).toHaveBeenCalled();
  });
});

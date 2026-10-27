import { afterEach, describe, expect, it, vi } from "vitest";

import { ServerResourceSampler, type ServerMetricsDeps } from "../src/server-resource-sampler.js";
import { ServerTelemetry } from "../src/telemetry/server-telemetry.js";
import type { TelemetryEventRecord } from "../src/types.js";

/** Catalog-validating telemetry that keeps what it would write. */
function capture(): { telemetry: ServerTelemetry; written: TelemetryEventRecord[] } {
  const written: TelemetryEventRecord[] = [];
  return {
    telemetry: new ServerTelemetry({ write: (_origin, batch) => written.push(...batch) }),
    written,
  };
}

describe("ServerResourceSampler", () => {
  afterEach(() => {
    delete process.env.OPPI_SERVER_METRICS_INTERVAL_MS;
    vi.restoreAllMocks();
  });

  it("writes each sample at once as a server.resources event and keeps the latest reading", async () => {
    const { telemetry, written } = capture();
    const deps: ServerMetricsDeps = {
      telemetry,
      getSessionCounts: () => ({ busy: 1, ready: 2, starting: 0, total: 3 }),
      getWebSocketCount: () => 7,
      getEventRingSnapshots: () => [
        { ring: "session", length: 3, capacity: 4 },
        { ring: "session", length: 1, capacity: 10 },
        { ring: "session", length: 1, capacity: 0 },
      ],
      hostProbe: {
        sample: async () => ({
          scope: "container" as const,
          cpu: 12.5,
          cpuCores: 2,
          cpuLimited: true,
          memUsed: 1000,
          memTotal: 4000,
        }),
        reset: () => {},
      },
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

    await (sampler as unknown as { sample: () => Promise<void> }).sample();

    expect(written).toEqual([
      {
        v: 2,
        ts: 2_000,
        origin: "server",
        name: "server.resources",
        fields: {
          cpu_total_pct: 30,
          cpu_user_pct: 25,
          cpu_system_pct: 5,
          rss_mb: 100,
          heap_used_mb: 25,
          heap_total_mb: 50,
          external_mb: 5,
          sessions_busy: 1,
          sessions_ready: 2,
          sessions_starting: 0,
          sessions_total: 3,
          sessions_peak: 5,
          ws_connections: 7,
          event_loop_p50_ms: 50,
          event_loop_p95_ms: 95,
          event_loop_p99_ms: 99,
          event_loop_max_ms: 200,
          event_ring_peak_ratio: 0.75,
          host_cpu_pct: 12.5,
          host_cpu_cores: 2,
          host_cpu_limited: 1,
          host_mem_used_mb: 1000,
          host_mem_total_mb: 4000,
        },
        tags: { host_scope: "container" },
      },
    ]);
    expect(sampler.latestSample).toEqual({
      ts: 2_000,
      cpu: { user: 25, system: 5, total: 30 },
      memory: { heapUsed: 25, heapTotal: 50, rss: 100, external: 5 },
      sessions: { busy: 1, ready: 2, starting: 0, total: 3, peak: 5 },
      wsConnections: 7,
      eventLoop: { p50: 50, p95: 95, p99: 99, max: 200 },
      host: {
        scope: "container",
        cpu: 12.5,
        cpuCores: 2,
        cpuLimited: true,
        memUsed: 1000,
        memTotal: 4000,
      },
    });
    expect(eventLoopResetCalled).toBe(true);
    expect((sampler as unknown as { activeSessionPeak: number }).activeSessionPeak).toBe(3);
  });

  it("uses the default interval for invalid env values and custom values when valid", () => {
    const fakeTimer = { unref: vi.fn() } as unknown as NodeJS.Timeout;
    const setIntervalSpy = vi.spyOn(globalThis, "setInterval").mockReturnValue(fakeTimer);

    const deps: ServerMetricsDeps = {
      telemetry: capture().telemetry,
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

  it("drops a sample whose host read was still in flight when sampling stopped", async () => {
    vi.spyOn(globalThis, "setInterval").mockReturnValue({
      unref: vi.fn(),
    } as unknown as NodeJS.Timeout);
    vi.spyOn(globalThis, "clearInterval").mockImplementation(() => {});
    let finishHostRead: (value: { scope: "host"; cpu: number }) => void = () => {};
    const { telemetry, written } = capture();
    const sampler = new ServerResourceSampler({
      telemetry,
      getSessionCounts: () => ({ busy: 0, ready: 0, starting: 0, total: 0 }),
      getWebSocketCount: () => 0,
      hostProbe: {
        sample: () =>
          new Promise((resolve) => {
            finishHostRead = resolve;
          }),
        reset: () => {},
      },
    });

    sampler.start();
    const inFlight = (sampler as unknown as { sample: () => Promise<void> }).sample();
    sampler.stop();
    finishHostRead({ scope: "host", cpu: 50 });
    await inFlight;

    expect(written).toEqual([]);
    expect(sampler.latestSample).toBeNull();
  });

  it("swallows sampling errors without writing an event", async () => {
    const stderr = vi.spyOn(process.stderr, "write").mockReturnValue(true);
    const { telemetry, written } = capture();
    const sampler = new ServerResourceSampler({
      telemetry,
      getSessionCounts: () => {
        throw new Error("boom");
      },
      getWebSocketCount: () => 0,
    });

    await (sampler as unknown as { sample: () => Promise<void> }).sample();
    expect(written).toEqual([]);
    expect(stderr).toHaveBeenCalled();
  });
});

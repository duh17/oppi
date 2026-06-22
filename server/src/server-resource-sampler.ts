/**
 * Server resource utilization metrics collector.
 *
 * Periodically samples CPU, memory, event loop lag, active sessions, and
 * WebSocket connections. Writes samples to daily JSONL files following the
 * same pattern as chat-metrics for the SQLite importer pipeline.
 *
 * File pattern: server-metrics-YYYY-MM-DD.jsonl
 */

import { existsSync, mkdirSync } from "node:fs";
import { monitorEventLoopDelay, type IntervalHistogram } from "node:perf_hooks";
import { join } from "node:path";
import {
  appendJsonlLineWithByteLimit,
  dateString,
  jsonlMaxBytesFromEnv,
  pruneOldJsonlFiles,
  retentionDaysFromEnv,
  round2,
} from "./metric-utils.js";
import { createLogger } from "./logger.js";

const FILE_PREFIX = "server-metrics-";
const FILE_SUFFIX = ".jsonl";
const DEFAULT_INTERVAL_MS = 30_000; // 30s
const DEFAULT_RETENTION_DAYS = 30;
const NS_PER_MS = 1_000_000;

const log = createLogger({ base: { component: "server_resource_sampler" } });

export interface EventRingSnapshot {
  ring: string;
  length: number;
  capacity: number;
}

export interface ServerMetricsDeps {
  /** Absolute path to diagnostics/telemetry directory. */
  telemetryDir: string;
  /** Returns count of in-memory active sessions by status. */
  getSessionCounts: () => { busy: number; ready: number; starting: number; total: number };
  /** Returns count of open WebSocket connections. */
  getWebSocketCount: () => number;
  /** Optional: record selected drill-down samples to the operational metrics collector. */
  recordOpsMetric?: (metric: string, value: number, tags?: Record<string, string>) => void;
  /** Returns event ring snapshots for utilization sampling. */
  getEventRingSnapshots?: () => EventRingSnapshot[];
}

interface CpuSnapshot {
  user: number; // microseconds
  system: number;
  timestamp: number; // Date.now()
}

function intervalFromEnv(): number {
  const raw = process.env.OPPI_SERVER_METRICS_INTERVAL_MS?.trim() ?? "";
  const parsed = Number.parseInt(raw, 10);
  if (Number.isFinite(parsed) && parsed >= 5000) return parsed;
  return DEFAULT_INTERVAL_MS;
}

export class ServerResourceSampler {
  private timer: NodeJS.Timeout | null = null;
  private lastCpu: CpuSnapshot | null = null;
  private eventLoopDelay: IntervalHistogram | null = null;
  private readonly maxFileBytes = jsonlMaxBytesFromEnv("OPPI_SERVER_METRICS_DAILY_FILE_MAX_BYTES");
  private readonly cappedFiles = new Set<string>();
  /** Peak active session count since last sample — reset each interval. */
  private activeSessionPeak = 0;

  constructor(private readonly deps: ServerMetricsDeps) {}

  /** Update the high-water mark. Called externally when sessions start/stop. */
  recordActiveSessionCount(count: number): void {
    if (count > this.activeSessionPeak) {
      this.activeSessionPeak = count;
    }
  }

  start(): void {
    if (this.timer) return;

    // Take initial CPU snapshot for delta calculation
    const usage = process.cpuUsage();
    this.lastCpu = { user: usage.user, system: usage.system, timestamp: Date.now() };

    try {
      this.eventLoopDelay = monitorEventLoopDelay({ resolution: 20 });
      this.eventLoopDelay.enable();
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      log.warn("server_metrics.event_loop_delay.unavailable", { error: message });
      this.eventLoopDelay = null;
    }

    const intervalMs = intervalFromEnv();
    this.timer = setInterval(() => this.sample(), intervalMs);
    // Don't block process exit
    this.timer.unref();

    log.info("server_metrics.sampler.started", { intervalMs });
  }

  stop(): void {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
    this.eventLoopDelay?.disable();
    this.eventLoopDelay = null;
  }

  private captureEventLoopDelay(): { p50: number; p95: number; p99: number; max: number } {
    const histogram = this.eventLoopDelay;
    if (!histogram) return { p50: 0, p95: 0, p99: 0, max: 0 };

    const toMs = (value: number): number =>
      Number.isFinite(value) ? round2(value / NS_PER_MS) : 0;
    const snapshot = {
      p50: toMs(histogram.percentile(50)),
      p95: toMs(histogram.percentile(95)),
      p99: toMs(histogram.percentile(99)),
      max: toMs(histogram.max),
    };
    histogram.reset();
    return snapshot;
  }

  private sample(): void {
    try {
      const now = Date.now();
      const mem = process.memoryUsage();

      // Bun's JSC reports unreliable heapTotal — use bun:jsc for accurate values
      let heapUsed = mem.heapUsed;
      let heapTotal = mem.heapTotal;
      if (typeof (globalThis as Record<string, unknown>).Bun !== "undefined") {
        try {
          // eslint-disable-next-line @typescript-eslint/no-require-imports
          const jsc = require("bun:jsc") as {
            heapStats(): { heapSize: number; heapCapacity: number };
          };
          const stats = jsc.heapStats();
          heapUsed = stats.heapSize;
          heapTotal = stats.heapCapacity;
        } catch {
          if (heapUsed > heapTotal) heapTotal = heapUsed;
        }
      }

      const sessions = this.deps.getSessionCounts();
      const wsCount = this.deps.getWebSocketCount();
      const eventLoop = this.captureEventLoopDelay();

      // CPU usage as percentage (delta since last sample)
      let cpuUser = 0;
      let cpuSystem = 0;
      const cpuUsage = process.cpuUsage();
      if (this.lastCpu) {
        const elapsedMs = now - this.lastCpu.timestamp;
        if (elapsedMs > 0) {
          const elapsedUs = elapsedMs * 1000;
          // cpuUsage returns microseconds; normalize to percentage of one core
          cpuUser = round2(((cpuUsage.user - this.lastCpu.user) / elapsedUs) * 100);
          cpuSystem = round2(((cpuUsage.system - this.lastCpu.system) / elapsedUs) * 100);
        }
      }
      this.lastCpu = { user: cpuUsage.user, system: cpuUsage.system, timestamp: now };

      // Update peak from current sample, then capture and reset
      if (sessions.total > this.activeSessionPeak) {
        this.activeSessionPeak = sessions.total;
      }
      const peak = this.activeSessionPeak;
      this.activeSessionPeak = sessions.total; // reset for next interval

      // `peak` is written in the structured server resource sample below.
      // Do not also mirror it into server-ops metrics; that produced a noisy
      // duplicate no-SLO row every sampler interval.

      // Sample event ring utilization
      const ringSnapshots = this.deps.getEventRingSnapshots?.() ?? [];
      for (const snap of ringSnapshots) {
        if (snap.capacity > 0) {
          this.deps.recordOpsMetric?.(
            "server.event_ring_utilization",
            round2(snap.length / snap.capacity),
            { ring: snap.ring },
          );
        }
      }

      const record = {
        ts: now,
        cpu: {
          user: cpuUser,
          system: cpuSystem,
          total: round2(cpuUser + cpuSystem),
        },
        memory: {
          heapUsed: round2(heapUsed / 1024 / 1024),
          heapTotal: round2(heapTotal / 1024 / 1024),
          rss: round2(mem.rss / 1024 / 1024),
          external: round2(mem.external / 1024 / 1024),
        },
        sessions: {
          ...sessions,
          peak,
        },
        wsConnections: wsCount,
        eventLoop,
      };

      this.appendToFile(now, record);
      this.pruneOldFiles();
    } catch (err) {
      // Best effort — don't crash the server
      const message = err instanceof Error ? err.message : String(err);
      log.error("server_metrics.sample.failed", { error: message });
    }
  }

  private appendToFile(ts: number, record: unknown): void {
    const dir = this.deps.telemetryDir;
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }
    const fileName = `${FILE_PREFIX}${dateString(ts)}${FILE_SUFFIX}`;
    const filePath = join(dir, fileName);
    const wrote = appendJsonlLineWithByteLimit(
      filePath,
      JSON.stringify(record) + "\n",
      this.maxFileBytes,
    );
    if (!wrote) {
      this.warnDailyCapOnce(filePath);
    }
  }

  private warnDailyCapOnce(filePath: string): void {
    if (this.cappedFiles.has(filePath)) return;
    this.cappedFiles.add(filePath);
    log.warn("server_metrics.write.daily_file_cap_reached", {
      filePath,
      maxFileBytes: this.maxFileBytes,
    });
  }

  private pruneOldFiles(): void {
    pruneOldJsonlFiles(
      this.deps.telemetryDir,
      FILE_PREFIX,
      FILE_SUFFIX,
      retentionDaysFromEnv("OPPI_SERVER_METRICS_RETENTION_DAYS", DEFAULT_RETENTION_DAYS),
    );
  }
}

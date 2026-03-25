/**
 * Server resource utilization metrics collector.
 *
 * Periodically samples CPU, memory, event loop lag, active sessions, and
 * WebSocket connections. Writes samples to daily JSONL files following the
 * same pattern as chat-metrics for the SQLite importer pipeline.
 *
 * File pattern: server-metrics-YYYY-MM-DD.jsonl
 */

import { appendFileSync, existsSync, mkdirSync, readdirSync, unlinkSync } from "node:fs";
import { join } from "node:path";

const FILE_PREFIX = "server-metrics-";
const FILE_SUFFIX = ".jsonl";
const DEFAULT_INTERVAL_MS = 30_000; // 30s
const DEFAULT_RETENTION_DAYS = 30;

export interface ServerMetricsDeps {
  /** Absolute path to diagnostics/telemetry directory. */
  telemetryDir: string;
  /** Returns count of in-memory active sessions by status. */
  getSessionCounts: () => { busy: number; ready: number; starting: number; total: number };
  /** Returns count of open WebSocket connections. */
  getWebSocketCount: () => number;
  /** Optional: record to the operational metrics collector (for session_active_peak). */
  recordOpsMetric?: (metric: string, value: number) => void;
}

interface CpuSnapshot {
  user: number; // microseconds
  system: number;
  timestamp: number; // Date.now()
}

function retentionDaysFromEnv(): number {
  const raw = process.env.OPPI_SERVER_METRICS_RETENTION_DAYS?.trim() ?? "";
  const parsed = Number.parseInt(raw, 10);
  if (Number.isFinite(parsed) && parsed > 0) return parsed;
  return DEFAULT_RETENTION_DAYS;
}

function intervalFromEnv(): number {
  const raw = process.env.OPPI_SERVER_METRICS_INTERVAL_MS?.trim() ?? "";
  const parsed = Number.parseInt(raw, 10);
  if (Number.isFinite(parsed) && parsed >= 5000) return parsed;
  return DEFAULT_INTERVAL_MS;
}

function dateString(ts: number): string {
  const d = new Date(ts);
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, "0");
  const day = String(d.getUTCDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function round2(n: number): number {
  return Math.round(n * 100) / 100;
}

export class ServerResourceSampler {
  private timer: NodeJS.Timeout | null = null;
  private lastCpu: CpuSnapshot | null = null;
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

    const intervalMs = intervalFromEnv();
    this.timer = setInterval(() => this.sample(), intervalMs);
    // Don't block process exit
    this.timer.unref();

    console.log("[server-metrics] started", { intervalMs });
  }

  stop(): void {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  private sample(): void {
    try {
      const now = Date.now();
      const mem = process.memoryUsage();
      const sessions = this.deps.getSessionCounts();
      const wsCount = this.deps.getWebSocketCount();

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

      if (peak > 0) {
        this.deps.recordOpsMetric?.("server.session_active_peak", peak);
      }

      const record = {
        ts: now,
        cpu: {
          user: cpuUser,
          system: cpuSystem,
          total: round2(cpuUser + cpuSystem),
        },
        memory: {
          heapUsed: round2(mem.heapUsed / 1024 / 1024),
          heapTotal: round2(mem.heapTotal / 1024 / 1024),
          rss: round2(mem.rss / 1024 / 1024),
          external: round2(mem.external / 1024 / 1024),
        },
        sessions: {
          ...sessions,
          peak,
        },
        wsConnections: wsCount,
      };

      this.appendToFile(now, record);
      this.pruneOldFiles();
    } catch (err) {
      // Best effort — don't crash the server
      const message = err instanceof Error ? err.message : String(err);
      console.error("[server-metrics] sample failed", { error: message });
    }
  }

  private appendToFile(ts: number, record: unknown): void {
    const dir = this.deps.telemetryDir;
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }
    const fileName = `${FILE_PREFIX}${dateString(ts)}${FILE_SUFFIX}`;
    const filePath = join(dir, fileName);
    appendFileSync(filePath, JSON.stringify(record) + "\n");
  }

  private pruneOldFiles(): void {
    const retentionMs = retentionDaysFromEnv() * 24 * 60 * 60 * 1000;
    const cutoffMs = Date.now() - retentionMs;
    const dir = this.deps.telemetryDir;

    if (!existsSync(dir)) return;

    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch {
      return;
    }

    for (const entry of entries) {
      if (!entry.startsWith(FILE_PREFIX) || !entry.endsWith(FILE_SUFFIX)) continue;
      const datePart = entry.slice(FILE_PREFIX.length, -FILE_SUFFIX.length);
      const fileDate = Date.parse(`${datePart}T00:00:00.000Z`);
      if (Number.isNaN(fileDate) || fileDate >= cutoffMs) continue;
      try {
        unlinkSync(join(dir, entry));
      } catch {
        // Best effort
      }
    }
  }
}

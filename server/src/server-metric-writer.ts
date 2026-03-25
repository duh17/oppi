/**
 * JSONL metric writer for server operational metrics.
 *
 * Writes batched samples to daily JSONL files following the same rotation
 * and retention pattern as server-metrics.ts. Files land in:
 *   diagnostics/telemetry/server-ops-metrics-YYYY-MM-DD.jsonl
 *
 * Retention default: 30 days, configurable via OPPI_SERVER_OPS_METRICS_RETENTION_DAYS.
 */

import { appendFileSync, existsSync, mkdirSync, readdirSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import type { ServerMetricSample } from "./server-metric-collector.js";

const FILE_PREFIX = "server-ops-metrics-";
const FILE_SUFFIX = ".jsonl";
const DEFAULT_RETENTION_DAYS = 30;

function retentionDaysFromEnv(): number {
  const raw = process.env.OPPI_SERVER_OPS_METRICS_RETENTION_DAYS?.trim() ?? "";
  const parsed = Number.parseInt(raw, 10);
  if (Number.isFinite(parsed) && parsed > 0) return parsed;
  return DEFAULT_RETENTION_DAYS;
}

function dateString(ts: number): string {
  const d = new Date(ts);
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, "0");
  const day = String(d.getUTCDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

export interface MetricWriter {
  writeBatch(samples: ServerMetricSample[]): void;
}

export class JsonlMetricWriter implements MetricWriter {
  private readonly retentionDays: number;

  constructor(
    private readonly telemetryDir: string,
    retentionDays?: number,
  ) {
    this.retentionDays = retentionDays ?? retentionDaysFromEnv();
  }

  writeBatch(samples: ServerMetricSample[]): void {
    if (samples.length === 0) return;

    try {
      const now = Date.now();
      const record = {
        flushedAt: now,
        sampleCount: samples.length,
        samples,
      };

      if (!existsSync(this.telemetryDir)) {
        mkdirSync(this.telemetryDir, { recursive: true });
      }

      const fileName = `${FILE_PREFIX}${dateString(now)}${FILE_SUFFIX}`;
      const filePath = join(this.telemetryDir, fileName);
      appendFileSync(filePath, JSON.stringify(record) + "\n");

      this.pruneOldFiles();
    } catch (err) {
      // Best effort — never throw from the writer
      const message = err instanceof Error ? err.message : String(err);
      console.error("[server-ops-metrics] write failed", { error: message });
    }
  }

  private pruneOldFiles(): void {
    const retentionMs = this.retentionDays * 24 * 60 * 60 * 1000;
    const cutoffMs = Date.now() - retentionMs;

    if (!existsSync(this.telemetryDir)) return;

    let entries: string[];
    try {
      entries = readdirSync(this.telemetryDir);
    } catch {
      return;
    }

    for (const entry of entries) {
      if (!entry.startsWith(FILE_PREFIX) || !entry.endsWith(FILE_SUFFIX)) continue;
      const datePart = entry.slice(FILE_PREFIX.length, -FILE_SUFFIX.length);
      const fileDate = Date.parse(`${datePart}T00:00:00.000Z`);
      if (Number.isNaN(fileDate) || fileDate >= cutoffMs) continue;
      try {
        unlinkSync(join(this.telemetryDir, entry));
      } catch {
        // Best effort
      }
    }
  }
}

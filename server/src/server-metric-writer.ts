/**
 * JSONL metric writer for server operational metrics.
 *
 * Writes batched samples to daily JSONL files following the same rotation
 * and retention pattern as server-metrics.ts. Files land in:
 *   diagnostics/telemetry/server-ops-metrics-YYYY-MM-DD.jsonl
 *
 * Retention default: 30 days, configurable via OPPI_SERVER_OPS_METRICS_RETENTION_DAYS.
 */

import { appendFileSync, existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import type { ServerMetricSample } from "./server-metric-collector.js";
import { dateString, pruneOldJsonlFiles, retentionDaysFromEnv } from "./metric-utils.js";

const FILE_PREFIX = "server-ops-metrics-";
const FILE_SUFFIX = ".jsonl";
const DEFAULT_RETENTION_DAYS = 30;

export interface MetricWriter {
  writeBatch(samples: ServerMetricSample[]): void;
}

export class JsonlMetricWriter implements MetricWriter {
  private readonly retentionDays: number;

  constructor(
    private readonly telemetryDir: string,
    retentionDays?: number,
  ) {
    this.retentionDays =
      retentionDays ??
      retentionDaysFromEnv("OPPI_SERVER_OPS_METRICS_RETENTION_DAYS", DEFAULT_RETENTION_DAYS);
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
    pruneOldJsonlFiles(this.telemetryDir, FILE_PREFIX, FILE_SUFFIX, this.retentionDays);
  }
}

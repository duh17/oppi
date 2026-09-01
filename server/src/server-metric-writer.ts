/**
 * JSONL metric writer for server operational metrics.
 *
 * Writes batched samples to daily JSONL files following the same rotation
 * and retention pattern as server-metrics.ts. Files land in:
 *   diagnostics/telemetry/server-ops-metrics-YYYY-MM-DD.jsonl
 *
 * Retention default: 30 days, configurable via OPPI_SERVER_OPS_METRICS_RETENTION_DAYS.
 */

import { existsSync } from "node:fs";
import { join } from "node:path";
import type { ServerMetricSample } from "./server-metric-collector.js";
import {
  appendJsonlLineWithByteLimit,
  dateString,
  ensurePrivateDiagnosticsDir,
  jsonlMaxBytesFromEnv,
  pruneOldJsonlFiles,
  retentionDaysFromEnv,
} from "./metric-utils.js";
import { createLogger } from "./logger.js";

const FILE_PREFIX = "server-ops-metrics-";
const FILE_SUFFIX = ".jsonl";
const DEFAULT_RETENTION_DAYS = 30;

const log = createLogger({ base: { component: "server_metric_writer" } });

export interface MetricWriter {
  writeBatch(samples: ServerMetricSample[]): void;
}

export class JsonlMetricWriter implements MetricWriter {
  private readonly retentionDays: number;
  private readonly maxFileBytes: number | null;
  private readonly cappedFiles = new Set<string>();

  constructor(
    private readonly telemetryDir: string,
    retentionDays?: number,
    maxFileBytes?: number | null,
  ) {
    this.retentionDays =
      retentionDays ??
      retentionDaysFromEnv("OPPI_SERVER_OPS_METRICS_RETENTION_DAYS", DEFAULT_RETENTION_DAYS);
    this.maxFileBytes =
      maxFileBytes === undefined
        ? jsonlMaxBytesFromEnv("OPPI_SERVER_OPS_METRICS_DAILY_FILE_MAX_BYTES")
        : maxFileBytes;
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
        ensurePrivateDiagnosticsDir(this.telemetryDir);
      }

      const fileName = `${FILE_PREFIX}${dateString(now)}${FILE_SUFFIX}`;
      const filePath = join(this.telemetryDir, fileName);
      const wrote = appendJsonlLineWithByteLimit(
        filePath,
        JSON.stringify(record) + "\n",
        this.maxFileBytes,
      );
      if (!wrote) {
        this.warnDailyCapOnce(filePath);
      }

      this.pruneOldFiles();
    } catch (err) {
      // Best effort — never throw from the writer
      const message = err instanceof Error ? err.message : String(err);
      log.error("server_ops_metrics.write.failed", { error: message });
    }
  }

  private warnDailyCapOnce(filePath: string): void {
    if (this.cappedFiles.has(filePath)) return;
    this.cappedFiles.add(filePath);
    log.warn("server_ops_metrics.write.daily_file_cap_reached", {
      filePath,
      maxFileBytes: this.maxFileBytes,
    });
  }

  private pruneOldFiles(): void {
    pruneOldJsonlFiles(this.telemetryDir, FILE_PREFIX, FILE_SUFFIX, this.retentionDays);
  }
}

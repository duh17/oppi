/**
 * Daily JSONL files for v2 telemetry event records, one line per event:
 *   diagnostics/telemetry/app-events-YYYY-MM-DD.jsonl     (uploaded by Apple clients)
 *   diagnostics/telemetry/server-events-YYYY-MM-DD.jsonl  (server emitters and resource samples)
 *
 * Files are named by the server's UTC write date; readers filter by each
 * record's `ts`. Retention and daily byte caps come from the environment:
 *
 * | origin | retention (default)                        | daily cap                                  |
 * | app    | OPPI_CHAT_METRICS_RETENTION_DAYS (14)      | OPPI_TELEMETRY_DAILY_FILE_MAX_BYTES        |
 * | server | OPPI_SERVER_METRICS_RETENTION_DAYS (30)    | OPPI_SERVER_METRICS_DAILY_FILE_MAX_BYTES   |
 *
 * Pruning also removes the pre-v2 files (`chat-metrics-`, `server-ops-metrics-`,
 * `server-metrics-`) on their successor's retention so they age out. Nothing
 * reads or writes those files any more.
 */

import { existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";

import { createLogger } from "../logger.js";
import {
  appendJsonlLineWithByteLimit,
  dateString,
  jsonlMaxBytesFromEnv,
  pruneOldJsonlFiles,
  retentionDaysFromEnv,
} from "../metric-utils.js";
import type { TelemetryEventRecord } from "../types.js";
import type { TelemetryOrigin } from "./catalog.js";

const FILE_SUFFIX = ".jsonl";

const ORIGIN_FILES = {
  app: {
    prefix: "app-events-",
    legacyPrefixes: ["chat-metrics-"],
    retentionEnv: "OPPI_CHAT_METRICS_RETENTION_DAYS",
    defaultRetentionDays: 14,
    maxBytesEnv: "OPPI_TELEMETRY_DAILY_FILE_MAX_BYTES",
  },
  server: {
    prefix: "server-events-",
    legacyPrefixes: ["server-ops-metrics-", "server-metrics-"],
    retentionEnv: "OPPI_SERVER_METRICS_RETENTION_DAYS",
    defaultRetentionDays: 30,
    maxBytesEnv: "OPPI_SERVER_METRICS_DAILY_FILE_MAX_BYTES",
  },
} as const satisfies Record<
  TelemetryOrigin,
  {
    prefix: string;
    legacyPrefixes: readonly string[];
    retentionEnv: string;
    defaultRetentionDays: number;
    maxBytesEnv: string;
  }
>;

const log = createLogger({ base: { component: "telemetry_event_writer" } });

/** File name of an origin's daily event file for a UTC timestamp. */
export function telemetryEventFileName(origin: TelemetryOrigin, ts: number): string {
  return `${ORIGIN_FILES[origin].prefix}${dateString(ts)}${FILE_SUFFIX}`;
}

export interface TelemetryEventSink {
  write(origin: TelemetryOrigin, records: readonly TelemetryEventRecord[]): void;
}

export class TelemetryEventWriter implements TelemetryEventSink {
  private readonly cappedFiles = new Set<string>();

  constructor(private readonly telemetryDir: string) {}

  /** Append records as one write. Best effort: logs and returns on failure. */
  write(origin: TelemetryOrigin, records: readonly TelemetryEventRecord[]): void {
    if (records.length === 0) return;
    try {
      if (!existsSync(this.telemetryDir)) {
        mkdirSync(this.telemetryDir, { recursive: true, mode: 0o700 });
      }
      const filePath = join(this.telemetryDir, telemetryEventFileName(origin, Date.now()));
      let lines = "";
      for (const record of records) lines += `${JSON.stringify(record)}\n`;
      const maxBytes = jsonlMaxBytesFromEnv(ORIGIN_FILES[origin].maxBytesEnv);
      if (!appendJsonlLineWithByteLimit(filePath, lines, maxBytes)) {
        this.warnDailyCapOnce(filePath, maxBytes);
      }
      this.prune(origin);
    } catch (err) {
      log.error("telemetry_events.write.failed", {
        origin,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }

  /** Remove an origin's event files, and its legacy files, past retention. */
  prune(origin: TelemetryOrigin): void {
    const spec = ORIGIN_FILES[origin];
    const days = retentionDaysFromEnv(spec.retentionEnv, spec.defaultRetentionDays);
    for (const prefix of [spec.prefix, ...spec.legacyPrefixes]) {
      pruneOldJsonlFiles(this.telemetryDir, prefix, FILE_SUFFIX, days);
    }
  }

  private warnDailyCapOnce(filePath: string, maxBytes: number | null): void {
    if (this.cappedFiles.has(filePath)) return;
    this.cappedFiles.add(filePath);
    log.warn("telemetry_events.write.daily_file_cap_reached", { filePath, maxBytes });
  }
}

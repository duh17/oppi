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
 * The daily cap bounds event volume, not resource history: `server.resources`
 * (one small record every 30 s, about 2 MB a day) is neither held to the cap nor
 * counted against it. The writer tracks the bytes of every other event in a file
 * itself (seeded from the file the first time a process writes to it), so a busy
 * day of ops events cannot starve the Server Metrics page of samples, and
 * resource samples cannot eat the ops budget.
 *
 * Pruning also removes the pre-v2 files (`chat-metrics-`, `server-ops-metrics-`,
 * `server-metrics-`) on their successor's retention so they age out. Nothing
 * reads or writes those files any more.
 */

import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

import { createLogger } from "../logger.js";
import {
  dateString,
  jsonlMaxBytesFromEnv,
  pruneOldJsonlFiles,
  retentionDaysFromEnv,
} from "../metric-utils.js";
import type { TelemetryEventRecord } from "../types.js";
import type { TelemetryOrigin } from "./catalog.js";

const FILE_SUFFIX = ".jsonl";

/** Events written whatever the daily cap says: the Server Metrics history reads them. */
const CAP_EXEMPT_EVENTS: ReadonlySet<string> = new Set(["server.resources"]);

/** True for a stored line of a cap-exempt event. */
function isCapExemptLine(line: string): boolean {
  try {
    const name = (JSON.parse(line) as { name?: unknown }).name;
    return typeof name === "string" && CAP_EXEMPT_EVENTS.has(name);
  } catch {
    return false;
  }
}

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
  /** Bytes of cap-counted events per daily file, for this process's view of the file. */
  private readonly cappedBytes = new Map<string, number>();

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
      let exemptLines = "";
      for (const record of records) {
        const line = `${JSON.stringify(record)}\n`;
        if (CAP_EXEMPT_EVENTS.has(record.name)) exemptLines += line;
        else lines += line;
      }
      if (exemptLines) appendFileSync(filePath, exemptLines, { encoding: "utf8", mode: 0o600 });
      if (lines) {
        const maxBytes = jsonlMaxBytesFromEnv(ORIGIN_FILES[origin].maxBytesEnv);
        if (!this.appendCounted(filePath, lines, maxBytes)) {
          this.warnDailyCapOnce(filePath, maxBytes);
        }
      }
      this.prune(origin);
    } catch (err) {
      log.error("telemetry_events.write.failed", {
        origin,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }

  /** Append cap-counted lines unless they would push the file's counted bytes past `maxBytes`. */
  private appendCounted(filePath: string, lines: string, maxBytes: number | null): boolean {
    const lineBytes = Buffer.byteLength(lines, "utf8");
    if (maxBytes !== null) {
      const counted = this.countedBytes(filePath);
      if (lineBytes > maxBytes || counted + lineBytes > maxBytes) return false;
    }
    appendFileSync(filePath, lines, { encoding: "utf8", mode: 0o600 });
    if (this.cappedBytes.has(filePath)) {
      this.cappedBytes.set(filePath, (this.cappedBytes.get(filePath) ?? 0) + lineBytes);
    }
    return true;
  }

  /** Bytes of the file's cap-counted lines; reads an existing file once per process. */
  private countedBytes(filePath: string): number {
    const known = this.cappedBytes.get(filePath);
    if (known !== undefined) return known;
    let counted = 0;
    if (existsSync(filePath)) {
      for (const line of readFileSync(filePath, "utf8").split("\n")) {
        if (line && !isCapExemptLine(line)) counted += Buffer.byteLength(line, "utf8") + 1;
      }
    }
    this.cappedBytes.set(filePath, counted);
    return counted;
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

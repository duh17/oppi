/**
 * History for the Server Metrics page, read from the resource sampler's raw
 * daily files (`server-metrics-YYYY-MM-DD.jsonl`, one sample every ~30s, kept
 * 30 days). Every range buckets those samples on request; no derived files.
 *
 * Cost, measured on mac-studio: 30 days is ~86k samples (~25–36 MB) and
 * parses in ~90 ms, one file at a time so the event loop gets turns between
 * days. The page refreshes only the 1h and 24h ranges on a timer.
 */

import { readFile } from "node:fs/promises";
import { join } from "node:path";

import { dateString, round2 } from "./metric-utils.js";

export const RAW_FILE_PREFIX = "server-metrics-";
const FILE_SUFFIX = ".jsonl";

const MINUTE_MS = 60_000;
const HOUR_MS = 60 * MINUTE_MS;
const DAY_MS = 24 * HOUR_MS;

/** Series every point carries. Host series are absent before host sampling existed. */
export const SERVER_METRIC_SERIES = [
  "cpu",
  "rss",
  "heapUsed",
  "eventLoopP99",
  "sessions",
  "wsConnections",
  "hostCpu",
  "memUsed",
  "diskUsed",
] as const;
export type ServerMetricSeriesKey = (typeof SERVER_METRIC_SERIES)[number];

/** One line of `server-metrics-*.jsonl`, as the sampler writes it. */
export interface ServerResourceRecord {
  ts: number;
  cpu: { user: number; system: number; total: number };
  memory: { heapUsed: number; heapTotal: number; rss: number; external: number };
  sessions: { busy: number; ready: number; starting: number; total: number; peak: number };
  wsConnections: number;
  eventLoop: { p50: number; p95: number; p99: number; max: number };
  host?: HostRecord;
}

/**
 * Host readings, from the machine or from the container Oppi runs in.
 * `scope: "container"` means CPU and memory are the container's cgroup usage
 * against its limits, not the machine's. MB and percent.
 */
export interface HostRecord {
  scope: "host" | "container";
  /** Busy share of `cpuCores`, 0–100. */
  cpu?: number;
  /** CPUs available: the machine's, the container's CPU quota, or every CPU it may run on. */
  cpuCores?: number;
  /** True when `cpuCores` is a container's CPU quota. */
  cpuLimited?: boolean;
  /** Machine load average; omitted in a container, where it is the machine's. */
  load1?: number;
  memUsed?: number;
  /** Physical memory, or the container's memory limit. */
  memTotal?: number;
  /** True when `memTotal` is a container's memory limit, not the machine's memory. */
  memLimited?: boolean;
  diskUsed?: number;
  diskTotal?: number;
}

export const SERVER_METRICS_RANGES = {
  "1h": { durationMs: HOUR_MS, bucketMs: MINUTE_MS },
  "24h": { durationMs: DAY_MS, bucketMs: 5 * MINUTE_MS },
  "7d": { durationMs: 7 * DAY_MS, bucketMs: 30 * MINUTE_MS },
  "30d": { durationMs: 30 * DAY_MS, bucketMs: 2 * HOUR_MS },
} as const;
export type ServerMetricsRange = keyof typeof SERVER_METRICS_RANGES;

export function parseServerMetricsRange(raw: string | null): ServerMetricsRange | undefined {
  if (raw === null) return "24h";
  return Object.hasOwn(SERVER_METRICS_RANGES, raw) ? (raw as ServerMetricsRange) : undefined;
}

/** Columnar series: `avg[i]` and `max[i]` belong to `ts[i]`; null is a gap. */
export interface ServerMetricsSeries {
  avg: Array<number | null>;
  max: Array<number | null>;
}

export interface ServerMetricsHistory {
  range: ServerMetricsRange;
  bucketMs: number;
  /** Bucket start times, ms since epoch, oldest first. */
  ts: number[];
  series: Record<ServerMetricSeriesKey, ServerMetricsSeries>;
}

interface Stat {
  sum: number;
  max: number;
  n: number;
}
type Bucket = Partial<Record<ServerMetricSeriesKey, Stat>>;

function recordValues(record: ServerResourceRecord): Record<ServerMetricSeriesKey, unknown> {
  return {
    cpu: record.cpu?.total,
    rss: record.memory?.rss,
    heapUsed: record.memory?.heapUsed,
    eventLoopP99: record.eventLoop?.p99,
    sessions: record.sessions?.total,
    wsConnections: record.wsConnections,
    hostCpu: record.host?.cpu,
    memUsed: record.host?.memUsed,
    diskUsed: record.host?.diskUsed,
  };
}

function addRecord(bucket: Bucket, record: ServerResourceRecord): void {
  const values = recordValues(record);
  for (const key of SERVER_METRIC_SERIES) {
    const value = values[key];
    if (typeof value !== "number" || !Number.isFinite(value)) continue;
    const stat = bucket[key];
    if (stat) {
      stat.sum += value;
      stat.max = Math.max(stat.max, value);
      stat.n++;
    } else {
      bucket[key] = { sum: value, max: value, n: 1 };
    }
  }
}

function bucketStart(ts: number, bucketMs: number): number {
  return Math.floor(ts / bucketMs) * bucketMs;
}

async function readRawRecords(dir: string, date: string): Promise<ServerResourceRecord[]> {
  let text: string;
  try {
    text = await readFile(join(dir, `${RAW_FILE_PREFIX}${date}${FILE_SUFFIX}`), "utf8");
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw err;
  }
  const records: ServerResourceRecord[] = [];
  for (const line of text.split("\n")) {
    if (!line) continue;
    try {
      const value: unknown = JSON.parse(line);
      if (
        typeof value === "object" &&
        value !== null &&
        typeof (value as { ts?: unknown }).ts === "number"
      ) {
        records.push(value as ServerResourceRecord);
      }
    } catch {
      // A torn final line from a crash mid-append; the rest of the file is fine.
    }
  }
  return records;
}

export async function readServerMetricsHistory(
  dir: string,
  range: ServerMetricsRange,
  now: number = Date.now(),
): Promise<ServerMetricsHistory> {
  const spec = SERVER_METRICS_RANGES[range];
  const firstBucket = bucketStart(now - spec.durationMs, spec.bucketMs) + spec.bucketMs;
  const lastBucket = bucketStart(now, spec.bucketMs);
  const buckets = new Map<number, Bucket>();

  // Files are UTC days; read every day the window touches, oldest first.
  for (let day = bucketStart(firstBucket, DAY_MS); day <= now; day += DAY_MS) {
    for (const record of await readRawRecords(dir, dateString(day))) {
      const start = bucketStart(record.ts, spec.bucketMs);
      if (start < firstBucket || start > lastBucket) continue;
      let bucket = buckets.get(start);
      if (!bucket) {
        bucket = {};
        buckets.set(start, bucket);
      }
      addRecord(bucket, record);
    }
  }

  const ts: number[] = [];
  const series = Object.fromEntries(
    SERVER_METRIC_SERIES.map((key) => [key, { avg: [], max: [] } as ServerMetricsSeries]),
  ) as Record<ServerMetricSeriesKey, ServerMetricsSeries>;
  for (let start = firstBucket; start <= lastBucket; start += spec.bucketMs) {
    ts.push(start);
    const bucket = buckets.get(start);
    for (const key of SERVER_METRIC_SERIES) {
      const stat = bucket?.[key];
      series[key].avg.push(stat ? round2(stat.sum / stat.n) : null);
      series[key].max.push(stat ? stat.max : null);
    }
  }
  return { range, bucketMs: spec.bucketMs, ts, series };
}

/**
 * Server operational metric collector.
 *
 * Event-driven buffer that accumulates metric samples in memory and
 * flushes them to a MetricWriter on a timer or when the buffer fills.
 * All public methods are non-blocking and never throw — metrics are
 * best-effort and must not impact server operation.
 */

import type { ServerMetricName } from "./server-metric-registry.js";
import type { MetricWriter } from "./server-metric-writer.js";

export interface ServerMetricSample {
  ts: number;
  metric: ServerMetricName;
  value: number;
  tags?: Record<string, string>;
}

const MAX_TAG_KEY_LENGTH = 32;
const MAX_TAG_VALUE_LENGTH = 128;
const MAX_TAGS_PER_SAMPLE = 8;

/** Sanitize tags: truncate keys/values, cap count, drop empty values. */
function sanitizeTags(
  tags: Record<string, string> | undefined,
): Record<string, string> | undefined {
  if (!tags) return undefined;

  const keys = Object.keys(tags);
  if (keys.length === 0) return undefined;

  const result: Record<string, string> = {};
  let count = 0;

  for (const key of keys) {
    if (count >= MAX_TAGS_PER_SAMPLE) break;

    const value = tags[key];
    if (!value && value !== "0") continue;

    const safeKey = key.slice(0, MAX_TAG_KEY_LENGTH);
    const safeValue = value.slice(0, MAX_TAG_VALUE_LENGTH);
    result[safeKey] = safeValue;
    count++;
  }

  return count > 0 ? result : undefined;
}

export class ServerMetricCollector {
  private buffer: ServerMetricSample[] = [];
  private flushTimer: NodeJS.Timeout | null = null;
  private readonly flushIntervalMs: number;
  private readonly maxBufferSize: number;

  constructor(
    private readonly writer: MetricWriter,
    options?: { flushIntervalMs?: number; maxBufferSize?: number },
  ) {
    this.flushIntervalMs = options?.flushIntervalMs ?? 10_000;
    this.maxBufferSize = options?.maxBufferSize ?? 500;
  }

  /** Record a single metric sample. Non-blocking, never throws. */
  record(metric: ServerMetricName, value: number, tags?: Record<string, string>): void {
    try {
      const sample: ServerMetricSample = {
        ts: Date.now(),
        metric,
        value,
        tags: sanitizeTags(tags),
      };
      this.buffer.push(sample);

      if (this.buffer.length >= this.maxBufferSize) {
        this.flush();
      }
    } catch {
      // Best effort — never throw from record()
    }
  }

  /** Start periodic flush timer. */
  start(): void {
    if (this.flushTimer) return;
    this.flushTimer = setInterval(() => this.flush(), this.flushIntervalMs);
    this.flushTimer.unref();
  }

  /** Flush buffered samples to storage. */
  flush(): void {
    if (this.buffer.length === 0) return;
    const batch = this.buffer;
    this.buffer = [];
    try {
      this.writer.writeBatch(batch);
    } catch {
      // Best effort — never throw from flush()
    }
  }

  /** Stop the flush timer and flush remaining samples. */
  stop(): void {
    if (this.flushTimer) {
      clearInterval(this.flushTimer);
      this.flushTimer = null;
    }
    this.flush();
  }

  /** Current buffer length (for testing). */
  get bufferedCount(): number {
    return this.buffer.length;
  }
}

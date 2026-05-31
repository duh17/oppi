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

const AGGREGATED_SUM_METRICS = new Set<ServerMetricName>([
  "server.ws_message_sent",
  "server.ws_message_received",
  "server.ws_binary_received_bytes",
  "server.user_stream_event",
  "server.gate_decision",
  "server.turn_input_tokens",
  "server.turn_output_tokens",
  "server.turn_cost",
]);

const AGGREGATED_MAX_METRICS = new Set<ServerMetricName>([
  "server.broadcast_fanout",
  "server.event_ring_utilization",
]);

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

function stableTagKey(tags: Record<string, string> | undefined): string {
  if (!tags) return "";
  return Object.keys(tags)
    .sort()
    .map((key) => `${key}=${tags[key] ?? ""}`)
    .join("\u0000");
}

function aggregateKey(metric: ServerMetricName, tags: Record<string, string> | undefined): string {
  return `${metric}\u0000${stableTagKey(tags)}`;
}

export class ServerMetricCollector {
  private buffer: ServerMetricSample[] = [];
  private aggregateBuffer: Map<string, ServerMetricSample> = new Map();
  private flushTimer: NodeJS.Timeout | null = null;
  private readonly flushIntervalMs: number;
  private readonly maxBufferSize: number;

  constructor(
    private readonly writer: MetricWriter,
    options?: { flushIntervalMs?: number; maxBufferSize?: number },
  ) {
    this.flushIntervalMs = options?.flushIntervalMs ?? 60_000;
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

      const shouldAggregate =
        Number.isFinite(sample.value) &&
        (AGGREGATED_SUM_METRICS.has(metric) || AGGREGATED_MAX_METRICS.has(metric));
      if (shouldAggregate) {
        const key = aggregateKey(metric, sample.tags);
        const existing = this.aggregateBuffer.get(key);
        if (existing) {
          existing.ts = sample.ts;
          existing.value = AGGREGATED_SUM_METRICS.has(metric)
            ? existing.value + sample.value
            : Math.max(existing.value, sample.value);
        } else {
          this.aggregateBuffer.set(key, sample);
        }
      } else {
        this.buffer.push(sample);
      }

      if (this.bufferedCount >= this.maxBufferSize) {
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
    if (this.bufferedCount === 0) return;
    const batch = [...this.aggregateBuffer.values(), ...this.buffer];
    this.aggregateBuffer.clear();
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
    return this.buffer.length + this.aggregateBuffer.size;
  }
}

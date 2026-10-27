/**
 * Typed server telemetry emitter.
 *
 * `record(name, fields, tags)` takes its types from the catalog, so an unknown
 * event, field, tag, or enum value fails to compile. Events are validated
 * against the catalog again at runtime (`name` tags are sanitized), buffered,
 * and written as v2 records on a 60 s timer or when the buffer fills. Events
 * whose catalog entry declares `storage.aggregate` fold into one record per
 * tag set, session, and workspace for the flush window.
 *
 * Best effort: no public method throws, and telemetry never affects the
 * operation it measures.
 */

import { createLogger } from "../logger.js";
import type { TelemetryEventRecord } from "../types.js";
import {
  EVENT_DEFS,
  type EventFields,
  type EventTags,
  type ServerEventName,
  type StorageSpec,
} from "./catalog.js";
import type { TelemetryEventSink } from "./event-writer.js";
import { validateEvent } from "./validate.js";

const log = createLogger({ base: { component: "server_telemetry" } });

export interface TelemetryRecordIds {
  sessionId?: string;
  workspaceId?: string;
}

function aggregateKey(record: TelemetryEventRecord): string {
  const tags = Object.keys(record.tags)
    .sort()
    .map((key) => `${key}=${record.tags[key]}`)
    .join("\u0000");
  return [record.name, record.sessionId ?? "", record.workspaceId ?? "", tags].join("\u0001");
}

function fold(into: TelemetryEventRecord, next: TelemetryEventRecord, storage: StorageSpec): void {
  into.ts = next.ts;
  for (const [field, op] of Object.entries(storage.aggregate)) {
    const value = next.fields[field];
    if (value === undefined) continue;
    const current = into.fields[field];
    if (current === undefined) into.fields[field] = value;
    else into.fields[field] = op === "sum" ? current + value : Math.max(current, value);
  }
}

export class ServerTelemetry {
  private buffer: TelemetryEventRecord[] = [];
  private aggregates = new Map<string, TelemetryEventRecord>();
  private flushTimer: NodeJS.Timeout | null = null;
  private readonly rejected = new Set<string>();
  private readonly flushIntervalMs: number;
  private readonly maxBufferSize: number;

  constructor(
    private readonly sink: TelemetryEventSink,
    options?: { flushIntervalMs?: number; maxBufferSize?: number },
  ) {
    this.flushIntervalMs = options?.flushIntervalMs ?? 60_000;
    this.maxBufferSize = options?.maxBufferSize ?? 500;
  }

  /** Buffer one event. Aggregated events fold into their window record. */
  record<N extends ServerEventName>(
    name: N,
    fields: EventFields<N>,
    tags: EventTags<N>,
    ids?: TelemetryRecordIds,
  ): void {
    try {
      const record = this.build(name, fields, tags, ids);
      if (!record) return;
      const storage = EVENT_DEFS[name]?.storage;
      if (storage) {
        const key = aggregateKey(record);
        const existing = this.aggregates.get(key);
        if (existing) fold(existing, record, storage);
        else this.aggregates.set(key, record);
      } else {
        this.buffer.push(record);
      }
      if (this.bufferedCount >= this.maxBufferSize) this.flush();
    } catch {
      // Best effort — never throw from record()
    }
  }

  /**
   * Write one event now, bypassing the buffer. For low-rate samples a reader
   * needs promptly: `server.resources` feeds the Server Metrics page history.
   */
  recordNow<N extends ServerEventName>(
    name: N,
    fields: EventFields<N>,
    tags: EventTags<N>,
    ids?: TelemetryRecordIds,
  ): void {
    try {
      const record = this.build(name, fields, tags, ids);
      if (record) this.sink.write("server", [record]);
    } catch {
      // Best effort
    }
  }

  start(): void {
    if (this.flushTimer) return;
    this.flushTimer = setInterval(() => this.flush(), this.flushIntervalMs);
    this.flushTimer.unref();
  }

  flush(): void {
    if (this.bufferedCount === 0) return;
    const batch = [...this.aggregates.values(), ...this.buffer];
    this.aggregates.clear();
    this.buffer = [];
    try {
      this.sink.write("server", batch);
    } catch {
      // Best effort
    }
  }

  stop(): void {
    if (this.flushTimer) {
      clearInterval(this.flushTimer);
      this.flushTimer = null;
    }
    this.flush();
  }

  get bufferedCount(): number {
    return this.buffer.length + this.aggregates.size;
  }

  private build(
    name: string,
    fields: object,
    tags: object,
    ids: TelemetryRecordIds | undefined,
  ): TelemetryEventRecord | undefined {
    const result = validateEvent("server", name, fields, tags);
    if (!result.ok) {
      // Types rule out most of these; runtime values (an unexpected enum
      // string, a NaN duration) can still slip through. Log each kind once.
      const key = `${name}:${result.reason}`;
      if (!this.rejected.has(key)) {
        this.rejected.add(key);
        log.warn("server_telemetry.event_rejected", { name, reason: result.reason });
      }
      return undefined;
    }
    return {
      v: 2,
      ts: Date.now(),
      origin: "server",
      name,
      fields: result.event.fields,
      tags: result.event.tags,
      ...(ids?.sessionId ? { sessionId: ids.sessionId } : {}),
      ...(ids?.workspaceId ? { workspaceId: ids.workspaceId } : {}),
    };
  }
}

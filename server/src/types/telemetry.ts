export function telemetryUploadsEnabledFromEnv(mode = process.env.OPPI_TELEMETRY_MODE): boolean {
  const raw = mode?.trim().toLowerCase() ?? "";
  if (!raw) {
    return true;
  }

  switch (raw) {
    case "internal":
    case "debug":
    case "test":
    case "qa":
    case "staging":
    case "dev":
    case "development":
    case "enabled":
    case "on":
    case "true":
    case "1":
      return true;
    case "public":
    case "release":
    case "prod":
    case "production":
    case "off":
    case "disabled":
    case "none":
    case "false":
    case "0":
      return false;
    default:
      return false;
  }
}

export type ClientKind = "ios" | "mac";

/**
 * Who sent an upload. Shared by `POST /telemetry/events`, `/telemetry/client-logs`,
 * and `/telemetry/metrickit`. `deviceModel` is the hardware identifier
 * (`iPhone17,1`), not a marketing name.
 */
export interface TelemetryClient {
  kind: ClientKind;
  appVersion?: string;
  buildNumber?: string;
  /** Short SHA, optional `-dirty`. Anything else is dropped at ingest. */
  gitCommit?: string;
  osVersion?: string;
  deviceModel?: string;
  appInstanceId?: string;
  bootId?: string;
}

/**
 * Why ingest did not store an uploaded event. A `POST /telemetry/events` body is
 * `{ generatedAt, client, events: [{ ts, name, fields, tags?, sessionId?,
 * workspaceId? }] }`, where each event follows the telemetry catalog; ingest
 * validates every event (`routes/telemetry.ts`) and the Swift encoder is
 * generated from the catalog.
 */
export type TelemetryDropReason =
  | "malformed"
  | "invalid_timestamp"
  | "over_batch_limit"
  | "unknown_event"
  | "wrong_origin"
  | "missing_field"
  | "unknown_field"
  | "invalid_field_value"
  | "missing_tag"
  | "unknown_tag"
  | "invalid_tag_value"
  | "emit_policy";

export interface TelemetryEventUploadResponse {
  ok: true;
  accepted: number;
  /** Events not stored, by reason. Retrying them cannot succeed. */
  dropped: Partial<Record<TelemetryDropReason, number>>;
}

/**
 * One stored telemetry event: one JSONL line in `app-events-YYYY-MM-DD.jsonl`
 * or `server-events-YYYY-MM-DD.jsonl`. Server records aggregated by the catalog
 * carry the flush-window sum or max in `fields` and the last event's `ts`.
 */
export interface TelemetryEventRecord {
  v: 2;
  ts: number;
  origin: "app" | "server";
  name: string;
  fields: Record<string, number>;
  tags: Record<string, string>;
  sessionId?: string;
  workspaceId?: string;
  client?: TelemetryClient;
}

export interface MetricKitPayloadItem {
  /** "metric" (MXMetricPayload) or "diagnostic" (MXDiagnosticPayload). */
  kind: "metric" | "diagnostic";
  /** Window start of telemetry sample (ms since epoch). */
  windowStartMs: number;
  /** Window end of telemetry sample (ms since epoch). */
  windowEndMs: number;
  /** Low-cardinality summary suitable for dashboards/alerts. */
  summary: Record<string, string>;
  /** Sanitized raw payload JSON for later inspection/replay. */
  raw: Record<string, unknown> | string;
}

export interface MetricKitUploadRequest {
  generatedAt: number;
  client: TelemetryClient;
  payloads: MetricKitPayloadItem[];
}

export type ClientLogLevel = "debug" | "info" | "warn" | "error";

export interface ClientLogEntry {
  /** Client-side timestamp (ms since epoch). */
  ts: number;
  /** Monotonic per-process sequence assigned before upload. */
  seq: number;
  level: ClientLogLevel;
  category: string;
  message: string;
  metadata?: Record<string, string>;
  sessionId?: string;
  workspaceId?: string;
}

export interface ClientLogUploadRequest {
  generatedAt: number;
  client: TelemetryClient;
  droppedCount?: number;
  entries: ClientLogEntry[];
}

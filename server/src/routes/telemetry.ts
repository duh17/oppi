import type { IncomingMessage, ServerResponse } from "node:http";
import { appendFileSync, existsSync, mkdirSync, readdirSync, unlinkSync } from "node:fs";
import { join } from "node:path";

import type {
  ChatMetricSample,
  ChatMetricUploadRequest,
  MetricKitPayloadItem,
  MetricKitUploadRequest,
} from "../types.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

const METRICKIT_DIR = "telemetry";
const METRICKIT_FILE_PREFIX = "metrickit-";
const METRICKIT_FILE_SUFFIX = ".jsonl";
const METRICKIT_MAX_PAYLOAD_COUNT = 160;
const METRICKIT_MAX_SUMMARY_FIELDS = 24;
const METRICKIT_MAX_SUMMARY_VALUE_CHARS = 256;

const CHAT_METRIC_FILE_PREFIX = "chat-metrics-";
const CHAT_METRIC_MAX_SAMPLE_COUNT = 200;
const CHAT_METRIC_MAX_TAG_FIELDS = 16;
const CHAT_METRIC_MAX_TAG_KEY_CHARS = 96;
const CHAT_METRIC_MAX_TAG_VALUE_CHARS = 256;
const CHAT_METRIC_MAX_METRIC_CHARS = 96;
const CHAT_METRIC_MAX_UNIT_CHARS = 16;

function telemetryDir(ctx: RouteContext): string {
  return join(ctx.storage.getDataDir(), "diagnostics", METRICKIT_DIR);
}

function metrickitFileName(timestampMs: number): string {
  const date = new Date(timestampMs);
  return `${METRICKIT_FILE_PREFIX}${date.toISOString().slice(0, 10)}${METRICKIT_FILE_SUFFIX}`;
}

function metrickitRetentionDaysFromEnv(): number {
  const raw = process.env.OPPI_METRICKIT_RETENTION_DAYS?.trim() ?? "";
  const parsed = Number.parseInt(raw, 10);
  if (Number.isFinite(parsed) && parsed > 0) return parsed;
  return 14;
}

function chatMetricRetentionDaysFromEnv(): number {
  const raw = process.env.OPPI_CHAT_METRICS_RETENTION_DAYS?.trim() ?? "";
  const parsed = Number.parseInt(raw, 10);
  if (Number.isFinite(parsed) && parsed > 0) return parsed;
  return 14;
}

function telemetryUploadsEnabledFromEnv(): boolean {
  const raw = process.env.OPPI_TELEMETRY_MODE?.trim().toLowerCase() ?? "";
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

function isString(value: unknown): value is string {
  return typeof value === "string";
}

function trimText(value: string | undefined, maxLength: number): string {
  return isString(value) ? value.slice(0, maxLength) : "";
}

function toFiniteNumber(value: unknown, fallback: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return fallback;
  return Math.trunc(value);
}

function pruneTelemetryDataByPrefix(
  ctx: RouteContext,
  filePrefix: string,
  retentionDays: number,
): void {
  const retentionMs = retentionDays * 24 * 60 * 60 * 1_000;
  const cutoffMs = Date.now() - retentionMs;
  const dir = telemetryDir(ctx);

  if (!existsSync(dir)) {
    return;
  }

  let entries: string[];
  try {
    entries = readdirSync(dir);
  } catch {
    return;
  }

  for (const entry of entries) {
    if (!entry.startsWith(filePrefix) || !entry.endsWith(METRICKIT_FILE_SUFFIX)) {
      continue;
    }

    const datePart = entry.slice(filePrefix.length, -METRICKIT_FILE_SUFFIX.length);
    const fileDate = Date.parse(`${datePart}T00:00:00.000Z`);
    if (Number.isNaN(fileDate) || fileDate >= cutoffMs) {
      continue;
    }

    try {
      unlinkSync(join(dir, entry));
    } catch {
      // Best effort.
    }
  }
}

function pruneOldMetricKitTelemetryData(ctx: RouteContext): void {
  pruneTelemetryDataByPrefix(ctx, METRICKIT_FILE_PREFIX, metrickitRetentionDaysFromEnv());
}

function pruneOldChatMetricsTelemetryData(ctx: RouteContext): void {
  pruneTelemetryDataByPrefix(ctx, CHAT_METRIC_FILE_PREFIX, chatMetricRetentionDaysFromEnv());
}

function sanitizePayloadValue(
  value: unknown,
  depth: number,
):
  | string
  | number
  | boolean
  | null
  | (string | number | boolean | null)[]
  | Record<string, unknown> {
  if (value === null || value === undefined) return null;
  if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
    return value;
  }

  if (Array.isArray(value)) {
    return value.slice(0, 16).map((item) => {
      if (typeof item === "string") return item.slice(0, 128);
      if (typeof item === "number" || typeof item === "boolean") return item;
      if (item === null || item === undefined) return null;
      return String(item);
    });
  }

  if (typeof value === "object" && depth > 0) {
    const obj = value as Record<string, unknown>;
    const safe: Record<string, unknown> = {};
    for (const [key, child] of Object.entries(obj).slice(0, 16)) {
      safe[trimText(key, 96)] = sanitizePayloadValue(child, depth - 1);
    }
    return safe;
  }

  return String(value).slice(0, 128);
}

function sanitizePayloadRaw(payload: unknown): Record<string, unknown> {
  if (!payload || typeof payload !== "object") return {};

  const input = payload as Record<string, unknown>;
  const out: Record<string, unknown> = {};

  for (const [key, value] of Object.entries(input).slice(0, 64)) {
    out[trimText(key, 96)] = sanitizePayloadValue(value, 3);
  }

  return out;
}

function sanitizeSummary(value: unknown): Record<string, string> {
  if (!value || typeof value !== "object") return {};

  const input = value as Record<string, unknown>;
  const out: Record<string, string> = {};

  for (const [key, child] of Object.entries(input)) {
    if (Object.keys(out).length >= METRICKIT_MAX_SUMMARY_FIELDS) break;

    const safeKey = trimText(key, 96);
    if (safeKey.length === 0) continue;

    if (typeof child === "string") {
      out[safeKey] = trimText(child, METRICKIT_MAX_SUMMARY_VALUE_CHARS);
      continue;
    }

    if (typeof child === "number") {
      out[safeKey] = String(child);
      continue;
    }

    if (typeof child === "boolean") {
      out[safeKey] = child ? "true" : "false";
      continue;
    }

    if (child instanceof Date) {
      out[safeKey] = child.toISOString();
      continue;
    }

    if (child && typeof child === "object") {
      out[safeKey] = trimText(JSON.stringify(child), METRICKIT_MAX_SUMMARY_VALUE_CHARS);
      continue;
    }

    out[safeKey] = "";
  }

  return out;
}

function sanitizeString(value: unknown, maxLength: number): string {
  if (!isString(value)) return "";
  return trimText(value, maxLength);
}

function normalizePayload(
  payload: unknown,
  fallbackWindowStart: number,
): { payload: MetricKitPayloadItem; ok: true } | { ok: false } {
  if (!payload || typeof payload !== "object") {
    return { ok: false };
  }

  const raw = payload as Record<string, unknown>;
  const kind = raw.kind === "diagnostic" ? "diagnostic" : "metric";

  const windowStart = toFiniteNumber(raw.windowStartMs, fallbackWindowStart);
  const windowEnd = toFiniteNumber(raw.windowEndMs, fallbackWindowStart);

  return {
    ok: true,
    payload: {
      kind,
      windowStartMs: windowStart,
      windowEndMs: Math.max(windowStart, windowEnd),
      summary: sanitizeSummary(raw.summary),
      raw: sanitizePayloadRaw(raw.raw),
    },
  };
}

function parseRequest(body: unknown): MetricKitUploadRequest | null {
  if (!body || typeof body !== "object") return null;

  const raw = body as Record<string, unknown>;
  const rawPayloads = raw.payloads;
  if (!Array.isArray(rawPayloads)) return null;

  const generatedAt = toFiniteNumber(raw.generatedAt, Date.now());
  const result: MetricKitUploadRequest = {
    generatedAt,
    appVersion: sanitizeString(raw.appVersion, 96),
    buildNumber: sanitizeString(raw.buildNumber, 64),
    osVersion: sanitizeString(raw.osVersion, 128),
    deviceModel: sanitizeString(raw.deviceModel, 128),
    payloads: [],
  };

  for (const candidate of rawPayloads.slice(0, METRICKIT_MAX_PAYLOAD_COUNT)) {
    const parsed = normalizePayload(candidate, generatedAt);
    if (parsed.ok) result.payloads.push(parsed.payload);
  }

  if (result.payloads.length === 0) return null;
  return result;
}

function appendMetricKitRecord(ctx: RouteContext, request: MetricKitUploadRequest): void {
  const dir = telemetryDir(ctx);
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
  }

  const record = {
    receivedAt: Date.now(),
    generatedAt: request.generatedAt,
    appVersion: request.appVersion,
    buildNumber: request.buildNumber,
    osVersion: request.osVersion,
    deviceModel: request.deviceModel,
    payloadCount: request.payloads.length,
    payloads: request.payloads,
  };

  const path = join(dir, metrickitFileName(request.generatedAt));
  appendFileSync(path, `${JSON.stringify(record)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
}

const CHAT_METRIC_NAMES = new Set<ChatMetricSample["metric"]>([
  "chat.ttft_ms",
  "chat.catchup_ms",
  "chat.catchup_ring_miss",
  "chat.timeline_apply_ms",
  "chat.timeline_layout_ms",
  "chat.ws_decode_ms",
  "chat.coalescer_flush_events",
  "chat.coalescer_flush_bytes",
  "chat.inbound_queue_depth",
  "chat.full_reload_ms",
  "chat.fresh_content_lag_ms",
  "chat.cache_load_ms",
  "chat.reducer_load_ms",
  "chat.ws_connect_ms",
  "chat.voice_prewarm_ms",
  "chat.voice_setup_ms",
  "chat.voice_first_result_ms",
]);

const CHAT_METRIC_UNITS = new Set<ChatMetricSample["unit"]>(["ms", "count", "ratio"]);

function sanitizeChatMetricTags(value: unknown): Record<string, string> {
  if (!value || typeof value !== "object") {
    return {};
  }

  const out: Record<string, string> = {};
  const input = value as Record<string, unknown>;

  for (const [key, rawValue] of Object.entries(input)) {
    if (Object.keys(out).length >= CHAT_METRIC_MAX_TAG_FIELDS) {
      break;
    }

    if (typeof rawValue !== "string") {
      continue;
    }

    const safeKey = trimText(key, CHAT_METRIC_MAX_TAG_KEY_CHARS);
    if (!safeKey) {
      continue;
    }

    out[safeKey] = trimText(rawValue, CHAT_METRIC_MAX_TAG_VALUE_CHARS);
  }

  return out;
}

function normalizeChatMetricSample(value: unknown): ChatMetricSample | null {
  if (!value || typeof value !== "object") {
    return null;
  }

  const sample = value as Record<string, unknown>;

  const tsRaw = sample.ts;
  const valueRaw = sample.value;
  if (typeof tsRaw !== "number" || !Number.isFinite(tsRaw)) {
    return null;
  }
  if (typeof valueRaw !== "number" || !Number.isFinite(valueRaw)) {
    return null;
  }

  const metricRaw = sanitizeString(
    sample.metric,
    CHAT_METRIC_MAX_METRIC_CHARS,
  ) as ChatMetricSample["metric"];
  if (!CHAT_METRIC_NAMES.has(metricRaw)) {
    return null;
  }

  const unitRaw = sanitizeString(
    sample.unit,
    CHAT_METRIC_MAX_UNIT_CHARS,
  ) as ChatMetricSample["unit"];
  if (!CHAT_METRIC_UNITS.has(unitRaw)) {
    return null;
  }

  const sessionId = sanitizeString(sample.sessionId, 96);
  const workspaceId = sanitizeString(sample.workspaceId, 96);
  const tags = sanitizeChatMetricTags(sample.tags);

  return {
    ts: Math.trunc(tsRaw),
    metric: metricRaw,
    value: valueRaw,
    unit: unitRaw,
    ...(sessionId ? { sessionId } : {}),
    ...(workspaceId ? { workspaceId } : {}),
    ...(Object.keys(tags).length > 0 ? { tags } : {}),
  };
}

function parseChatMetricRequest(body: unknown): ChatMetricUploadRequest | null {
  if (!body || typeof body !== "object") {
    return null;
  }

  const raw = body as Record<string, unknown>;
  const rawSamples = raw.samples;
  if (!Array.isArray(rawSamples)) {
    return null;
  }

  const generatedAt = toFiniteNumber(raw.generatedAt, Date.now());
  const samples: ChatMetricSample[] = [];

  for (const candidate of rawSamples.slice(0, CHAT_METRIC_MAX_SAMPLE_COUNT)) {
    const normalized = normalizeChatMetricSample(candidate);
    if (normalized) {
      samples.push(normalized);
    }
  }

  if (samples.length === 0) {
    return null;
  }

  return {
    generatedAt,
    appVersion: sanitizeString(raw.appVersion, 96),
    buildNumber: sanitizeString(raw.buildNumber, 64),
    osVersion: sanitizeString(raw.osVersion, 128),
    deviceModel: sanitizeString(raw.deviceModel, 128),
    samples,
  };
}

function appendChatMetricRecord(ctx: RouteContext, request: ChatMetricUploadRequest): void {
  const dir = telemetryDir(ctx);
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
  }

  const record = {
    receivedAt: Date.now(),
    generatedAt: request.generatedAt,
    appVersion: request.appVersion,
    buildNumber: request.buildNumber,
    osVersion: request.osVersion,
    deviceModel: request.deviceModel,
    sampleCount: request.samples.length,
    samples: request.samples,
  };

  const path = join(
    dir,
    `${CHAT_METRIC_FILE_PREFIX}${new Date(request.generatedAt).toISOString().slice(0, 10)}${METRICKIT_FILE_SUFFIX}`,
  );
  appendFileSync(path, `${JSON.stringify(record)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
}

export function createTelemetryRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  async function handleUploadMetricKit(req: IncomingMessage, res: ServerResponse): Promise<void> {
    if (!telemetryUploadsEnabledFromEnv()) {
      helpers.error(res, 403, "telemetry uploads disabled by OPPI_TELEMETRY_MODE");
      return;
    }

    const rawBody = await helpers.parseBody<MetricKitUploadRequest>(req);
    const request = parseRequest(rawBody);
    if (!request) {
      helpers.error(res, 400, "payloads must be a non-empty array");
      return;
    }

    appendMetricKitRecord(ctx, request);
    pruneOldMetricKitTelemetryData(ctx);

    const windowStartMs = Math.min(...request.payloads.map((payload) => payload.windowStartMs));
    const windowEndMs = Math.max(...request.payloads.map((payload) => payload.windowEndMs));

    helpers.json(res, {
      ok: true,
      accepted: request.payloads.length,
      windowStartMs,
      windowEndMs,
    });
  }

  async function handleUploadChatMetrics(req: IncomingMessage, res: ServerResponse): Promise<void> {
    if (!telemetryUploadsEnabledFromEnv()) {
      helpers.error(res, 403, "telemetry uploads disabled by OPPI_TELEMETRY_MODE");
      return;
    }

    const rawBody = await helpers.parseBody<ChatMetricUploadRequest>(req);
    const request = parseChatMetricRequest(rawBody);
    if (!request) {
      helpers.error(res, 400, "samples must be a non-empty array of valid metrics");
      return;
    }

    appendChatMetricRecord(ctx, request);
    pruneOldChatMetricsTelemetryData(ctx);

    const windowStartMs = Math.min(...request.samples.map((sample) => sample.ts));
    const windowEndMs = Math.max(...request.samples.map((sample) => sample.ts));

    helpers.json(res, {
      ok: true,
      accepted: request.samples.length,
      windowStartMs,
      windowEndMs,
    });
  }

  return async ({ method, path, req, res }) => {
    if (method === "POST" && path === "/telemetry/metrickit") {
      await handleUploadMetricKit(req, res);
      return true;
    }

    if (method === "POST" && path === "/telemetry/chat-metrics") {
      await handleUploadChatMetrics(req, res);
      return true;
    }

    return false;
  };
}

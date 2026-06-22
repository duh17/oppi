import type { IncomingMessage, ServerResponse } from "node:http";
import { existsSync, mkdirSync, readdirSync, unlinkSync } from "node:fs";
import { join } from "node:path";

import { isSensitiveLogKey, redactLogString, REDACTED } from "../log-redact.js";
import { appendJsonlLineWithByteLimit, jsonlMaxBytesFromEnv } from "../metric-utils.js";
import { createLogger } from "../logger.js";
import {
  CHAT_METRIC_NAME_VALUES,
  CHAT_METRIC_REGISTRY,
  telemetryUploadsEnabledFromEnv,
  type ChatMetricSample,
  type ChatMetricUploadRequest,
  type ClientKind,
  type ClientLogEntry,
  type ClientLogLevel,
  type ClientLogUploadRequest,
  type MetricKitPayloadItem,
  type MetricKitUploadRequest,
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

const CLIENT_LOG_FILE_PREFIX = "client-logs-";
const CLIENT_LOG_MAX_ENTRY_COUNT = 200;
const CLIENT_LOG_MAX_CATEGORY_CHARS = 96;
const CLIENT_LOG_MAX_MESSAGE_CHARS = 2_048;
const CLIENT_LOG_MAX_METADATA_FIELDS = 24;
const CLIENT_LOG_MAX_METADATA_KEY_CHARS = 96;
const CLIENT_LOG_MAX_METADATA_VALUE_CHARS = 512;
const CLIENT_LOG_MAX_ID_CHARS = 128;

const log = createLogger({ base: { component: "telemetry_routes" } });
const cappedTelemetryFiles = new Set<string>();

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

function toValidTimestamp(value: unknown, fallback: number): number | null {
  if (value === undefined || value === null) {
    return fallback;
  }
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return null;
  }

  const timestamp = Math.trunc(value);
  return Number.isNaN(new Date(timestamp).getTime()) ? null : timestamp;
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

function sanitizeRedactedString(value: unknown, maxLength: number): string {
  if (!isString(value)) return "";
  return redactLogString(value, maxLength);
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
  const rawClientKind = sanitizeString(raw.clientKind, 16);
  const appInstanceId = sanitizeRedactedString(raw.appInstanceId, 128);
  const bootId = sanitizeRedactedString(raw.bootId, 128);
  const result: MetricKitUploadRequest = {
    generatedAt,
    appVersion: sanitizeString(raw.appVersion, 96),
    buildNumber: sanitizeString(raw.buildNumber, 64),
    osVersion: sanitizeString(raw.osVersion, 128),
    deviceModel: sanitizeString(raw.deviceModel, 128),
    clientKind: rawClientKind === "ios" || rawClientKind === "mac" ? rawClientKind : undefined,
    appInstanceId: appInstanceId || undefined,
    bootId: bootId || undefined,
    payloads: [],
  };

  for (const candidate of rawPayloads.slice(0, METRICKIT_MAX_PAYLOAD_COUNT)) {
    const parsed = normalizePayload(candidate, generatedAt);
    if (parsed.ok) result.payloads.push(parsed.payload);
  }

  if (result.payloads.length === 0) return null;
  return result;
}

function appendTelemetryRecord(kind: string, path: string, record: unknown): void {
  const maxBytes = jsonlMaxBytesFromEnv("OPPI_TELEMETRY_DAILY_FILE_MAX_BYTES");
  const wrote = appendJsonlLineWithByteLimit(path, `${JSON.stringify(record)}\n`, maxBytes);
  if (wrote) return;

  const key = `${kind}:${path}`;
  if (cappedTelemetryFiles.has(key)) return;
  cappedTelemetryFiles.add(key);
  log.warn("telemetry.write.daily_file_cap_reached", {
    kind,
    path,
    maxBytes,
  });
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
    clientKind: request.clientKind,
    appInstanceId: request.appInstanceId,
    bootId: request.bootId,
    payloadCount: request.payloads.length,
    payloads: request.payloads,
  };

  const path = join(dir, metrickitFileName(request.generatedAt));
  appendTelemetryRecord("metrickit", path, record);
}

const CHAT_METRIC_NAMES = new Set<ChatMetricSample["metric"]>(CHAT_METRIC_NAME_VALUES);

if (CHAT_METRIC_NAMES.size !== CHAT_METRIC_NAME_VALUES.length) {
  throw new Error("CHAT_METRIC_NAME_VALUES contains duplicate entries");
}

if (Object.keys(CHAT_METRIC_REGISTRY).length !== CHAT_METRIC_NAME_VALUES.length) {
  throw new Error("CHAT_METRIC_REGISTRY must stay in parity with CHAT_METRIC_NAME_VALUES");
}

function isChatMetricName(value: string): value is ChatMetricSample["metric"] {
  return CHAT_METRIC_NAMES.has(value as ChatMetricSample["metric"]);
}

function normalizeChatMetricTagKey(key: string): string {
  const candidate = trimText(key, CHAT_METRIC_MAX_TAG_KEY_CHARS);
  if (!candidate) {
    return "";
  }

  const normalized = candidate
    .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
    .replace(/[^A-Za-z0-9_]+/g, "_")
    .replace(/_+/g, "_")
    .replace(/^_+|_+$/g, "")
    .toLowerCase();

  return trimText(normalized, CHAT_METRIC_MAX_TAG_KEY_CHARS);
}

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

    const safeKey = normalizeChatMetricTagKey(key);
    if (!safeKey || safeKey in out) {
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

  const metricCandidate = sanitizeString(sample.metric, CHAT_METRIC_MAX_METRIC_CHARS);
  if (!isChatMetricName(metricCandidate)) {
    return null;
  }
  const metricRaw = metricCandidate;

  const unitRaw = sanitizeString(
    sample.unit,
    CHAT_METRIC_MAX_UNIT_CHARS,
  ) as ChatMetricSample["unit"];
  if (unitRaw !== CHAT_METRIC_REGISTRY[metricRaw].unit) {
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
  appendTelemetryRecord("chat_metrics", path, record);
}

function isClientKind(value: string): value is ClientKind {
  return value === "ios" || value === "mac";
}

function normalizeClientLogLevel(value: unknown): ClientLogLevel | null {
  if (value === "debug" || value === "info" || value === "warn" || value === "error") {
    return value;
  }
  if (value === "warning") {
    return "warn";
  }
  return null;
}

function sanitizeClientLogMetadata(value: unknown): Record<string, string> | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return undefined;
  }

  const out: Record<string, string> = {};
  for (const [key, rawValue] of Object.entries(value as Record<string, unknown>)) {
    if (Object.keys(out).length >= CLIENT_LOG_MAX_METADATA_FIELDS) {
      break;
    }
    if (typeof rawValue !== "string") {
      continue;
    }

    const safeKey = redactLogString(key.trim(), CLIENT_LOG_MAX_METADATA_KEY_CHARS);
    if (!safeKey || safeKey in out) {
      continue;
    }

    out[safeKey] =
      isSensitiveLogKey(key) || isSensitiveLogKey(safeKey)
        ? REDACTED
        : redactLogString(rawValue, CLIENT_LOG_MAX_METADATA_VALUE_CHARS);
  }

  return Object.keys(out).length > 0 ? out : undefined;
}

function normalizeClientLogEntry(value: unknown): ClientLogEntry | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }

  const raw = value as Record<string, unknown>;
  const ts = raw.ts;
  const seq = raw.seq;
  if (typeof ts !== "number" || !Number.isFinite(ts)) {
    return null;
  }
  if (typeof seq !== "number" || !Number.isFinite(seq)) {
    return null;
  }

  const level = normalizeClientLogLevel(raw.level);
  if (!level) {
    return null;
  }

  const category = sanitizeRedactedString(raw.category, CLIENT_LOG_MAX_CATEGORY_CHARS);
  const message = sanitizeRedactedString(raw.message, CLIENT_LOG_MAX_MESSAGE_CHARS);
  if (!category || !message) {
    return null;
  }

  const metadata = sanitizeClientLogMetadata(raw.metadata);
  const sessionId = sanitizeRedactedString(raw.sessionId, CLIENT_LOG_MAX_ID_CHARS);
  const workspaceId = sanitizeRedactedString(raw.workspaceId, CLIENT_LOG_MAX_ID_CHARS);

  return {
    ts: Math.trunc(ts),
    seq: Math.trunc(seq),
    level,
    category,
    message,
    ...(metadata ? { metadata } : {}),
    ...(sessionId ? { sessionId } : {}),
    ...(workspaceId ? { workspaceId } : {}),
  };
}

function parseClientLogRequest(body: unknown): ClientLogUploadRequest | null {
  if (!body || typeof body !== "object") {
    return null;
  }

  const raw = body as Record<string, unknown>;
  const clientKindRaw = sanitizeString(raw.clientKind, 16);
  if (!isClientKind(clientKindRaw)) {
    return null;
  }

  const rawEntries = raw.entries;
  if (!Array.isArray(rawEntries)) {
    return null;
  }

  const entries: ClientLogEntry[] = [];
  for (const candidate of rawEntries.slice(0, CLIENT_LOG_MAX_ENTRY_COUNT)) {
    const normalized = normalizeClientLogEntry(candidate);
    if (normalized) {
      entries.push(normalized);
    }
  }

  if (entries.length === 0) {
    return null;
  }

  const generatedAt = toValidTimestamp(raw.generatedAt, Date.now());
  if (generatedAt === null) {
    return null;
  }

  const droppedCountRaw = raw.droppedCount;
  const droppedCount =
    typeof droppedCountRaw === "number" && Number.isFinite(droppedCountRaw)
      ? Math.max(0, Math.trunc(droppedCountRaw))
      : undefined;

  return {
    generatedAt,
    appVersion: sanitizeRedactedString(raw.appVersion, 96),
    buildNumber: sanitizeRedactedString(raw.buildNumber, 64),
    osVersion: sanitizeRedactedString(raw.osVersion, 128),
    deviceModel: sanitizeRedactedString(raw.deviceModel, 128),
    clientKind: clientKindRaw,
    appInstanceId: sanitizeRedactedString(raw.appInstanceId, CLIENT_LOG_MAX_ID_CHARS),
    bootId: sanitizeRedactedString(raw.bootId, CLIENT_LOG_MAX_ID_CHARS),
    ...(droppedCount && droppedCount > 0 ? { droppedCount } : {}),
    entries,
  };
}

function appendClientLogRecord(ctx: RouteContext, request: ClientLogUploadRequest): void {
  const dir = telemetryDir(ctx);
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
  }

  const receivedAt = Date.now();
  const record = {
    receivedAt,
    generatedAt: request.generatedAt,
    appVersion: request.appVersion,
    buildNumber: request.buildNumber,
    osVersion: request.osVersion,
    deviceModel: request.deviceModel,
    clientKind: request.clientKind,
    appInstanceId: request.appInstanceId,
    bootId: request.bootId,
    droppedCount: request.droppedCount ?? 0,
    entryCount: request.entries.length,
    entries: request.entries.map((entry) => ({
      receivedAt,
      clientKind: request.clientKind,
      appInstanceId: request.appInstanceId,
      bootId: request.bootId,
      ...entry,
    })),
  };

  const path = join(
    dir,
    `${CLIENT_LOG_FILE_PREFIX}${new Date(request.generatedAt).toISOString().slice(0, 10)}${METRICKIT_FILE_SUFFIX}`,
  );
  appendTelemetryRecord("client_logs", path, record);
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

  async function handleUploadClientLogs(req: IncomingMessage, res: ServerResponse): Promise<void> {
    if (!telemetryUploadsEnabledFromEnv()) {
      helpers.error(res, 403, "telemetry uploads disabled by OPPI_TELEMETRY_MODE");
      return;
    }

    const rawBody = await helpers.parseBody<ClientLogUploadRequest>(req);
    const request = parseClientLogRequest(rawBody);
    if (!request) {
      helpers.error(res, 400, "entries must be a non-empty array of valid client logs");
      return;
    }

    appendClientLogRecord(ctx, request);
    pruneTelemetryDataByPrefix(ctx, CLIENT_LOG_FILE_PREFIX, chatMetricRetentionDaysFromEnv());

    const windowStartMs = Math.min(...request.entries.map((entry) => entry.ts));
    const windowEndMs = Math.max(...request.entries.map((entry) => entry.ts));

    helpers.json(res, {
      ok: true,
      accepted: request.entries.length,
      droppedCount: request.droppedCount ?? 0,
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

    if (method === "POST" && path === "/telemetry/client-logs") {
      await handleUploadClientLogs(req, res);
      return true;
    }

    return false;
  };
}

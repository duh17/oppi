import type { IncomingMessage, ServerResponse } from "node:http";
import { join } from "node:path";

import { isSensitiveLogKey, redactLogString, REDACTED } from "../log-redact.js";
import { createLogger, type Logger } from "../logger.js";
import { TelemetryEventWriter } from "../telemetry/event-writer.js";
import { validateEvent } from "../telemetry/validate.js";
import {
  telemetryUploadsEnabledFromEnv,
  type ClientKind,
  type ClientLogEntry,
  type ClientLogLevel,
  type ClientLogUploadRequest,
  type MetricKitPayloadItem,
  type MetricKitUploadRequest,
  type TelemetryClient,
  type TelemetryDropReason,
  type TelemetryEventRecord,
  type TelemetryEventUploadResponse,
} from "../types.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

const TELEMETRY_DIR = "telemetry";

const METRICKIT_MAX_PAYLOAD_COUNT = 160;
const METRICKIT_MAX_SUMMARY_FIELDS = 24;
const METRICKIT_MAX_SUMMARY_VALUE_CHARS = 256;

const EVENTS_MAX_PER_UPLOAD = 500;
const EVENT_ID_MAX_CHARS = 96;

const CLIENT_LOG_MAX_ENTRY_COUNT = 200;
const CLIENT_LOG_MAX_CATEGORY_CHARS = 96;
const CLIENT_LOG_MAX_MESSAGE_CHARS = 2_048;
const CLIENT_LOG_MAX_METADATA_FIELDS = 24;
const CLIENT_LOG_MAX_METADATA_KEY_CHARS = 96;
const CLIENT_LOG_MAX_METADATA_VALUE_CHARS = 512;
const CLIENT_LOG_MAX_ID_CHARS = 128;

const log = createLogger({ base: { component: "telemetry_routes" } });

function telemetryDir(ctx: RouteContext): string {
  return join(ctx.storage.getDataDir(), "diagnostics", TELEMETRY_DIR);
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

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
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

/** Short SHA, optional `-dirty`. Missing and anything else, including `unknown`, are dropped. */
function sanitizeGitCommit(value: unknown): string | undefined {
  const raw = trimText(isString(value) ? value : undefined, 64).trim();
  if (!raw) return undefined;
  if (/^[0-9a-f]{7,40}(?:-dirty)?$/i.test(raw)) return raw.toLowerCase();
  return undefined;
}

function sanitizeRedactedString(value: unknown, maxLength: number): string {
  if (!isString(value)) return "";
  return redactLogString(value, maxLength);
}

function isClientKind(value: unknown): value is ClientKind {
  return value === "ios" || value === "mac";
}

/**
 * The `client` envelope shared by every upload. `kind` is required; every other
 * field is optional, redacted, and length-bounded.
 */
function parseTelemetryClient(value: unknown): TelemetryClient | null {
  if (!isRecord(value) || !isClientKind(value.kind)) return null;
  const client: TelemetryClient = { kind: value.kind };
  const text = (key: keyof Omit<TelemetryClient, "kind" | "gitCommit">, max: number): void => {
    const sanitized = sanitizeRedactedString(value[key], max);
    if (sanitized) client[key] = sanitized;
  };
  text("appVersion", 96);
  text("buildNumber", 64);
  text("osVersion", 128);
  text("deviceModel", 128);
  text("appInstanceId", CLIENT_LOG_MAX_ID_CHARS);
  text("bootId", CLIENT_LOG_MAX_ID_CHARS);
  const gitCommit = sanitizeGitCommit(value.gitCommit);
  if (gitCommit) client.gitCommit = gitCommit;
  return client;
}

/** Pre-v2 stored shape for MetricKit and client-log files: client fields at the top level. */
function flattenedClient(client: TelemetryClient): Record<string, string | undefined> {
  return {
    appVersion: client.appVersion,
    buildNumber: client.buildNumber,
    gitCommit: client.gitCommit,
    osVersion: client.osVersion,
    deviceModel: client.deviceModel,
    clientKind: client.kind,
    appInstanceId: client.appInstanceId,
    bootId: client.bootId,
  };
}

// ── MetricKit ──

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

function parseMetricKitRequest(body: unknown): MetricKitUploadRequest | null {
  if (!isRecord(body)) return null;
  const client = parseTelemetryClient(body.client);
  if (!client || !Array.isArray(body.payloads)) return null;

  const generatedAt = toFiniteNumber(body.generatedAt, Date.now());
  // The timestamp names the daily file; one outside the Date range has no day.
  if (Number.isNaN(new Date(generatedAt).getTime())) return null;
  const payloads: MetricKitPayloadItem[] = [];
  for (const candidate of body.payloads.slice(0, METRICKIT_MAX_PAYLOAD_COUNT)) {
    const parsed = normalizePayload(candidate, generatedAt);
    if (parsed.ok) payloads.push(parsed.payload);
  }

  if (payloads.length === 0) return null;
  return { generatedAt, client, payloads };
}

function metricKitRecord(request: MetricKitUploadRequest): Record<string, unknown> {
  return {
    receivedAt: Date.now(),
    generatedAt: request.generatedAt,
    ...flattenedClient(request.client),
    payloadCount: request.payloads.length,
    payloads: request.payloads,
  };
}

// ── App events ──

function countDrop(
  dropped: Partial<Record<TelemetryDropReason, number>>,
  reason: TelemetryDropReason,
  count = 1,
): void {
  dropped[reason] = (dropped[reason] ?? 0) + count;
}

/**
 * Validate an events upload against the catalog. Returns null for a malformed
 * envelope; otherwise the records to store and the drop counts by reason.
 */
function parseEventsRequest(body: unknown): {
  client: TelemetryClient;
  records: TelemetryEventRecord[];
  dropped: Partial<Record<TelemetryDropReason, number>>;
} | null {
  if (!isRecord(body) || !Array.isArray(body.events)) return null;
  const client = parseTelemetryClient(body.client);
  if (!client) return null;

  const records: TelemetryEventRecord[] = [];
  const dropped: Partial<Record<TelemetryDropReason, number>> = {};
  if (body.events.length > EVENTS_MAX_PER_UPLOAD) {
    countDrop(dropped, "over_batch_limit", body.events.length - EVENTS_MAX_PER_UPLOAD);
  }

  for (const candidate of body.events.slice(0, EVENTS_MAX_PER_UPLOAD)) {
    if (!isRecord(candidate)) {
      countDrop(dropped, "malformed");
      continue;
    }
    const ts = candidate.ts;
    if (typeof ts !== "number" || !Number.isFinite(ts) || ts <= 0) {
      countDrop(dropped, "invalid_timestamp");
      continue;
    }
    const result = validateEvent("app", candidate.name, candidate.fields, candidate.tags);
    if (!result.ok) {
      countDrop(dropped, result.reason);
      continue;
    }
    const sessionId = sanitizeRedactedString(candidate.sessionId, EVENT_ID_MAX_CHARS);
    const workspaceId = sanitizeRedactedString(candidate.workspaceId, EVENT_ID_MAX_CHARS);
    records.push({
      v: 2,
      ts: Math.trunc(ts),
      origin: "app",
      name: result.event.name,
      fields: result.event.fields,
      tags: result.event.tags,
      ...(sessionId ? { sessionId } : {}),
      ...(workspaceId ? { workspaceId } : {}),
      client,
    });
  }

  return { client, records, dropped };
}

// ── Client logs ──

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
  if (!isRecord(value)) {
    return undefined;
  }

  const out: Record<string, string> = {};
  for (const [key, rawValue] of Object.entries(value)) {
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
  if (!isRecord(value)) {
    return null;
  }

  const ts = value.ts;
  const seq = value.seq;
  if (typeof ts !== "number" || !Number.isFinite(ts)) {
    return null;
  }
  if (typeof seq !== "number" || !Number.isFinite(seq)) {
    return null;
  }

  const level = normalizeClientLogLevel(value.level);
  if (!level) {
    return null;
  }

  const category = sanitizeRedactedString(value.category, CLIENT_LOG_MAX_CATEGORY_CHARS);
  const message = sanitizeRedactedString(value.message, CLIENT_LOG_MAX_MESSAGE_CHARS);
  if (!category || !message) {
    return null;
  }

  const metadata = sanitizeClientLogMetadata(value.metadata);
  const sessionId = sanitizeRedactedString(value.sessionId, CLIENT_LOG_MAX_ID_CHARS);
  const workspaceId = sanitizeRedactedString(value.workspaceId, CLIENT_LOG_MAX_ID_CHARS);

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
  if (!isRecord(body) || !Array.isArray(body.entries)) {
    return null;
  }
  const client = parseTelemetryClient(body.client);
  if (!client) {
    return null;
  }

  const entries: ClientLogEntry[] = [];
  for (const candidate of body.entries.slice(0, CLIENT_LOG_MAX_ENTRY_COUNT)) {
    const normalized = normalizeClientLogEntry(candidate);
    if (normalized) {
      entries.push(normalized);
    }
  }

  if (entries.length === 0) {
    return null;
  }

  const generatedAt = toValidTimestamp(body.generatedAt, Date.now());
  if (generatedAt === null) {
    return null;
  }

  const droppedCountRaw = body.droppedCount;
  const droppedCount =
    typeof droppedCountRaw === "number" && Number.isFinite(droppedCountRaw)
      ? Math.max(0, Math.trunc(droppedCountRaw))
      : undefined;

  return {
    generatedAt,
    client,
    ...(droppedCount && droppedCount > 0 ? { droppedCount } : {}),
    entries,
  };
}

function clientLogRecord(request: ClientLogUploadRequest): Record<string, unknown> {
  const receivedAt = Date.now();
  const { client } = request;
  return {
    receivedAt,
    generatedAt: request.generatedAt,
    ...flattenedClient(client),
    droppedCount: request.droppedCount ?? 0,
    entryCount: request.entries.length,
    entries: request.entries.map((entry) => ({
      receivedAt,
      clientKind: client.kind,
      appInstanceId: client.appInstanceId,
      bootId: client.bootId,
      ...entry,
    })),
  };
}

/** Distinct (reason, build) pairs remembered for drop logging before the set resets. */
const DROP_LOG_MEMORY = 256;

export function createTelemetryRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
  logger: Logger = log,
): RouteDispatcher {
  let eventWriter: TelemetryEventWriter | undefined;
  const writer = (): TelemetryEventWriter =>
    (eventWriter ??= new TelemetryEventWriter(telemetryDir(ctx)));
  const loggedDrops = new Set<string>();

  /**
   * An uploaded event the catalog refuses is lost to the client, which is told
   * only in the response. Log it once per reason and client build so a build
   * that emits a stale name or tag is visible without a log line per upload.
   */
  function logDrops(
    dropped: Partial<Record<TelemetryDropReason, number>>,
    client: TelemetryClient,
  ): void {
    const build = `${client.appVersion ?? "?"}+${client.buildNumber ?? "?"}`;
    const fresh: Partial<Record<TelemetryDropReason, number>> = {};
    for (const [reason, count] of Object.entries(dropped) as [TelemetryDropReason, number][]) {
      const key = `${reason}|${build}|${client.kind}`;
      if (loggedDrops.has(key)) continue;
      if (loggedDrops.size >= DROP_LOG_MEMORY) loggedDrops.clear();
      loggedDrops.add(key);
      fresh[reason] = count;
    }
    if (Object.keys(fresh).length === 0) return;
    logger.warn("telemetry_events.dropped", {
      dropped: fresh,
      clientKind: client.kind,
      appVersion: client.appVersion,
      buildNumber: client.buildNumber,
      gitCommit: client.gitCommit,
    });
  }

  async function handleUploadMetricKit(req: IncomingMessage, res: ServerResponse): Promise<void> {
    if (!telemetryUploadsEnabledFromEnv()) {
      helpers.error(res, 403, "telemetry uploads disabled by OPPI_TELEMETRY_MODE");
      return;
    }

    const request = parseMetricKitRequest(await helpers.parseBody<unknown>(req));
    if (!request) {
      helpers.error(res, 400, "client and a non-empty payloads array are required");
      return;
    }

    writer().writeRecord("metrickit", request.generatedAt, metricKitRecord(request));

    const windowStartMs = Math.min(...request.payloads.map((payload) => payload.windowStartMs));
    const windowEndMs = Math.max(...request.payloads.map((payload) => payload.windowEndMs));

    helpers.json(res, {
      ok: true,
      accepted: request.payloads.length,
      windowStartMs,
      windowEndMs,
    });
  }

  async function handleUploadEvents(req: IncomingMessage, res: ServerResponse): Promise<void> {
    if (!telemetryUploadsEnabledFromEnv()) {
      helpers.error(res, 403, "telemetry uploads disabled by OPPI_TELEMETRY_MODE");
      return;
    }

    const parsed = parseEventsRequest(await helpers.parseBody<unknown>(req));
    if (!parsed) {
      helpers.error(res, 400, "client and an events array are required");
      return;
    }

    writer().write("app", parsed.records);
    logDrops(parsed.dropped, parsed.client);
    const response: TelemetryEventUploadResponse = {
      ok: true,
      accepted: parsed.records.length,
      dropped: parsed.dropped,
    };
    helpers.json(res, response);
  }

  async function handleUploadClientLogs(req: IncomingMessage, res: ServerResponse): Promise<void> {
    if (!telemetryUploadsEnabledFromEnv()) {
      helpers.error(res, 403, "telemetry uploads disabled by OPPI_TELEMETRY_MODE");
      return;
    }

    const request = parseClientLogRequest(await helpers.parseBody<unknown>(req));
    if (!request) {
      helpers.error(
        res,
        400,
        "client and a non-empty entries array of valid client logs are required",
      );
      return;
    }

    writer().writeRecord("client_logs", request.generatedAt, clientLogRecord(request));

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

    if (method === "POST" && path === "/telemetry/events") {
      await handleUploadEvents(req, res);
      return true;
    }

    if (method === "POST" && path === "/telemetry/client-logs") {
      await handleUploadClientLogs(req, res);
      return true;
    }

    return false;
  };
}

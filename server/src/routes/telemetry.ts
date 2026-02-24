import type { IncomingMessage, ServerResponse } from "node:http";
import { appendFileSync, existsSync, mkdirSync, readdirSync, unlinkSync } from "node:fs";
import { join } from "node:path";

import type { MetricKitPayloadItem, MetricKitUploadRequest } from "../types.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

const METRICKIT_DIR = "telemetry";
const METRICKIT_FILE_PREFIX = "metrickit-";
const METRICKIT_FILE_SUFFIX = ".jsonl";
const METRICKIT_MAX_PAYLOAD_COUNT = 160;
const METRICKIT_MAX_SUMMARY_FIELDS = 24;
const METRICKIT_MAX_SUMMARY_VALUE_CHARS = 256;

function telemetryDir(ctx: RouteContext): string {
  return join(ctx.storage.getDataDir(), "diagnostics", METRICKIT_DIR);
}

function metrickitFileName(timestampMs: number): string {
  const date = new Date(timestampMs);
  return `${METRICKIT_FILE_PREFIX}${date.toISOString().slice(0, 10)}${METRICKIT_FILE_SUFFIX}`;
}

function retentionDaysFromEnv(): number {
  const raw = process.env.OPPI_METRICKIT_RETENTION_DAYS?.trim() ?? "";
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

function pruneOldTelemetryData(ctx: RouteContext): void {
  const retentionMs = retentionDaysFromEnv() * 24 * 60 * 60 * 1_000;
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
    if (!entry.startsWith(METRICKIT_FILE_PREFIX) || !entry.endsWith(METRICKIT_FILE_SUFFIX)) {
      continue;
    }

    const datePart = entry.slice(METRICKIT_FILE_PREFIX.length, -METRICKIT_FILE_SUFFIX.length);
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

function appendRecord(ctx: RouteContext, request: MetricKitUploadRequest): void {
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

export function createTelemetryRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  async function handleUploadMetricKit(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const rawBody = await helpers.parseBody<MetricKitUploadRequest>(req);
    const request = parseRequest(rawBody);
    if (!request) {
      helpers.error(res, 400, "payloads must be a non-empty array");
      return;
    }

    appendRecord(ctx, request);
    pruneOldTelemetryData(ctx);

    const windowStartMs = Math.min(...request.payloads.map((payload) => payload.windowStartMs));
    const windowEndMs = Math.max(...request.payloads.map((payload) => payload.windowEndMs));

    helpers.json(res, {
      ok: true,
      accepted: request.payloads.length,
      windowStartMs,
      windowEndMs,
    });
  }

  return async ({ method, path, req, res }) => {
    if (method === "POST" && path === "/telemetry/metrickit") {
      await handleUploadMetricKit(req, res);
      return true;
    }

    return false;
  };
}

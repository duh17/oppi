import { readStoredCredential, type ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { AuthResult, Credential } from "@earendil-works/pi-ai";

import { safeErrorMessage } from "./log-utils.js";

const CODEX_PROVIDER_ID = "openai-codex";
const CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage";
const FIVE_HOUR_SECONDS = 5 * 60 * 60;
const WEEKLY_SECONDS = 7 * 24 * 60 * 60;

export interface CodexUsageWindow {
  usedPercent: number;
  remainingPercent: number;
  limitWindowSeconds: number;
  resetAt: number;
}

export interface CodexUsageCredits {
  hasCredits: boolean;
  unlimited: boolean;
  balance: string | null;
}

export interface CodexAdditionalRateLimit {
  meteredFeature: string | null;
  limitName: string | null;
  fiveHour: CodexUsageWindow | null;
  weekly: CodexUsageWindow | null;
}

export interface CodexUsageStatus {
  providerId: typeof CODEX_PROVIDER_ID;
  authenticated: boolean;
  planType: string | null;
  rateLimitReachedType: string | null;
  fiveHour: CodexUsageWindow | null;
  weekly: CodexUsageWindow | null;
  credits: CodexUsageCredits | null;
  additionalRateLimits: CodexAdditionalRateLimit[];
  fetchedAt: number;
  error?: string;
}

type CodexModelRuntime = Pick<ModelRuntime, "getAuth">;
type FetchLike = typeof fetch;

interface FetchCodexUsageStatusOptions {
  modelRuntime: CodexModelRuntime;
  readCredential?: (providerId: string) => Credential | undefined;
  fetchImpl?: FetchLike;
  now?: () => number;
}

function emptyStatus(now: number, authenticated = false, error?: string): CodexUsageStatus {
  return {
    providerId: CODEX_PROVIDER_ID,
    authenticated,
    planType: null,
    rateLimitReachedType: null,
    fiveHour: null,
    weekly: null,
    credits: null,
    additionalRateLimits: [],
    fetchedAt: now,
    ...(error ? { error } : {}),
  };
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function readNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function readString(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value : null;
}

function extractAccountId(credential: Credential | undefined): string | null {
  const record = asRecord(credential);
  if (!record) return null;
  return readString(record.accountId);
}

function normalizeWindow(windowLike: unknown): CodexUsageWindow | null {
  const window = asRecord(windowLike);
  if (!window) return null;

  const usedPercent = readNumber(window.used_percent);
  const limitWindowSeconds = readNumber(window.limit_window_seconds);
  const resetAt = readNumber(window.reset_at);
  if (usedPercent === null || limitWindowSeconds === null || resetAt === null) {
    return null;
  }

  return {
    usedPercent,
    remainingPercent: Math.max(0, 100 - usedPercent),
    limitWindowSeconds,
    resetAt,
  };
}

function pickWindowByDuration(
  windows: CodexUsageWindow[],
  seconds: number,
): CodexUsageWindow | null {
  return windows.find((window) => window.limitWindowSeconds === seconds) ?? null;
}

function normalizeRateLimit(rateLimitLike: unknown): {
  fiveHour: CodexUsageWindow | null;
  weekly: CodexUsageWindow | null;
} {
  const rateLimit = asRecord(rateLimitLike);
  if (!rateLimit) {
    return { fiveHour: null, weekly: null };
  }

  const windows = [
    normalizeWindow(rateLimit.primary_window),
    normalizeWindow(rateLimit.secondary_window),
  ].filter((window): window is CodexUsageWindow => window !== null);

  return {
    fiveHour: pickWindowByDuration(windows, FIVE_HOUR_SECONDS),
    weekly: pickWindowByDuration(windows, WEEKLY_SECONDS),
  };
}

function normalizeCredits(creditsLike: unknown): CodexUsageCredits | null {
  const credits = asRecord(creditsLike);
  if (!credits) return null;

  return {
    hasCredits: credits.has_credits === true,
    unlimited: credits.unlimited === true,
    balance: readString(credits.balance) ?? (credits.balance === "0" ? "0" : null),
  };
}

function normalizeAdditionalRateLimits(additionalLike: unknown): CodexAdditionalRateLimit[] {
  if (!Array.isArray(additionalLike)) return [];

  return additionalLike
    .map((entry) => {
      const record = asRecord(entry);
      if (!record) return null;
      const windows = normalizeRateLimit(record.rate_limit);
      return {
        meteredFeature: readString(record.metered_feature),
        limitName: readString(record.limit_name),
        fiveHour: windows.fiveHour,
        weekly: windows.weekly,
      } satisfies CodexAdditionalRateLimit;
    })
    .filter((entry): entry is CodexAdditionalRateLimit => entry !== null);
}

function parseMaybeJson(text: string): unknown {
  if (text.trim().length === 0) return null;
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

function parseErrorMessage(status: number, payload: unknown, fallbackText: string): string {
  const record = asRecord(payload);
  const error = asRecord(record?.error);
  const message =
    readString(error?.message) ?? readString(record?.message) ?? readString(fallbackText);
  return message
    ? `Codex usage fetch failed (${status}): ${message}`
    : `Codex usage fetch failed (${status})`;
}

export async function fetchCodexUsageStatus(
  options: FetchCodexUsageStatusOptions,
): Promise<CodexUsageStatus> {
  const now = options.now ?? Date.now;
  const readCredential = options.readCredential ?? readStoredCredential;
  const fetchImpl = options.fetchImpl ?? fetch;
  const initialCredential = readCredential(CODEX_PROVIDER_ID);
  if (!initialCredential) {
    return emptyStatus(now(), false);
  }

  let auth: AuthResult | undefined;
  try {
    auth = await options.modelRuntime.getAuth(CODEX_PROVIDER_ID);
  } catch (error) {
    return emptyStatus(now(), true, `Codex auth refresh failed: ${safeErrorMessage(error)}`);
  }

  const apiKey = auth?.auth.apiKey;
  if (!apiKey) {
    return emptyStatus(
      now(),
      true,
      "Codex OAuth credential is present, but no access token is available.",
    );
  }

  const accountId = extractAccountId(readCredential(CODEX_PROVIDER_ID) ?? initialCredential);
  const headers = new Headers({
    Authorization: `Bearer ${apiKey}`,
    Accept: "application/json",
    "User-Agent": "OppiServer/1.0",
  });
  if (accountId) {
    headers.set("ChatGPT-Account-Id", accountId);
  }

  try {
    const response = await fetchImpl(CODEX_USAGE_URL, {
      method: "GET",
      headers,
    });
    const text = await response.text();
    const payload = parseMaybeJson(text);

    if (!response.ok) {
      return emptyStatus(now(), true, parseErrorMessage(response.status, payload, text));
    }

    const record = asRecord(payload);
    if (!record) {
      return emptyStatus(now(), true, "Codex usage fetch failed: invalid response payload.");
    }
    const baseWindows = normalizeRateLimit(record.rate_limit);

    return {
      providerId: CODEX_PROVIDER_ID,
      authenticated: true,
      planType: readString(record?.plan_type),
      rateLimitReachedType: readString(asRecord(record?.rate_limit_reached_type)?.type),
      fiveHour: baseWindows.fiveHour,
      weekly: baseWindows.weekly,
      credits: normalizeCredits(record?.credits),
      additionalRateLimits: normalizeAdditionalRateLimits(record?.additional_rate_limits),
      fetchedAt: now(),
    } satisfies CodexUsageStatus;
  } catch (error) {
    return emptyStatus(now(), true, `Codex usage fetch failed: ${safeErrorMessage(error)}`);
  }
}

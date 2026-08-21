import { readStoredCredential } from "@earendil-works/pi-coding-agent";
import type { AuthResult, Credential } from "@earendil-works/pi-ai";
import { safeErrorMessage } from "../log-utils.js";
import type {
  FetchProviderQuotasOptions,
  ProviderQuota,
  ProviderQuotaPacing,
  ProviderQuotaWindow,
  ProviderQuotaWindowKey,
  QuotaModelRuntime,
} from "./types.js";

export const UPSTREAM_TIMEOUT_MS = 10_000;
const ERROR_MESSAGE_MAX_CHARS = 200;

export function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

export function readNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

export function readString(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value : null;
}

export function clampPercent(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.max(0, Math.min(100, value));
}

function remainingFromUsed(usedPercent: number): number {
  return clampPercent(100 - usedPercent);
}

export function parseMaybeJson(text: string): unknown {
  if (text.trim().length === 0) return null;
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

export function extractAccountId(credential: Credential | undefined): string | null {
  const record = asRecord(credential);
  if (!record) return null;
  return readString(record.accountId);
}

/** Parse an ISO timestamp into Unix epoch seconds; null when missing/unparseable. */
export function parseIsoToUnixSeconds(value: string | null): number | null {
  if (!value) return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? Math.floor(ms / 1000) : null;
}

export function credentialType(credential: Credential | undefined): string | null {
  const record = asRecord(credential);
  if (!record) return null;
  return readString(record.type);
}

/** Empty quota row for unauthenticated / error paths. */
export function emptyProviderQuota(
  providerId: string,
  displayName: string,
  now: number,
  authenticated = false,
  error?: string,
): ProviderQuota {
  return {
    providerId,
    displayName,
    authenticated,
    planType: null,
    windows: [],
    credits: null,
    prepaidBalanceCents: null,
    fetchedAt: now,
    ...(error ? { error } : {}),
  };
}

/** Build one usage window; remaining% is derived from used%. */
export function makeProviderQuotaWindow(input: {
  key: ProviderQuotaWindowKey;
  shortLabel: string;
  title: string;
  usedPercent: number;
  limitWindowSeconds: number | null;
  resetAt: number | null;
  includeWeekdayInReset: boolean;
}): ProviderQuotaWindow {
  const usedPercent = clampPercent(input.usedPercent);
  return {
    key: input.key,
    shortLabel: input.shortLabel,
    title: input.title,
    usedPercent,
    remainingPercent: remainingFromUsed(usedPercent),
    limitWindowSeconds: input.limitWindowSeconds,
    resetAt: input.resetAt,
    includeWeekdayInReset: input.includeWeekdayInReset,
  };
}

/** Derive snapshot pacing without using provider identity or quota history. */
export function deriveProviderQuotaPacing(
  window: ProviderQuotaWindow,
  fetchedAt: number,
): ProviderQuotaPacing {
  const resetAt = window.resetAt;
  const timeRemainingSeconds =
    resetAt !== null && Number.isFinite(resetAt) && Number.isFinite(fetchedAt)
      ? resetAt - fetchedAt / 1000
      : null;
  const validTimeRemaining =
    timeRemainingSeconds !== null &&
    Number.isFinite(timeRemainingSeconds) &&
    timeRemainingSeconds > 0;
  const validRemaining = Number.isFinite(window.remainingPercent);
  const validWindow =
    window.limitWindowSeconds !== null &&
    Number.isFinite(window.limitWindowSeconds) &&
    window.limitWindowSeconds > 0;

  if (!validTimeRemaining || !validRemaining || !validWindow) {
    return {
      source: "unknown",
      status: "unknown",
      timeRemainingSeconds: validTimeRemaining ? timeRemainingSeconds : null,
      supplyRatio: null,
      targetBurnPercentPerHour: null,
      recentBurnPercentPerHour: null,
      paceRatio: null,
      projectedExhaustionAt: null,
      projectedRemainingPercent: null,
    };
  }

  const validTime = timeRemainingSeconds as number;
  const validWindowSeconds = window.limitWindowSeconds as number;
  const remainingRatio = Math.max(0, Math.min(1, window.remainingPercent / 100));
  const remainingPercent = remainingRatio * 100;
  const supplyRatio = remainingRatio / (validTime / validWindowSeconds);
  const targetBurnPercentPerHour = remainingPercent / (validTime / 3600);
  if (!Number.isFinite(supplyRatio) || !Number.isFinite(targetBurnPercentPerHour)) {
    return {
      source: "unknown",
      status: "unknown",
      timeRemainingSeconds,
      supplyRatio: null,
      targetBurnPercentPerHour: null,
      recentBurnPercentPerHour: null,
      paceRatio: null,
      projectedExhaustionAt: null,
      projectedRemainingPercent: null,
    };
  }

  const thresholdEpsilon = 1e-9;
  const status =
    supplyRatio > 1.2 + thresholdEpsilon
      ? "plenty"
      : supplyRatio >= 0.8 - thresholdEpsilon
        ? "on_pace"
        : "conserve";
  return {
    source: "snapshot",
    status,
    timeRemainingSeconds,
    supplyRatio,
    targetBurnPercentPerHour,
    recentBurnPercentPerHour: null,
    paceRatio: null,
    projectedExhaustionAt: null,
    projectedRemainingPercent: null,
  };
}

/**
 * Provider-agnostic window cleanup: first window wins per key, then shortest
 * period first (null durations last). Detail UIs show the full list; compact
 * UIs take the first entry after this sort.
 */
export function normalizeProviderQuotaWindows(
  windows: readonly ProviderQuotaWindow[],
): ProviderQuotaWindow[] {
  const seen = new Set<string>();
  const deduped: ProviderQuotaWindow[] = [];
  for (const window of windows) {
    const key = window.key.trim();
    if (!key || seen.has(key)) continue;
    seen.add(key);
    deduped.push(window.key === key ? window : { ...window, key });
  }

  return deduped
    .map((window, index) => ({ window, index }))
    .sort((left, right) => {
      const leftSeconds = left.window.limitWindowSeconds;
      const rightSeconds = right.window.limitWindowSeconds;
      const leftRank = leftSeconds === null ? Number.POSITIVE_INFINITY : leftSeconds;
      const rightRank = rightSeconds === null ? Number.POSITIVE_INFINITY : rightSeconds;
      if (leftRank !== rightRank) return leftRank - rightRank;
      return left.index - right.index;
    })
    .map(({ window }) => window);
}

export function finalizeProviderQuota(quota: ProviderQuota): ProviderQuota {
  const windows = normalizeProviderQuotaWindows(quota.windows);
  return {
    ...quota,
    windows: windows.map((window) => ({
      ...window,
      pacing: deriveProviderQuotaPacing(window, quota.fetchedAt),
    })),
  };
}

function truncateMessage(message: string): string {
  const compact = message.replace(/\s+/g, " ").trim();
  if (compact.length <= ERROR_MESSAGE_MAX_CHARS) return compact;
  return `${compact.slice(0, ERROR_MESSAGE_MAX_CHARS - 1)}…`;
}

export function parseUpstreamErrorMessage(
  providerLabel: string,
  status: number,
  payload: unknown,
  fallbackText: string,
): string {
  const record = asRecord(payload);
  const error = asRecord(record?.error);
  const message =
    readString(error?.message) ??
    readString(record?.error) ??
    readString(record?.message) ??
    readString(fallbackText);
  return message
    ? truncateMessage(`${providerLabel} quota fetch failed (${status}): ${message}`)
    : `${providerLabel} quota fetch failed (${status})`;
}

export async function readResponseText(response: Response): Promise<string> {
  try {
    return await response.text();
  } catch {
    return "";
  }
}

/**
 * Resolve a bearer access token for OAuth-backed provider quota APIs.
 * Returns an empty/error quota when credentials are missing or refresh fails.
 */
export async function resolveProviderAccessToken(
  providerId: string,
  modelRuntime: QuotaModelRuntime,
  readCredential: (providerId: string) => Credential | undefined,
  now: number,
  displayName: string,
): Promise<{ token: string; credential: Credential } | { quota: ProviderQuota }> {
  const initialCredential = readCredential(providerId);
  if (!initialCredential) {
    return { quota: emptyProviderQuota(providerId, displayName, now, false) };
  }

  let auth: AuthResult | undefined;
  try {
    auth = await modelRuntime.getAuth(providerId);
  } catch (error) {
    return {
      quota: emptyProviderQuota(
        providerId,
        displayName,
        now,
        true,
        `${displayName} auth refresh failed: ${safeErrorMessage(error)}`,
      ),
    };
  }

  const apiKey = auth?.auth.apiKey;
  if (!apiKey) {
    return {
      quota: emptyProviderQuota(
        providerId,
        displayName,
        now,
        true,
        `${displayName} credential is present, but no access token is available.`,
      ),
    };
  }

  return {
    token: apiKey,
    credential: readCredential(providerId) ?? initialCredential,
  };
}

export function resolveQuotaFetchDeps(options: FetchProviderQuotasOptions): {
  now: () => number;
  readCredential: (providerId: string) => Credential | undefined;
  fetchImpl: typeof fetch;
  fetchedAt: number;
} {
  const now = options.now ?? Date.now;
  return {
    now,
    readCredential: options.readCredential ?? readStoredCredential,
    fetchImpl: options.fetchImpl ?? fetch,
    fetchedAt: now(),
  };
}

import type {
  FetchProviderQuotasOptions,
  ProviderQuota,
  ProviderQuotaAdapter,
  ProviderQuotaCredits,
  ProviderQuotaWindow,
} from "../types.js";
import {
  asRecord,
  emptyProviderQuota,
  extractAccountId,
  finalizeProviderQuota,
  makeProviderQuotaWindow,
  parseMaybeJson,
  parseUpstreamErrorMessage,
  readNumber,
  readResponseText,
  readString,
  resolveProviderAccessToken,
  resolveQuotaFetchDeps,
  UPSTREAM_TIMEOUT_MS,
} from "../shared.js";
import { safeErrorMessage } from "../../log-utils.js";

const CODEX_PROVIDER_ID = "openai-codex";
const CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage";
const FIVE_HOUR_SECONDS = 5 * 60 * 60;
const WEEKLY_SECONDS = 7 * 24 * 60 * 60;

function normalizeCodexWindow(windowLike: unknown): {
  usedPercent: number;
  limitWindowSeconds: number;
  resetAt: number;
} | null {
  const window = asRecord(windowLike);
  if (!window) return null;

  const usedPercent = readNumber(window.used_percent);
  const limitWindowSeconds = readNumber(window.limit_window_seconds);
  const resetAt = readNumber(window.reset_at);
  if (usedPercent === null || limitWindowSeconds === null || resetAt === null) {
    return null;
  }

  return { usedPercent, limitWindowSeconds, resetAt };
}

function pickCodexWindowByDuration(
  windows: Array<{ usedPercent: number; limitWindowSeconds: number; resetAt: number }>,
  seconds: number,
): { usedPercent: number; limitWindowSeconds: number; resetAt: number } | null {
  return windows.find((window) => window.limitWindowSeconds === seconds) ?? null;
}

function normalizeCodexRateLimitWindows(rateLimitLike: unknown): ProviderQuotaWindow[] {
  const rateLimit = asRecord(rateLimitLike);
  if (!rateLimit) return [];

  const rawWindows = [
    normalizeCodexWindow(rateLimit.primary_window),
    normalizeCodexWindow(rateLimit.secondary_window),
  ].filter(
    (window): window is { usedPercent: number; limitWindowSeconds: number; resetAt: number } =>
      window !== null,
  );

  const windows: ProviderQuotaWindow[] = [];
  const fiveHour = pickCodexWindowByDuration(rawWindows, FIVE_HOUR_SECONDS);
  if (fiveHour) {
    windows.push(
      makeProviderQuotaWindow({
        key: "five_hour",
        shortLabel: "5h",
        title: "5-hour",
        usedPercent: fiveHour.usedPercent,
        limitWindowSeconds: fiveHour.limitWindowSeconds,
        resetAt: fiveHour.resetAt,
        includeWeekdayInReset: false,
      }),
    );
  }

  const weekly = pickCodexWindowByDuration(rawWindows, WEEKLY_SECONDS);
  if (weekly) {
    windows.push(
      makeProviderQuotaWindow({
        key: "weekly",
        shortLabel: "7d",
        title: "Weekly",
        usedPercent: weekly.usedPercent,
        limitWindowSeconds: weekly.limitWindowSeconds,
        resetAt: weekly.resetAt,
        includeWeekdayInReset: true,
      }),
    );
  }

  return windows;
}

function normalizeCodexCredits(creditsLike: unknown): ProviderQuotaCredits | null {
  const credits = asRecord(creditsLike);
  if (!credits) return null;

  return {
    hasCredits: credits.has_credits === true,
    unlimited: credits.unlimited === true,
    balance: readString(credits.balance) ?? (credits.balance === "0" ? "0" : null),
  };
}

export async function fetchCodexProviderQuota(
  options: FetchProviderQuotasOptions,
): Promise<ProviderQuota> {
  const { readCredential, fetchImpl, fetchedAt } = resolveQuotaFetchDeps(options);
  const displayName = "Codex";

  const resolved = await resolveProviderAccessToken(
    CODEX_PROVIDER_ID,
    options.modelRuntime,
    readCredential,
    fetchedAt,
    displayName,
  );
  if ("quota" in resolved) return finalizeProviderQuota(resolved.quota);

  const accountId = extractAccountId(resolved.credential);
  const headers = new Headers({
    Authorization: `Bearer ${resolved.token}`,
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
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
    const text = await readResponseText(response);
    const payload = parseMaybeJson(text);

    if (!response.ok) {
      return finalizeProviderQuota(
        emptyProviderQuota(
          CODEX_PROVIDER_ID,
          displayName,
          fetchedAt,
          true,
          parseUpstreamErrorMessage(displayName, response.status, payload, text),
        ),
      );
    }

    const record = asRecord(payload);
    if (!record) {
      return finalizeProviderQuota(
        emptyProviderQuota(
          CODEX_PROVIDER_ID,
          displayName,
          fetchedAt,
          true,
          "Codex quota fetch failed: invalid response payload.",
        ),
      );
    }

    return finalizeProviderQuota({
      providerId: CODEX_PROVIDER_ID,
      displayName,
      authenticated: true,
      planType: readString(record.plan_type),
      windows: normalizeCodexRateLimitWindows(record.rate_limit),
      credits: normalizeCodexCredits(record.credits),
      prepaidBalanceCents: null,
      fetchedAt,
    });
  } catch (error) {
    return finalizeProviderQuota(
      emptyProviderQuota(
        CODEX_PROVIDER_ID,
        displayName,
        fetchedAt,
        true,
        `Codex quota fetch failed: ${safeErrorMessage(error)}`,
      ),
    );
  }
}

export const codexProviderQuotaAdapter: ProviderQuotaAdapter = {
  providerId: CODEX_PROVIDER_ID,
  displayName: "Codex",
  fetch: fetchCodexProviderQuota,
};

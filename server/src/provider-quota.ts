import { readStoredCredential, type ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { AuthResult, Credential } from "@earendil-works/pi-ai";

import { safeErrorMessage } from "./log-utils.js";

const CODEX_PROVIDER_ID = "openai-codex";
const XAI_PROVIDER_ID = "xai";

const CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage";
const XAI_BILLING_URL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";
const XAI_SETTINGS_URL = "https://cli-chat-proxy.grok.com/v1/settings";

const FIVE_HOUR_SECONDS = 5 * 60 * 60;
const WEEKLY_SECONDS = 7 * 24 * 60 * 60;
const UPSTREAM_TIMEOUT_MS = 10_000;
const ERROR_MESSAGE_MAX_CHARS = 200;

export type ProviderQuotaWindowKey = "five_hour" | "weekly" | "monthly" | string;

export interface ProviderQuotaWindow {
  key: ProviderQuotaWindowKey;
  /** Compact badge label prefix, e.g. "5h" or "7d". */
  shortLabel: string;
  /** Detail-row title, e.g. "5-hour" or "Weekly". */
  title: string;
  usedPercent: number;
  remainingPercent: number;
  limitWindowSeconds: number | null;
  /** Unix epoch seconds when the window resets, when known. */
  resetAt: number | null;
  /** Prefer weekday in reset copy (weekly/monthly windows). */
  includeWeekdayInReset: boolean;
}

export interface ProviderQuotaCredits {
  hasCredits: boolean;
  unlimited: boolean;
  balance: string | null;
}

export interface ProviderQuota {
  providerId: string;
  displayName: string;
  authenticated: boolean;
  planType: string | null;
  windows: ProviderQuotaWindow[];
  credits: ProviderQuotaCredits | null;
  /** Prepaid consumer balance in USD cents when the provider reports it. */
  prepaidBalanceCents: number | null;
  fetchedAt: number;
  error?: string;
}

export interface ProviderQuotasStatus {
  providers: ProviderQuota[];
  fetchedAt: number;
}

type QuotaModelRuntime = Pick<ModelRuntime, "getAuth">;
type FetchLike = typeof fetch;

export interface FetchProviderQuotasOptions {
  modelRuntime: QuotaModelRuntime;
  readCredential?: (providerId: string) => Credential | undefined;
  fetchImpl?: FetchLike;
  now?: () => number;
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

function clampPercent(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.max(0, Math.min(100, value));
}

function remainingFromUsed(usedPercent: number): number {
  return clampPercent(100 - usedPercent);
}

function parseMaybeJson(text: string): unknown {
  if (text.trim().length === 0) return null;
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

function extractAccountId(credential: Credential | undefined): string | null {
  const record = asRecord(credential);
  if (!record) return null;
  return readString(record.accountId);
}

function credentialType(credential: Credential | undefined): string | null {
  const record = asRecord(credential);
  if (!record) return null;
  return readString(record.type);
}

function emptyProvider(
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

function makeWindow(input: {
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
      makeWindow({
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
      makeWindow({
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

function truncateMessage(message: string): string {
  const compact = message.replace(/\s+/g, " ").trim();
  if (compact.length <= ERROR_MESSAGE_MAX_CHARS) return compact;
  return `${compact.slice(0, ERROR_MESSAGE_MAX_CHARS - 1)}…`;
}

function parseErrorMessage(
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

async function readResponseText(response: Response): Promise<string> {
  try {
    return await response.text();
  } catch {
    return "";
  }
}

async function resolveAccessToken(
  providerId: string,
  modelRuntime: QuotaModelRuntime,
  readCredential: (providerId: string) => Credential | undefined,
  now: number,
  displayName: string,
): Promise<{ token: string; credential: Credential } | { quota: ProviderQuota }> {
  const initialCredential = readCredential(providerId);
  if (!initialCredential) {
    return { quota: emptyProvider(providerId, displayName, now, false) };
  }

  let auth: AuthResult | undefined;
  try {
    auth = await modelRuntime.getAuth(providerId);
  } catch (error) {
    return {
      quota: emptyProvider(
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
      quota: emptyProvider(
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

export async function fetchCodexProviderQuota(
  options: FetchProviderQuotasOptions,
): Promise<ProviderQuota> {
  const now = options.now ?? Date.now;
  const readCredential = options.readCredential ?? readStoredCredential;
  const fetchImpl = options.fetchImpl ?? fetch;
  const fetchedAt = now();
  const displayName = "Codex";

  const resolved = await resolveAccessToken(
    CODEX_PROVIDER_ID,
    options.modelRuntime,
    readCredential,
    fetchedAt,
    displayName,
  );
  if ("quota" in resolved) return resolved.quota;

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
      return emptyProvider(
        CODEX_PROVIDER_ID,
        displayName,
        fetchedAt,
        true,
        parseErrorMessage(displayName, response.status, payload, text),
      );
    }

    const record = asRecord(payload);
    if (!record) {
      return emptyProvider(
        CODEX_PROVIDER_ID,
        displayName,
        fetchedAt,
        true,
        "Codex quota fetch failed: invalid response payload.",
      );
    }

    return {
      providerId: CODEX_PROVIDER_ID,
      displayName,
      authenticated: true,
      planType: readString(record.plan_type),
      windows: normalizeCodexRateLimitWindows(record.rate_limit),
      credits: normalizeCodexCredits(record.credits),
      prepaidBalanceCents: null,
      fetchedAt,
    };
  } catch (error) {
    return emptyProvider(
      CODEX_PROVIDER_ID,
      displayName,
      fetchedAt,
      true,
      `Codex quota fetch failed: ${safeErrorMessage(error)}`,
    );
  }
}

function readCentValue(value: unknown): number | null {
  const direct = readNumber(value);
  if (direct !== null) return Math.trunc(direct);
  const record = asRecord(value);
  if (!record) return null;
  const nested = readNumber(record.val);
  return nested === null ? null : Math.trunc(nested);
}

function parseIsoToUnixSeconds(value: string | null): number | null {
  if (!value) return null;
  const ms = Date.parse(value);
  if (!Number.isFinite(ms)) return null;
  return Math.floor(ms / 1000);
}

function periodWindowSeconds(startIso: string | null, endIso: string | null): number | null {
  const start = parseIsoToUnixSeconds(startIso);
  const end = parseIsoToUnixSeconds(endIso);
  if (start === null || end === null || end <= start) return null;
  return end - start;
}

function shortLabelForSeconds(seconds: number | null, fallback: string): string {
  if (seconds === null) return fallback;
  if (Math.abs(seconds - FIVE_HOUR_SECONDS) <= 60) return "5h";
  if (Math.abs(seconds - WEEKLY_SECONDS) <= 3600) return "7d";
  if (seconds >= 25 * 24 * 60 * 60 && seconds <= 32 * 24 * 60 * 60) return "30d";
  if (seconds % (24 * 60 * 60) === 0) {
    const days = Math.round(seconds / (24 * 60 * 60));
    return `${days}d`;
  }
  if (seconds % 3600 === 0) {
    return `${Math.round(seconds / 3600)}h`;
  }
  return fallback;
}

function normalizeXaiWindows(config: Record<string, unknown>): ProviderQuotaWindow[] {
  const windows: ProviderQuotaWindow[] = [];
  const usedPercent = readNumber(config.creditUsagePercent);
  const currentPeriod = asRecord(config.currentPeriod);
  const periodType = readString(currentPeriod?.type) ?? readString(currentPeriod?.["type"]);
  const periodStart = readString(currentPeriod?.start) ?? readString(config.billingPeriodStart);
  const periodEnd = readString(currentPeriod?.end) ?? readString(config.billingPeriodEnd);
  const limitWindowSeconds = periodWindowSeconds(periodStart, periodEnd);
  const resetAt = parseIsoToUnixSeconds(periodEnd);

  if (usedPercent !== null) {
    const isWeekly =
      (periodType?.toUpperCase().includes("WEEKLY") ?? false) ||
      (limitWindowSeconds !== null &&
        Math.abs(limitWindowSeconds - WEEKLY_SECONDS) <= 2 * 24 * 60 * 60);
    const isMonthly =
      (periodType?.toUpperCase().includes("MONTHLY") ?? false) ||
      (limitWindowSeconds !== null && limitWindowSeconds >= 25 * 24 * 60 * 60);
    const key = isMonthly && !isWeekly ? "monthly" : isWeekly ? "weekly" : "current";
    const title = key === "monthly" ? "Monthly" : key === "weekly" ? "Weekly" : "Current period";
    const fallbackShort = key === "monthly" ? "30d" : key === "weekly" ? "7d" : "left";

    windows.push(
      makeWindow({
        key,
        shortLabel: shortLabelForSeconds(limitWindowSeconds, fallbackShort),
        title,
        usedPercent,
        limitWindowSeconds,
        resetAt,
        includeWeekdayInReset: key !== "monthly",
      }),
    );
    return windows;
  }

  // Legacy monthly cents shape.
  const monthlyLimit = readCentValue(config.monthlyLimit);
  const used = readCentValue(config.used);
  if (monthlyLimit !== null && monthlyLimit > 0 && used !== null) {
    const legacyUsedPercent = clampPercent((used / monthlyLimit) * 100);
    windows.push(
      makeWindow({
        key: "monthly",
        shortLabel: "30d",
        title: "Monthly",
        usedPercent: legacyUsedPercent,
        limitWindowSeconds: periodWindowSeconds(
          readString(config.billingPeriodStart),
          readString(config.billingPeriodEnd),
        ),
        resetAt: parseIsoToUnixSeconds(readString(config.billingPeriodEnd)),
        includeWeekdayInReset: false,
      }),
    );
  }

  return windows;
}

export async function fetchXaiProviderQuota(
  options: FetchProviderQuotasOptions,
): Promise<ProviderQuota> {
  const now = options.now ?? Date.now;
  const readCredential = options.readCredential ?? readStoredCredential;
  const fetchImpl = options.fetchImpl ?? fetch;
  const fetchedAt = now();
  const displayName = "xAI";
  const credential = readCredential(XAI_PROVIDER_ID);

  if (!credential) {
    return emptyProvider(XAI_PROVIDER_ID, displayName, fetchedAt, false);
  }

  // Consumer credit quota is OAuth-backed (Grok Build / SuperGrok). API keys use a
  // different rate-limit surface and should not present empty consumer windows.
  if (credentialType(credential) === "api_key") {
    return emptyProvider(XAI_PROVIDER_ID, displayName, fetchedAt, false);
  }

  const resolved = await resolveAccessToken(
    XAI_PROVIDER_ID,
    options.modelRuntime,
    readCredential,
    fetchedAt,
    displayName,
  );
  if ("quota" in resolved) return resolved.quota;

  const headers = new Headers({
    Authorization: `Bearer ${resolved.token}`,
    Accept: "application/json",
    "User-Agent": "OppiServer/1.0",
    "X-XAI-Token-Auth": "xai-grok-cli",
  });

  try {
    // Billing is required; settings only enriches planType. Fetch independently so a
    // settings timeout/network failure cannot erase a successful billing snapshot.
    const billingResult = await fetchImpl(XAI_BILLING_URL, {
      method: "GET",
      headers,
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    })
      .then(async (response) => ({ response, text: await readResponseText(response) }))
      .catch((error: unknown) => ({ error }));

    if ("error" in billingResult) {
      return emptyProvider(
        XAI_PROVIDER_ID,
        displayName,
        fetchedAt,
        true,
        `xAI quota fetch failed: ${safeErrorMessage(billingResult.error)}`,
      );
    }

    const billingPayload = parseMaybeJson(billingResult.text);
    if (!billingResult.response.ok) {
      return emptyProvider(
        XAI_PROVIDER_ID,
        displayName,
        fetchedAt,
        true,
        parseErrorMessage(
          displayName,
          billingResult.response.status,
          billingPayload,
          billingResult.text,
        ),
      );
    }

    const billing = asRecord(billingPayload);
    const config = asRecord(billing?.config);
    if (!billing || !config) {
      return emptyProvider(
        XAI_PROVIDER_ID,
        displayName,
        fetchedAt,
        true,
        "xAI quota fetch failed: invalid response payload.",
      );
    }

    let planType: string | null = null;
    try {
      const settingsResponse = await fetchImpl(XAI_SETTINGS_URL, {
        method: "GET",
        headers,
        signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
      });
      const settingsText = await readResponseText(settingsResponse);
      if (settingsResponse.ok) {
        const settings = asRecord(parseMaybeJson(settingsText));
        planType =
          readString(settings?.subscription_tier_display) ??
          readString(settings?.subscription_tier) ??
          null;
      }
    } catch {
      // Optional enrichment only.
    }

    return {
      providerId: XAI_PROVIDER_ID,
      displayName,
      authenticated: true,
      planType,
      windows: normalizeXaiWindows(config),
      credits: null,
      prepaidBalanceCents: readCentValue(config.prepaidBalance),
      fetchedAt,
    };
  } catch (error) {
    return emptyProvider(
      XAI_PROVIDER_ID,
      displayName,
      fetchedAt,
      true,
      `xAI quota fetch failed: ${safeErrorMessage(error)}`,
    );
  }
}

export async function fetchProviderQuotas(
  options: FetchProviderQuotasOptions,
): Promise<ProviderQuotasStatus> {
  const now = options.now ?? Date.now;
  const fetchedAt = now();
  const [codex, xai] = await Promise.all([
    fetchCodexProviderQuota(options),
    fetchXaiProviderQuota(options),
  ]);

  return {
    providers: [codex, xai],
    fetchedAt,
  };
}

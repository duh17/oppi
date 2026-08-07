import type {
  FetchLike,
  FetchProviderQuotasOptions,
  ProviderQuota,
  ProviderQuotaAdapter,
  ProviderQuotaWindow,
} from "../types.js";
import {
  asRecord,
  clampPercent,
  credentialType,
  emptyProviderQuota,
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

const XAI_PROVIDER_ID = "xai";
// xAI flips ?format=credits between a creditUsagePercent shape and a metadata-only
// shape (both observed on 2026-07-31). Fetch credits + plain /v1/billing and prefer
// the credits percent window, falling back to plain monthly used/limit.
const XAI_BILLING_CREDITS_URL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";
const XAI_BILLING_PLAIN_URL = "https://cli-chat-proxy.grok.com/v1/billing";
const XAI_SETTINGS_URL = "https://cli-chat-proxy.grok.com/v1/settings";
const FIVE_HOUR_SECONDS = 5 * 60 * 60;
const WEEKLY_SECONDS = 7 * 24 * 60 * 60;

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
      makeProviderQuotaWindow({
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

  // Monthly cents shape (plain /v1/billing, and older credits payloads).
  const monthlyLimit = readCentValue(config.monthlyLimit);
  const used = readCentValue(config.used);
  if (monthlyLimit !== null && monthlyLimit > 0 && used !== null) {
    const legacyUsedPercent = clampPercent((used / monthlyLimit) * 100);
    windows.push(
      makeProviderQuotaWindow({
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

type XaiBillingFetchResult =
  | { kind: "network"; error: unknown }
  | { kind: "http"; status: number; payload: unknown; text: string }
  | { kind: "invalid" }
  | { kind: "ok"; config: Record<string, unknown> };

async function fetchXaiBillingConfig(
  fetchImpl: FetchLike,
  url: string,
  headers: Headers,
): Promise<XaiBillingFetchResult> {
  try {
    const response = await fetchImpl(url, {
      method: "GET",
      headers,
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
    const text = await readResponseText(response);
    const payload = parseMaybeJson(text);
    if (!response.ok) {
      return { kind: "http", status: response.status, payload, text };
    }
    const billing = asRecord(payload);
    const config = asRecord(billing?.config);
    if (!billing || !config) return { kind: "invalid" };
    return { kind: "ok", config };
  } catch (error) {
    return { kind: "network", error };
  }
}

function xaiBillingFailureQuota(
  fetchedAt: number,
  displayName: string,
  results: XaiBillingFetchResult[],
): ProviderQuota {
  const network = results.find((result) => result.kind === "network");
  if (network && network.kind === "network") {
    return emptyProviderQuota(
      XAI_PROVIDER_ID,
      displayName,
      fetchedAt,
      true,
      `xAI quota fetch failed: ${safeErrorMessage(network.error)}`,
    );
  }

  const http = results.find((result) => result.kind === "http");
  if (http && http.kind === "http") {
    return emptyProviderQuota(
      XAI_PROVIDER_ID,
      displayName,
      fetchedAt,
      true,
      parseUpstreamErrorMessage(displayName, http.status, http.payload, http.text),
    );
  }

  return emptyProviderQuota(
    XAI_PROVIDER_ID,
    displayName,
    fetchedAt,
    true,
    "xAI quota fetch failed: invalid response payload.",
  );
}

export async function fetchXaiProviderQuota(
  options: FetchProviderQuotasOptions,
): Promise<ProviderQuota> {
  const { readCredential, fetchImpl, fetchedAt } = resolveQuotaFetchDeps(options);
  const displayName = "xAI";
  const credential = readCredential(XAI_PROVIDER_ID);

  if (!credential) {
    return finalizeProviderQuota(
      emptyProviderQuota(XAI_PROVIDER_ID, displayName, fetchedAt, false),
    );
  }

  // Consumer credit quota is OAuth-backed (Grok Build / SuperGrok). API keys use a
  // different rate-limit surface and should not present empty consumer windows.
  if (credentialType(credential) === "api_key") {
    return finalizeProviderQuota(
      emptyProviderQuota(XAI_PROVIDER_ID, displayName, fetchedAt, false),
    );
  }

  const resolved = await resolveProviderAccessToken(
    XAI_PROVIDER_ID,
    options.modelRuntime,
    readCredential,
    fetchedAt,
    displayName,
  );
  if ("quota" in resolved) return finalizeProviderQuota(resolved.quota);

  const headers = new Headers({
    Authorization: `Bearer ${resolved.token}`,
    Accept: "application/json",
    "User-Agent": "OppiServer/1.0",
    "X-XAI-Token-Auth": "xai-grok-cli",
  });

  try {
    // Billing is required; settings only enriches planType. Fetch credits + plain
    // billing in parallel: credits carries the weekly percent when present, plain
    // carries monthly used/limit. A settings failure never erases a billing snapshot.
    const [creditsBilling, plainBilling] = await Promise.all([
      fetchXaiBillingConfig(fetchImpl, XAI_BILLING_CREDITS_URL, headers),
      fetchXaiBillingConfig(fetchImpl, XAI_BILLING_PLAIN_URL, headers),
    ]);

    const creditsConfig = creditsBilling.kind === "ok" ? creditsBilling.config : null;
    const plainConfig = plainBilling.kind === "ok" ? plainBilling.config : null;
    if (!creditsConfig && !plainConfig) {
      return finalizeProviderQuota(
        xaiBillingFailureQuota(fetchedAt, displayName, [creditsBilling, plainBilling]),
      );
    }

    const windowsFromCredits = creditsConfig ? normalizeXaiWindows(creditsConfig) : [];
    const windowsFromPlain = plainConfig ? normalizeXaiWindows(plainConfig) : [];
    // Prefer the credits percent window when present; otherwise use monthly cents.
    // Adapters may later emit multiple distinct keys; finalize sorts/dedupes them.
    const windows = windowsFromCredits.length > 0 ? windowsFromCredits : windowsFromPlain;
    const prepaidBalanceCents =
      readCentValue(creditsConfig?.prepaidBalance) ??
      readCentValue(plainConfig?.prepaidBalance) ??
      null;

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

    return finalizeProviderQuota({
      providerId: XAI_PROVIDER_ID,
      displayName,
      authenticated: true,
      planType,
      windows,
      credits: null,
      prepaidBalanceCents,
      fetchedAt,
    });
  } catch (error) {
    return finalizeProviderQuota(
      emptyProviderQuota(
        XAI_PROVIDER_ID,
        displayName,
        fetchedAt,
        true,
        `xAI quota fetch failed: ${safeErrorMessage(error)}`,
      ),
    );
  }
}

export const xaiProviderQuotaAdapter: ProviderQuotaAdapter = {
  providerId: XAI_PROVIDER_ID,
  displayName: "xAI",
  fetch: fetchXaiProviderQuota,
};

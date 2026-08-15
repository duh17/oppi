import { safeErrorMessage } from "../../log-utils.js";
import type {
  FetchProviderQuotasOptions,
  ProviderQuota,
  ProviderQuotaAdapter,
  ProviderQuotaWindow,
} from "../types.js";
import {
  asRecord,
  credentialType,
  emptyProviderQuota,
  finalizeProviderQuota,
  makeProviderQuotaWindow,
  parseIsoToUnixSeconds,
  parseMaybeJson,
  parseUpstreamErrorMessage,
  readNumber,
  readResponseText,
  readString,
  resolveQuotaFetchDeps,
  UPSTREAM_TIMEOUT_MS,
} from "../shared.js";

const OPENCODE_GO_PROVIDER_ID = "opencode-go";
const OPENCODE_GO_USAGE_URL = "https://opencode.ai/zen/go/v1/usage";
const FIVE_HOUR_SECONDS = 5 * 60 * 60;
const WEEKLY_SECONDS = 7 * 24 * 60 * 60;

// OpenCode Go reports percent-of-limit per window only (no dollar amounts, no
// window length). Plan limits are $12 / 5h, $30 / week, $60 / month (2026-08).
// Upstream currently pairs any non-"ok" status with percent 100, so mapping
// percent alone cannot hide a rate-limited window today.

interface OpenCodeGoWindowSpec {
  /** Field name in the upstream `usage` payload. */
  payloadKey: string;
  key: string;
  shortLabel: string;
  title: string;
  limitWindowSeconds: number | null;
  includeWeekdayInReset: boolean;
}

const WINDOW_SPECS: readonly OpenCodeGoWindowSpec[] = [
  {
    payloadKey: "rolling",
    key: "five_hour",
    shortLabel: "5h",
    title: "5-hour",
    limitWindowSeconds: FIVE_HOUR_SECONDS,
    includeWeekdayInReset: false,
  },
  {
    payloadKey: "weekly",
    key: "weekly",
    shortLabel: "7d",
    title: "Weekly",
    limitWindowSeconds: WEEKLY_SECONDS,
    includeWeekdayInReset: true,
  },
  {
    // Monthly resetsAt is calendar-anchored and the window length varies; leave
    // null so the aggregator sorts it after the shorter windows.
    payloadKey: "monthly",
    key: "monthly",
    shortLabel: "30d",
    title: "Monthly",
    limitWindowSeconds: null,
    includeWeekdayInReset: false,
  },
];

function normalizeOpenCodeGoWindows(usage: Record<string, unknown>): ProviderQuotaWindow[] {
  const windows: ProviderQuotaWindow[] = [];
  for (const spec of WINDOW_SPECS) {
    const window = asRecord(usage[spec.payloadKey]);
    if (!window) continue;
    const usedPercent = readNumber(window.percent);
    if (usedPercent === null) continue;
    windows.push(
      makeProviderQuotaWindow({
        key: spec.key,
        shortLabel: spec.shortLabel,
        title: spec.title,
        usedPercent,
        limitWindowSeconds: spec.limitWindowSeconds,
        resetAt: parseIsoToUnixSeconds(readString(window.resetsAt)),
        includeWeekdayInReset: spec.includeWeekdayInReset,
      }),
    );
  }
  return windows;
}

export async function fetchOpenCodeGoProviderQuota(
  options: FetchProviderQuotasOptions,
): Promise<ProviderQuota> {
  const { readCredential, fetchImpl, fetchedAt } = resolveQuotaFetchDeps(options);
  const displayName = "OpenCode Go";
  const credential = readCredential(OPENCODE_GO_PROVIDER_ID);

  if (!credential) {
    return finalizeProviderQuota(
      emptyProviderQuota(OPENCODE_GO_PROVIDER_ID, displayName, fetchedAt, false),
    );
  }

  // OpenCode Go ships an API key; no OAuth token refresh path exists.
  if (credentialType(credential) !== "api_key") {
    return finalizeProviderQuota(
      emptyProviderQuota(
        OPENCODE_GO_PROVIDER_ID,
        displayName,
        fetchedAt,
        true,
        "OpenCode Go quota fetch failed: unexpected credential type; API key expected.",
      ),
    );
  }
  const apiKey = readString(asRecord(credential)?.key);
  if (!apiKey) {
    return finalizeProviderQuota(
      emptyProviderQuota(
        OPENCODE_GO_PROVIDER_ID,
        displayName,
        fetchedAt,
        true,
        "OpenCode Go credential is present, but no API key is available.",
      ),
    );
  }

  try {
    const response = await fetchImpl(OPENCODE_GO_USAGE_URL, {
      method: "GET",
      headers: new Headers({
        Authorization: `Bearer ${apiKey}`,
        Accept: "application/json",
        "User-Agent": "OppiServer/1.0",
      }),
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
    const text = await readResponseText(response);
    const payload = parseMaybeJson(text);

    if (!response.ok) {
      // A valid key without an active Go plan also lands here (upstream 401).
      return finalizeProviderQuota(
        emptyProviderQuota(
          OPENCODE_GO_PROVIDER_ID,
          displayName,
          fetchedAt,
          true,
          parseUpstreamErrorMessage(displayName, response.status, payload, text),
        ),
      );
    }

    const usage = asRecord(asRecord(payload)?.usage);
    if (!usage) {
      return finalizeProviderQuota(
        emptyProviderQuota(
          OPENCODE_GO_PROVIDER_ID,
          displayName,
          fetchedAt,
          true,
          "OpenCode Go quota fetch failed: invalid response payload.",
        ),
      );
    }

    return finalizeProviderQuota({
      providerId: OPENCODE_GO_PROVIDER_ID,
      displayName,
      authenticated: true,
      planType: "Go",
      windows: normalizeOpenCodeGoWindows(usage),
      credits: null,
      prepaidBalanceCents: null,
      fetchedAt,
    });
  } catch (error) {
    return finalizeProviderQuota(
      emptyProviderQuota(
        OPENCODE_GO_PROVIDER_ID,
        displayName,
        fetchedAt,
        true,
        `OpenCode Go quota fetch failed: ${safeErrorMessage(error)}`,
      ),
    );
  }
}

export const openCodeGoProviderQuotaAdapter: ProviderQuotaAdapter = {
  providerId: OPENCODE_GO_PROVIDER_ID,
  displayName: "OpenCode Go",
  fetch: fetchOpenCodeGoProviderQuota,
};

import type { ModelAuth } from "@earendil-works/pi-ai";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { emptyProviderQuota, makeProviderQuotaWindow, UPSTREAM_TIMEOUT_MS } from "./shared.js";
import type { ProviderQuota, ProviderQuotaAdapter, ProviderQuotaWindow } from "./types.js";

/** A declaration emitted by a global Pi extension during provider registration. */
export const EXTENSION_PROVIDER_QUOTA_CHANNEL = "oppi:provider-quota:v1";

export interface ExtensionQuotaSource {
  providerId: string;
  displayName: string;
  fetch(context: {
    signal: AbortSignal;
    getAuth(): Promise<ModelAuth | undefined>;
  }): Promise<unknown>;
}

function record(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function boundedString(value: unknown, max = 80): string {
  if (typeof value !== "string" || !value.trim() || value.length > max) {
    throw new Error("Invalid extension quota response");
  }
  return value;
}

function integerOrNull(value: unknown): number | null {
  if (value === null || value === undefined) return null;
  if (!Number.isSafeInteger(value) || (value as number) < 0) {
    throw new Error("Invalid extension quota response");
  }
  return value as number;
}

function parseWindow(value: unknown): ProviderQuotaWindow {
  const window = record(value);
  if (
    !window ||
    typeof window.usedPercent !== "number" ||
    !Number.isFinite(window.usedPercent) ||
    window.usedPercent < 0 ||
    window.usedPercent > 100 ||
    typeof window.includeWeekdayInReset !== "boolean"
  ) {
    throw new Error("Invalid extension quota response");
  }
  return makeProviderQuotaWindow({
    key: boundedString(window.key, 48),
    shortLabel: boundedString(window.shortLabel, 24),
    title: boundedString(window.title),
    usedPercent: window.usedPercent,
    limitWindowSeconds: integerOrNull(window.limitWindowSeconds),
    resetAt: integerOrNull(window.resetAt),
    includeWeekdayInReset: window.includeWeekdayInReset,
  });
}

/** Rebuild the DTO from an extension's untrusted shape; never forward extra fields. */
export function parseExtensionQuota(
  value: unknown,
  source: ExtensionQuotaSource,
  fetchedAt: number,
): ProviderQuota {
  const result = record(value);
  const windows = result?.windows;
  if (
    !result ||
    typeof result.authenticated !== "boolean" ||
    !Array.isArray(windows) ||
    windows.length > 12
  ) {
    throw new Error("Invalid extension quota response");
  }
  const credits =
    result.credits === null || result.credits === undefined ? null : record(result.credits);
  if (
    (result.credits !== null && result.credits !== undefined && !credits) ||
    (credits && (typeof credits.hasCredits !== "boolean" || typeof credits.unlimited !== "boolean"))
  ) {
    throw new Error("Invalid extension quota response");
  }
  const balance = credits?.balance;
  const prepaidBalanceCents = integerOrNull(result.prepaidBalanceCents);
  if (result.error !== null && result.error !== undefined) boundedString(result.error, 200);
  return {
    providerId: source.providerId,
    displayName: source.displayName,
    authenticated: result.authenticated,
    planType:
      result.planType === null || result.planType === undefined
        ? null
        : boundedString(result.planType),
    windows: Array.from(windows, parseWindow),
    credits: credits
      ? {
          hasCredits: credits.hasCredits as boolean,
          unlimited: credits.unlimited as boolean,
          balance: balance === null || balance === undefined ? null : boundedString(balance, 80),
        }
      : null,
    prepaidBalanceCents,
    fetchedAt,
    ...(result.error === undefined || result.error === null
      ? {}
      : { error: "Extension quota unavailable" }),
  };
}

export function parseExtensionQuotaSource(value: unknown): ExtensionQuotaSource | undefined {
  try {
    const source = record(value);
    if (!source) return undefined;
    const providerId = source.providerId;
    const fetcher = source.fetch;
    const name = source.displayName;
    if (
      typeof providerId !== "string" ||
      !/^[a-z0-9][a-z0-9._-]{0,79}$/.test(providerId) ||
      typeof fetcher !== "function"
    )
      return undefined;
    return {
      providerId,
      displayName: name === undefined ? providerId : boundedString(name),
      fetch: fetcher.bind(value) as ExtensionQuotaSource["fetch"],
    };
  } catch {
    return undefined;
  }
}

function raceAbort<T>(promise: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) return Promise.reject(signal.reason);
  return new Promise<T>((resolve, reject) => {
    const abort = (): void => reject(signal.reason);
    signal.addEventListener("abort", abort, { once: true });
    promise.then(resolve, reject).finally(() => signal.removeEventListener("abort", abort));
  });
}

/** Bound a provider-owned callback even when it ignores the abort signal. */
export function extensionQuotaAdapter(
  source: ExtensionQuotaSource,
  modelRuntime: Pick<ModelRuntime, "getAuth" | "hasConfiguredAuth">,
  generationSignal: AbortSignal,
): ProviderQuotaAdapter {
  return {
    providerId: source.providerId,
    displayName: source.displayName,
    async fetch(options): Promise<ProviderQuota> {
      const now = (options.now ?? Date.now)();
      if (!modelRuntime.hasConfiguredAuth(source.providerId)) {
        return emptyProviderQuota(source.providerId, source.displayName, now);
      }
      const signal = AbortSignal.any([generationSignal, AbortSignal.timeout(UPSTREAM_TIMEOUT_MS)]);
      try {
        // Promise.resolve().then also converts synchronous callback throws to rejections.
        const result = await raceAbort(
          Promise.resolve().then(() => {
            signal.throwIfAborted();
            return source.fetch({
              signal,
              getAuth: async () =>
                (await modelRuntime.getAuth(source.providerId, { signal }))?.auth,
            });
          }),
          signal,
        );
        signal.throwIfAborted();
        return parseExtensionQuota(result, source, now);
      } catch {
        // Upstream errors can include raw credentials or request bodies. Never echo them.
        throw new Error("Extension quota request failed or returned invalid data");
      }
    },
  };
}

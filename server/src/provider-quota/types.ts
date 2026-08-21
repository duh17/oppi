import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { Credential } from "@earendil-works/pi-ai";

export type ProviderQuotaWindowKey = "five_hour" | "weekly" | "monthly" | string;
export type ProviderQuotaPacingSource = "snapshot" | "observed" | "unknown";
export type ProviderQuotaPacingStatus = "plenty" | "on_pace" | "conserve" | "unknown";

export interface ProviderQuotaPacing {
  source: ProviderQuotaPacingSource;
  status: ProviderQuotaPacingStatus;
  timeRemainingSeconds: number | null;
  supplyRatio: number | null;
  targetBurnPercentPerHour: number | null;
  recentBurnPercentPerHour: number | null;
  paceRatio: number | null;
  projectedExhaustionAt: number | null;
  projectedRemainingPercent: number | null;
}

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
  /** Server-derived snapshot pacing; absent only on pre-pacing inputs. */
  pacing?: ProviderQuotaPacing;
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

export type QuotaModelRuntime = Pick<ModelRuntime, "getAuth">;
export type FetchLike = typeof fetch;

export interface FetchProviderQuotasOptions {
  modelRuntime: QuotaModelRuntime;
  readCredential?: (providerId: string) => Credential | undefined;
  fetchImpl?: FetchLike;
  now?: () => number;
  /** Override the built-in adapter list (tests / future extension). */
  adapters?: readonly ProviderQuotaAdapter[];
}

/**
 * One upstream quota source.
 *
 * Add a provider:
 * 1. `adapters/<id>.ts` implementing this interface (use helpers from `shared.ts`)
 * 2. Append the adapter in `adapters/registry.ts`
 * 3. Match `providerId` to the model-catalog / provider-auth id so the Apple client joins automatically
 * 4. Emit one or more windows; the aggregator sorts shortest-first and the client picks compact vs detail
 *
 * Do not branch in Apple UI on provider names. Keep upstream parsing inside the adapter.
 */
export interface ProviderQuotaAdapter {
  readonly providerId: string;
  readonly displayName: string;
  fetch(options: FetchProviderQuotasOptions): Promise<ProviderQuota>;
}

/**
 * Pi-compatible cache-miss detection for live notices and session diagnostics.
 *
 * Live tracking starts with the first assistant response observed by the current
 * runtime, and notices remain gated by Pi's showCacheMissNotices setting.
 * Session diagnostics reconstruct cache re-billing from available history.
 */

/** Anthropic's default prompt-cache TTL, matching Pi's transcript notice. */
export const CACHE_MISS_TTL_MS = 5 * 60 * 1000;
const CACHE_MISS_NOISE_FLOOR_TOKENS = 1024;
const CACHE_MISS_NOTICE_TOKENS = 20_000;
const CACHE_MISS_NOTICE_COST = 0.1;

export type CacheMissReason = "model_switch" | "idle" | "other";

export interface CacheMissNotice {
  id: string;
  missedTokens: number;
  missedCost: number;
  idleMs: number;
  reason: CacheMissReason;
}

export interface CacheWasteTotals {
  missedTokens: number;
  missedCost: number;
  missCount: number;
}

export interface CacheMissTrackerState {
  previous?: {
    promptTokens: number;
    modelKey: string;
    timestamp: number;
    reportedCache: boolean;
  };
}

export interface CacheMissModelPriceSource {
  find(
    provider: string,
    modelId: string,
  ):
    | {
        cost: {
          cacheRead: number;
        };
      }
    | undefined;
}

interface CacheUsage {
  input: number;
  cacheRead: number;
  cacheWrite: number;
  cost: {
    input: number;
    cacheRead: number;
    cacheWrite: number;
  };
}

export interface CacheMissAssistantMessage {
  role: "assistant";
  provider: string;
  model: string;
  timestamp: number;
  stopReason?: string;
  usage: CacheUsage;
}

function finiteNumber(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

export function asCacheMissAssistantMessage(value: unknown): CacheMissAssistantMessage | undefined {
  if (!value || typeof value !== "object") return undefined;
  const message = value as Record<string, unknown>;
  if (message.role !== "assistant") return undefined;
  if (typeof message.provider !== "string" || typeof message.model !== "string") return undefined;
  if (typeof message.timestamp !== "number" || !Number.isFinite(message.timestamp))
    return undefined;
  if (!message.usage || typeof message.usage !== "object") return undefined;

  const usage = message.usage as Record<string, unknown>;
  const cost =
    usage.cost && typeof usage.cost === "object" ? (usage.cost as Record<string, unknown>) : {};

  return {
    role: "assistant",
    provider: message.provider,
    model: message.model,
    timestamp: message.timestamp,
    ...(typeof message.stopReason === "string" ? { stopReason: message.stopReason } : {}),
    usage: {
      input: finiteNumber(usage.input),
      cacheRead: finiteNumber(usage.cacheRead),
      cacheWrite: finiteNumber(usage.cacheWrite),
      cost: {
        input: finiteNumber(cost.input),
        cacheRead: finiteNumber(cost.cacheRead),
        cacheWrite: finiteNumber(cost.cacheWrite),
      },
    },
  };
}

function previousRequest(
  message: CacheMissAssistantMessage,
  reportedCache: boolean,
): CacheMissTrackerState["previous"] {
  const { usage } = message;
  const promptTokens = usage.input + usage.cacheRead + usage.cacheWrite;
  if (promptTokens <= 0) return undefined;
  return {
    promptTokens,
    modelKey: `${message.provider}/${message.model}`,
    timestamp: message.timestamp,
    reportedCache: reportedCache || usage.cacheRead + usage.cacheWrite > 0,
  };
}

function detectCacheMiss(
  tracker: CacheMissTrackerState,
  message: CacheMissAssistantMessage,
  models?: CacheMissModelPriceSource,
): (Omit<CacheMissNotice, "id" | "reason"> & { modelChanged: boolean }) | undefined {
  const previous = tracker.previous;
  const { usage } = message;
  const promptTokens = usage.input + usage.cacheRead + usage.cacheWrite;
  let miss: (Omit<CacheMissNotice, "id" | "reason"> & { modelChanged: boolean }) | undefined;

  if (
    previous &&
    promptTokens > 0 &&
    (usage.cacheRead + usage.cacheWrite > 0 || previous.reportedCache)
  ) {
    const missedTokens = Math.min(previous.promptTokens, promptTokens) - usage.cacheRead;
    if (missedTokens > CACHE_MISS_NOISE_FLOOR_TOKENS) {
      const paidTokens = usage.input + usage.cacheWrite;
      const paidPerToken =
        paidTokens > 0 ? (usage.cost.input + usage.cost.cacheWrite) / paidTokens : 0;
      const readPerToken =
        usage.cacheRead > 0
          ? usage.cost.cacheRead / usage.cacheRead
          : (models?.find(message.provider, message.model)?.cost.cacheRead ?? 0) / 1_000_000;
      miss = {
        missedTokens,
        missedCost: missedTokens * Math.max(0, paidPerToken - readPerToken),
        idleMs: Math.max(0, message.timestamp - previous.timestamp),
        modelChanged: `${message.provider}/${message.model}` !== previous.modelKey,
      };
    }
  }

  tracker.previous = previousRequest(message, previous?.reportedCache ?? false) ?? previous;
  return miss;
}

export function observeCacheMiss(
  tracker: CacheMissTrackerState,
  message: CacheMissAssistantMessage,
  models?: CacheMissModelPriceSource,
): CacheMissNotice | undefined {
  const miss = detectCacheMiss(tracker, message, models);
  if (
    !miss ||
    (miss.missedTokens < CACHE_MISS_NOTICE_TOKENS && miss.missedCost < CACHE_MISS_NOTICE_COST)
  ) {
    return undefined;
  }

  return {
    id: `cache-miss:${message.timestamp}:${message.provider}/${message.model}`,
    missedTokens: miss.missedTokens,
    missedCost: miss.missedCost,
    idleMs: miss.idleMs,
    reason: miss.modelChanged
      ? "model_switch"
      : miss.idleMs >= CACHE_MISS_TTL_MS
        ? "idle"
        : "other",
  };
}

/** Full-history cache re-billing, reset at intentional structural context changes. */
export function computeCacheWaste(
  entries: readonly unknown[],
  models?: CacheMissModelPriceSource,
): CacheWasteTotals {
  const tracker: CacheMissTrackerState = {};
  const totals: CacheWasteTotals = { missedTokens: 0, missedCost: 0, missCount: 0 };

  for (const value of entries) {
    if (!value || typeof value !== "object") continue;
    const entry = value as Record<string, unknown>;
    if (entry.type === "compaction" || entry.type === "branch_summary") {
      resetCacheMissTracker(tracker);
      continue;
    }
    if (entry.type !== "message") continue;

    const message = asCacheMissAssistantMessage(entry.message);
    if (!message) continue;
    const miss = detectCacheMiss(tracker, message, models);
    if (!miss) continue;
    totals.missedTokens += miss.missedTokens;
    totals.missedCost += miss.missedCost;
    totals.missCount += 1;
  }

  return totals;
}

export function resetCacheMissTracker(tracker: CacheMissTrackerState): void {
  tracker.previous = undefined;
}

export function navigationCreatedBranchSummary(value: unknown): boolean {
  if (!value || typeof value !== "object") return false;
  const summaryEntry = (value as Record<string, unknown>).summaryEntry;
  return typeof summaryEntry === "object" && summaryEntry !== null;
}

export function shouldDisplayCacheMissForMessage(message: CacheMissAssistantMessage): boolean {
  return message.stopReason !== "aborted" && message.stopReason !== "error";
}

export function formatCacheMissNotice(notice: CacheMissNotice): string {
  const tokens =
    notice.missedTokens < 10_000
      ? `${(notice.missedTokens / 1_000).toFixed(1)}k`
      : `${Math.round(notice.missedTokens / 1_000)}k`;
  const cost = notice.missedCost >= 0.01 ? ` (~$${notice.missedCost.toFixed(2)})` : "";
  const detail = `${tokens} tokens re-billed${cost}`;
  if (notice.reason === "model_switch") return `Cache miss after model switch: ${detail}`;
  if (notice.reason === "idle") {
    return `Cache miss after ${Math.round(notice.idleMs / 60_000)}m idle: ${detail}`;
  }
  return `Cache miss: ${detail}`;
}
